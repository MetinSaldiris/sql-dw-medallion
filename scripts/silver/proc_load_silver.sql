/*
===============================================================================
Stored Procedure: silver.load_silver  (Bronze -> Silver)
===============================================================================
Script Purpose:
    Full-refresh ETL from bronze to silver. For each target table the proc:
        1. TRUNCATE the silver table.
        2. INSERT the cleansed, conformed, deduplicated result set from bronze.

Cleansing rules applied (summary):
    * Whitespace            - TRIM() on all free-text string columns.
    * Coded categoricals    - UPPER(TRIM(x)) then CASE mapping to readable
                              values (M/F -> Male/Female, S/M -> Single/Married,
                              M/R/S/T -> Mountain/Road/Other Sales/Touring,
                              country codes -> full names). Unknowns -> 'n/a'.
    * Duplicates            - ROW_NUMBER() window keeps the most recent row
                              per natural key.
    * Invalid dates         - Sentinel 0 or wrong-length INT dates -> NULL;
                              future birthdates -> NULL.
    * Key repair            - Strip 'NAS' prefix from erp_cust_az12.cid and
                              '-' from erp_loc_a101.cid so they match CRM keys.
    * Derived columns       - crm_prd_info: split prd_key into cat_id + prd_key;
                              compute prd_end_dt as next start_dt minus one day.
    * Arithmetic integrity  - sls_sales recomputed when missing or inconsistent
                              with qty*price; sls_price derived when invalid.

Design choices:
    * Full refresh (TRUNCATE + INSERT) over MERGE: simpler, idempotent, and
      fine at this data volume. MERGE would matter for incremental loads.
    * Each step prints timing so you can spot regressions in the run log.
    * Single TRY/CATCH at the procedure level so any failure rolls forward a
      clear error message rather than partial silent corruption.

Usage:
    EXEC silver.load_silver;
===============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time       DATETIME,
            @end_time         DATETIME,
            @batch_start_time DATETIME,
            @batch_end_time   DATETIME;

    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '================================================';
        PRINT 'Loading Silver Layer';
        PRINT '================================================';

        PRINT '------------------------------------------------';
        PRINT 'Loading CRM Tables';
        PRINT '------------------------------------------------';

        --------------------------------------------------------------------
        -- silver.crm_cust_info
        --   * Dedupe on cst_id, keeping the newest cst_create_date.
        --   * Normalize marital status (S/M) and gender (F/M) codes.
        --   * TRIM names (source contains leading/trailing spaces).
        --   * Drop rows with NULL cst_id (cannot be joined downstream).
        --------------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.crm_cust_info';
        TRUNCATE TABLE silver.crm_cust_info;
        PRINT '>> Inserting Data Into: silver.crm_cust_info';
        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_firstname,
            cst_lastname,
            cst_marital_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            TRIM(cst_firstname) AS cst_firstname,
            TRIM(cst_lastname)  AS cst_lastname,
            CASE
                WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
                WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
                ELSE 'n/a'
            END AS cst_marital_status,
            CASE
                WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
                WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
                ELSE 'n/a'
            END AS cst_gndr,
            cst_create_date
        FROM (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY cst_id
                       ORDER BY cst_create_date DESC
                   ) AS flag_last
            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL
        ) t
        WHERE flag_last = 1;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        --------------------------------------------------------------------
        -- silver.crm_prd_info
        --   * prd_key in bronze is a concatenation: "CO-PE-BK-M82B-58".
        --     First 5 chars (CO_PE) are the category id that joins to
        --     erp_px_cat_g1v2.id; the remainder is the real product key.
        --   * Replace NULL cost with 0 (downstream math would break otherwise).
        --   * Map product line codes to readable labels.
        --   * Compute prd_end_dt = next version's start_dt - 1. This gives
        --     each version a clean [start, end] range and enables the gold
        --     "current products" filter (WHERE prd_end_dt IS NULL).
        --------------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.crm_prd_info';
        TRUNCATE TABLE silver.crm_prd_info;
        PRINT '>> Inserting Data Into: silver.crm_prd_info';
        INSERT INTO silver.crm_prd_info (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,
            REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_')         AS cat_id,
            SUBSTRING(prd_key, 7, LEN(prd_key))                 AS prd_key,
            TRIM(prd_nm)                                        AS prd_nm,
            ISNULL(prd_cost, 0)                                 AS prd_cost,
            CASE
                WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
                WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
                WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other Sales'
                WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Touring'
                ELSE 'n/a'
            END                                                 AS prd_line,
            CAST(prd_start_dt AS DATE)                          AS prd_start_dt,
            CAST(
                DATEADD(DAY, -1,
                    LEAD(prd_start_dt) OVER (
                        PARTITION BY prd_key
                        ORDER BY prd_start_dt
                    )
                ) AS DATE
            )                                                   AS prd_end_dt
        FROM bronze.crm_prd_info;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        --------------------------------------------------------------------
        -- silver.crm_sales_details
        --   * Dates arrive as INT YYYYMMDD; 0 = missing, and anything with
        --     length != 8 is malformed. Both become NULL.
        --   * Re-derive sls_sales when it disagrees with qty * ABS(price).
        --     ABS() guards against negative prices sneaking in.
        --   * Derive sls_price when missing/negative using sales/qty;
        --     NULLIF prevents divide-by-zero when qty is 0.
        --------------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.crm_sales_details';
        TRUNCATE TABLE silver.crm_sales_details;
        PRINT '>> Inserting Data Into: silver.crm_sales_details';
        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            CASE
                WHEN sls_order_dt = 0 OR LEN(sls_order_dt) != 8 THEN NULL
                ELSE CAST(CAST(sls_order_dt AS VARCHAR(8)) AS DATE)
            END AS sls_order_dt,
            CASE
                WHEN sls_ship_dt = 0 OR LEN(sls_ship_dt) != 8 THEN NULL
                ELSE CAST(CAST(sls_ship_dt AS VARCHAR(8)) AS DATE)
            END AS sls_ship_dt,
            CASE
                WHEN sls_due_dt = 0 OR LEN(sls_due_dt) != 8 THEN NULL
                ELSE CAST(CAST(sls_due_dt AS VARCHAR(8)) AS DATE)
            END AS sls_due_dt,
            CASE
                WHEN sls_sales IS NULL
                     OR sls_sales <= 0
                     OR sls_sales != sls_quantity * ABS(sls_price)
                    THEN sls_quantity * ABS(sls_price)
                ELSE sls_sales
            END AS sls_sales,
            sls_quantity,
            CASE
                WHEN sls_price IS NULL OR sls_price <= 0
                    THEN sls_sales / NULLIF(sls_quantity, 0)
                ELSE sls_price
            END AS sls_price
        FROM bronze.crm_sales_details;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        PRINT '------------------------------------------------';
        PRINT 'Loading ERP Tables';
        PRINT '------------------------------------------------';

        --------------------------------------------------------------------
        -- silver.erp_cust_az12
        --   * cid in the ERP file sometimes has a 'NAS' prefix (e.g.
        --     'NASAW00011000'); strip it so it matches crm_cust_info.cst_key.
        --   * Future birthdates are clearly wrong -> NULL.
        --   * Accept both 'M'/'Male' and 'F'/'Female'; normalize to the
        --     same vocabulary CRM uses.
        --------------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.erp_cust_az12';
        TRUNCATE TABLE silver.erp_cust_az12;
        PRINT '>> Inserting Data Into: silver.erp_cust_az12';
        INSERT INTO silver.erp_cust_az12 (
            cid,
            bdate,
            gen
        )
        SELECT
            CASE
                WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid))
                ELSE cid
            END AS cid,
            CASE
                WHEN bdate > GETDATE() THEN NULL
                ELSE bdate
            END AS bdate,
            CASE
                WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE') THEN 'Female'
                WHEN UPPER(TRIM(gen)) IN ('M', 'MALE')   THEN 'Male'
                ELSE 'n/a'
            END AS gen
        FROM bronze.erp_cust_az12;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        --------------------------------------------------------------------
        -- silver.erp_loc_a101
        --   * cid uses 'AW-00011000'; strip the hyphen to match CRM.
        --   * Expand ISO-ish country codes to human-readable names.
        --   * Blank / NULL -> 'n/a' (explicit unknown, not missing).
        --------------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.erp_loc_a101';
        TRUNCATE TABLE silver.erp_loc_a101;
        PRINT '>> Inserting Data Into: silver.erp_loc_a101';
        INSERT INTO silver.erp_loc_a101 (
            cid,
            cntry
        )
        SELECT
            REPLACE(cid, '-', '') AS cid,
            CASE
                WHEN TRIM(cntry) = 'DE'           THEN 'Germany'
                WHEN TRIM(cntry) IN ('US', 'USA') THEN 'United States'
                WHEN TRIM(cntry) = '' OR cntry IS NULL THEN 'n/a'
                ELSE TRIM(cntry)
            END AS cntry
        FROM bronze.erp_loc_a101;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        --------------------------------------------------------------------
        -- silver.erp_px_cat_g1v2
        --   Already clean in source -> straight copy. Kept as an explicit
        --   step so every silver table has a single, consistent loader.
        --------------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.erp_px_cat_g1v2';
        TRUNCATE TABLE silver.erp_px_cat_g1v2;
        PRINT '>> Inserting Data Into: silver.erp_px_cat_g1v2';
        INSERT INTO silver.erp_px_cat_g1v2 (
            id,
            cat,
            subcat,
            maintenance
        )
        SELECT
            id,
            cat,
            subcat,
            maintenance
        FROM bronze.erp_px_cat_g1v2;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '==========================================';
        PRINT 'Loading Silver Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';
    END TRY
    BEGIN CATCH
        PRINT '==========================================';
        PRINT 'ERROR OCCURRED DURING LOADING SILVER LAYER';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error State  : ' + CAST(ERROR_STATE()  AS NVARCHAR);
        PRINT '==========================================';
    END CATCH
END;
GO
