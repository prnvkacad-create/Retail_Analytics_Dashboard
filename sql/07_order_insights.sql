/* =====================================================================
   07_order_insights.sql           Dashboard page: ORDER INSIGHTS
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* ---------------- KPI cards ---------------- */
SELECT
    (SELECT COUNT(order_id)                   FROM blinkit.orders)   AS total_orders,    -- 5,000
    (SELECT SUM(order_total)                  FROM blinkit.orders)   AS total_revenue,   -- 11,009,308.50  (~11.01M)
    (SELECT COUNT(product_id)                 FROM blinkit.products) AS total_products,  -- 268
    (SELECT COUNT(DISTINCT brand)             FROM blinkit.products) AS total_brands;    -- 267
GO

/* ---------------- Visual: Monthly orders and revenue trend (line) ----------------
   + month-over-month change. Note 2023-03 and 2024-11 are partial months. */
WITH m AS (
    SELECT DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS order_month,
           COUNT(*) AS orders, SUM(order_total) AS revenue
    FROM blinkit.orders
    GROUP BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)
)
SELECT  order_month, orders, revenue,
        CAST(100.0 * (revenue - LAG(revenue) OVER (ORDER BY order_month))
                   / NULLIF(LAG(revenue) OVER (ORDER BY order_month), 0) AS DECIMAL(7,2)) AS revenue_mom_pct,
        CAST(revenue / orders AS DECIMAL(10,2)) AS avg_order_value
FROM m
ORDER BY order_month;
GO

/* ---------------- Visual: Orders by delivery status (column) ---------------- */
SELECT  delivery_status,
        COUNT(*) AS orders,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_orders   -- On Time 69.4 | Slightly 20.7 | Significantly 9.9
FROM blinkit.orders
GROUP BY delivery_status
ORDER BY orders DESC;
GO

/* ---------------- Visual: Payment method split (donut) ---------------- */
SELECT  payment_method,
        COUNT(*) AS orders,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_orders,
        CAST(SUM(order_total) AS DECIMAL(14,2)) AS revenue
FROM blinkit.orders
GROUP BY payment_method
ORDER BY orders DESC;                   -- Card 1,285 | Cash 1,257 | Wallet 1,244 | UPI 1,214
GO

/* ---------------- Visual: Top 10 best-selling products by quantity (column) ----------------
   The report groups by product_name (51 names across 268 SKUs), so we do the same. */
SELECT TOP (10)
        p.product_name,
        SUM(i.quantity) AS units_sold
FROM blinkit.order_items i
JOIN blinkit.products p ON p.product_id = i.product_id
GROUP BY p.product_name
ORDER BY units_sold DESC, p.product_name;   -- Pet Treats 473, Toilet Cleaner 430, Dish Soap 397, Vitamins 380, Cough Syrup 373 ...
GO


/* =====================================================================
   EXTRA ANALYSIS (not on the dashboard)
   ===================================================================== */

/* E1. Category performance from line items (units, revenue, estimated margin). */
SELECT  category,
        SUM(quantity)                                  AS units,
        CAST(SUM(line_total) AS DECIMAL(14,2))         AS item_revenue,
        CAST(SUM(est_margin_value) AS DECIMAL(14,2))   AS est_margin_value,
        CAST(100.0 * SUM(line_total) / SUM(SUM(line_total)) OVER () AS DECIMAL(5,2)) AS pct_of_item_revenue
FROM blinkit.vw_order_lines
GROUP BY category
ORDER BY item_revenue DESC;             -- Dairy & Breakfast, Pharmacy, Fruits & Vegetables lead
GO

/* E2. Top 10 products by revenue with rank + running share. */
WITH p AS (
    SELECT product_name, SUM(line_total) AS revenue FROM blinkit.vw_order_lines GROUP BY product_name
)
SELECT TOP (10)
        RANK() OVER (ORDER BY revenue DESC) AS revenue_rank,
        product_name, CAST(revenue AS DECIMAL(14,2)) AS revenue,
        CAST(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
                   / SUM(revenue) OVER () AS DECIMAL(5,2)) AS cumulative_pct
FROM p
ORDER BY revenue_rank;
GO

/* E3. Peak ordering hours and weekdays. */
SELECT order_hour, COUNT(*) AS orders, CAST(SUM(order_total) AS DECIMAL(14,2)) AS revenue
FROM blinkit.vw_order_enriched GROUP BY order_hour ORDER BY order_hour;

SELECT order_weekday, COUNT(*) AS orders, CAST(AVG(order_total) AS DECIMAL(10,2)) AS avg_order_value
FROM blinkit.vw_order_enriched GROUP BY order_weekday
ORDER BY CASE order_weekday WHEN 'Monday' THEN 1 WHEN 'Tuesday' THEN 2 WHEN 'Wednesday' THEN 3 WHEN 'Thursday' THEN 4
                            WHEN 'Friday' THEN 5 WHEN 'Saturday' THEN 6 ELSE 7 END;
GO

/* E4. Revenue two ways: order_total (what the dashboard reports) vs. sum of line items.
       These disagree materially - confirm the business definition before publishing revenue. */
SELECT  CAST(SUM(o.order_total) AS DECIMAL(14,2))  AS revenue_from_orders,
        CAST(SUM(i.items_total) AS DECIMAL(14,2))  AS revenue_from_items,
        CAST(SUM(o.order_total) - SUM(i.items_total) AS DECIMAL(14,2)) AS unexplained_gap
FROM blinkit.orders o
JOIN (SELECT order_id, SUM(line_total) AS items_total FROM blinkit.order_items GROUP BY order_id) i
  ON i.order_id = o.order_id;
GO

/* E5. Basket size: units per order and share of orders by units. */
SELECT units, COUNT(*) AS orders, CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_orders
FROM blinkit.vw_order_enriched
GROUP BY units ORDER BY units;
GO
