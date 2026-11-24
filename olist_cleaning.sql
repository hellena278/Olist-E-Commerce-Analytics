select * from adworks_raw.customers;
select * from adworks_raw.orders;
select * from adworks_raw.order_items;
select * from adworks_raw.order_payments;
select * from adworks_raw.products;
select * from adworks_raw.product_category_name_translation;

--table 1 : cleaning product table
--Taking the raw products table, attaching English category names from the translation table, filling in missing (NULL) categories as 'uncategorized', and replacing messy 32-character IDs with clean P00001 IDs.

CREATE DATABASE IF NOT EXISTS adworks_staging;

DROP TABLE IF EXISTS adworks_staging.products;

CREATE TABLE adworks_staging.products AS
SELECT 
    CONCAT('P', LPAD(ROW_NUMBER() OVER (ORDER BY p.product_id), 5, '0')) AS product_key, -- Generate new product key // product_key=product_id
    p.product_id AS raw_product_id,
    CASE 
        WHEN p.product_category_name = 'pc_gamer' THEN 'pc_gamer'
        WHEN p.product_category_name = 'portateis_cozinha_e_preparadores_de_alimentos' THEN 'kitchen_portable_appliances'
        ELSE COALESCE(t.product_category_name_english, 'uncategorized')
    END AS category_name,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM adworks_raw.products p
LEFT JOIN adworks_raw.product_category_name_translation t
    ON p.product_category_name = t.product_category_name;

-- RESULT: The above SQL code creates a new database called `adworks_staging` and a new table called `products` within that database. The new table is populated with data from the `adworks_raw.products` table, with the following transformations:
-- 1. A new `product_key` is generated for each product, which is a concatenation of 'P' and a zero-padded row number.
-- 2. The `raw_product_id` is retained from the original table.
-- 3. The `category_name` is determined based on the original `product_category_name`, with specific mappings for 'pc_gamer' and 'portateis_cozinha_e_preparadores_de_alimentos', and a fallback to the English translation or 'uncategorized' if no translation is available.
-- 4. The product's weight, length, height, and width are retained from the original table.


--Table 2 : cleaning customers table
--Take raw customers table,create a cleaned and standardized customer table from the original raw customer data.

DROP TABLE IF EXISTS adworks_staging.customers;

CREATE TABLE adworks_staging.customers AS
SELECT 
    CONCAT('C', LPAD(ROW_NUMBER() OVER (ORDER BY c.customer_id), 6, '0')) AS customer_key,
    c.customer_id AS raw_customer_id,
    c.customer_unique_id AS raw_customer_unique_id,
    TRIM(LOWER(c.customer_city)) AS customer_city,
    UPPER(TRIM(c.customer_state)) AS customer_state
FROM adworks_raw.customers c
WHERE c.customer_id IS NOT NULL;

select * from adworks_staging.customers;

--RESULT: The above SQL code creates a new table called `customers` within the `adworks_staging` database. The new table is populated with data from the `adworks_raw.customers` table, with the following transformations:
-- 1. A new `customer_key` is generated for each customer, which is a concatenation of 'C' and a zero-padded row number.
-- 2. The `raw_customer_id` and `raw_customer_unique_id` are retained from the original table.
-- 3. The `customer_city` is standardized by trimming whitespace and converting to lowercase.
-- 4. The `customer_state` is standardized by trimming whitespace and converting to uppercase.

--TABLE 3 : create a structured transaction table by combining orders, order items, customers, and products.

DROP TABLE IF EXISTS adworks_staging.transactions;

CREATE TABLE adworks_staging.transactions AS
SELECT 
    CONCAT('O', LPAD(DENSE_RANK() OVER (ORDER BY o.order_purchase_timestamp, o.order_id), 6, '0')) AS order_key,
    oi.order_item_id AS order_line_item,
    c.customer_key,
    p.product_key,
    o.order_status,
    CAST(o.order_purchase_timestamp AS DATETIME) AS order_date,
    CAST(NULLIF(o.order_delivered_customer_date, '') AS DATETIME) AS delivered_date,
    CAST(NULLIF(o.order_estimated_delivery_date, '') AS DATETIME) AS estimated_date,
    ROUND(oi.price, 2) AS item_price,
    ROUND(oi.freight_value, 2) AS freight_value
FROM adworks_raw.order_items oi
INNER JOIN adworks_raw.orders o 
    ON oi.order_id = o.order_id
INNER JOIN adworks_staging.customers c 
    ON o.customer_id = c.raw_customer_id
INNER JOIN adworks_staging.products p 
    ON oi.product_id = p.raw_product_id;

select * from adworks_staging.transactions;

-- Total units sold across all valid (non-canceled) orders
SELECT COUNT(*) AS total_quantity_sold
FROM adworks_staging.transactions
WHERE order_status = 'canceled';

select round(sum (item_price), 2) as total_sales
from adworks_staging.transactions
where order_status != 'canceled';


--It combines raw order data with cleaned customer and product records to create a structured transaction table for sales analysis.
--RESULT: The above SQL code creates a new table called `transactions` within the `adworks_staging` database. The new table is populated with data from the `adworks_raw.orders`, `adworks_raw.order_items`, `adworks_staging.customers`, and `adworks_staging.products` tables, with the following transformations:
-- 1. A new `order_key` is generated for each order, which is a concatenation of 'O' and a zero-padded dense rank based on the order purchase timestamp and order ID.
-- 2. The `order_line_item` is retained from the original order items table.
-- 3. The `customer_key` and `product_key` are retrieved from the cleaned customers and products tables, respectively.
-- 4. The `order_status` is retained from the original orders table.
-- 5. The `order_date`, `delivered_date`, and `estimated_date` are cast to DATETIME format, with empty strings converted to NULL for the delivered and estimated dates.
-- 6. The `item_price` and `freight_value` are rounded to two decimal places for consistency in financial reporting.    


--Create Analysis Table

CREATE DATABASE IF NOT EXISTS adworks_analytics;

DROP TABLE IF EXISTS adworks_analytics.sales_data;

CREATE TABLE adworks_analytics.sales_data AS
SELECT 
    -- 1. Clean IDs
    t.order_key,
    t.order_line_item,
    t.customer_key,
    c.raw_customer_unique_id AS unique_customer_id,
    t.product_key,

    -- 2. Product & Customer Location
    p.category_name,
    c.customer_city,
    c.customer_state,

    -- 3. Order Status & Dates
    t.order_status,
    DATE(t.order_date) AS order_date,

    DATE(t.delivered_date) AS delivered_date,
    DATE(t.estimated_date) AS estimated_date,
    DATEDIFF(t.delivered_date, t.estimated_date) AS delivery_delay_days,

    -- 4. Quantity & Revenue
    1 AS quantity,
    ROUND(t.item_price, 2) AS revenue

FROM adworks_staging.transactions t
INNER JOIN adworks_staging.products p 
    ON t.product_key = p.product_key
INNER JOIN adworks_staging.customers c 
    ON t.customer_key = c.customer_key

WHERE t.order_key IS NOT NULL
  AND t.customer_key IS NOT NULL
  AND t.product_key IS NOT NULL
  AND t.order_date IS NOT NULL
  AND t.item_price > 0;

select * from adworks_analytics.sales_data;


--Query 1: Total Orders and Revenue (excluding canceled and unavailable orders)
select count(*) as total_orders, 
round(sum(revenue), 2) as total_revenue
from adworks_analytics.sales_data
where order_status NOT IN ('canceled', 'unavailable');

SELECT 
    COUNT(DISTINCT order_key) AS total_orders
FROM adworks_analytics.sales_data
WHERE order_status NOT IN ('canceled', 'unavailable');



