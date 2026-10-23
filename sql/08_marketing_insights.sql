/* =====================================================================
   08_marketing_insights.sql       Dashboard page: MARKETING INSIGHTS
   ===================================================================== */
USE BlinkitAnalytics;
GO

/* ---------------- KPI cards ----------------
   The report averages the supplied ROAS column. A spend-weighted ROAS
   (total revenue / total spend) is shown next to it because the two differ. */
SELECT
    COUNT(DISTINCT campaign_id)                                  AS total_campaigns,        -- 5,400 (= rows; campaign_id is unique per row)
    COUNT(DISTINCT campaign_name)                                AS distinct_campaign_names,-- 9
    CAST(SUM(spend) AS DECIMAL(14,2))                            AS total_spend,            -- 16,319,838.24
    CAST(SUM(revenue_generated) AS DECIMAL(14,2))                AS total_revenue,          -- 32,193,407.37
    CAST(AVG(roas) AS DECIMAL(6,2))                              AS avg_roas_dashboard,     -- 2.74 (simple average of supplied column)
    CAST(SUM(revenue_generated) / NULLIF(SUM(spend), 0) AS DECIMAL(6,2)) AS roas_weighted   -- 1.97 (revenue / spend)
FROM blinkit.marketing_performance;
GO

/* ---------------- Visual: Return on ad spend by channel (column) ---------------- */
SELECT  channel,
        CAST(AVG(roas) AS DECIMAL(6,3))                                          AS avg_roas_dashboard,
        CAST(SUM(revenue_generated) / NULLIF(SUM(spend), 0) AS DECIMAL(6,3))     AS roas_weighted,
        CAST(SUM(spend) AS DECIMAL(14,2))                                        AS spend,
        CAST(SUM(revenue_generated) AS DECIMAL(14,2))                            AS revenue
FROM blinkit.marketing_performance
GROUP BY channel
ORDER BY roas_weighted DESC;
GO

/* ---------------- Visual: Monthly marketing spend vs revenue generated (line) ---------------- */
SELECT campaign_month, CAST(spend AS DECIMAL(14,2)) AS spend,
       CAST(revenue_generated AS DECIMAL(14,2)) AS revenue_generated, roas_weighted
FROM blinkit.vw_monthly_marketing
ORDER BY campaign_month;
GO

/* ---------------- Visual: Top campaigns by total conversions (bar, Top 10 - only 9 exist) ---------------- */
SELECT TOP (10)
        campaign_name, SUM(conversions) AS total_conversions
FROM blinkit.marketing_performance
GROUP BY campaign_name
ORDER BY total_conversions DESC;        -- New User Discount 33,964 | Category Promotion 33,568 | Referral Program 33,490 ...
GO

/* ---------------- Visual: Marketing conversion funnel ---------------- */
SELECT  SUM(CAST(impressions AS BIGINT)) AS impressions,   -- 29,487,610
        SUM(CAST(clicks AS BIGINT))      AS clicks,        --  2,974,145
        SUM(CAST(conversions AS BIGINT)) AS conversions,   --    298,038
        CAST(100.0 * SUM(clicks)      / NULLIF(SUM(impressions), 0) AS DECIMAL(6,2)) AS ctr_pct,            -- ~10.09
        CAST(100.0 * SUM(conversions) / NULLIF(SUM(clicks), 0)      AS DECIMAL(6,2)) AS click_to_conv_pct   -- ~10.02
FROM blinkit.marketing_performance;
GO

/* ---------------- Visual: Marketing budget allocation by channel (donut) ---------------- */
SELECT  channel,
        CAST(SUM(spend) AS DECIMAL(14,2)) AS spend,
        CAST(100.0 * SUM(spend) / SUM(SUM(spend)) OVER () AS DECIMAL(5,2)) AS pct_of_budget
FROM blinkit.marketing_performance
GROUP BY channel
ORDER BY spend DESC;
GO


/* =====================================================================
   EXTRA ANALYSIS (not on the dashboard)
   ===================================================================== */

/* E1. Campaign scorecard: efficiency, not just volume. */
SELECT  campaign_name,
        CAST(SUM(spend) AS DECIMAL(14,2))                                       AS spend,
        CAST(SUM(revenue_generated) AS DECIMAL(14,2))                           AS revenue,
        CAST(SUM(revenue_generated) / NULLIF(SUM(spend), 0) AS DECIMAL(6,3))    AS roas_weighted,
        SUM(conversions)                                                        AS conversions,
        CAST(SUM(spend) / NULLIF(SUM(conversions), 0) AS DECIMAL(10,2))         AS cost_per_conversion,
        CAST(100.0 * SUM(clicks) / NULLIF(SUM(impressions), 0) AS DECIMAL(6,2)) AS ctr_pct
FROM blinkit.marketing_performance
GROUP BY campaign_name
ORDER BY roas_weighted DESC;            -- Referral Program best (~2.03), Category Promotion weakest (~1.94)
GO

/* E2. Channel x audience heat-map (weighted ROAS). */
SELECT  channel, target_audience,
        CAST(SUM(revenue_generated) / NULLIF(SUM(spend), 0) AS DECIMAL(6,3)) AS roas_weighted,
        CAST(SUM(spend) AS DECIMAL(14,2)) AS spend
FROM blinkit.marketing_performance
GROUP BY channel, target_audience
ORDER BY roas_weighted DESC;
GO

/* E3. Loss-making campaign-days (revenue < spend). Observed: 791 of 5,400 rows. */
SELECT  COUNT(*)                                              AS loss_making_rows,
        CAST(SUM(spend - revenue_generated) AS DECIMAL(14,2)) AS net_loss,
        CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM blinkit.marketing_performance) AS DECIMAL(5,2)) AS pct_of_rows
FROM blinkit.marketing_performance
WHERE revenue_generated < spend;
GO

/* E4. Spend efficiency in spend quartiles: do bigger days earn more per rupee?
       Observed: weighted ROAS falls from ~3.97 (lowest-spend quartile) to ~1.30 (highest) - revenue does not
       scale with spend, i.e. strongly diminishing returns. */
WITH q AS (
    SELECT *, NTILE(4) OVER (ORDER BY spend) AS spend_quartile FROM blinkit.marketing_performance
)
SELECT  spend_quartile,
        CAST(MIN(spend) AS DECIMAL(12,2)) AS min_spend, CAST(MAX(spend) AS DECIMAL(12,2)) AS max_spend,
        CAST(SUM(revenue_generated) / NULLIF(SUM(spend), 0) AS DECIMAL(6,3)) AS roas_weighted
FROM q GROUP BY spend_quartile ORDER BY spend_quartile;
GO
