/* =====================================================================
   10_delivery_insights.sql        EXTRA - delivery performance
   The Power BI model already relates blinkit_delivery_performance to
   orders (1:1) but no page visualises it. These queries cover that gap.
   Remember: delivery_time_minutes = minutes late (+) / early (-) vs the
   promised time, and status bands are On Time <= 5, Slightly 6-15,
   Significantly 16-30 minutes late.
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* 1. SLA summary. */
SELECT  COUNT(*)                                                                    AS orders,
        CAST(100.0 * SUM(CASE WHEN delivery_status = 'On Time' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS on_time_pct,
        CAST(AVG(delivery_time_minutes) AS DECIMAL(6,2))                            AS avg_minutes_vs_promise,
        CAST(AVG(CASE WHEN delivery_status <> 'On Time' THEN delivery_time_minutes END) AS DECIMAL(6,2)) AS avg_delay_when_late,
        CAST(AVG(distance_km) AS DECIMAL(5,2))                                      AS avg_distance_km
FROM blinkit.delivery_performance;
GO

/* 2. Status mix by month - is service getting better or worse? */
SELECT  order_month,
        COUNT(*) AS orders,
        CAST(100.0 * SUM(CASE WHEN delivery_status = 'On Time'              THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS on_time_pct,
        CAST(100.0 * SUM(CASE WHEN delivery_status = 'Slightly Delayed'     THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS slightly_delayed_pct,
        CAST(100.0 * SUM(CASE WHEN delivery_status = 'Significantly Delayed' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS significantly_delayed_pct
FROM blinkit.vw_order_enriched
GROUP BY order_month
ORDER BY order_month;
GO

/* 3. Does distance explain lateness? (In this data it barely does - rates are flat across bands.) */
SELECT  CASE WHEN distance_km <= 1 THEN '0-1 km' WHEN distance_km <= 2 THEN '1-2 km'
             WHEN distance_km <= 3 THEN '2-3 km' WHEN distance_km <= 4 THEN '3-4 km' ELSE '4-5 km' END AS distance_band,
        COUNT(*) AS orders,
        CAST(100.0 * SUM(CASE WHEN delivery_status <> 'On Time' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS late_pct,
        CAST(AVG(delivery_time_minutes) AS DECIMAL(6,2)) AS avg_minutes_vs_promise
FROM blinkit.delivery_performance
GROUP BY CASE WHEN distance_km <= 1 THEN '0-1 km' WHEN distance_km <= 2 THEN '1-2 km'
              WHEN distance_km <= 3 THEN '2-3 km' WHEN distance_km <= 4 THEN '3-4 km' ELSE '4-5 km' END
ORDER BY MIN(distance_km);
GO

/* 4. Lateness by hour of day (peak-hour pressure). Observed: 23%-37% across hours, no clear peak. */
SELECT  order_hour, COUNT(*) AS orders,
        CAST(100.0 * SUM(CASE WHEN delivery_status <> 'On Time' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS late_pct
FROM blinkit.vw_order_enriched
GROUP BY order_hour
ORDER BY order_hour;
GO

/* 5. Delay reasons. Only 'Traffic' exists and it is also attached to 1,568 on-time orders,
      so the field cannot explain delays - fix capture at source before building a visual on it. */
SELECT  delivery_status, ISNULL(reasons_if_delayed, '(none recorded)') AS reason, COUNT(*) AS orders
FROM blinkit.delivery_performance
GROUP BY delivery_status, ISNULL(reasons_if_delayed, '(none recorded)')
ORDER BY delivery_status, orders DESC;
GO

/* 6. Customer impact: rating by delivery status. Observed: avg rating is ~3.3-3.4 for every status. */
SELECT  delivery_status,
        COUNT(*) AS orders,
        CAST(AVG(CAST(rating AS DECIMAL(4,2))) AS DECIMAL(4,2)) AS avg_rating,
        CAST(100.0 * SUM(CASE WHEN rating <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_rating_1_2
FROM blinkit.vw_order_enriched
WHERE rating IS NOT NULL
GROUP BY delivery_status
ORDER BY avg_rating DESC;
GO

/* 7. Delivery partners: every partner_id appears once in this data set (5,000 partners for 5,000 orders),
      so a partner league table is not meaningful here. With production data use this template. */
SELECT TOP (20)
        delivery_partner_id, COUNT(*) AS deliveries,
        CAST(100.0 * SUM(CASE WHEN delivery_status = 'On Time' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS on_time_pct,
        CAST(AVG(delivery_time_minutes) AS DECIMAL(6,2)) AS avg_minutes_vs_promise
FROM blinkit.delivery_performance
GROUP BY delivery_partner_id
HAVING COUNT(*) >= 30
ORDER BY on_time_pct DESC, deliveries DESC;
GO
