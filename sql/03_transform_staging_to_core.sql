/* =====================================================================
   03_transform_staging_to_core.sql
   Purpose : Type-cast, trim and load stg.* into the constrained
             blinkit.* tables. Runs in ONE transaction: any conversion
             error, constraint violation or orphaned key rolls it all back.
   Re-runnable: clears the core tables first (children before parents).
   ===================================================================== */
USE BlinkitAnalytics;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    /* ---- Clear (reverse dependency order) ---- */
    DELETE FROM blinkit.inventory_monthly;
    DELETE FROM blinkit.inventory;
    DELETE FROM blinkit.marketing_performance;
    DELETE FROM blinkit.delivery_performance;
    DELETE FROM blinkit.customer_feedback;
    DELETE FROM blinkit.order_items;
    DELETE FROM blinkit.orders;
    DELETE FROM blinkit.products;
    DELETE FROM blinkit.customers;
    DBCC CHECKIDENT ('blinkit.inventory_monthly', RESEED, 0) WITH NO_INFOMSGS;

    /* ---- customers ---- */
    INSERT INTO blinkit.customers
           (customer_id, customer_name, email, phone, address, area, pincode,
            registration_date, customer_segment, total_orders, avg_order_value)
    SELECT  CONVERT(INT, customer_id),
            LTRIM(RTRIM(customer_name)),
            NULLIF(LTRIM(RTRIM(email)), ''),
            NULLIF(LTRIM(RTRIM(phone)), ''),
            NULLIF(LTRIM(RTRIM(REPLACE(address, CHAR(10), N' '))), ''),   -- flatten embedded line breaks
            NULLIF(LTRIM(RTRIM(area)), ''),
            CONVERT(INT, NULLIF(pincode, '')),
            CONVERT(DATE, registration_date, 23),
            LTRIM(RTRIM(customer_segment)),
            CONVERT(INT, total_orders),
            CONVERT(DECIMAL(12,2), avg_order_value)
    FROM stg.customers;

    /* ---- products ---- */
    INSERT INTO blinkit.products
           (product_id, product_name, category, brand, price, mrp,
            margin_percentage, shelf_life_days, min_stock_level, max_stock_level)
    SELECT  CONVERT(INT, product_id),
            LTRIM(RTRIM(product_name)), LTRIM(RTRIM(category)), LTRIM(RTRIM(brand)),
            CONVERT(DECIMAL(12,2), price), CONVERT(DECIMAL(12,2), mrp),
            CONVERT(DECIMAL(5,2),  margin_percentage),
            CONVERT(INT, shelf_life_days), CONVERT(INT, min_stock_level), CONVERT(INT, max_stock_level)
    FROM stg.products;

    /* ---- orders ---- */
    INSERT INTO blinkit.orders
           (order_id, customer_id, order_date, promised_delivery_time, actual_delivery_time,
            delivery_status, order_total, payment_method, delivery_partner_id, store_id)
    SELECT  CONVERT(BIGINT, order_id), CONVERT(INT, customer_id),
            CONVERT(DATETIME2(0), order_date, 120),
            CONVERT(DATETIME2(0), promised_delivery_time, 120),
            CONVERT(DATETIME2(0), actual_delivery_time, 120),
            LTRIM(RTRIM(delivery_status)),
            CONVERT(DECIMAL(12,2), order_total),
            LTRIM(RTRIM(payment_method)),
            CONVERT(INT, delivery_partner_id), CONVERT(INT, store_id)
    FROM stg.orders;

    /* ---- order_items ---- */
    INSERT INTO blinkit.order_items (order_id, product_id, quantity, unit_price)
    SELECT CONVERT(BIGINT, order_id), CONVERT(INT, product_id),
           CONVERT(INT, quantity), CONVERT(DECIMAL(12,2), unit_price)
    FROM stg.order_items;

    /* ---- customer_feedback ---- */
    INSERT INTO blinkit.customer_feedback
           (feedback_id, order_id, customer_id, rating, feedback_text,
            feedback_category, sentiment, feedback_date)
    SELECT  CONVERT(INT, feedback_id), CONVERT(BIGINT, order_id), CONVERT(INT, customer_id),
            CONVERT(TINYINT, rating), NULLIF(LTRIM(RTRIM(feedback_text)), ''),
            LTRIM(RTRIM(feedback_category)), LTRIM(RTRIM(sentiment)),
            CONVERT(DATE, feedback_date, 23)
    FROM stg.customer_feedback;

    /* ---- delivery_performance ---- */
    INSERT INTO blinkit.delivery_performance
           (order_id, delivery_partner_id, promised_time, actual_time,
            delivery_time_minutes, distance_km, delivery_status, reasons_if_delayed)
    SELECT  CONVERT(BIGINT, order_id), CONVERT(INT, delivery_partner_id),
            CONVERT(DATETIME2(0), promised_time, 120), CONVERT(DATETIME2(0), actual_time, 120),
            CONVERT(DECIMAL(6,1), delivery_time_minutes), CONVERT(DECIMAL(6,2), distance_km),
            LTRIM(RTRIM(delivery_status)),
            NULLIF(LTRIM(RTRIM(reasons_if_delayed)), '')
    FROM stg.delivery_performance;

    /* ---- marketing_performance ---- */
    INSERT INTO blinkit.marketing_performance
           (campaign_id, campaign_name, campaign_date, target_audience, channel,
            impressions, clicks, conversions, spend, revenue_generated, roas)
    SELECT  CONVERT(INT, campaign_id), LTRIM(RTRIM(campaign_name)), CONVERT(DATE, [date], 23),
            LTRIM(RTRIM(target_audience)), LTRIM(RTRIM(channel)),
            CONVERT(INT, impressions), CONVERT(INT, clicks), CONVERT(INT, conversions),
            CONVERT(DECIMAL(14,2), spend), CONVERT(DECIMAL(14,2), revenue_generated),
            CONVERT(DECIMAL(8,2), roas)
    FROM stg.marketing_performance;

    /* ---- inventory (daily): dd-mm-yyyy -> DATE (style 105) ---- */
    INSERT INTO blinkit.inventory (product_id, stock_date, stock_received, damaged_stock)
    SELECT CONVERT(INT, product_id), CONVERT(DATE, [date], 105),
           CONVERT(INT, stock_received), CONVERT(INT, damaged_stock)
    FROM stg.inventory;

    /* ---- inventory_monthly: 'Mar-23' -> 2023-03-01 (locale independent) ---- */
    INSERT INTO blinkit.inventory_monthly (product_id, stock_month, stock_received, damaged_stock)
    SELECT CONVERT(INT, product_id),
           DATEFROMPARTS(2000 + CONVERT(INT, RIGHT(LTRIM(RTRIM([date])), 2)),
                         (CHARINDEX(LEFT(LTRIM(RTRIM([date])), 3), 'JanFebMarAprMayJunJulAugSepOctNovDec') + 2) / 3,
                         1),
           CONVERT(INT, stock_received), CONVERT(INT, damaged_stock)
    FROM stg.inventory_new;

    COMMIT TRANSACTION;
    PRINT 'Staging -> core load committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Load rolled back.';
    THROW;
END CATCH;
GO

/* ---------- Reconciliation: every staged row must land in core ---------- */
SELECT t.table_name, t.staged_rows, t.core_rows,
       CASE WHEN t.staged_rows = t.core_rows THEN 'OK' ELSE 'MISMATCH' END AS status
FROM (
    SELECT 'customers' AS table_name, (SELECT COUNT(*) FROM stg.customers) AS staged_rows, (SELECT COUNT(*) FROM blinkit.customers) AS core_rows
    UNION ALL SELECT 'products',              (SELECT COUNT(*) FROM stg.products),              (SELECT COUNT(*) FROM blinkit.products)
    UNION ALL SELECT 'orders',                (SELECT COUNT(*) FROM stg.orders),                (SELECT COUNT(*) FROM blinkit.orders)
    UNION ALL SELECT 'order_items',           (SELECT COUNT(*) FROM stg.order_items),           (SELECT COUNT(*) FROM blinkit.order_items)
    UNION ALL SELECT 'customer_feedback',     (SELECT COUNT(*) FROM stg.customer_feedback),     (SELECT COUNT(*) FROM blinkit.customer_feedback)
    UNION ALL SELECT 'delivery_performance',  (SELECT COUNT(*) FROM stg.delivery_performance),  (SELECT COUNT(*) FROM blinkit.delivery_performance)
    UNION ALL SELECT 'marketing_performance', (SELECT COUNT(*) FROM stg.marketing_performance), (SELECT COUNT(*) FROM blinkit.marketing_performance)
    UNION ALL SELECT 'inventory',             (SELECT COUNT(*) FROM stg.inventory),             (SELECT COUNT(*) FROM blinkit.inventory)
    UNION ALL SELECT 'inventory_monthly',     (SELECT COUNT(*) FROM stg.inventory_new),         (SELECT COUNT(*) FROM blinkit.inventory_monthly)
) AS t;
GO
