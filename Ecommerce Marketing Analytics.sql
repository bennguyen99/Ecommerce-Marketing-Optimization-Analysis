/* DATA CLEANING */

-- CLEANING DATA

-- Check data type
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'tax_amount';

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'Online_Sales_raw';

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'marketing_spend_raw';

	-- Reformat the GST column in "tax_amount" to integer
DROP TABLE IF EXISTS tax_amount_fmt;

CREATE TEMP TABLE tax_amount_fmt AS
(SELECT "Product_Category",
REPLACE ("GST", '%', '')::INT AS "GST_fmt"
FROM "tax_amount");

-- Reformat data type
	-- Reformat Transation_Date column
DROP TABLE IF EXISTS online_sales_fmt;

With Transaction_Date AS
(SELECT *, 
REPLACE ("Transaction_Date", '/', '-') AS "Transaction_Date_new"
FROM "Online_Sales_raw"), 

online_sales_date AS
(SELECT *, 
CONCAT(
		RIGHT("Transaction_Date_new", 4) 
		|| '-' 
		|| REPLACE("Transaction_Date_new", RIGHT("Transaction_Date_new", 5), '')
		)::date AS "Transaction_Date_fmt"
FROM Transaction_Date)

SELECT *,
TO_CHAR ("Transaction_Date_fmt", 'Mon') AS "Month",
EXTRACT (MONTH FROM "Transaction_Date_fmt") AS "Month_Num"
INTO online_sales_fmt
FROM online_sales_date;

	-- Reformat Date column
DROP TABLE IF EXISTS marketing_spend_fmt;
	
With Date AS
(SELECT *, 
REPLACE ("Date", '/', '-') AS "Date_new"
FROM "marketing_spend_raw")

SELECT *, 
CONCAT(
		RIGHT("Date_new", 4) 
		|| '-' 
		|| REPLACE("Date_new", RIGHT("Date_new", 5), '')
		)::date AS "Date_fmt"
INTO marketing_spend_fmt
FROM Date;

DROP TABLE IF EXISTS customers_segmented;

WITH Longevity_segmentation AS
(SELECT *, 
CASE
WHEN "Tenure_Months" <= 6 THEN 'New'
WHEN "Tenure_Months" < 24 THEN 'Established'
ELSE 'Loyal'
END AS "tenure_segment"
FROM customers
)

SELECT *
INTO customers_segmented
FROM Longevity_segmentation;

/* EDA */

/* I. Channel & Spending Efficiency */
-- 1. How does ROAS vary across channels month by month?

	-- Calculate retail price after discount
WITH revenue_after_coupon AS
(SELECT o."Month", o."Month_Num",
SUM(CASE 
WHEN "Coupon_Status" IN ('Used') THEN ("Avg_Price" - ("Avg_Price"/100 * "Discount_pct")) * "Quantity"
ELSE "Avg_Price"*"Quantity"
END) AS revenue_after_coupon
FROM online_sales_fmt AS o
INNER JOIN discount_coupon AS d
ON o."Product_Category" = d."Product_Category"
AND o."Month" = d."Month"
GROUP BY o."Month", o."Month_Num"),
	
	-- Calculate the total ad spend of each month
marketing_spend_total AS 
(SELECT 
SUM("Offline_Spend") AS "Offline_Spend", 
SUM("Online_Spend") AS "Online_Spend",
TO_CHAR ("Date_fmt", 'Mon') AS "Month",
EXTRACT (MONTH FROM "Date_fmt") AS "Month_Num"
FROM marketing_spend_fmt
GROUP BY TO_CHAR ("Date_fmt", 'Mon'), 
EXTRACT (MONTH FROM "Date_fmt"))
	
	-- Calculate monthly ROAS for each channel
SELECT r."Month",
ROUND(revenue_after_coupon/"Offline_Spend", 2) AS ROAS_Offline,
ROUND(revenue_after_coupon/"Online_Spend", 2) AS ROAS_Online
FROM revenue_after_coupon AS r
INNER JOIN marketing_spend_total AS m
ON r."Month" = m."Month"
AND r."Month_Num" = m."Month_Num"
ORDER BY r."Month_Num" ASC;

-- 2. Find cities with high ad spend and low ROAS (ineffective ad spend by location)
	-- Assumption: Ad spend is divided evenly for every city. Real-life situations would require further clarification of the budget allocated for each location.

 	-- Calculate annual revenue after discount
WITH revenue_after_disc AS
(SELECT EXTRACT (YEAR FROM o."Transaction_Date_fmt") AS "Year",
c."Location",
ROUND(
SUM(CASE 
WHEN "Coupon_Status" IN ('Used') THEN ("Avg_Price" - ("Avg_Price"/100 * "Discount_pct")) * "Quantity"
ELSE "Avg_Price"*"Quantity"
END), 2)
AS revenue_after_disc
FROM online_sales_fmt AS o
INNER JOIN discount_coupon AS d
ON o."Product_Category" = d."Product_Category"
INNER JOIN customers AS c
ON o."CustomerID" = c."CustomerID"
GROUP BY EXTRACT (YEAR FROM o."Transaction_Date_fmt"), c."Location"
),	

	-- Calculate the total ad spend of each month and divide by 5 (the number of locations)
marketing_spend_total AS 
(SELECT 
ROUND (SUM("Offline_Spend" + "Online_Spend")/5, 2) AS "ad_spend",
EXTRACT (YEAR FROM "Date_fmt") AS "Year"
FROM marketing_spend_fmt
GROUP BY EXTRACT (YEAR FROM "Date_fmt")
)

SELECT r."Year", "Location",
r."revenue_after_disc"/m."ad_spend" AS ROAS
FROM revenue_after_disc AS r
INNER JOIN marketing_spend_total AS m
ON r."Year" = m."Year";

/* 
Top 2 top ROAS: Chicago & California
Top 2 bottom ROAS: Washington DC and New Jersey 
*/

-- 3. ROAS by demographics

 	-- Calculate annual revenue after discount
SELECT c."tenure_segment", c."Gender",
EXTRACT (YEAR FROM o."Transaction_Date_fmt") AS "Year",
COUNT (DISTINCT o."CustomerID") AS "customer_count",
ROUND(
SUM(CASE 
WHEN "Coupon_Status" IN ('Used') THEN ("Avg_Price" - ("Avg_Price"/100 * "Discount_pct")) * "Quantity"
ELSE "Avg_Price"*"Quantity"
END), 2)
AS revenue_after_disc
FROM online_sales_fmt AS o
INNER JOIN discount_coupon AS d
ON o."Product_Category" = d."Product_Category"
INNER JOIN customers_segmented AS c
ON o."CustomerID" = c."CustomerID"
GROUP BY EXTRACT (YEAR FROM o."Transaction_Date_fmt"), c."tenure_segment", c."Gender"
ORDER BY revenue_after_disc DESC;

-- 4. Cost per Order by channel
	-- Calculate order count
WITH order_count AS
(SELECT "Month", "Month_Num",
COUNT (DISTINCT "Transaction_ID") AS "order_count"
FROM online_sales_fmt
GROUP BY "Month", "Month_Num"
),
	
	-- Calculate the total ad spend of each month
marketing_spend_total AS 
(SELECT 
SUM("Offline_Spend") AS "Offline_Spend", 
SUM("Online_Spend") AS "Online_Spend",
TO_CHAR ("Date_fmt", 'Mon') AS "Month",
EXTRACT (MONTH FROM "Date_fmt") AS "Month_Num"
FROM marketing_spend_fmt
GROUP BY TO_CHAR ("Date_fmt", 'Mon'), 
EXTRACT (MONTH FROM "Date_fmt")
)
	-- Calculate cost per Order
SELECT o."Month",
m."Offline_Spend"/o."order_count" AS "Offline_CPO",
ROUND(m."Online_Spend"/o."order_count", 2) AS "Online_CPO"
FROM order_count AS o
INNER JOIN marketing_spend_total AS m
ON o."Month" = m."Month"
AND o."Month_Num" = m."Month_Num"
ORDER BY o."Month_Num" ASC;

/* Promotion & Coupon Optimization */
-- 5. Redemption Rate
	/* Note: "Since the dataset did not include campaign-level ad spend, I allocated total daily marketing cost proportionally 
	across transactions based on revenue share. This provides a consistent cost base to evaluate coupon-level ROAS." */
	-- by coupon code
	
-- Cleaned & corrected SQL
-- 1) Delivery_Charges allocated per order line using Transaction_Count
-- 2) net_profit = total_revenue_after_discount - total_cogs - total_allocated_ad_spend

WITH sales_base AS (
    -- transaction-line level: compute revenue per line and transaction-level line count
    SELECT
        o."Transaction_ID",
        o."Transaction_Date_fmt",
        o."Coupon_Status",
        d."Coupon_Code",
        d."Discount_pct",
        o."Quantity",
        o."Avg_Price",
        o."Delivery_Charges",
        t."GST_fmt",
        COUNT(*) OVER (PARTITION BY o."Transaction_ID") AS transaction_line_count,

        -- revenue after discount on this line
        ROUND(
            CASE
                WHEN o."Coupon_Status" = 'Used'
                    THEN (o."Avg_Price" - (o."Avg_Price" * d."Discount_pct" / 100.0)) * o."Quantity"
                ELSE o."Avg_Price" * o."Quantity"
            END, 1
        ) AS revenue_after_discount,

        -- discount amount on this line
        ROUND(
            CASE
                WHEN o."Coupon_Status" = 'Used'
                    THEN (o."Avg_Price" * d."Discount_pct" / 100.0) * o."Quantity"
                ELSE 0
            END, 1
        ) AS discount_amount
    FROM online_sales_fmt AS o
    JOIN discount_coupon AS d
        ON o."Product_Category" = d."Product_Category"
        AND o."Month" = d."Month"
    JOIN tax_amount_fmt AS t
        ON o."Product_Category" = t."Product_Category"
),

-- total daily revenue used for proportional allocation of daily ad spend
daily_revenue AS (
    SELECT
        "Transaction_Date_fmt",
        SUM(revenue_after_discount) AS total_daily_revenue
    FROM sales_base
    GROUP BY "Transaction_Date_fmt"
),

-- bring in daily marketing spend
daily_spend AS (
    SELECT
        m."Date_fmt",
        m."Online_Spend",
        m."Offline_Spend",
        COALESCE(r.total_daily_revenue, 0) AS total_daily_revenue
    FROM marketing_spend_fmt AS m
    LEFT JOIN daily_revenue AS r
        ON m."Date_fmt" = r."Transaction_Date_fmt"
),

-- allocate daily spend proportionally to each transaction-line; compute per-row COGS correctly
sales_with_spend AS (
    SELECT
        s.*,
        d."Online_Spend",
        d."Offline_Spend",
        d.total_daily_revenue,

        -- allocate online/offline spend proportionally by revenue share
        CASE
            WHEN d.total_daily_revenue > 0 THEN (s.revenue_after_discount / d.total_daily_revenue) * d."Online_Spend"
            ELSE 0
        END AS allocated_online_spend,

        CASE
            WHEN d.total_daily_revenue > 0 THEN (s.revenue_after_discount / d.total_daily_revenue) * d."Offline_Spend"
            ELSE 0
        END AS allocated_offline_spend,

        -- per-row COGS:
        --  - delivery charge is order-level: allocate by dividing by number of lines in that transaction
        --  - GST/other product-level cost approximated as revenue_after_discount * GST_fmt / 100
        ( COALESCE(s."Delivery_Charges", 0) / NULLIF(s.transaction_line_count, 0)
        ) 
        + ( (s.revenue_after_discount * COALESCE(s."GST_fmt", 0)) / 100.0
        ) AS per_row_cogs
    FROM sales_base AS s
    LEFT JOIN daily_spend AS d
        ON s."Transaction_Date_fmt" = d."Date_fmt"
),

-- aggregate up to coupon-code level (only include orders where coupon was used)
coupon_summary AS (
    SELECT
        "Coupon_Code",
        "Discount_pct",
        COUNT(DISTINCT "Transaction_ID") AS order_count,
        COUNT(*) FILTER (WHERE "Coupon_Status" = 'Used') AS coupon_used_count,
        SUM(revenue_after_discount) AS total_revenue_after_discount,
        SUM(discount_amount) AS total_discount,
        ROUND(SUM(per_row_cogs), 1) AS total_cogs,
        ROUND(SUM(allocated_online_spend), 1) AS total_online_ad_spend,
        ROUND(SUM(allocated_offline_spend), 1) AS total_offline_ad_spend
    FROM sales_with_spend
    WHERE "Coupon_Status" = 'Used'
    GROUP BY "Coupon_Code", "Discount_pct"
)

-- final metrics: net profit includes allocated ad spend; margin computed on net profit
SELECT
    cs."Coupon_Code", CONCAT(cs."Discount_pct", '%') AS "discount_pct",
	cs."coupon_used_count", cs."total_revenue_after_discount",
    -- net profit subtracts COGS and allocated ad spend
    ROUND(
        cs.total_revenue_after_discount
        - cs.total_cogs
        - (cs.total_online_ad_spend + cs.total_offline_ad_spend)
    , 2) AS net_profit,
    -- profit margin = net_profit / total_revenue_after_discount * 100
    CONCAT( 
	ROUND(
        CASE WHEN cs.total_revenue_after_discount <> 0 
            THEN (
                (cs.total_revenue_after_discount - cs.total_cogs - (cs.total_online_ad_spend + cs.total_offline_ad_spend))
                / cs.total_revenue_after_discount * 100.0
            )
            ELSE NULL
        END
    , 2), '%') AS profit_margin_pct
FROM coupon_summary cs
ORDER BY profit_margin_pct ASC;


/* Group code "WEMP" and code "AND30" records a considerably low profit margin from -12.64% to only 8.98%. 
Based on this table, it is also obvious that within a coupon group, certain coupons perform better than others */

	-- by discount range
WITH sales_base AS (
    	-- transaction-line level: compute revenue per line and transaction-level line count
    SELECT
        o."Transaction_ID",
        o."Transaction_Date_fmt",
        o."Coupon_Status",
        d."Coupon_Code",
        d."Discount_pct",
        o."Quantity",
        o."Avg_Price",
        o."Delivery_Charges",
        t."GST_fmt",
        COUNT(*) OVER (PARTITION BY o."Transaction_ID") AS transaction_line_count,

        -- revenue after discount on this line
        ROUND(
            CASE
                WHEN o."Coupon_Status" = 'Used'
                    THEN (o."Avg_Price" - (o."Avg_Price" * d."Discount_pct" / 100.0)) * o."Quantity"
                ELSE o."Avg_Price" * o."Quantity"
            END, 1
        ) AS revenue_after_discount,

        -- discount amount on this line
        ROUND(
            CASE
                WHEN o."Coupon_Status" = 'Used'
                    THEN (o."Avg_Price" * d."Discount_pct" / 100.0) * o."Quantity"
                ELSE 0
            END, 1
        ) AS discount_amount
    FROM online_sales_fmt AS o
    JOIN discount_coupon AS d
        ON o."Product_Category" = d."Product_Category"
        AND o."Month" = d."Month"
    JOIN tax_amount_fmt AS t
        ON o."Product_Category" = t."Product_Category"
),

			-- total daily revenue used for proportional allocation of daily ad spend
daily_revenue AS (
    SELECT
        "Transaction_Date_fmt",
        SUM(revenue_after_discount) AS total_daily_revenue
    FROM sales_base
    GROUP BY "Transaction_Date_fmt"
),

			-- bring in daily marketing spend
daily_spend AS (
    SELECT
        m."Date_fmt",
        m."Online_Spend",
        m."Offline_Spend",
        COALESCE(r.total_daily_revenue, 0) AS total_daily_revenue
    FROM marketing_spend_fmt AS m
    LEFT JOIN daily_revenue AS r
        ON m."Date_fmt" = r."Transaction_Date_fmt"
),

			-- allocate daily spend proportionally to each transaction-line; compute per-row COGS correctly
sales_with_spend AS (
    SELECT
        s.*,
        d."Online_Spend",
        d."Offline_Spend",
        d.total_daily_revenue,

        		-- allocate online/offline spend proportionally by revenue share
        CASE
            WHEN d.total_daily_revenue > 0 THEN (s.revenue_after_discount / d.total_daily_revenue) * d."Online_Spend"
            ELSE 0
        END AS allocated_online_spend,

        CASE
            WHEN d.total_daily_revenue > 0 THEN (s.revenue_after_discount / d.total_daily_revenue) * d."Offline_Spend"
            ELSE 0
        END AS allocated_offline_spend,

       		-- per-row COGS:
        	--  - delivery charge is order-level: allocate by dividing by number of lines in that transaction
        	--  - GST/other product-level cost approximated as revenue_after_discount * GST_fmt / 100
        ( COALESCE(s."Delivery_Charges", 0) / NULLIF(s.transaction_line_count, 0)
        ) 
        + ( (s.revenue_after_discount * COALESCE(s."GST_fmt", 0)) / 100.0
        ) AS per_row_cogs
    FROM sales_base AS s
    LEFT JOIN daily_spend AS d
        ON s."Transaction_Date_fmt" = d."Date_fmt"
),

			-- aggregate up to coupon-code level (only include orders where coupon was used)
coupon_summary AS (
    SELECT "Discount_pct",
        COUNT(DISTINCT "Transaction_ID") AS order_count,
        COUNT(*) FILTER (WHERE "Coupon_Status" = 'Used') AS coupon_used_count,
        SUM(revenue_after_discount) AS total_revenue_after_discount,
        SUM(discount_amount) AS total_discount,
        ROUND(SUM(per_row_cogs), 1) AS total_cogs,
        ROUND(SUM(allocated_online_spend), 1) AS total_online_ad_spend,
        ROUND(SUM(allocated_offline_spend), 1) AS total_offline_ad_spend
    FROM sales_with_spend
    WHERE "Coupon_Status" = 'Used'
    GROUP BY "Discount_pct"
)

			-- final metrics: net profit includes allocated ad spend; margin computed on net profit
SELECT CONCAT(cs."Discount_pct", '%') AS "discount_pct",
	cs."coupon_used_count", cs."total_revenue_after_discount",
    			-- net profit subtracts COGS and allocated ad spend
    ROUND(
        cs.total_revenue_after_discount
        - cs.total_cogs
        - (cs.total_online_ad_spend + cs.total_offline_ad_spend)
    , 2) AS net_profit,
    			-- profit margin = net_profit / total_revenue_after_discount * 100
    CONCAT( 
	ROUND(
        CASE WHEN cs.total_revenue_after_discount <> 0 
            THEN (
                (cs.total_revenue_after_discount - cs.total_cogs - (cs.total_online_ad_spend + cs.total_offline_ad_spend))
                / cs.total_revenue_after_discount * 100.0
            )
            ELSE NULL
        END
    , 2), '%') AS profit_margin_pct
FROM coupon_summary cs
ORDER BY profit_margin_pct ASC;
