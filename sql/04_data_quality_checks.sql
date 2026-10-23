/* =====================================================================
   04_data_quality_checks.sql
   Purpose : Profile the loaded data and surface issues BEFORE anyone
             trusts a dashboard number. Each check returns a small result
             set: issue, rows_affected, total_rows, comment.
   Notes   : The "Observed" values in comments are from the supplied
             files; run the script to confirm on your copy.
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* ---------- A. Referential / key integrity (should all be 0) ---------- */
SELECT 'orders without a customer'                 AS check_name, COUNT(*) AS rows_affected
FROM blinkit.orders o LEFT JOIN blinkit.customers c ON c.customer_id = o.customer_id WHERE c.customer_id IS NULL
UNION ALL SELECT 'order_items without an order',    COUNT(*) FROM blinkit.order_items i LEFT JOIN blinkit.orders o ON o.order_id = i.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'order_items without a product',   COUNT(*) FROM blinkit.order_items i LEFT JOIN blinkit.products p ON p.product_id = i.product_id WHERE p.product_id IS NULL
UNION ALL SELECT 'feedback whose customer <> order customer', COUNT(*)
          FROM blinkit.customer_feedback f JOIN blinkit.orders o ON o.order_id = f.order_id WHERE f.customer_id <> o.customer_id
UNION ALL SELECT 'delivery rows whose status <> orders status', COUNT(*)
          FROM blinkit.delivery_performance d JOIN blinkit.orders o ON o.order_id = d.order_id WHERE d.delivery_status <> o.delivery_status
UNION ALL SELECT 'delivery rows whose partner <> orders partner', COUNT(*)
          FROM blinkit.delivery_performance d JOIN blinkit.orders o ON o.order_id = d.order_id WHERE d.delivery_partner_id <> o.delivery_partner_id
UNION ALL SELECT 'orders missing delivery row',     COUNT(*) FROM blinkit.orders o LEFT JOIN blinkit.delivery_performance d ON d.order_id = o.order_id WHERE d.order_id IS NULL
UNION ALL SELECT 'orders missing feedback row',     COUNT(*) FROM blinkit.orders o LEFT JOIN blinkit.customer_feedback f ON f.order_id = o.order_id WHERE f.order_id IS NULL
UNION ALL SELECT 'orders missing line items',       COUNT(*) FROM blinkit.orders o WHERE NOT EXISTS (SELECT 1 FROM blinkit.order_items i WHERE i.order_id = o.order_id)
UNION ALL SELECT 'marketing: clicks > impressions or conversions > clicks', COUNT(*)
          FROM blinkit.marketing_performance WHERE clicks > impressions OR conversions > clicks;
GO

/* ---------- B. Business-rule / consistency findings ---------- */
WITH item_totals AS (
    SELECT order_id, SUM(line_total) AS items_total FROM blinkit.order_items GROUP BY order_id
), cust_orders AS (
    SELECT customer_id, COUNT(*) AS actual_orders FROM blinkit.orders GROUP BY customer_id
)
SELECT *
FROM (
    /* B1. order_total should equal the sum of its line items.
       Observed: ~all 5,000 orders differ; SUM(order_total)=11,009,308.50 vs SUM(line items)=4,972,415.43 */
    SELECT 'B1 orders.order_total <> SUM(order_items.line_total)' AS issue,
           SUM(CASE WHEN ABS(o.order_total - i.items_total) > 0.01 THEN 1 ELSE 0 END) AS rows_affected,
           COUNT(*) AS total_rows
    FROM blinkit.orders o JOIN item_totals i ON i.order_id = o.order_id
    UNION ALL
    /* B2. customers.total_orders should equal orders actually in the dataset.
       Observed: SUM(total_orders)=26,229 vs 5,000 orders; only ~115 customers match. */
    SELECT 'B2 customers.total_orders <> orders in dataset',
           SUM(CASE WHEN c.total_orders <> ISNULL(co.actual_orders, 0) THEN 1 ELSE 0 END), COUNT(*)
    FROM blinkit.customers c LEFT JOIN cust_orders co ON co.customer_id = c.customer_id
    UNION ALL
    /* B3. customers with no order at all. Observed: 328 of 2,500. */
    SELECT 'B3 customers with zero orders', COUNT(*), (SELECT COUNT(*) FROM blinkit.customers)
    FROM blinkit.customers c WHERE NOT EXISTS (SELECT 1 FROM blinkit.orders o WHERE o.customer_id = c.customer_id)
    UNION ALL
    /* B4. orders placed BEFORE the customer's registration date. Observed: ~2,556 of 5,000. */
    SELECT 'B4 order placed before customer registration_date',
           SUM(CASE WHEN CAST(o.order_date AS DATE) < c.registration_date THEN 1 ELSE 0 END), COUNT(*)
    FROM blinkit.orders o JOIN blinkit.customers c ON c.customer_id = o.customer_id
    UNION ALL
    /* B5. Supplied ROAS vs revenue / spend. Observed: ~5,374 of 5,400 rows differ by > 0.01. */
    SELECT 'B5 marketing.roas <> revenue_generated / spend',
           SUM(CASE WHEN ABS(roas - revenue_generated / NULLIF(spend, 0)) > 0.01 THEN 1 ELSE 0 END), COUNT(*)
    FROM blinkit.marketing_performance
    UNION ALL
    /* B6. campaign_id is unique per ROW, so "Total campaigns" = 5,400 although
       there are only 9 distinct campaign names. */
    SELECT 'B6 distinct campaign_id vs distinct campaign_name (rows = ids)',
           COUNT(DISTINCT campaign_id), COUNT(DISTINCT campaign_name)
    FROM blinkit.marketing_performance
    UNION ALL
    /* B7. A delay reason is recorded for on-time orders. Observed: 1,568 of 3,470; and the
       only reason value is 'Traffic'. */
    SELECT 'B7 On Time orders that still carry a delay reason',
           SUM(CASE WHEN reasons_if_delayed IS NOT NULL THEN 1 ELSE 0 END), COUNT(*)
    FROM blinkit.delivery_performance WHERE delivery_status = 'On Time'
    UNION ALL
    /* B8. Rating vs sentiment overlap: rating 3 is tagged Negative AND Neutral, 4 is Neutral AND Positive. */
    SELECT 'B8 rating 3 tagged Negative (should be Neutral?)',
           SUM(CASE WHEN sentiment = 'Negative' THEN 1 ELSE 0 END), COUNT(*)
    FROM blinkit.customer_feedback WHERE rating = 3
) AS x;
GO

/* ---------- C. Inventory checks (the ones that move a dashboard KPI) ---------- */
/* C1. Daily inventory table (used by the Power BI gauge).
   Observed: damaged_stock only ever holds 0 or 2; damaged > received on 29,255 of 75,172 rows;
   total damaged / total received = 54.4%. That is not a credible damage rate. */
SELECT  COUNT(*)                                                   AS total_rows,
        SUM(CASE WHEN damaged_stock > stock_received THEN 1 ELSE 0 END) AS damaged_exceeds_received,
        COUNT(DISTINCT damaged_stock)                              AS distinct_damaged_values,
        SUM(stock_received)                                        AS total_received,
        SUM(damaged_stock)                                         AS total_damaged,
        CAST(100.0 * SUM(damaged_stock) / NULLIF(SUM(stock_received), 0) AS DECIMAL(6,2)) AS damaged_pct
FROM blinkit.inventory;

/* C2. Monthly inventory table (blinkit_inventoryNew.csv, not in the .pbix).
   Observed: damaged 3.85% of received, but the same (product, month) appears on several rows. */
SELECT  COUNT(*) AS total_rows,
        COUNT(*) - COUNT(DISTINCT CONCAT(product_id, '|', stock_month)) AS repeated_product_month_rows,
        SUM(stock_received) AS total_received,
        SUM(damaged_stock)  AS total_damaged,
        CAST(100.0 * SUM(damaged_stock) / NULLIF(SUM(stock_received), 0) AS DECIMAL(6,2)) AS damaged_pct
FROM blinkit.inventory_monthly;

/* C3. Coverage: the daily file ends 2024-11-05; both November-2024 months are partial. */
SELECT MIN(stock_date) AS first_day, MAX(stock_date) AS last_day FROM blinkit.inventory;
SELECT MIN(order_date) AS first_order, MAX(order_date) AS last_order FROM blinkit.orders;
GO

/* ---------- D. Lookup values (sanity-check the categorical domains) ---------- */
SELECT 'delivery_status' AS col, delivery_status AS val, COUNT(*) AS n FROM blinkit.orders GROUP BY delivery_status
UNION ALL SELECT 'payment_method',   payment_method,   COUNT(*) FROM blinkit.orders GROUP BY payment_method
UNION ALL SELECT 'customer_segment', customer_segment, COUNT(*) FROM blinkit.customers GROUP BY customer_segment
UNION ALL SELECT 'category',         category,         COUNT(*) FROM blinkit.products GROUP BY category
UNION ALL SELECT 'channel',          channel,          COUNT(*) FROM blinkit.marketing_performance GROUP BY channel
UNION ALL SELECT 'campaign_name',    campaign_name,    COUNT(*) FROM blinkit.marketing_performance GROUP BY campaign_name
UNION ALL SELECT 'target_audience',  target_audience,  COUNT(*) FROM blinkit.marketing_performance GROUP BY target_audience
ORDER BY col, val;
GO
