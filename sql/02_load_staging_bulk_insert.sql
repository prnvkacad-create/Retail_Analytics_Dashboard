/* =====================================================================
   02_load_staging_bulk_insert.sql
   Purpose : Create the stg.* landing tables (every column is text) and
             BULK INSERT the nine CSV files into them untouched.
   Why     : Loading raw text first means a bad value can never abort the
             file load; typing and cleaning happen in script 03.

   BEFORE YOU RUN
   1. Copy the CSVs into one folder that the SQL Server SERVICE ACCOUNT
      can read (e.g. C:\blinkit\data\) and set @DataFolder below.
   2. Files are CRLF + comma delimited. blinkit_customers.csv and
      blinkit_products.csv are UTF-8 and contain quoted text with commas
      and (for addresses) embedded line breaks - hence FORMAT = 'CSV'.
      If your copy has LF-only line endings, add ROWTERMINATOR = '0x0a'
      inside usp_bulk_load.
   ===================================================================== */
USE BlinkitAnalytics;
GO

DROP TABLE IF EXISTS stg.customers, stg.products, stg.orders, stg.order_items,
                     stg.customer_feedback, stg.delivery_performance,
                     stg.marketing_performance, stg.inventory, stg.inventory_new;
GO

CREATE TABLE stg.customers (
    customer_id NVARCHAR(500), customer_name NVARCHAR(500), email NVARCHAR(500), phone NVARCHAR(500),
    address NVARCHAR(1000), area NVARCHAR(500), pincode NVARCHAR(500), registration_date NVARCHAR(500),
    customer_segment NVARCHAR(500), total_orders NVARCHAR(500), avg_order_value NVARCHAR(500));

CREATE TABLE stg.products (
    product_id NVARCHAR(500), product_name NVARCHAR(500), category NVARCHAR(500), brand NVARCHAR(500),
    price NVARCHAR(500), mrp NVARCHAR(500), margin_percentage NVARCHAR(500), shelf_life_days NVARCHAR(500),
    min_stock_level NVARCHAR(500), max_stock_level NVARCHAR(500));

CREATE TABLE stg.orders (
    order_id NVARCHAR(500), customer_id NVARCHAR(500), order_date NVARCHAR(500),
    promised_delivery_time NVARCHAR(500), actual_delivery_time NVARCHAR(500), delivery_status NVARCHAR(500),
    order_total NVARCHAR(500), payment_method NVARCHAR(500), delivery_partner_id NVARCHAR(500), store_id NVARCHAR(500));

CREATE TABLE stg.order_items (
    order_id NVARCHAR(500), product_id NVARCHAR(500), quantity NVARCHAR(500), unit_price NVARCHAR(500));

CREATE TABLE stg.customer_feedback (
    feedback_id NVARCHAR(500), order_id NVARCHAR(500), customer_id NVARCHAR(500), rating NVARCHAR(500),
    feedback_text NVARCHAR(1000), feedback_category NVARCHAR(500), sentiment NVARCHAR(500), feedback_date NVARCHAR(500));

CREATE TABLE stg.delivery_performance (
    order_id NVARCHAR(500), delivery_partner_id NVARCHAR(500), promised_time NVARCHAR(500), actual_time NVARCHAR(500),
    delivery_time_minutes NVARCHAR(500), distance_km NVARCHAR(500), delivery_status NVARCHAR(500), reasons_if_delayed NVARCHAR(500));

CREATE TABLE stg.marketing_performance (
    campaign_id NVARCHAR(500), campaign_name NVARCHAR(500), [date] NVARCHAR(500), target_audience NVARCHAR(500),
    channel NVARCHAR(500), impressions NVARCHAR(500), clicks NVARCHAR(500), conversions NVARCHAR(500),
    spend NVARCHAR(500), revenue_generated NVARCHAR(500), roas NVARCHAR(500));

CREATE TABLE stg.inventory (                -- dates arrive as dd-mm-yyyy
    product_id NVARCHAR(500), [date] NVARCHAR(500), stock_received NVARCHAR(500), damaged_stock NVARCHAR(500));

CREATE TABLE stg.inventory_new (            -- dates arrive as Mon-yy (e.g. Mar-23)
    product_id NVARCHAR(500), [date] NVARCHAR(500), stock_received NVARCHAR(500), damaged_stock NVARCHAR(500));
GO

/* ---------- Small helper so each load is one readable line ---------- */
CREATE OR ALTER PROCEDURE stg.usp_bulk_load
    @target_table NVARCHAR(256),     -- e.g. N'stg.orders'
    @data_folder  NVARCHAR(400),     -- e.g. N'C:\blinkit\data\'
    @file_name    NVARCHAR(100)      -- e.g. N'blinkit_orders.csv'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @file_path NVARCHAR(500) = @data_folder + @file_name;
    DECLARE @sql NVARCHAR(MAX) =
        N'BULK INSERT ' + @target_table + N'
          FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
          WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','',
                CODEPAGE = ''65001'', KEEPNULLS, TABLOCK);';
    EXEC sys.sp_executesql @sql;
    PRINT CONCAT(@target_table, ' loaded from ', @file_path);
END;
GO

/* ---------- Load all files (edit the folder path) ---------- */
DECLARE @DataFolder NVARCHAR(400) = N'C:\blinkit\data\';   -- <<< CHANGE ME (keep trailing backslash)

TRUNCATE TABLE stg.customers;             EXEC stg.usp_bulk_load N'stg.customers',             @DataFolder, N'blinkit_customers.csv';
TRUNCATE TABLE stg.products;              EXEC stg.usp_bulk_load N'stg.products',              @DataFolder, N'blinkit_products.csv';
TRUNCATE TABLE stg.orders;                EXEC stg.usp_bulk_load N'stg.orders',                @DataFolder, N'blinkit_orders.csv';
TRUNCATE TABLE stg.order_items;           EXEC stg.usp_bulk_load N'stg.order_items',           @DataFolder, N'blinkit_order_items.csv';
TRUNCATE TABLE stg.customer_feedback;     EXEC stg.usp_bulk_load N'stg.customer_feedback',     @DataFolder, N'blinkit_customer_feedback.csv';
TRUNCATE TABLE stg.delivery_performance;  EXEC stg.usp_bulk_load N'stg.delivery_performance',  @DataFolder, N'blinkit_delivery_performance.csv';
TRUNCATE TABLE stg.marketing_performance; EXEC stg.usp_bulk_load N'stg.marketing_performance', @DataFolder, N'blinkit_marketing_performance.csv';
TRUNCATE TABLE stg.inventory;             EXEC stg.usp_bulk_load N'stg.inventory',             @DataFolder, N'blinkit_inventory.csv';
TRUNCATE TABLE stg.inventory_new;         EXEC stg.usp_bulk_load N'stg.inventory_new',         @DataFolder, N'blinkit_inventoryNew.csv';
GO

/* ---------- Expected row counts (from the supplied files) ----------
   customers 2,500 | products 268 | orders 5,000 | order_items 5,000
   customer_feedback 5,000 | delivery_performance 5,000
   marketing_performance 5,400 | inventory 75,172 | inventory_new 18,105 */
SELECT 'customers' AS stg_table, COUNT(*) AS row_count FROM stg.customers
UNION ALL SELECT 'products',              COUNT(*) FROM stg.products
UNION ALL SELECT 'orders',                COUNT(*) FROM stg.orders
UNION ALL SELECT 'order_items',           COUNT(*) FROM stg.order_items
UNION ALL SELECT 'customer_feedback',     COUNT(*) FROM stg.customer_feedback
UNION ALL SELECT 'delivery_performance',  COUNT(*) FROM stg.delivery_performance
UNION ALL SELECT 'marketing_performance', COUNT(*) FROM stg.marketing_performance
UNION ALL SELECT 'inventory',             COUNT(*) FROM stg.inventory
UNION ALL SELECT 'inventory_new',         COUNT(*) FROM stg.inventory_new;
GO
