/* =====================================================================
   06_customer_insights.sql        Dashboard page: CUSTOMER INSIGHTS
   Each query reproduces one visual of the Power BI page (same
   aggregation), followed by extra analysis that goes beyond the report.
   "Expected" = value obtained from the supplied CSVs.
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* ---------------- KPI cards ---------------- */
SELECT
    (SELECT COUNT(*) FROM blinkit.customers)                                          AS total_customers,      -- 2,500
    (SELECT CAST(AVG(avg_order_value) AS DECIMAL(10,2)) FROM blinkit.customers)       AS avg_order_value,      -- 1,102.38  (average of the customer-level column)
    (SELECT CAST(AVG(CAST(rating AS DECIMAL(4,2))) AS DECIMAL(4,2)) FROM blinkit.customer_feedback) AS avg_rating, -- 3.34
    (SELECT COUNT(DISTINCT feedback_id) FROM blinkit.customer_feedback)               AS total_feedback;       -- 5,000
GO

/* ---------------- Visual: Customer distribution by segment (donut) ---------------- */
SELECT  customer_segment,
        COUNT(*)                                                            AS customers,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))      AS pct_of_customers
FROM blinkit.customers
GROUP BY customer_segment
ORDER BY customers DESC;
GO

/* ---------------- Visual: Customer distribution by area (bar, Top 10) ---------------- */
SELECT TOP (10) area, COUNT(*) AS customers
FROM blinkit.customers
GROUP BY area
ORDER BY customers DESC, area;          -- Jalna 18, Orai 17, Bathinda 17, Deoghar 17 ...
GO

/* ---------------- Visual: New customer registrations by month (line) ---------------- */
SELECT  DATEFROMPARTS(YEAR(registration_date), MONTH(registration_date), 1) AS registration_month,
        COUNT(*) AS new_customers
FROM blinkit.customers
GROUP BY DATEFROMPARTS(YEAR(registration_date), MONTH(registration_date), 1)
ORDER BY registration_month;
GO

/* ---------------- Visual: Feedback volume by sentiment (donut) ---------------- */
SELECT  sentiment,
        COUNT(DISTINCT feedback_id)                                          AS feedback_count,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))       AS pct_of_feedback
FROM blinkit.customer_feedback
GROUP BY sentiment
ORDER BY feedback_count DESC;           -- Neutral 1,738 | Negative 1,642 | Positive 1,620
GO

/* ---------------- Visual: Average rating by feedback category (column) ---------------- */
SELECT  feedback_category,
        COUNT(*)                                                     AS feedback_count,
        CAST(AVG(CAST(rating AS DECIMAL(4,2))) AS DECIMAL(4,2))      AS avg_rating
FROM blinkit.customer_feedback
GROUP BY feedback_category
ORDER BY avg_rating DESC;
GO

/* ---------------- Visual: Customer value analysis - order frequency vs spend (scatter, by segment) ---------------- */
SELECT  customer_segment,
        SUM(total_orders)                              AS total_orders,        -- x axis
        CAST(AVG(avg_order_value) AS DECIMAL(10,2))    AS avg_order_value      -- y axis
FROM blinkit.customers
GROUP BY customer_segment
ORDER BY customer_segment;
GO


/* =====================================================================
   EXTRA ANALYSIS (not on the dashboard)
   ===================================================================== */

/* E1. Segment profile built from ACTUAL orders (compare with the declared
       total_orders / avg_order_value above - they do not agree, see script 04). */
SELECT  c.customer_segment,
        COUNT(DISTINCT c.customer_id)                           AS customers,
        COUNT(DISTINCT o.customer_id)                           AS customers_with_orders,
        COUNT(o.order_id)                                       AS orders,
        CAST(SUM(o.order_total) AS DECIMAL(14,2))               AS revenue,
        CAST(AVG(o.order_total) AS DECIMAL(10,2))               AS actual_aov,
        CAST(1.0 * COUNT(o.order_id) / NULLIF(COUNT(DISTINCT o.customer_id), 0) AS DECIMAL(6,2)) AS orders_per_active_customer
FROM blinkit.customers c
LEFT JOIN blinkit.orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_segment
ORDER BY revenue DESC;
GO

/* E2. Repeat-purchase rate (customers with >= 2 orders / customers with >= 1 order).
       Observed: 1,492 of 2,172 ordering customers = 68.7%. */
WITH per_customer AS (
    SELECT customer_id, COUNT(*) AS orders FROM blinkit.orders GROUP BY customer_id
)
SELECT  COUNT(*)                                                        AS ordering_customers,
        SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END)                    AS repeat_customers,
        CAST(100.0 * SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS repeat_rate_pct
FROM per_customer;
GO

/* E3. Revenue concentration (Pareto): share of revenue from the top 20% of ordering customers.
       Observed: top quintile ~40.9% of revenue, bottom quintile ~4.6%. */
WITH cust_rev AS (
    SELECT customer_id, SUM(order_total) AS revenue FROM blinkit.orders GROUP BY customer_id
), ranked AS (
    SELECT customer_id, revenue,
           NTILE(5) OVER (ORDER BY revenue DESC) AS quintile      -- 1 = top 20%
    FROM cust_rev
)
SELECT  quintile,
        COUNT(*)                                                          AS customers,
        CAST(SUM(revenue) AS DECIMAL(14,2))                               AS revenue,
        CAST(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER () AS DECIMAL(5,2)) AS pct_of_revenue
FROM ranked
GROUP BY quintile
ORDER BY quintile;
GO

/* E4. Lapsed customers: >= 2 orders but no order in the last 90 days of the data.
       Anchor date = latest order in the data set (not GETDATE(), the data is historical). */
DECLARE @anchor DATE = (SELECT CAST(MAX(order_date) AS DATE) FROM blinkit.orders);
SELECT TOP (25)
        c.customer_id, c.customer_name, c.customer_segment, c.area,
        COUNT(*)                                   AS orders,
        CAST(SUM(o.order_total) AS DECIMAL(12,2))  AS lifetime_revenue,
        MAX(CAST(o.order_date AS DATE))            AS last_order_day,
        DATEDIFF(DAY, MAX(o.order_date), @anchor)  AS days_since_last_order
FROM blinkit.customers c
JOIN blinkit.orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.customer_name, c.customer_segment, c.area
HAVING COUNT(*) >= 2 AND DATEDIFF(DAY, MAX(o.order_date), @anchor) > 90
ORDER BY lifetime_revenue DESC;
GO

/* E5. Does a late delivery cost us rating points? Avg rating by delivery_status.
       Observed: no. ~3.33 / 3.39 / 3.33 for On Time / Slightly / Significantly Delayed - ratings look
       independent of delivery performance in this data set. */
SELECT  delivery_status,
        COUNT(*)                                               AS orders_with_feedback,
        CAST(AVG(CAST(rating AS DECIMAL(4,2))) AS DECIMAL(4,2)) AS avg_rating,
        CAST(100.0 * SUM(CASE WHEN sentiment = 'Negative' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_negative
FROM blinkit.vw_order_enriched
WHERE rating IS NOT NULL
GROUP BY delivery_status
ORDER BY avg_rating DESC;
GO
