/* =====================================================================
   09_inventory_insights.sql       Dashboard page: INVENTORY INSIGHTS
   !! Read docs/data_quality_findings.md first. The daily inventory table
   the report uses has a damaged-stock field that is not credible
   (54% of received; damaged > received on 29k rows). The monthly file
   (blinkit_inventoryNew.csv, loaded as blinkit.inventory_monthly) gives
   ~3.9%. Both are shown so the difference is visible.
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* ---------------- Visual: Damaged stock vs total stock received (gauge) ---------------- */
SELECT 'daily table (used by the .pbix)' AS source,
       SUM(stock_received) AS stock_received, SUM(damaged_stock) AS damaged_stock,
       CAST(100.0 * SUM(damaged_stock) / NULLIF(SUM(stock_received), 0) AS DECIMAL(6,2)) AS damaged_pct   -- 147,526 / 80,268 -> 54.41
FROM blinkit.inventory
UNION ALL
SELECT 'monthly table (blinkit_inventoryNew.csv)',
       SUM(stock_received), SUM(damaged_stock),
       CAST(100.0 * SUM(damaged_stock) / NULLIF(SUM(stock_received), 0) AS DECIMAL(6,2))                  -- 28,779 / 1,109 -> 3.85
FROM blinkit.inventory_monthly;
GO

/* ---------------- Visual: Monthly damaged stock trend (line) ---------------- */
SELECT stock_month, stock_received, damaged_stock, damaged_pct
FROM blinkit.vw_monthly_inventory
ORDER BY stock_month;

/* Same trend from the monthly table (rows repeat per product-month, so SUM is the right roll-up). */
SELECT stock_month, SUM(stock_received) AS stock_received, SUM(damaged_stock) AS damaged_stock,
       CAST(100.0 * SUM(damaged_stock) / NULLIF(SUM(stock_received), 0) AS DECIMAL(6,2)) AS damaged_pct
FROM blinkit.inventory_monthly
GROUP BY stock_month
ORDER BY stock_month;
GO

/* ---------------- Visual: Stock level range by product - min vs max (clustered column, Top 10 by max level) ----------------
   Report grouping = product_name; its measure is SUM over the SKUs sharing that name. */
SELECT TOP (10)
        product_name,
        SUM(min_stock_level) AS min_stock_level,
        SUM(max_stock_level) AS max_stock_level
FROM blinkit.products
GROUP BY product_name
ORDER BY SUM(max_stock_level) DESC, product_name;
GO

/* ---------------- Visual: Average profit margin by category (bar) ---------------- */
SELECT category,
       CAST(AVG(margin_percentage) AS DECIMAL(5,2)) AS avg_margin_pct,
       COUNT(*) AS skus
FROM blinkit.products
GROUP BY category
ORDER BY avg_margin_pct DESC;
GO

/* ---------------- Visual: Average shelf life by category in days (bar) ---------------- */
SELECT category,
       CAST(AVG(CAST(shelf_life_days AS DECIMAL(8,2))) AS DECIMAL(8,1)) AS avg_shelf_life_days,
       MIN(shelf_life_days) AS min_shelf_life_days
FROM blinkit.products
GROUP BY category
ORDER BY avg_shelf_life_days;
GO


/* =====================================================================
   EXTRA ANALYSIS (not on the dashboard)
   ===================================================================== */

/* E1. Perishability watch-list: short shelf life (<= 7 days) with margin and sales velocity.
       Fast-moving, short-life SKUs are where over-ordering turns into write-offs. */
SELECT  p.product_id, p.product_name, p.category, p.shelf_life_days, p.margin_percentage,
        ISNULL(s.units_sold, 0)   AS units_sold,
        p.min_stock_level, p.max_stock_level
FROM blinkit.products p
LEFT JOIN (SELECT product_id, SUM(quantity) AS units_sold FROM blinkit.order_items GROUP BY product_id) s
       ON s.product_id = p.product_id
WHERE p.shelf_life_days <= 7
ORDER BY units_sold DESC;
GO

/* E2. Damage rate by category (monthly table - the more credible source). */
SELECT  p.category,
        SUM(m.stock_received) AS stock_received,
        SUM(m.damaged_stock)  AS damaged_stock,
        CAST(100.0 * SUM(m.damaged_stock) / NULLIF(SUM(m.stock_received), 0) AS DECIMAL(6,2)) AS damaged_pct
FROM blinkit.inventory_monthly m
JOIN blinkit.products p ON p.product_id = m.product_id
GROUP BY p.category
ORDER BY damaged_pct DESC;
GO

/* E3. Products never ordered in the order data (candidates for range review).
       Observed: none - all 268 SKUs appear in order_items. Kept as a reusable check. */
SELECT p.product_id, p.product_name, p.category, p.brand, p.price
FROM blinkit.products p
WHERE NOT EXISTS (SELECT 1 FROM blinkit.order_items i WHERE i.product_id = p.product_id)
ORDER BY p.category, p.product_name;
GO

/* E4. margin_percentage vs the MRP-to-price gap. Observed: they are the same number (within rounding),
       and both margin and shelf life are constant within a category. So the two category bar charts
       on the dashboard show category-level constants, not variation between products. */
SELECT category,
       MIN(margin_percentage) AS min_margin_pct, MAX(margin_percentage) AS max_margin_pct,
       CAST(AVG(100.0 * (mrp - price) / mrp) AS DECIMAL(5,2)) AS avg_gap_mrp_to_price_pct,
       MIN(shelf_life_days)   AS min_shelf_life_days, MAX(shelf_life_days) AS max_shelf_life_days
FROM blinkit.products
GROUP BY category
ORDER BY category;
GO
