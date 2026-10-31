USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
21_RCA_Run8_CPU_Scheduler_Validation.sql

PURPOSE
-------
Controlled validation of the CPU / scheduler-pressure detector.

DESIGN
------
- Create a CPU-heavy, read-heavy workload.
- Run multiple concurrent copies to create scheduler pressure.
- Existing sampler captures server and live-request state every 5 seconds.
- Existing XE capture records completed executions.
- No blocking is intentionally introduced.
- No stale-statistics scenario is intentionally introduced.
- No memory-grant cap is intentionally introduced.
- Workload uses OPTION(RECOMPILE) to reduce plan-reuse ambiguity.

EXPECTED RCA STORY
------------------
CPU_SCHEDULER_PRESSURE = PRIMARY / HIGH when:
- SQL CPU is materially elevated,
- runnable-task pressure is observed,
- and/or a small number of requests dominate captured CPU,
without a stronger dedicated upstream detector.

NOTE
----
How high SQL CPU gets depends on laptop CPU count and concurrent workload count.
If the first pass is too light, increase the number of concurrent workload
windows rather than changing detector thresholds immediately.
==============================================================================*/


/*==============================================================================
0. BUILD TEST DATA
==============================================================================*/

DROP PROCEDURE IF EXISTS dbo.usp_RCA_Run8_CPU;
DROP TABLE IF EXISTS dbo.RCA_Run8_CPU;
GO

CREATE TABLE dbo.RCA_Run8_CPU
(
      RowID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_Run8_CPU PRIMARY KEY CLUSTERED
    , GroupID int NOT NULL
    , SortKey bigint NOT NULL
    , Amount decimal(19,4) NOT NULL
    , Payload char(120) NOT NULL
);
GO

PRINT 'RUN 8: loading 2,000,000 rows...';

INSERT dbo.RCA_Run8_CPU WITH (TABLOCK)
(
      GroupID
    , SortKey
    , Amount
    , Payload
)
SELECT
      (x.n%10000)+1
    , ABS(CONVERT(bigint,CHECKSUM(NEWID())))
    , CONVERT(decimal(19,4),((x.n%100000)+1)*2.71)
    , REPLICATE(CHAR(65+(x.n%26)),120)
FROM
(
    SELECT Number AS n
    FROM dbo.RCA_Number

    UNION ALL

    SELECT Number+1000000
    FROM dbo.RCA_Number
) AS x;
GO

UPDATE STATISTICS dbo.RCA_Run8_CPU WITH FULLSCAN;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run8_CPU
    @Loops int = 8
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @i int=1;

    WHILE @i<=@Loops
    BEGIN
        SELECT
              GroupID
            , Cnt        = COUNT_BIG(*)
            , SumAmount  = SUM(Amount)
            , AvgAmount  = AVG(Amount)
            , MaxSortKey = MAX(SortKey)
            , CheckValue =
                CHECKSUM_AGG
                (
                    CHECKSUM
                    (
                          SortKey
                        , Amount
                        , Payload
                    )
                )
        FROM dbo.RCA_Run8_CPU
        GROUP BY GroupID
        HAVING COUNT_BIG(*)>50
        ORDER BY
              SUM(Amount) DESC
            , MAX(SortKey) DESC
        OPTION
        (
              RECOMPILE
            , MAXDOP 4
        );

        SET @i+=1;
    END;
END;
GO


SELECT
      TableExists =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Run8_CPU',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ProcedureExists =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run8_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TableRows =
        (SELECT COUNT_BIG(*) FROM dbo.RCA_Run8_CPU);
GO


/*==============================================================================
WINDOW 1 - START CAPTURE

Record returned CaptureRunID.
==============================================================================*/

USE DBA;
GO

DECLARE @RunID bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 8 - CPU / scheduler pressure validation',
     @CaptureRunID=@RunID OUTPUT;

SELECT
      @RunID AS CaptureRunID
    , 'STARTED' AS Run8Status;
GO


/*==============================================================================
WINDOW 2 - SAMPLER

Replace <RUN8_ID>.
Leave executing.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID=<RUN8_ID>,
     @DurationMinutes=4,
     @SampleSeconds=5;
GO


/*==============================================================================
WINDOWS 3-6 - CPU WORKLOAD

Open FOUR separate SSMS windows and start these within a few seconds of each
other.

If the machine has many CPU cores and this is not enough load, open 6-8
workload windows instead.

WINDOW 3
==============================================================================*/

USE RCA;
GO
EXEC dbo.usp_RCA_Run8_CPU @Loops=8;
GO


/*==============================================================================
WINDOW 4
==============================================================================*/

USE RCA;
GO
EXEC dbo.usp_RCA_Run8_CPU @Loops=8;
GO


/*==============================================================================
WINDOW 5
==============================================================================*/

USE RCA;
GO
EXEC dbo.usp_RCA_Run8_CPU @Loops=8;
GO


/*==============================================================================
WINDOW 6
==============================================================================*/

USE RCA;
GO
EXEC dbo.usp_RCA_Run8_CPU @Loops=8;
GO


/*==============================================================================
LIVE PROOF - RUN WHILE WORKLOAD WINDOWS ARE EXECUTING
==============================================================================*/

USE DBA;
GO

SELECT TOP (30)
      CaptureTimeUTC
    , SqlCpuPercent
    , OtherCpuPercent
    , SystemIdlePercent
    , RunnableTasks
    , MemoryGrantsPending
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=<RUN8_ID>
ORDER BY CaptureTimeUTC DESC;
GO

SELECT TOP (30)
      CaptureTimeUTC
    , SessionID
    , Status
    , Command
    , WaitType
    , CPUms
    , ElapsedMs
    , LogicalReads
    , DOP
    , HostName
    , ProgramName
    , LoginName
    , RunningStatement
FROM dbo.RCA_LiveRequestSnapshot
WHERE CaptureRunID=<RUN8_ID>
ORDER BY
      CaptureTimeUTC DESC
    , CPUms DESC;
GO


/*==============================================================================
AFTER WORKLOAD AND SAMPLER COMPLETE
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=<RUN8_ID>;
GO

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID=<RUN8_ID>;
GO

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID=<RUN8_ID>,
     @Reparse=1;
GO

EXEC dbo.usp_RCA_BuildCPUSchedulerEvidence
     @CaptureRunID=<RUN8_ID>;
GO


/*==============================================================================
EVIDENCE
==============================================================================*/

SELECT *
FROM dbo.vw_RCA_CPUSchedulerEvidence
WHERE CaptureRunID=<RUN8_ID>;
GO


/*==============================================================================
ACCEPTANCE TEST
==============================================================================*/

SELECT
      Run8 =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_CPUSchedulerEvidence
                WHERE CaptureRunID=<RUN8_ID>
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
                  AND SqlCpuSaturation=1
                  AND
                  (
                       SchedulerPressure=1
                       OR RunawayQueryDominance=1
                  )
                  AND ISNULL(NonSqlCpuDominance,0)=0
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END
    , PeakSqlCpuPercent =
        (
            SELECT MAX(PeakSqlCpuPercent)
            FROM dbo.RCA_CPUSchedulerEvidence
            WHERE CaptureRunID=<RUN8_ID>
        )
    , PeakRunnableTasks =
        (
            SELECT MAX(PeakRunnableTasks)
            FROM dbo.RCA_CPUSchedulerEvidence
            WHERE CaptureRunID=<RUN8_ID>
        )
    , TopExecutionCPUSharePercent =
        (
            SELECT MAX(TopExecutionCPUSharePercent)
            FROM dbo.RCA_CPUSchedulerEvidence
            WHERE CaptureRunID=<RUN8_ID>
        );
GO


/*==============================================================================
FINAL OUTPUT

The unified cause candidate view already includes CPU_SCHEDULER_PRESSURE.
==============================================================================*/

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=<RUN8_ID>,
     @IncludeTechnicalEvidence=1;
GO
