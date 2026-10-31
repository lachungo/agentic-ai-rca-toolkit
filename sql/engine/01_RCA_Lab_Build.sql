USE master;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_ID(N'RCA') IS NULL CREATE DATABASE RCA;
GO
ALTER DATABASE RCA SET RECOVERY SIMPLE;
GO
USE RCA;
GO

DROP PROCEDURE IF EXISTS dbo.usp_RCA_PerformanceQuery;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_RunWorkload;
DROP TABLE IF EXISTS dbo.RCA_WorkResult;
DROP TABLE IF EXISTS dbo.RCA_GeneralLedger;
DROP TABLE IF EXISTS dbo.RCA_SecurityPerformance;
DROP TABLE IF EXISTS dbo.RCA_Portfolio;
DROP TABLE IF EXISTS dbo.RCA_EntityClass;
DROP TABLE IF EXISTS dbo.RCA_Number;
GO

CREATE TABLE dbo.RCA_Number
(
    Number int NOT NULL CONSTRAINT PK_RCA_Number PRIMARY KEY
);
GO

;WITH
E1(N) AS
(
    SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1))d(N)
),
E2(N) AS (SELECT 1 FROM E1 a CROSS JOIN E1 b),
E4(N) AS (SELECT 1 FROM E2 a CROSS JOIN E2 b),
E6(N) AS (SELECT 1 FROM E4 a CROSS JOIN E2 b),
N AS
(
    SELECT TOP (1000000)
        ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS n
    FROM E6
)
INSERT dbo.RCA_Number(Number)
SELECT CONVERT(int,n) FROM N;
GO

CREATE TABLE dbo.RCA_EntityClass
(
    EntityClassID int NOT NULL CONSTRAINT PK_RCA_EntityClass PRIMARY KEY,
    EntityClassName varchar(50) NOT NULL
);
INSERT dbo.RCA_EntityClass VALUES
(1,'Fund'),(2,'Portfolio'),(3,'Account'),(4,'Strategy'),(5,'Legal Entity');
GO

CREATE TABLE dbo.RCA_Portfolio
(
    PortfolioID int NOT NULL CONSTRAINT PK_RCA_Portfolio PRIMARY KEY,
    PortfolioCode varchar(20) NOT NULL,
    PortfolioName varchar(100) NOT NULL,
    EntityClassID int NOT NULL,
    IsActive bit NOT NULL,
    CreatedDate date NOT NULL
);
GO

INSERT dbo.RCA_Portfolio
SELECT TOP (5000)
    Number,
    CONCAT('PORT-',RIGHT(CONCAT('000000',Number),6)),
    CONCAT('RCA Portfolio ',Number),
    CASE WHEN Number%10<7 THEN 2 WHEN Number%10=7 THEN 1
         WHEN Number%10=8 THEN 3 ELSE 4 END,
    IIF(Number%50=0,0,1),
    DATEADD(day,-(Number%2500),CONVERT(date,'2026-08-08'))
FROM dbo.RCA_Number
ORDER BY Number;
GO

CREATE TABLE dbo.RCA_SecurityPerformance
(
    SecurityPerformanceID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_SecurityPerformance PRIMARY KEY CLUSTERED,
    PortfolioID int NOT NULL,
    EntityClassID int NOT NULL,
    SecurityID int NOT NULL,
    AsOfDate date NOT NULL,
    MarketValue decimal(19,4) NOT NULL,
    CostBasis decimal(19,4) NOT NULL,
    UnrealizedGainLoss AS (MarketValue-CostBasis) PERSISTED,
    Quantity decimal(19,4) NOT NULL,
    Price decimal(19,6) NOT NULL,
    StatusCode char(1) NOT NULL,
    SourceSystem varchar(20) NOT NULL,
    Payload char(50) NULL
);
GO

PRINT 'Loading 5,000,000 RCA_SecurityPerformance rows...';
INSERT dbo.RCA_SecurityPerformance WITH(TABLOCK)
(
    PortfolioID,EntityClassID,SecurityID,AsOfDate,MarketValue,
    CostBasis,Quantity,Price,StatusCode,SourceSystem,Payload
)
SELECT
    CASE WHEN n%100<35 THEN 1001 WHEN n%100<50 THEN 1002
         WHEN n%100<60 THEN 1003 ELSE ((n*37)%5000)+1 END,
    CASE WHEN n%10<8 THEN 2 ELSE (n%4)+1 END,
    ((n*17)%100000)+1,
    DATEADD(day,-(n%1825),CONVERT(date,'2026-08-08')),
    CONVERT(decimal(19,4),((n%100000)+100)*10.13),
    CONVERT(decimal(19,4),((n%95000)+100)*9.71),
    CONVERT(decimal(19,4),((n%10000)+1)/7.0),
    CONVERT(decimal(19,6),((n%50000)+100)/31.0),
    IIF(n%25=0,'I','A'),
    CASE n%4 WHEN 0 THEN 'FOIL' WHEN 1 THEN 'UEP'
             WHEN 2 THEN 'GL' ELSE 'RCA' END,
    REPLICATE(CHAR(65+(n%26)),50)
FROM
(
    SELECT Number n FROM dbo.RCA_Number
    UNION ALL SELECT Number+1000000 FROM dbo.RCA_Number
    UNION ALL SELECT Number+2000000 FROM dbo.RCA_Number
    UNION ALL SELECT Number+3000000 FROM dbo.RCA_Number
    UNION ALL SELECT Number+4000000 FROM dbo.RCA_Number
)x;
GO

CREATE INDEX IX_RCA_SecurityPerformance_AsOfDate
ON dbo.RCA_SecurityPerformance(AsOfDate)
INCLUDE(PortfolioID,EntityClassID,SecurityID,MarketValue,CostBasis,StatusCode);
GO

CREATE INDEX IX_RCA_SecurityPerformance_Portfolio
ON dbo.RCA_SecurityPerformance(PortfolioID,AsOfDate)
INCLUDE(EntityClassID,SecurityID,MarketValue,CostBasis,Quantity,Price,StatusCode);
GO

CREATE TABLE dbo.RCA_GeneralLedger
(
    GeneralLedgerID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_GeneralLedger PRIMARY KEY CLUSTERED,
    PortfolioID int NOT NULL,
    GLDate date NOT NULL,
    GLAccountCode varchar(20) NOT NULL,
    GLCredit decimal(19,4) NOT NULL,
    GLDebit decimal(19,4) NOT NULL,
    MultiCurrencyMultiplier decimal(19,8) NOT NULL,
    TransactionType varchar(20) NOT NULL,
    ReferenceNumber varchar(40) NULL,
    Payload char(40) NULL
);
GO

PRINT 'Loading 3,000,000 RCA_GeneralLedger rows...';
INSERT dbo.RCA_GeneralLedger WITH(TABLOCK)
(
    PortfolioID,GLDate,GLAccountCode,GLCredit,GLDebit,
    MultiCurrencyMultiplier,TransactionType,ReferenceNumber,Payload
)
SELECT
    CASE WHEN n%100<35 THEN 1001 WHEN n%100<50 THEN 1002
         ELSE ((n*53)%5000)+1 END,
    DATEADD(day,-(n%1825),CONVERT(date,'2026-08-08')),
    CONCAT('GL-',RIGHT(CONCAT('0000',n%250),4)),
    CONVERT(decimal(19,4),(n%75000)*1.11),
    CONVERT(decimal(19,4),(n%73000)*1.07),
    CONVERT(decimal(19,8),0.75+((n%100)/100.0)),
    CASE n%4 WHEN 0 THEN 'BUY' WHEN 1 THEN 'SELL'
             WHEN 2 THEN 'ACCRUAL' ELSE 'CASH' END,
    CONCAT('REF-',n),
    REPLICATE(CHAR(65+(n%26)),40)
FROM
(
    SELECT Number n FROM dbo.RCA_Number
    UNION ALL SELECT Number+1000000 FROM dbo.RCA_Number
    UNION ALL SELECT Number+2000000 FROM dbo.RCA_Number
)x;
GO

CREATE INDEX IX_RCA_GeneralLedger_PortfolioDate
ON dbo.RCA_GeneralLedger(PortfolioID,GLDate)
INCLUDE(GLAccountCode,GLCredit,GLDebit);
GO

CREATE TABLE dbo.RCA_WorkResult
(
    WorkResultID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_WorkResult PRIMARY KEY CLUSTERED,
    RunID uniqueidentifier NOT NULL,
    SessionID int NOT NULL,
    PortfolioID int NOT NULL,
    SecurityID int NOT NULL,
    AsOfDate date NOT NULL,
    MarketValue decimal(19,4) NOT NULL,
    CostBasis decimal(19,4) NOT NULL,
    CalculatedValue decimal(28,8) NULL,
    CreatedTime datetime2(3) NOT NULL
        CONSTRAINT DF_RCA_WorkResult_Created DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_RCA_WorkResult_RunID ON dbo.RCA_WorkResult(RunID);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_PerformanceQuery
    @AsOfDate date,
    @EntityClassID int,
    @PortfolioID int,
    @LookbackMonths int,
    @DeletePercent int=20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunID uniqueidentifier=NEWID(),
            @StartDate date=DATEADD(month,-@LookbackMonths,@AsOfDate);

    SELECT
        sp.SecurityPerformanceID,sp.PortfolioID,sp.EntityClassID,
        sp.SecurityID,sp.AsOfDate,sp.MarketValue,sp.CostBasis,
        sp.Quantity,sp.Price,sp.StatusCode,
        CalculatedExposure=CONVERT(decimal(28,8),
          (sp.MarketValue-sp.CostBasis)*NULLIF(sp.Quantity,0)/NULLIF(sp.Price,0))
    INTO #PerformanceWork
    FROM dbo.RCA_SecurityPerformance sp
    WHERE sp.AsOfDate BETWEEN @StartDate AND @AsOfDate
      AND sp.EntityClassID=@EntityClassID
      AND (sp.PortfolioID=@PortfolioID OR @PortfolioID=0);

    CREATE CLUSTERED INDEX CX_PerformanceWork
      ON #PerformanceWork(PortfolioID,SecurityID,AsOfDate);

    SELECT
        gl.PortfolioID,gl.GLAccountCode,
        NetLedgerValue=SUM((gl.GLCredit-gl.GLDebit)*gl.MultiCurrencyMultiplier),
        LedgerRows=COUNT_BIG(*)
    INTO #LedgerWork
    FROM dbo.RCA_GeneralLedger gl
    WHERE gl.GLDate BETWEEN @StartDate AND @AsOfDate
      AND (gl.PortfolioID=@PortfolioID OR @PortfolioID=0)
    GROUP BY gl.PortfolioID,gl.GLAccountCode;

    SELECT PortfolioID,PortfolioLedgerValue=SUM(NetLedgerValue)
    INTO #LedgerByPortfolio
    FROM #LedgerWork
    GROUP BY PortfolioID;

    CREATE UNIQUE CLUSTERED INDEX CX_LedgerByPortfolio
      ON #LedgerByPortfolio(PortfolioID);

    INSERT dbo.RCA_WorkResult
    (
        RunID,SessionID,PortfolioID,SecurityID,AsOfDate,
        MarketValue,CostBasis,CalculatedValue
    )
    SELECT
        @RunID,@@SPID,p.PortfolioID,p.SecurityID,p.AsOfDate,
        p.MarketValue,p.CostBasis,
        p.CalculatedExposure+ISNULL(l.PortfolioLedgerValue,0)
    FROM #PerformanceWork p
    LEFT JOIN #LedgerByPortfolio l
      ON l.PortfolioID=p.PortfolioID
    WHERE p.StatusCode='A';

    DELETE wr
    FROM dbo.RCA_WorkResult wr
    WHERE wr.RunID=@RunID
      AND ABS(CONVERT(bigint,wr.SecurityID))%100<@DeletePercent;

    SELECT
        RunID=@RunID,
        PortfolioID,
        TotalRows=COUNT_BIG(*),
        TotalMarketValue=SUM(MarketValue),
        TotalCostBasis=SUM(CostBasis),
        TotalCalculatedValue=SUM(CalculatedValue)
    FROM dbo.RCA_WorkResult
    WHERE RunID=@RunID
    GROUP BY PortfolioID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_RunWorkload
    @Iterations int=3,
    @Heavy bit=1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int=1;

    WHILE @i<=@Iterations
    BEGIN
        IF @Heavy=1
            EXEC dbo.usp_RCA_PerformanceQuery
                 @AsOfDate='2026-08-08',
                 @EntityClassID=2,
                 @PortfolioID=0,
                 @LookbackMonths=36,
                 @DeletePercent=20;
        ELSE
            EXEC dbo.usp_RCA_PerformanceQuery
                 @AsOfDate='2026-08-08',
                 @EntityClassID=2,
                 @PortfolioID=1001,
                 @LookbackMonths=12,
                 @DeletePercent=20;
        SET @i+=1;
    END
END;
GO

UPDATE STATISTICS dbo.RCA_SecurityPerformance WITH FULLSCAN;
UPDATE STATISTICS dbo.RCA_GeneralLedger WITH FULLSCAN;
GO

SELECT 'RCA_SecurityPerformance' TableName,COUNT_BIG(*) TotalRows
FROM dbo.RCA_SecurityPerformance
UNION ALL
SELECT 'RCA_GeneralLedger',COUNT_BIG(*) FROM dbo.RCA_GeneralLedger
UNION ALL
SELECT 'RCA_Portfolio',COUNT_BIG(*) FROM dbo.RCA_Portfolio;
GO

SELECT TOP(10) PortfolioID,COUNT_BIG(*) TotalRows
FROM dbo.RCA_SecurityPerformance
GROUP BY PortfolioID
ORDER BY COUNT_BIG(*) DESC;
GO

SELECT
    TableName=OBJECT_NAME(s.object_id),
    StatisticName=s.name,
    StatsLastUpdated=STATS_DATE(s.object_id,s.stats_id)
FROM sys.stats s
WHERE s.object_id IN
(
    OBJECT_ID('dbo.RCA_SecurityPerformance'),
    OBJECT_ID('dbo.RCA_GeneralLedger')
)
ORDER BY TableName,StatisticName;
GO

PRINT 'RCA LAB BUILD COMPLETE';
PRINT 'Do not run the workload yet. Next step is the XE capture.';
GO

/*
AFTER XE IS INSTALLED:

EXEC RCA.dbo.usp_RCA_PerformanceQuery
     @AsOfDate='2026-08-08',
     @EntityClassID=2,
     @PortfolioID=1001,
     @LookbackMonths=12,
     @DeletePercent=20;

HEAVIER:
EXEC RCA.dbo.usp_RCA_PerformanceQuery
     @AsOfDate='2026-08-08',
     @EntityClassID=2,
     @PortfolioID=0,
     @LookbackMonths=36,
     @DeletePercent=20;
*/
