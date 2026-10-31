USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  14_RCA_Run6_Memory_Spill_Validation.sql

  PURPOSE
  -------
  Create a clean memory-grant/spill validation scenario.

  DESIGN
  ------
  - Fresh FULLSCAN statistics before capture.
  - OPTION(RECOMPILE) to avoid plan-reuse ambiguity.
  - Same data and query shape for baseline and impacted executions.
  - Baseline uses normal memory grant.
  - Impacted executions deliberately cap memory with MAX_GRANT_PERCENT = 1.
  - Large window sort + aggregation creates a memory-intensive plan.
==============================================================================*/

DROP PROCEDURE IF EXISTS dbo.usp_RCA_Run6_MemorySpill;
DROP TABLE IF EXISTS dbo.RCA_Run6_MemorySpill;
GO

CREATE TABLE dbo.RCA_Run6_MemorySpill
(
      SpillID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_Run6_MemorySpill PRIMARY KEY CLUSTERED
    , GroupID int NOT NULL
    , SortKey1 bigint NOT NULL
    , SortKey2 varchar(100) NOT NULL
    , Amount decimal(19,4) NOT NULL
    , Payload char(200) NOT NULL
);
GO

PRINT 'RUN 6: loading 2,000,000 rows...';

INSERT dbo.RCA_Run6_MemorySpill WITH (TABLOCK)
(
      GroupID,SortKey1,SortKey2,Amount,Payload
)
SELECT
      (x.n%50000)+1
    , ABS(CONVERT(bigint,CHECKSUM(NEWID())))
    , RIGHT(
    REPLICATE('0',20)
    + CONVERT(
        varchar(20),
        (CONVERT(bigint,x.n) * CONVERT(bigint,7919))
        % CONVERT(bigint,999999999)
      ),
    20
)
    , CONVERT(decimal(19,4),((x.n%100000)+1)*3.17)
    , REPLICATE(CHAR(65+(x.n%26)),200)
FROM
(
    SELECT Number AS n FROM dbo.RCA_Number
    UNION ALL
    SELECT Number+1000000 FROM dbo.RCA_Number
) x;
GO

/* Fresh stats are intentional so Run 5's cause should not dominate. */
UPDATE STATISTICS dbo.RCA_Run6_MemorySpill WITH FULLSCAN;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run6_MemorySpill
      @MaxGrantPercent decimal(5,2)=NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql nvarchar(max)=N'
    SELECT
          GroupID
        , TotalRows=COUNT_BIG(*)
        , TotalAmount=SUM(Amount)
        , MaxSortKey=MAX(SortKey1)
        , MinSortKey2=MIN(SortKey2)
    FROM
    (
        SELECT
              GroupID,SortKey1,SortKey2,Amount
            , rn=ROW_NUMBER() OVER
              (
                  PARTITION BY GroupID
                  ORDER BY SortKey1 DESC,SortKey2,Payload
              )
        FROM dbo.RCA_Run6_MemorySpill
    ) d
    WHERE rn<=40
    GROUP BY GroupID
    ORDER BY TotalAmount DESC,GroupID
    OPTION (RECOMPILE';

    IF @MaxGrantPercent IS NOT NULL
        SET @sql += N', MAX_GRANT_PERCENT = '+CONVERT(varchar(20),@MaxGrantPercent);

    SET @sql += N');';
    EXEC sys.sp_executesql @sql;
END;
GO

/* PRE-CAPTURE PROOF */
SELECT
      StatisticName=s.name
    , sp.last_updated
    , sp.rows
    , sp.rows_sampled
    , sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id,s.stats_id) sp
WHERE s.object_id=OBJECT_ID(N'dbo.RCA_Run6_MemorySpill')
ORDER BY s.stats_id;
GO

SELECT
      ProcedureExists=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run6_MemorySpill',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , TableRows=(SELECT COUNT_BIG(*) FROM dbo.RCA_Run6_MemorySpill);
GO

/*==============================================================================
  EXECUTION INSTRUCTIONS
==============================================================================

  WINDOW 1 - START CAPTURE
  ------------------------
  USE DBA;
  GO
  DECLARE @RunID bigint;
  EXEC dbo.usp_RCA_StartCapture
       @CaptureReason=N'Run 6 - memory grant / spill validation',
       @CaptureRunID=@RunID OUTPUT;
  SELECT @RunID AS CaptureRunID;
  GO

  WINDOW 2 - SAMPLER
  ------------------
  USE DBA;
  GO
  EXEC dbo.usp_RCA_RunSampler
       @CaptureRunID=<RUN6_ID>,
       @DurationMinutes=4,
       @SampleSeconds=5;
  GO

  WINDOW 3 - WORKLOAD
  -------------------
  USE RCA;
  GO

  -- BASELINE
  EXEC dbo.usp_RCA_Run6_MemorySpill @MaxGrantPercent=NULL;
  GO
  WAITFOR DELAY '00:00:05';
  GO

  -- IMPACTED #1
  EXEC dbo.usp_RCA_Run6_MemorySpill @MaxGrantPercent=1;
  GO
  WAITFOR DELAY '00:00:05';
  GO

  -- IMPACTED #2
  EXEC dbo.usp_RCA_Run6_MemorySpill @MaxGrantPercent=1;
  GO

  WINDOW 1 - STOP / IMPORT / ANALYZE
  ----------------------------------
  USE DBA;
  GO
  EXEC dbo.usp_RCA_StopCapture @CaptureRunID=<RUN6_ID>;
  GO
  EXEC dbo.usp_RCA_ImportXE @CaptureRunID=<RUN6_ID>;
  GO
  EXEC dbo.usp_RCA_AnalyzeCaptureRun
       @CaptureRunID=<RUN6_ID>,
       @Reparse=1;
  GO

  VALIDATION
  ----------
  SELECT
      ExecutionEvidenceID,PlanEvidenceID,NodeID,PhysicalOp,LogicalOp,
      HasSpillWarning,EstimateRows,ActualRows,EstimateActualRatio
  FROM dbo.RCA_PlanOperator
  WHERE CaptureRunID=<RUN6_ID>
    AND HasSpillWarning=1
  ORDER BY ExecutionEvidenceID,PlanEvidenceID,NodeID;
  GO

  SELECT *
  FROM dbo.vw_RCA_MemorySpillEvidence
  WHERE CaptureRunID=<RUN6_ID>
  ORDER BY CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END,
           CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
  GO

  SELECT *
  FROM dbo.vw_RCA_StatisticsCardinalityEvidence
  WHERE CaptureRunID=<RUN6_ID>;
  GO

  SELECT *
  FROM dbo.vw_RCA_ParameterSensitivePlanEvidence
  WHERE CaptureRunID=<RUN6_ID>;
  GO

  SELECT *
  FROM dbo.vw_RCA_MemorySpillIncidentEvidence
  WHERE CaptureRunID=<RUN6_ID>;
  GO

  EXEC dbo.usp_RCA_ShowIncidentReport
       @CaptureRunID=<RUN6_ID>,
       @IncludeTechnicalEvidence=1;
  GO

  EXPECTED RCA STORY
  ------------------
  MEMORY_GRANT_SPILL should be PRIMARY when spill warnings and regression exist
  without stronger parameter-sensitive/statistics-cardinality evidence.
==============================================================================*/

/* Optional cleanup after validation:
DROP PROCEDURE IF EXISTS dbo.usp_RCA_Run6_MemorySpill;
DROP TABLE IF EXISTS dbo.RCA_Run6_MemorySpill;
GO
*/
