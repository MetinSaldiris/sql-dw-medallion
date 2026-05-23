/*
===============================================================================
Quality Checks: Gold Layer
===============================================================================
Star-schema integrity checks. All queries should return ZERO rows when the
model is sound:
    * Surrogate keys must be unique inside each dimension.
    * Every fact row must resolve to a real customer + product (no orphan
      facts).
===============================================================================
*/

-- ====================================================================
-- gold.dim_customers
-- ====================================================================
-- customer_key must be unique
SELECT customer_key, COUNT(*) AS duplicate_count
FROM gold.dim_customers
GROUP BY customer_key
HAVING COUNT(*) > 1;

-- ====================================================================
-- gold.dim_products
-- ====================================================================
-- product_key must be unique
SELECT product_key, COUNT(*) AS duplicate_count
FROM gold.dim_products
GROUP BY product_key
HAVING COUNT(*) > 1;

-- ====================================================================
-- gold.fact_sales <-> dim referential integrity
-- ====================================================================
-- Every fact row should join to a customer AND a product.
-- Any rows returned here are orphan facts (broken keys upstream).
SELECT *
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c ON c.customer_key = f.customer_key
LEFT JOIN gold.dim_products  p ON p.product_key  = f.product_key
WHERE p.product_key IS NULL
   OR c.customer_key IS NULL;
