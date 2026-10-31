USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  11_RCA_Run4_Stale_Statistics_Validation.sql

  PURPOSE
  -------
  Build Run 4 as a deliberately different RCA scenario:

      PRIMARY TEST: stale / misleading statistics and cardinality estimation
      MUST NOT TEST: parameter-sensitive plan reuse

  DESIGN
  ------
  1. Create a 1,000,000-row baseline distribution.
  2. Create and FULLSCAN the RegionCode index statistics.
  3. Mark those statistics NORECOMPUTE so SQL Server cannot auto-refresh them.
  4. Insert 2,000,000 NEW rows for RegionCode = 9999 AFTER the statistics.
  5. Execute with OPTION (RECOMPILE), so runtime = compiled parameter value.
  6. Capture the resulting actual plan, stats metadata, CPU, reads, rows, etc.

  Expected evidence:
      - @RegionCode compiled value = runtime value
      - zero PARAMETER_SENSITIVE_PLAN_REUSE cases
      - stats last updated BEFORE 2M-row hot-key insert
      - modification_counter around 2,000,000
      - severe estimate-vs-actual mismatch for RegionCode = 9999
      - expensive access path / reads caused by stale distribution knowledge

  This script does NOT alter the RCA engine.
==============================================================================*/


/*==============================================================================
  1. CLEAN PRIOR RUN 4 LAB OBJECTS
==============================================================================*/
DROP PROCEDURE IF EXISTS dbo.usp_RCA_Run4_StatsRegression;
DROP TABLE IF EXISTS dbo.RCA_Run4_StatsSkew;
GO


/*==============================================================================
  2. BUILD BASELINE TABLE
==============================================================================*/
CREATE TABLE dbo.RCA_Run4_StatsSkew
(
      StatsSkewID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_Run4_StatsSkew PRIMARY KEY CLUSTERED
    , RegionCode int NOT NULL
    , AccountID int NOT NULL
    , EventDate date NOT NULL
    , Amount decimal(19,4) NOT NULL
    , FeeAmount decimal(19,4) NOT NULL
    , StatusCode char(1) NOT NULL
    , SourceSystem varchar(20) NOT NULL
    , Payload char(100) NULL
);
GO

PRINT 'RUN 4: Loading 1,000,000 baseline rows...';

INSERT dbo.RCA_Run4_StatsSkew WITH (TABLOCK)
(
      RegionCode
    , AccountID
    , EventDate
    , Amount
    , FeeAmount
    , StatusCode
    , SourceSystem
    , Payload
)
SELECT
      RegionCode   = ((n.Number - 1) % 1000) + 1
    , AccountID    = ((n.Number * 17) % 250000) + 1
    , EventDate    = DATEADD(day,-(n.Number % 730),CONVERT(date,'2026-08-12'))
    , Amount       = CONVERT(decimal(19,4),((n.Number % 100000)+100) * 7.37)
    , FeeAmount    = CONVERT(decimal(19,4),((n.Number % 2500)+1) * 0.43)
    , StatusCode   = CASE WHEN n.Number % 20 = 0 THEN 'I' ELSE 'A' END
    , SourceSystem = CASE n.Number % 4
                         WHEN 0 THEN 'FOIL'
                         WHEN 1 THEN 'UEP'
                         WHEN 2 THEN 'GL'
                         ELSE 'RCA'
                     END
    , Payload      = REPLICATE(CHAR(65 + (n.Number % 26)),100)
FROM dbo.RCA_Number AS n;
GO


/*==============================================================================
  3. CREATE A DELIBERATELY NON-COVERING INDEX

  The optimizer will believe RegionCode=9999 is extremely selective because
  9999 does not exist when the histogram is built.  The query needs columns
  outside this index, so a bad estimate can make lookups/access-path choices
  materially expensive.
==============================================================================*/
CREATE INDEX IX_RCA_Run4_StatsSkew_Region
ON dbo.RCA_Run4_StatsSkew(RegionCode);
GO

UPDATE STATISTICS dbo.RCA_Run4_StatsSkew
    IX_RCA_Run4_StatsSkew_Region
WITH FULLSCAN, NORECOMPUTE;
GO


/*==============================================================================
  4. RECORD THE FROZEN STATISTICS BASELINE
==============================================================================*/
SELECT
      Phase = 'BEFORE_HOT_INSERT'
    , StatisticName = s.name
    , LastUpdated = sp.last_updated
    , RowsAtStatsTime = sp.rows
    , RowsSampled = sp.rows_sampled
    , ModificationCounter = sp.modification_counter
    , NoRecompute = s.no_recompute
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id,s.stats_id) AS sp
WHERE s.object_id = OBJECT_ID(N'dbo.RCA_Run4_StatsSkew')
  AND s.name = N'IX_RCA_Run4_StatsSkew_Region';
GO


/*==============================================================================
  5. INSERT 2,000,000 ROWS FOR A VALUE ABSENT FROM THE HISTOGRAM

  RegionCode 9999 did not exist when statistics were built.
==============================================================================*/
PRINT 'RUN 4: Loading 2,000,000 hot-key rows AFTER statistics were frozen...';

INSERT dbo.RCA_Run4_StatsSkew WITH (TABLOCK)
(
      RegionCode
    , AccountID
    , EventDate
    , Amount
    , FeeAmount
    , StatusCode
    , SourceSystem
    , Payload
)
SELECT
      RegionCode   = 9999
    , AccountID    = ((x.n * 29) % 250000) + 1
    , EventDate    = DATEADD(day,-(x.n % 365),CONVERT(date,'2026-08-12'))
    , Amount       = CONVERT(decimal(19,4),((x.n % 100000)+500) * 11.17)
    , FeeAmount    = CONVERT(decimal(19,4),((x.n % 5000)+1) * 0.79)
    , StatusCode   = CASE WHEN x.n % 25 = 0 THEN 'I' ELSE 'A' END
    , SourceSystem = CASE x.n % 4
                         WHEN 0 THEN 'FOIL'
                         WHEN 1 THEN 'UEP'
                         WHEN 2 THEN 'GL'
                         ELSE 'RCA'
                     END
    , Payload      = REPLICATE(CHAR(65 + (x.n % 26)),100)
FROM
(
    SELECT Number AS n
    FROM dbo.RCA_Number

    UNION ALL

    SELECT Number + 1000000
    FROM dbo.RCA_Number
) AS x;
GO


/*==============================================================================
  6. PROVE THE STATISTICS ARE NOW STALE
==============================================================================*/
SELECT
      Phase = 'AFTER_HOT_INSERT'
    , CurrentTableRows = (SELECT COUNT_BIG(*) FROM dbo.RCA_Run4_StatsSkew)
    , HotKeyRows = (SELECT COUNT_BIG(*)
                    FROM dbo.RCA_Run4_StatsSkew
                    WHERE RegionCode = 9999)
    , StatisticName = s.name
    , LastUpdated = sp.last_updated
    , RowsAtStatsTime = sp.rows
    , RowsSampled = sp.rows_sampled
    , ModificationCounter = sp.modification_counter
    , NoRecompute = s.no_recompute
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id,s.stats_id) AS sp
WHERE s.object_id = OBJECT_ID(N'dbo.RCA_Run4_StatsSkew')
  AND s.name = N'IX_RCA_Run4_StatsSkew_Region';
GO

DBCC SHOW_STATISTICS
(
    'dbo.RCA_Run4_StatsSkew',
    'IX_RCA_Run4_StatsSkew_Region'
)
WITH HISTOGRAM;
GO


/*==============================================================================
  7. RUN 4 WORKLOAD PROCEDURE

  OPTION (RECOMPILE) is intentional:
      compiled parameter = runtime parameter
      no plan-reuse explanation should be necessary.

  The engine should instead follow:
      stale stats -> bad cardinality -> bad access path -> resource regression.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run4_StatsRegression
      @RegionCode int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          s.StatsSkewID
        , s.RegionCode
        , s.AccountID
        , s.EventDate
        , s.Amount
        , s.FeeAmount
        , s.StatusCode
        , s.SourceSystem
        , s.Payload
    INTO #Run4Work
    FROM dbo.RCA_Run4_StatsSkew AS s
    WHERE s.RegionCode = @RegionCode
    OPTION (RECOMPILE);

    CREATE CLUSTERED INDEX CX_Run4Work
        ON #Run4Work(StatsSkewID);

    SELECT
          RegionCode       = @RegionCode
        , TotalRows        = COUNT_BIG(*)
        , TotalAmount      = SUM(Amount)
        , TotalFees        = SUM(FeeAmount)
        , ActiveRows       = SUM(CASE WHEN StatusCode='A' THEN CONVERT(bigint,1)
                                      ELSE CONVERT(bigint,0) END)
        , DistinctAccounts = COUNT_BIG(DISTINCT AccountID)
    FROM #Run4Work
    OPTION (RECOMPILE);
END;
GO


/*==============================================================================
  8. PRE-CAPTURE VALIDATION
==============================================================================*/
SELECT
      ObjectName = N'dbo.usp_RCA_Run4_StatsRegression'
    , ProcExists =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run4_StatsRegression',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TableRows = (SELECT COUNT_BIG(*) FROM dbo.RCA_Run4_StatsSkew)
    , BaselineRegion42Rows =
        (SELECT COUNT_BIG(*) FROM dbo.RCA_Run4_StatsSkew WHERE RegionCode=42)
    , HotRegion9999Rows =
        (SELECT COUNT_BIG(*) FROM dbo.RCA_Run4_StatsSkew WHERE RegionCode=9999);
GO


/*==============================================================================
  RUN 4 EXECUTION INSTRUCTIONS
  ------------------------------------------------------------------------------

  WINDOW 1 - START CAPTURE
  ========================
  USE DBA;
  GO

  DECLARE @RunID bigint;

  EXEC dbo.usp_RCA_StartCapture
       @CaptureReason =
           N'Run 4 - stale statistics / cardinality estimation validation',
       @CaptureRunID = @RunID OUTPUT;

  SELECT @RunID AS CaptureRunID;
  GO

  Write down the new CaptureRunID.  Use it below as <RUN4_ID>.


  WINDOW 2 - SAMPLER
  ==================
  USE DBA;
  GO

  EXEC dbo.usp_RCA_RunSampler
       @CaptureRunID = <RUN4_ID>,
       @DurationMinutes = 3,
       @SampleSeconds = 5;
  GO


  WINDOW 3 - WORKLOAD
  ===================
  USE RCA;
  GO

  -- Baseline execution: represented in the frozen histogram.
  EXEC dbo.usp_RCA_Run4_StatsRegression
       @RegionCode = 42;
  GO

  -- Impacted execution #1: value absent when statistics were built.
  EXEC dbo.usp_RCA_Run4_StatsRegression
       @RegionCode = 9999;
  GO

  -- Impacted execution #2: repeat to prove consistency.
  EXEC dbo.usp_RCA_Run4_StatsRegression
       @RegionCode = 9999;
  GO


  WINDOW 1 - STOP / IMPORT / ANALYZE
  ==================================
  USE DBA;
  GO

  EXEC dbo.usp_RCA_StopCapture
       @CaptureRunID = <RUN4_ID>;
  GO

  EXEC dbo.usp_RCA_ImportXE
       @CaptureRunID = <RUN4_ID>;
  GO

  EXEC dbo.usp_RCA_AnalyzeCaptureRun
       @CaptureRunID = <RUN4_ID>,
       @Reparse = 1;
  GO


  RUN 4 VALIDATION
  ================
  1. Parameter-sensitive detector MUST return zero cases:

  SELECT *
  FROM dbo.vw_RCA_ParameterSensitivePlanEvidence
  WHERE CaptureRunID = <RUN4_ID>;
  GO

  Expected: 0 rows.


  2. Show the final RCA report:

  EXEC dbo.usp_RCA_ShowIncidentReport
       @CaptureRunID = <RUN4_ID>,
       @IncludeTechnicalEvidence = 1;
  GO


  3. Check statistics evidence parsed from the actual plans:

  SELECT
        CaptureRunID
      , ExecutionEvidenceID
      , PlanEvidenceID
      , DatabaseName
      , SchemaName
      , TableName
      , StatisticsName
      , LastUpdate
      , ModificationCount
      , SamplingPercent
  FROM dbo.RCA_StatisticsUsed
  WHERE CaptureRunID = <RUN4_ID>
    AND TableName LIKE '%RCA_Run4_StatsSkew%'
  ORDER BY
        ExecutionEvidenceID,
        PlanEvidenceID,
        StatisticsName;
  GO


  4. Check compiled/runtime values.

  SELECT
        ExecutionEvidenceID
      , ParameterName
      , ParameterCompiledValue
      , ParameterRuntimeValue
      , EvidenceSource
  FROM dbo.RCA_RuntimeParameter
  WHERE CaptureRunID = <RUN4_ID>
  ORDER BY ExecutionEvidenceID,ParameterName;
  GO

  Expected for @RegionCode:
      baseline: compiled 42   / runtime 42
      impacted: compiled 9999 / runtime 9999

  That is the key proof that Run 4 is NOT a parameter-sensitive-plan test.


  5. Actual plan / cardinality evidence:

  SELECT TOP (30)
        p.LinkedExecutionEvidenceID AS ExecutionEvidenceID
      , o.PlanEvidenceID
      , o.NodeID
      , o.PhysicalOp
      , o.LogicalOp
      , o.EstimateRows
      , o.ActualRows
      , o.ActualRowsRead
      , o.EstimateActualRatio
      , o.DatabaseName
      , o.SchemaName
      , o.TableName
      , o.IndexName
  FROM dbo.RCA_PlanOperator o
  JOIN dbo.RCA_PlanEvidence p
    ON p.PlanEvidenceID = o.PlanEvidenceID
  WHERE o.CaptureRunID = <RUN4_ID>
  ORDER BY
      CASE
          WHEN o.EstimateActualRatio >= 100
            OR (o.EstimateActualRatio > 0 AND o.EstimateActualRatio <= 0.01)
          THEN 1 ELSE 2
      END,
      ISNULL(o.ActualRowsRead,o.ActualRows) DESC;
  GO


  EXPECTED RCA STORY
  ==================
  Parameter-sensitive plan reuse: NOT SUPPORTED.

  Expected primary evidence:
      - statistics were built against 1M rows
      - 2M rows for RegionCode 9999 were inserted afterward
      - NORECOMPUTE preserved the old histogram
      - query compiled specifically for runtime value 9999
      - optimizer still estimated from stale distribution
      - actual row volume greatly exceeded estimates
      - bad estimate drove expensive access behavior

  This is intentionally different from Run 3.
==============================================================================*/


/*==============================================================================
  OPTIONAL CLEANUP AFTER RUN 4 IS COMPLETELY FINISHED

  Do NOT run this until the capture/report is complete.
==============================================================================*/
/*
DROP PROCEDURE IF EXISTS dbo.usp_RCA_Run4_StatsRegression;
DROP TABLE IF EXISTS dbo.RCA_Run4_StatsSkew;
GO
*/

PRINT 'RUN 4 BUILD COMPLETE.';
PRINT 'Next: start a new RCA capture and follow the three-window instructions.';
GO
