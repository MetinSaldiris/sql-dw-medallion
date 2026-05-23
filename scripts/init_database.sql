/*
===============================================================================
Initialize Database: Create Medallion Schemas
===============================================================================
Target     : Azure SQL Database
Server     : dw-server-2026.database.windows.net
Database   : free-sql-db-2741331

Script Purpose:
    Create the three Medallion-architecture schemas (bronze, silver, gold)
    if they do not already exist. Idempotent and safe to re-run.

Why schema-only (no CREATE DATABASE):
    Azure SQL Database does not support `USE master` / `CREATE DATABASE`
    from within a user database. The database is provisioned once from the
    Azure portal; this script handles everything inside it.

Medallion layers:
    bronze  - raw, as-ingested data from source systems (CRM + ERP CSVs).
    silver  - cleansed, conformed, deduplicated data.
    gold    - business-ready star-schema views for BI/analytics.
===============================================================================
*/

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze')
    EXEC('CREATE SCHEMA bronze');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC('CREATE SCHEMA silver');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC('CREATE SCHEMA gold');
GO
