/*
===============================================================================
DDL Script: Create Gold Views (Star Schema)
===============================================================================
Script Purpose:
    The gold layer exposes business-ready data in Kimball star-schema form:
      * dim_customers  - conformed customer dimension.
      * dim_products   - conformed product dimension (current products only).
      * fact_sales     - sales transactions joined to the two dimensions by
                         surrogate keys.

Why views (not tables):
    * Always fresh: re-running silver.load_silver propagates instantly.
    * No extra storage (relevant on the Azure SQL free tier).
    * Simple to reason about while the model is still evolving.
    If/when performance matters, convert to tables + a gold.load_gold proc,
    or add indexed views.

Surrogate keys:
    ROW_NUMBER() generates dimensionless integer keys (customer_key,
    product_key). The fact joins on these, not on source natural keys.
    This insulates the model from upstream re-keying and makes slowly
    changing dimensions (SCD2) possible later without schema churn.
===============================================================================
*/

-- =============================================================================
-- Dimension: gold.dim_customers
--   Joins CRM customer (master) + ERP customer (birthdate, gender fallback)
--   + ERP location (country). CRM gender is authoritative; we only fall back
--   to ERP's gender when CRM says 'n/a' (we normalized it that way in silver).
-- =============================================================================
IF OBJECT_ID('gold.dim_customers', 'V') IS NOT NULL
    DROP VIEW gold.dim_customers;
GO

CREATE VIEW gold.dim_customers AS
SELECT
    ROW_NUMBER() OVER (ORDER BY ci.cst_id) AS customer_key,
    ci.cst_id                              AS customer_id,
    ci.cst_key                             AS customer_number,
    ci.cst_firstname                       AS first_name,
    ci.cst_lastname                        AS last_name,
    la.cntry                               AS country,
    ci.cst_marital_status                  AS marital_status,
    CASE
        WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr
        ELSE COALESCE(ca.gen, 'n/a')
    END                                    AS gender,
    ca.bdate                               AS birthdate,
    ci.cst_create_date                     AS create_date
FROM silver.crm_cust_info ci
LEFT JOIN silver.erp_cust_az12 ca
    ON ci.cst_key = ca.cid
LEFT JOIN silver.erp_loc_a101 la
    ON ci.cst_key = la.cid;
GO

-- =============================================================================
-- Dimension: gold.dim_products
--   Joins CRM product (master) + ERP category (cat/subcat/maintenance).
--   Filters prd_end_dt IS NULL to return only CURRENT product versions.
--   Silver's LEAD-based end-date trick leaves the active version open, so
--   this filter cleanly drops history.
-- =============================================================================
IF OBJECT_ID('gold.dim_products', 'V') IS NOT NULL
    DROP VIEW gold.dim_products;
GO

CREATE VIEW gold.dim_products AS
SELECT
    ROW_NUMBER() OVER (ORDER BY pn.prd_start_dt, pn.prd_key) AS product_key,
    pn.prd_id        AS product_id,
    pn.prd_key       AS product_number,
    pn.prd_nm        AS product_name,
    pn.cat_id        AS category_id,
    pc.cat           AS category,
    pc.subcat        AS subcategory,
    pc.maintenance   AS maintenance,
    pn.prd_cost      AS cost,
    pn.prd_line      AS product_line,
    pn.prd_start_dt  AS start_date
FROM silver.crm_prd_info pn
LEFT JOIN silver.erp_px_cat_g1v2 pc
    ON pn.cat_id = pc.id
WHERE pn.prd_end_dt IS NULL;
GO

-- =============================================================================
-- Fact: gold.fact_sales
--   One row per sales-order line. Joins resolve source natural keys
--   (sls_prd_key, sls_cust_id) to dim surrogate keys (product_key,
--   customer_key) so the BI model only ever joins on integers.
-- =============================================================================
IF OBJECT_ID('gold.fact_sales', 'V') IS NOT NULL
    DROP VIEW gold.fact_sales;
GO

CREATE VIEW gold.fact_sales AS
SELECT
    sd.sls_ord_num  AS order_number,
    pr.product_key  AS product_key,
    cu.customer_key AS customer_key,
    sd.sls_order_dt AS order_date,
    sd.sls_ship_dt  AS shipping_date,
    sd.sls_due_dt   AS due_date,
    sd.sls_sales    AS sales_amount,
    sd.sls_quantity AS quantity,
    sd.sls_price    AS price
FROM silver.crm_sales_details sd
LEFT JOIN gold.dim_products pr
    ON sd.sls_prd_key = pr.product_number
LEFT JOIN gold.dim_customers cu
    ON sd.sls_cust_id = cu.customer_id;
GO
