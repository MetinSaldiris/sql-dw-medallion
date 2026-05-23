/*
===============================================================================
Quality Checks: Silver Layer
===============================================================================
Run AFTER `EXEC silver.load_silver`. Each query is designed to return ZERO
rows when the data is clean. If a query returns rows, investigate the source
data and / or the silver.load_silver logic.

The DISTINCT-style standardization checks (marital_status, prd_line, gen,
cntry, maintenance) are not pass/fail — they let you eyeball the full set
of values to confirm normalization worked.
===============================================================================
*/

-- ====================================================================
-- silver.crm_cust_info
-- ====================================================================
-- PK uniqueness + non-null
SELECT cst_id, COUNT(*) AS dup_count
FROM silver.crm_cust_info
GROUP BY cst_id
HAVING COUNT(*) > 1 OR cst_id IS NULL;

-- No leading / trailing whitespace in cst_key
SELECT cst_key
FROM silver.crm_cust_info
WHERE cst_key != TRIM(cst_key);

-- Standardization: confirm only 'Single' / 'Married' / 'n/a'
SELECT DISTINCT cst_marital_status FROM silver.crm_cust_info;

-- Standardization: confirm only 'Female' / 'Male' / 'n/a'
SELECT DISTINCT cst_gndr FROM silver.crm_cust_info;

-- ====================================================================
-- silver.crm_prd_info
-- ====================================================================
-- PK uniqueness + non-null
SELECT prd_id, COUNT(*) AS dup_count
FROM silver.crm_prd_info
GROUP BY prd_id
HAVING COUNT(*) > 1 OR prd_id IS NULL;

-- No leading / trailing whitespace in prd_nm
SELECT prd_nm
FROM silver.crm_prd_info
WHERE prd_nm != TRIM(prd_nm);

-- No NULL or negative cost (NULL should have been ISNULL'd to 0)
SELECT prd_cost
FROM silver.crm_prd_info
WHERE prd_cost < 0 OR prd_cost IS NULL;

-- Standardization: only the four mapped lines + 'n/a'
SELECT DISTINCT prd_line FROM silver.crm_prd_info;

-- End-date must be on or after start-date (or NULL = current row)
SELECT *
FROM silver.crm_prd_info
WHERE prd_end_dt < prd_start_dt;

-- ====================================================================
-- silver.crm_sales_details
-- ====================================================================
-- Validate the underlying bronze INT dates would have parsed cleanly
SELECT NULLIF(sls_due_dt, 0) AS sls_due_dt
FROM bronze.crm_sales_details
WHERE sls_due_dt <= 0
   OR LEN(sls_due_dt) != 8
   OR sls_due_dt > 20500101
   OR sls_due_dt < 19000101;

-- Order date must precede ship/due dates
SELECT *
FROM silver.crm_sales_details
WHERE sls_order_dt > sls_ship_dt
   OR sls_order_dt > sls_due_dt;

-- Arithmetic: sales = quantity * price, all positive
SELECT DISTINCT sls_sales, sls_quantity, sls_price
FROM silver.crm_sales_details
WHERE sls_sales != sls_quantity * sls_price
   OR sls_sales    IS NULL
   OR sls_quantity IS NULL
   OR sls_price    IS NULL
   OR sls_sales    <= 0
   OR sls_quantity <= 0
   OR sls_price    <= 0
ORDER BY sls_sales, sls_quantity, sls_price;

-- ====================================================================
-- silver.erp_cust_az12
-- ====================================================================
-- Birthdates must fall in a sane window
SELECT DISTINCT bdate
FROM silver.erp_cust_az12
WHERE bdate < '1924-01-01'
   OR bdate > GETDATE();

-- Standardization: 'Female' / 'Male' / 'n/a'
SELECT DISTINCT gen FROM silver.erp_cust_az12;

-- ====================================================================
-- silver.erp_loc_a101
-- ====================================================================
-- Eyeball the country distribution
SELECT DISTINCT cntry
FROM silver.erp_loc_a101
ORDER BY cntry;

-- ====================================================================
-- silver.erp_px_cat_g1v2
-- ====================================================================
-- Whitespace check across all string columns
SELECT *
FROM silver.erp_px_cat_g1v2
WHERE cat         != TRIM(cat)
   OR subcat      != TRIM(subcat)
   OR maintenance != TRIM(maintenance);

-- Eyeball maintenance values
SELECT DISTINCT maintenance FROM silver.erp_px_cat_g1v2;
