SELECT pg_typeof ("GST")
FROM "tax_amount";

-- Reformat the GST column in "tax_amount" to integer
With tax_amount_fmt AS
(SELECT "Product_Category",
REPLACE ("GST", '%', '')::INT
FROM"tax_amount")

-- 
SELECT *
FROM tax_amount_fmt
LIMIT 5

