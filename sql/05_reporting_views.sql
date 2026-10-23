/* =====================================================================
   05_reporting_views.sql
   Purpose : Reusable, BI-friendly views on top of blinkit.* so Power BI
             (or any tool) can connect to SQL Server instead of CSVs, and
             the analysis scripts (06-10) stay short.
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* One row per order, everything a report usually needs. */
CREATE OR ALTER VIEW blinkit.vw_order_enriched AS
SELECT  o.order_id,
        o.order_date,
        CAST(o.order_date AS DATE)                         AS order_day,
        DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1) AS order_month,
        DATENAME(WEEKDAY, o.order_date)                    AS order_weekday,
        DATEPART(HOUR, o.order_date)                       AS order_hour,
        o.customer_id, c.customer_segment, c.area,
        o.payment_method, o.store_id, o.delivery_partner_id,
        o.order_total,
        it.items_total,                                    -- sum of line items (differs from order_total, see script 04)
        it.units,
        o.promised_delivery_time, o.actual_delivery_time,
        o.delivery_status,
        o.delivery_delay_min,
        d.distance_km, d.reasons_if_delayed,
        f.rating, f.sentiment, f.feedback_category
FROM blinkit.orders o
JOIN blinkit.customers c            ON c.customer_id = o.customer_id
LEFT JOIN blinkit.delivery_performance d ON d.order_id = o.order_id
LEFT JOIN blinkit.customer_feedback   f ON f.order_id = o.order_id
OUTER APPLY (SELECT SUM(i.line_total) AS items_total, SUM(i.quantity) AS units
             FROM blinkit.order_items i WHERE i.order_id = o.order_id) it;
GO

/* One row per order line with product attributes. */
CREATE OR ALTER VIEW blinkit.vw_order_lines AS
SELECT  i.order_id, o.order_date, CAST(o.order_date AS DATE) AS order_day,
        p.product_id, p.product_name, p.category, p.brand,
        i.quantity, i.unit_price, i.line_total, p.margin_percentage,
        CAST(i.line_total * p.margin_percentage / 100.0 AS DECIMAL(14,2)) AS est_margin_value
FROM blinkit.order_items i
JOIN blinkit.orders   o ON o.order_id   = i.order_id
JOIN blinkit.products p ON p.product_id = i.product_id;
GO

/* Month grain: sales + delivery quality. */
CREATE OR ALTER VIEW blinkit.vw_monthly_orders AS
SELECT  order_month,
        COUNT(*)                                        AS orders,
        SUM(order_total)                                AS revenue,
        AVG(order_total)                                AS avg_order_value,
        SUM(CASE WHEN delivery_status = 'On Time' THEN 1 ELSE 0 END) AS on_time_orders,
        CAST(100.0 * SUM(CASE WHEN delivery_status = 'On Time' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS on_time_pct
FROM blinkit.vw_order_enriched
GROUP BY order_month;
GO

/* Month grain: marketing efficiency. */
CREATE OR ALTER VIEW blinkit.vw_monthly_marketing AS
SELECT  DATEFROMPARTS(YEAR(campaign_date), MONTH(campaign_date), 1) AS campaign_month,
        SUM(spend) AS spend, SUM(revenue_generated) AS revenue_generated,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks, SUM(conversions) AS conversions,
        CAST(SUM(revenue_generated) / NULLIF(SUM(spend), 0) AS DECIMAL(8,3)) AS roas_weighted
FROM blinkit.marketing_performance
GROUP BY DATEFROMPARTS(YEAR(campaign_date), MONTH(campaign_date), 1);
GO

/* Month grain: inventory (daily table rolled up). */
CREATE OR ALTER VIEW blinkit.vw_monthly_inventory AS
SELECT  DATEFROMPARTS(YEAR(stock_date), MONTH(stock_date), 1) AS stock_month,
        SUM(stock_received) AS stock_received, SUM(damaged_stock) AS damaged_stock,
        CAST(100.0 * SUM(damaged_stock) / NULLIF(SUM(stock_received), 0) AS DECIMAL(6,2)) AS damaged_pct
FROM blinkit.inventory
GROUP BY DATEFROMPARTS(YEAR(stock_date), MONTH(stock_date), 1);
GO

/* Optional calendar dimension covering all fact tables. */
CREATE OR ALTER VIEW blinkit.vw_dim_date AS
WITH bounds AS (
    SELECT DATEFROMPARTS(YEAR(MIN(d)), 1, 1) AS d0, DATEFROMPARTS(YEAR(MAX(d)), 12, 31) AS d1
    FROM (SELECT CAST(MIN(order_date) AS DATE) AS d FROM blinkit.orders
          UNION ALL SELECT MAX(CAST(order_date AS DATE)) FROM blinkit.orders
          UNION ALL SELECT MIN(registration_date) FROM blinkit.customers
          UNION ALL SELECT MAX(campaign_date) FROM blinkit.marketing_performance
          UNION ALL SELECT MAX(stock_date) FROM blinkit.inventory) x
), cal AS (
    SELECT d0 AS dt, d1 FROM bounds
    UNION ALL
    SELECT DATEADD(DAY, 1, dt), d1 FROM cal WHERE dt < d1
)
SELECT  dt AS date_key, YEAR(dt) AS [year], DATEPART(QUARTER, dt) AS [quarter],
        MONTH(dt) AS month_no, DATENAME(MONTH, dt) AS month_name,
        DATEFROMPARTS(YEAR(dt), MONTH(dt), 1) AS month_start,
        DATENAME(WEEKDAY, dt) AS weekday_name
FROM cal;
-- usage: SELECT * FROM blinkit.vw_dim_date OPTION (MAXRECURSION 0);
GO
