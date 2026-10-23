/* =====================================================================
   01_create_database_and_tables.sql
   Project : Blinkit Retail Analytics (SQL Server + Power BI)
   Purpose : Create the database, schemas and the typed "core" tables.
   Target  : SQL Server 2017+ (BULK INSERT ... FORMAT='CSV' needs 2017+)
   Run     : Once, in SSMS / Azure Data Studio, before script 02.

   Layers
     stg     raw CSV copies (all text) - created in script 02
     blinkit typed, constrained tables - created here

   Note: two source columns named "date" are renamed (campaign_date,
   stock_date) because DATE is a T-SQL type name.
   ===================================================================== */

IF DB_ID(N'BlinkitAnalytics') IS NULL
    CREATE DATABASE BlinkitAnalytics;
GO
USE BlinkitAnalytics;
GO

IF SCHEMA_ID(N'stg')     IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'blinkit') IS NULL EXEC (N'CREATE SCHEMA blinkit');
GO

/* ---------- Drop in reverse dependency order (re-runnable) ---------- */
DROP TABLE IF EXISTS blinkit.inventory_monthly;
DROP TABLE IF EXISTS blinkit.inventory;
DROP TABLE IF EXISTS blinkit.marketing_performance;
DROP TABLE IF EXISTS blinkit.delivery_performance;
DROP TABLE IF EXISTS blinkit.customer_feedback;
DROP TABLE IF EXISTS blinkit.order_items;
DROP TABLE IF EXISTS blinkit.orders;
DROP TABLE IF EXISTS blinkit.products;
DROP TABLE IF EXISTS blinkit.customers;
GO

/* ---------- Dimensions ---------- */
CREATE TABLE blinkit.customers (
    customer_id        INT            NOT NULL,
    customer_name      NVARCHAR(100)  NOT NULL,
    email              NVARCHAR(150)  NULL,
    phone              VARCHAR(20)    NULL,      -- stored as text, keeps the leading '+'
    address            NVARCHAR(300)  NULL,
    area               NVARCHAR(100)  NULL,
    pincode            INT            NULL,
    registration_date  DATE           NOT NULL,
    customer_segment   VARCHAR(20)    NOT NULL,
    total_orders       INT            NOT NULL,  -- as supplied; see docs/data_quality_findings.md
    avg_order_value    DECIMAL(12,2)  NOT NULL,  -- as supplied (customer-level attribute)
    CONSTRAINT PK_customers PRIMARY KEY (customer_id),
    CONSTRAINT CK_customers_segment CHECK (customer_segment IN ('New','Regular','Premium','Inactive')),
    CONSTRAINT CK_customers_total_orders CHECK (total_orders >= 0)
);

CREATE TABLE blinkit.products (
    product_id         INT            NOT NULL,
    product_name       NVARCHAR(100)  NOT NULL,
    category           NVARCHAR(60)   NOT NULL,
    brand              NVARCHAR(100)  NOT NULL,
    price              DECIMAL(12,2)  NOT NULL,
    mrp                DECIMAL(12,2)  NOT NULL,
    margin_percentage  DECIMAL(5,2)   NOT NULL,
    shelf_life_days    INT            NOT NULL,
    min_stock_level    INT            NOT NULL,
    max_stock_level    INT            NOT NULL,
    CONSTRAINT PK_products PRIMARY KEY (product_id),
    CONSTRAINT CK_products_price CHECK (price > 0 AND price <= mrp),
    CONSTRAINT CK_products_stock_levels CHECK (min_stock_level <= max_stock_level)
);

/* ---------- Facts ---------- */
CREATE TABLE blinkit.orders (
    order_id                BIGINT         NOT NULL,   -- values exceed INT range
    customer_id             INT            NOT NULL,
    order_date              DATETIME2(0)   NOT NULL,
    promised_delivery_time  DATETIME2(0)   NOT NULL,
    actual_delivery_time    DATETIME2(0)   NOT NULL,
    delivery_status         VARCHAR(25)    NOT NULL,
    order_total             DECIMAL(12,2)  NOT NULL,
    payment_method          VARCHAR(20)    NOT NULL,
    delivery_partner_id     INT            NOT NULL,
    store_id                INT            NOT NULL,
    /* Same logic as the Power BI custom column "delivery_delay_min"
       (actual - promised, in minutes; negative = early). */
    delivery_delay_min AS CAST(DATEDIFF(SECOND, promised_delivery_time, actual_delivery_time) / 60.0 AS DECIMAL(8,2)) PERSISTED,
    CONSTRAINT PK_orders PRIMARY KEY (order_id),
    CONSTRAINT FK_orders_customers FOREIGN KEY (customer_id) REFERENCES blinkit.customers (customer_id),
    CONSTRAINT CK_orders_status CHECK (delivery_status IN ('On Time','Slightly Delayed','Significantly Delayed')),
    CONSTRAINT CK_orders_payment CHECK (payment_method IN ('Card','Cash','UPI','Wallet')),
    CONSTRAINT CK_orders_total CHECK (order_total >= 0)
);

CREATE TABLE blinkit.order_items (
    order_id    BIGINT         NOT NULL,
    product_id  INT            NOT NULL,
    quantity    INT            NOT NULL,
    unit_price  DECIMAL(12,2)  NOT NULL,
    line_total AS CAST(quantity * unit_price AS DECIMAL(14,2)) PERSISTED,
    CONSTRAINT PK_order_items PRIMARY KEY (order_id, product_id),
    CONSTRAINT FK_order_items_orders   FOREIGN KEY (order_id)   REFERENCES blinkit.orders (order_id),
    CONSTRAINT FK_order_items_products FOREIGN KEY (product_id) REFERENCES blinkit.products (product_id),
    CONSTRAINT CK_order_items_qty CHECK (quantity > 0)
);

CREATE TABLE blinkit.customer_feedback (
    feedback_id        INT            NOT NULL,
    order_id           BIGINT         NOT NULL,       -- 1 feedback per order
    customer_id        INT            NOT NULL,
    rating             TINYINT        NOT NULL,
    feedback_text      NVARCHAR(200)  NULL,
    feedback_category  VARCHAR(30)    NOT NULL,
    sentiment          VARCHAR(10)    NOT NULL,
    feedback_date      DATE           NOT NULL,
    CONSTRAINT PK_customer_feedback PRIMARY KEY (feedback_id),
    CONSTRAINT UQ_customer_feedback_order UNIQUE (order_id),
    CONSTRAINT FK_feedback_orders    FOREIGN KEY (order_id)    REFERENCES blinkit.orders (order_id),
    CONSTRAINT FK_feedback_customers FOREIGN KEY (customer_id) REFERENCES blinkit.customers (customer_id),
    CONSTRAINT CK_feedback_rating    CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT CK_feedback_sentiment CHECK (sentiment IN ('Positive','Neutral','Negative'))
);

CREATE TABLE blinkit.delivery_performance (
    order_id               BIGINT         NOT NULL,   -- 1 row per order
    delivery_partner_id    INT            NOT NULL,
    promised_time          DATETIME2(0)   NOT NULL,
    actual_time            DATETIME2(0)   NOT NULL,
    /* NOTE: in the source this is the minutes late (+) / early (-) versus the
       promise, NOT the total trip duration. Name kept for traceability. */
    delivery_time_minutes  DECIMAL(6,1)   NOT NULL,
    distance_km            DECIMAL(6,2)   NOT NULL,
    delivery_status        VARCHAR(25)    NOT NULL,
    reasons_if_delayed     VARCHAR(50)    NULL,
    CONSTRAINT PK_delivery_performance PRIMARY KEY (order_id),
    CONSTRAINT FK_delivery_orders FOREIGN KEY (order_id) REFERENCES blinkit.orders (order_id)
);

CREATE TABLE blinkit.marketing_performance (
    campaign_id        INT            NOT NULL,   -- unique per row (a campaign-day), not per campaign
    campaign_name      VARCHAR(50)    NOT NULL,
    campaign_date      DATE           NOT NULL,
    target_audience    VARCHAR(20)    NOT NULL,
    channel            VARCHAR(20)    NOT NULL,
    impressions        INT            NOT NULL,
    clicks             INT            NOT NULL,
    conversions        INT            NOT NULL,
    spend              DECIMAL(14,2)  NOT NULL,
    revenue_generated  DECIMAL(14,2)  NOT NULL,
    roas               DECIMAL(8,2)   NOT NULL,   -- as supplied; differs from revenue/spend, see docs
    CONSTRAINT PK_marketing_performance PRIMARY KEY (campaign_id)
);

CREATE TABLE blinkit.inventory (                 -- daily grain (used by the Power BI report)
    product_id      INT   NOT NULL,
    stock_date      DATE  NOT NULL,
    stock_received  INT   NOT NULL,
    damaged_stock   INT   NOT NULL,
    CONSTRAINT PK_inventory PRIMARY KEY (product_id, stock_date),
    CONSTRAINT FK_inventory_products FOREIGN KEY (product_id) REFERENCES blinkit.products (product_id)
);

CREATE TABLE blinkit.inventory_monthly (         -- blinkit_inventoryNew.csv (monthly grain, not in the .pbix)
    inventory_row_id INT IDENTITY(1,1) NOT NULL, -- source has repeated (product, month) rows, so no natural key
    product_id       INT   NOT NULL,
    stock_month      DATE  NOT NULL,             -- first day of the month
    stock_received   INT   NOT NULL,
    damaged_stock    INT   NOT NULL,
    CONSTRAINT PK_inventory_monthly PRIMARY KEY (inventory_row_id),
    CONSTRAINT FK_inventory_monthly_products FOREIGN KEY (product_id) REFERENCES blinkit.products (product_id)
);
GO

/* ---------- Supporting indexes for the reporting queries ---------- */
CREATE INDEX IX_orders_customer      ON blinkit.orders (customer_id) INCLUDE (order_total);
CREATE INDEX IX_orders_date          ON blinkit.orders (order_date)  INCLUDE (order_total, delivery_status, payment_method);
CREATE INDEX IX_order_items_product  ON blinkit.order_items (product_id) INCLUDE (quantity, unit_price);
CREATE INDEX IX_feedback_customer    ON blinkit.customer_feedback (customer_id);
CREATE INDEX IX_marketing_date       ON blinkit.marketing_performance (campaign_date) INCLUDE (channel, campaign_name, spend, revenue_generated);
CREATE INDEX IX_inventory_date       ON blinkit.inventory (stock_date) INCLUDE (stock_received, damaged_stock);
GO
