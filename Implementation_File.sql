-- Create staging table for raw data
CREATE TABLE SupplyChainRaw (
    SKU_ID VARCHAR(50),
    Category VARCHAR(50),
    Warehouse VARCHAR(50),
    Current_Stock INT,
    Average_Daily_Demand DECIMAL(10,2),
    Lead_Time_Days INT,
    Order_Cost DECIMAL(10,2),
    Holding_Cost_Per_Unit DECIMAL(10,2),
    Last_Order_Date DATE
);

-- Remove duplicates
DELETE FROM SupplyChainRaw
WHERE SKU_ID IN (
    SELECT SKU_ID
    FROM SupplyChainRaw
    GROUP BY SKU_ID, Warehouse
    HAVING COUNT(*) > 1
);

-- Replace NULL values with defaults
UPDATE SupplyChainRaw
SET Current_Stock = ISNULL(Current_Stock, 0),
    Average_Daily_Demand = ISNULL(Average_Daily_Demand, 0),
    Lead_Time_Days = ISNULL(Lead_Time_Days, 5),
    Order_Cost = ISNULL(Order_Cost, 100),
    Holding_Cost_Per_Unit = ISNULL(Holding_Cost_Per_Unit, 5);

-- Create clean fact table
CREATE TABLE SupplyChainFact AS
SELECT 
    SKU_ID,
    Category,
    Warehouse,
    Current_Stock,
    Average_Daily_Demand,
    Lead_Time_Days,
    Order_Cost,
    Holding_Cost_Per_Unit,
    Last_Order_Date
FROM SupplyChainRaw;

-- Calculate EOQ
ALTER TABLE SupplyChainFact ADD EOQ DECIMAL(18,2);

UPDATE SupplyChainFact
SET EOQ = SQRT((2 * (Average_Daily_Demand * 30) * Order_Cost) / NULLIF(Holding_Cost_Per_Unit,0));

-- Calculate Safety Stock
WITH DemandStats AS (
    SELECT 
        Warehouse,
        STDEV(Average_Daily_Demand) AS DemandStdDev
    FROM SupplyChainFact
    GROUP BY Warehouse
)
UPDATE f
SET f.Safety_Stock = (1.645 * d.DemandStdDev * f.Lead_Time_Days)
FROM SupplyChainFact f
JOIN DemandStats d ON f.Warehouse = d.Warehouse;

-- Calculate Reorder Point
ALTER TABLE SupplyChainFact ADD Reorder_Point DECIMAL(18,2);

UPDATE SupplyChainFact
SET Reorder_Point = (Average_Daily_Demand * Lead_Time_Days) + Safety_Stock;

-- Create warehouse summary view
CREATE VIEW vw_WarehouseSummary AS
SELECT 
    Warehouse,
    SUM(Current_Stock) AS Total_Stock,
    SUM(EOQ) AS Total_EOQ,
    SUM(Reorder_Point) AS Total_ROP,
    SUM(Safety_Stock) AS Total_SafetyStock
FROM SupplyChainFact
GROUP BY Warehouse;

-- Create stockout risk view
CREATE VIEW vw_StockoutRisk AS
SELECT 
    SKU_ID,
    Warehouse,
    Current_Stock,
    Safety_Stock,
    CASE WHEN Current_Stock < Safety_Stock THEN 'AT RISK' ELSE 'SAFE' END AS Stock_Status
FROM SupplyChainFact;

-- Create replenishment accuracy view
CREATE VIEW vw_ReplenishmentAccuracy AS
SELECT 
    Warehouse,
    COUNT(CASE WHEN Current_Stock BETWEEN 0.9*EOQ AND 1.1*EOQ THEN 1 END)*100.0 / COUNT(*) AS Accuracy_Percent
FROM SupplyChainFact
GROUP BY Warehouse;
