/*
===============================================================================
Stored Procedure: bronze.load_bronze  (Source CSVs -> Bronze)
===============================================================================
Script Purpose:
    Truncate + BULK INSERT each of the six bronze tables from the source CSVs.

Azure SQL Database notes (important — this is different from on-prem):
    * BULK INSERT on Azure SQL cannot read the local filesystem. It must read
      from an Azure Blob Storage container via an EXTERNAL DATA SOURCE. The
      prerequisites below are one-time infrastructure setup.
    * If you prefer not to host the CSVs in Blob, alternatives are:
        - Azure Data Factory / Synapse pipelines (Copy activity).
        - Uploading CSVs directly via Azure Data Studio "Import Wizard" or
          the SSMS Import/Export wizard (what you most likely already did).
        - bcp / sqlcmd from a client machine.
    * Because the bronze tables are ALREADY loaded in your environment, this
      procedure is committed as reference / disaster-recovery documentation.
      Re-running it requires the Blob + credential setup below.

One-time prerequisites (run once per database, not every load):

    -- A master key is required to store the SAS credential inside the DB.
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong-password>';

    -- A scoped credential wrapping a SAS token with read access to the container.
    CREATE DATABASE SCOPED CREDENTIAL BlobCred
        WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
             SECRET   = '<sas-token-without-leading-question-mark>';

    -- A pointer to the container holding the CSVs.
    CREATE EXTERNAL DATA SOURCE BronzeSource
        WITH (TYPE       = BLOB_STORAGE,
              LOCATION   = 'https://<account>.blob.core.windows.net/<container>',
              CREDENTIAL = BlobCred);

Why TRUNCATE + INSERT (vs MERGE / incremental):
    Bronze is a full-refresh landing zone. Idempotent, simple, and guarantees
    that silver sees a complete snapshot every run.

Usage:
    EXEC bronze.load_bronze;
===============================================================================
*/

CREATE OR ALTER PROCEDURE bronze.load_bronze AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time       DATETIME,
            @end_time         DATETIME,
            @batch_start_time DATETIME,
            @batch_end_time   DATETIME;

    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '================================================';
        PRINT 'Loading Bronze Layer';
        PRINT '================================================';

        PRINT '------------------------------------------------';
        PRINT 'Loading CRM Tables';
        PRINT '------------------------------------------------';

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.crm_cust_info';
        TRUNCATE TABLE bronze.crm_cust_info;
        PRINT '>> Inserting Data Into: bronze.crm_cust_info';
        BULK INSERT bronze.crm_cust_info
        FROM 'source_crm/cust_info.csv'
        WITH (DATA_SOURCE     = 'BronzeSource',
              FIRSTROW        = 2,
              FIELDTERMINATOR = ',',
              ROWTERMINATOR   = '0x0a',
              TABLOCK);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.crm_prd_info';
        TRUNCATE TABLE bronze.crm_prd_info;
        PRINT '>> Inserting Data Into: bronze.crm_prd_info';
        BULK INSERT bronze.crm_prd_info
        FROM 'source_crm/prd_info.csv'
        WITH (DATA_SOURCE     = 'BronzeSource',
              FIRSTROW        = 2,
              FIELDTERMINATOR = ',',
              ROWTERMINATOR   = '0x0a',
              TABLOCK);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.crm_sales_details';
        TRUNCATE TABLE bronze.crm_sales_details;
        PRINT '>> Inserting Data Into: bronze.crm_sales_details';
        BULK INSERT bronze.crm_sales_details
        FROM 'source_crm/sales_details.csv'
        WITH (DATA_SOURCE     = 'BronzeSource',
              FIRSTROW        = 2,
              FIELDTERMINATOR = ',',
              ROWTERMINATOR   = '0x0a',
              TABLOCK);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        PRINT '------------------------------------------------';
        PRINT 'Loading ERP Tables';
        PRINT '------------------------------------------------';

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.erp_loc_a101';
        TRUNCATE TABLE bronze.erp_loc_a101;
        PRINT '>> Inserting Data Into: bronze.erp_loc_a101';
        BULK INSERT bronze.erp_loc_a101
        FROM 'source_erp/LOC_A101.csv'
        WITH (DATA_SOURCE     = 'BronzeSource',
              FIRSTROW        = 2,
              FIELDTERMINATOR = ',',
              ROWTERMINATOR   = '0x0a',
              TABLOCK);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.erp_cust_az12';
        TRUNCATE TABLE bronze.erp_cust_az12;
        PRINT '>> Inserting Data Into: bronze.erp_cust_az12';
        BULK INSERT bronze.erp_cust_az12
        FROM 'source_erp/CUST_AZ12.csv'
        WITH (DATA_SOURCE     = 'BronzeSource',
              FIRSTROW        = 2,
              FIELDTERMINATOR = ',',
              ROWTERMINATOR   = '0x0a',
              TABLOCK);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.erp_px_cat_g1v2';
        TRUNCATE TABLE bronze.erp_px_cat_g1v2;
        PRINT '>> Inserting Data Into: bronze.erp_px_cat_g1v2';
        BULK INSERT bronze.erp_px_cat_g1v2
        FROM 'source_erp/PX_CAT_G1V2.csv'
        WITH (DATA_SOURCE     = 'BronzeSource',
              FIRSTROW        = 2,
              FIELDTERMINATOR = ',',
              ROWTERMINATOR   = '0x0a',
              TABLOCK);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '==========================================';
        PRINT 'Loading Bronze Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';
    END TRY
    BEGIN CATCH
        PRINT '==========================================';
        PRINT 'ERROR OCCURRED DURING LOADING BRONZE LAYER';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error State  : ' + CAST(ERROR_STATE()  AS NVARCHAR);
        PRINT '==========================================';
    END CATCH
END;
GO
