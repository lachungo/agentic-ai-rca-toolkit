USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    29_RCA_Run11_Memory_BufferPool_Validation.sql

    PURPOSE
    -------
    End-to-end validation of the INSTANCE_MEMORY_PRESSURE root-cause domain.

    TESTS
    -----
    Run 11A - LIVE NEGATIVE CONTROL
        Capture normal server-memory state for one minute.
        Expected:
            MEMORY_HEALTHY
            CONTRIBUTING / LOW
            Memory must NOT become a PRIMARY root cause.

    Run 11B - LIVE MEMORY-GRANT PRESSURE ATTEMPT
        Run several concurrent memory-intensive SQL Agent workers while the
        existing RCA sampler captures server state.
        Expected:
            The live collector must work.
            If pending grants or corroborating memory pressure occurs naturally,
            the detector may classify INSTANCE_MEMORY_PRESSURE.
            If the laptop remains healthy, that is also valid.

        IMPORTANT:
            Do NOT lower production-oriented thresholds just to force a pass.

    Run 11C - DETERMINISTIC POSITIVE CONTROL
        Start a fresh capture, populate it with the normal RCA sampler, then
        modify ONLY the captured Run 11C server-snapshot rows to represent
        sustained, corroborated memory pressure.

        This avoids inserting synthetic rows into a table whose full schema may
        evolve while still exercising the real detector and final RCA pipeline.

        Expected:
            INSTANCE_MEMORY_PRESSURE
            MEMORY_PRESSURE_MIXED
            PRIMARY
            HIGH

    HUMAN ACCEPTANCE
    ----------------
    dbo.usp_RCA_WhyWasItSlow must expose:
        Buffer Cache Hit Ratio
        Page Life Expectancy
        Available Physical Memory
        Memory Grants Pending
        Target vs Total Server Memory

    Buffer Cache Hit Ratio is SUPPORTING evidence only.
    It is never sufficient by itself to declare memory pressure.

    LAB ONLY
    --------
    Run 11B intentionally creates concurrent memory-intensive SQL workload.
    Do not execute the live workload portion on production.
==============================================================================*/


/*==============================================================================
    STEP 0 - PRE-FLIGHT
==============================================================================*/

SELECT
      CaptureRunTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ServerSnapshotTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , RCASampler =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , MemoryEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_MemoryPressureEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , MemoryDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildMemoryPressureEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseRanking =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HumanOutput =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO

SELECT
      BufferCacheHitRatio =
        CASE WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'BufferCacheHitRatio') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PageLifeExpectancySeconds =
        CASE WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'PageLifeExpectancySeconds') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TotalServerMemoryMB =
        CASE WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TotalServerMemoryMB') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TargetServerMemoryMB =
        CASE WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TargetServerMemoryMB') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , AvailablePhysicalMemoryMB =
        CASE WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'AvailablePhysicalMemoryMB') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , MemoryGrantsPending =
        CASE WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'MemoryGrantsPending') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NULL
 OR OBJECT_ID(N'dbo.RCA_MemoryPressureEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_BuildMemoryPressureEvidence',N'P') IS NULL
 OR OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'BufferCacheHitRatio') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'PageLifeExpectancySeconds') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TotalServerMemoryMB') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TargetServerMemoryMB') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'AvailablePhysicalMemoryMB') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'MemoryGrantsPending') IS NULL
BEGIN
    THROW 51700,N'Run 11 pre-flight failed. Required memory RCA objects or columns are missing.',1;
END;
GO


/*==============================================================================
    STEP 1 - CLEAN UP ANY OLD RUN 11 SQL AGENT JOBS
==============================================================================*/

USE msdb;
GO

DECLARE
      @JobName sysname
    , @CurrentAgentSessionID int;

SELECT @CurrentAgentSessionID=MAX(session_id)
FROM dbo.syssessions;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run11_Memory_%';

OPEN JobCleanup;
FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS=0
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs AS j
        JOIN dbo.sysjobactivity AS a
          ON a.job_id=j.job_id
         AND a.session_id=@CurrentAgentSessionID
        WHERE j.name=@JobName
          AND a.start_execution_date IS NOT NULL
          AND a.stop_execution_date IS NULL
    )
    BEGIN
        EXEC dbo.sp_stop_job @job_name=@JobName;
        WAITFOR DELAY '00:00:02';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs
        WHERE name=@JobName
    )
    BEGIN
        EXEC dbo.sp_delete_job
             @job_name=@JobName,
             @delete_unused_schedule=1;
    END;

    FETCH NEXT FROM JobCleanup INTO @JobName;
END;

CLOSE JobCleanup;
DEALLOCATE JobCleanup;

SELECT OldRun11JobsRemaining=COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run11_Memory_%';
GO


/*==============================================================================
    STEP 2 - CREATE BOUNDED LIVE MEMORY WORKLOAD

    Reuses RCA.dbo.RCA_Run8_CPU when available.

    The query is deliberately memory-intensive:
      - sort
      - aggregation
      - grouping
      - concurrent execution

    This is a LIVE ATTEMPT only. The laptop may still remain healthy.
==============================================================================*/

USE RCA;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run11_MemoryWorker
      @DurationSeconds int=90
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationSeconds < 10 OR @DurationSeconds > 300
        THROW 51701,N'@DurationSeconds must be between 10 and 300.',1;

    IF OBJECT_ID(N'dbo.RCA_Run8_CPU',N'U') IS NULL
        THROW 51702,N'RCA.dbo.RCA_Run8_CPU is required for the Run 11B live workload.',1;

    DECLARE
          @StopAt datetime2(3)=DATEADD(second,@DurationSeconds,SYSUTCDATETIME())
        , @Cycles int=0
        , @Sink bigint;

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        ;WITH q AS
        (
            SELECT
                  GroupID
                , SortKey
                , Amount
                , Payload
                , rn =
                    ROW_NUMBER() OVER
                    (
                        PARTITION BY GroupID
                        ORDER BY Amount DESC,SortKey DESC
                    )
            FROM dbo.RCA_Run8_CPU
        )
        SELECT
            @Sink =
                CHECKSUM_AGG
                (
                    CHECKSUM
                    (
                          GroupID
                        , rn
                        , SortKey
                        , Amount
                        , Payload
                    )
                )
        FROM q
        WHERE rn <= 5000
        OPTION
        (
              MAXDOP 1
            , RECOMPILE
        );

        SET @Cycles += 1;
    END;

    SELECT
          WorkerSessionID=@@SPID
        , CyclesCompleted=@Cycles
        , LastChecksum=@Sink;
END;
GO


/*==============================================================================
    RUN 11A - LIVE NEGATIVE CONTROL
==============================================================================*/

USE DBA;
GO

DECLARE @Run11A bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 11A - memory health negative control',
     @CaptureRunID=@Run11A OUTPUT;

SELECT
      CaptureRunID=@Run11A
    , Run11AStatus='STARTED';
GO

DECLARE @Run11A bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11A - memory health negative control'
);

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID=@Run11A,
     @DurationMinutes=1,
     @SampleSeconds=5;
GO

DECLARE @Run11A bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11A - memory health negative control'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run11A;

EXEC dbo.usp_RCA_BuildMemoryPressureEvidence
     @CaptureRunID=@Run11A;
GO

DECLARE @Run11A bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11A - memory health negative control'
);

SELECT
      CaptureRunID
    , COUNT(*) AS ServerSamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MIN(BufferCacheHitRatio) AS MinBufferCacheHitRatio
    , AVG(CONVERT(decimal(19,4),BufferCacheHitRatio)) AS AvgBufferCacheHitRatio
    , MIN(PageLifeExpectancySeconds) AS MinPLESeconds
    , AVG(CONVERT(decimal(19,2),PageLifeExpectancySeconds)) AS AvgPLESeconds
    , MIN(AvailablePhysicalMemoryMB) AS MinAvailablePhysicalMemoryMB
    , MAX(MemoryGrantsPending) AS PeakMemoryGrantsPending
    , MIN(TotalServerMemoryMB) AS MinTotalServerMemoryMB
    , MAX(TargetServerMemoryMB) AS MaxTargetServerMemoryMB
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@Run11A
GROUP BY CaptureRunID;

SELECT *
FROM dbo.RCA_MemoryPressureEvidence
WHERE CaptureRunID=@Run11A;

SELECT
      Run11A_NegativeControl=
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_MemoryPressureEvidence
                WHERE CaptureRunID=@Run11A
                  AND PressureSubtype='MEMORY_HEALTHY'
                  AND RootCauseRole='CONTRIBUTING'
                  AND Confidence='LOW'
            )
            AND NOT EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run11A
                  AND CauseCategory='INSTANCE_MEMORY_PRESSURE'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence IN ('HIGH','MEDIUM')
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END;

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run11A;
GO


/*==============================================================================
    RUN 11B - LIVE MEMORY-GRANT PRESSURE ATTEMPT

    Sampler:
        2 minutes / 5-second samples

    Workers:
        6 concurrent SQL Agent workers
        90 seconds each

    EXPECTATION
    -----------
    The collector must work.

    A live positive result is optional because the laptop may have sufficient
    memory and may never accumulate pending grants.

    Never reduce thresholds simply to force a live positive.
==============================================================================*/

USE DBA;
GO

DECLARE @Run11B bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 11B - live memory grant pressure attempt',
     @CaptureRunID=@Run11B OUTPUT;

SELECT
      CaptureRunID=@Run11B
    , Run11BStatus='STARTED';
GO


/*------------------------------------------------------------------------------
    Create sampler job.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE @Run11B bigint=
(
    SELECT MAX(CaptureRunID)
    FROM DBA.dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11B - live memory grant pressure attempt'
);

DECLARE @SamplerCommand nvarchar(max)=
    N'USE DBA;
      EXEC dbo.usp_RCA_RunSampler
           @CaptureRunID=' + CONVERT(nvarchar(30),@Run11B) + N',
           @DurationMinutes=2,
           @SampleSeconds=5;';

EXEC dbo.sp_add_job
     @job_name=N'RCA_Run11_Memory_Sampler',
     @enabled=1,
     @description=N'Run 11B server-memory sampler';

EXEC dbo.sp_add_jobstep
     @job_name=N'RCA_Run11_Memory_Sampler',
     @step_name=N'Run RCA sampler',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand,
     @on_success_action=1,
     @on_fail_action=2;

EXEC dbo.sp_add_jobserver
     @job_name=N'RCA_Run11_Memory_Sampler';

EXEC dbo.sp_start_job
     @job_name=N'RCA_Run11_Memory_Sampler';
GO

WAITFOR DELAY '00:00:10';
GO


/*------------------------------------------------------------------------------
    Create six concurrent worker jobs.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE
      @i int=1
    , @WorkerJob sysname
    , @WorkerCommand nvarchar(max);

WHILE @i <= 6
BEGIN
    SET @WorkerJob=
        CONCAT(N'RCA_Run11_Memory_Worker_',RIGHT('00'+CONVERT(varchar(2),@i),2));

    SET @WorkerCommand=
        N'USE RCA;
          EXEC dbo.usp_RCA_Run11_MemoryWorker
               @DurationSeconds=90;';

    EXEC dbo.sp_add_job
         @job_name=@WorkerJob,
         @enabled=1,
         @description=N'Run 11B concurrent memory-intensive worker';

    EXEC dbo.sp_add_jobstep
         @job_name=@WorkerJob,
         @step_name=N'Run memory workload',
         @subsystem=N'TSQL',
         @database_name=N'RCA',
         @command=@WorkerCommand,
         @on_success_action=1,
         @on_fail_action=2;

    EXEC dbo.sp_add_jobserver
         @job_name=@WorkerJob;

    EXEC dbo.sp_start_job
         @job_name=@WorkerJob;

    SET @i+=1;
END;

SELECT
      CreatedWorkerJobs=6
    , Run11B='STARTED';
GO

WAITFOR DELAY '00:02:10';
GO


/*------------------------------------------------------------------------------
    Verify job outcomes.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE @CurrentAgentSessionID int=
(
    SELECT MAX(session_id)
    FROM dbo.syssessions
);

SELECT
      j.name
    , a.start_execution_date
    , a.stop_execution_date
    , JobState=
        CASE
            WHEN a.start_execution_date IS NOT NULL
             AND a.stop_execution_date IS NULL
                THEN 'RUNNING'
            WHEN a.start_execution_date IS NOT NULL
             AND a.stop_execution_date IS NOT NULL
                THEN 'COMPLETED'
            ELSE 'NOT STARTED'
        END
    , LastRunStatus=
        (
            SELECT TOP (1)
                CASE h.run_status
                    WHEN 0 THEN 'FAILED'
                    WHEN 1 THEN 'SUCCEEDED'
                    WHEN 2 THEN 'RETRY'
                    WHEN 3 THEN 'CANCELED'
                    WHEN 4 THEN 'IN PROGRESS'
                    ELSE 'UNKNOWN'
                END
            FROM dbo.sysjobhistory AS h
            WHERE h.job_id=j.job_id
              AND h.step_id=0
            ORDER BY h.instance_id DESC
        )
FROM dbo.sysjobs AS j
LEFT JOIN dbo.sysjobactivity AS a
  ON a.job_id=j.job_id
 AND a.session_id=@CurrentAgentSessionID
WHERE j.name LIKE N'RCA_Run11_Memory_%'
ORDER BY j.name;
GO


/*------------------------------------------------------------------------------
    Stop capture and build memory evidence.
------------------------------------------------------------------------------*/

USE DBA;
GO

DECLARE @Run11B bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11B - live memory grant pressure attempt'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run11B;

EXEC dbo.usp_RCA_BuildMemoryPressureEvidence
     @CaptureRunID=@Run11B;
GO


/*------------------------------------------------------------------------------
    Run 11B evidence.
------------------------------------------------------------------------------*/

DECLARE @Run11B bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11B - live memory grant pressure attempt'
);

SELECT
      CaptureRunID
    , COUNT(*) AS ServerSamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MIN(BufferCacheHitRatio) AS MinBufferCacheHitRatio
    , AVG(CONVERT(decimal(19,4),BufferCacheHitRatio)) AS AvgBufferCacheHitRatio
    , MIN(PageLifeExpectancySeconds) AS MinPLESeconds
    , MAX(PageLifeExpectancySeconds) AS MaxPLESeconds
    , MIN(AvailablePhysicalMemoryMB) AS MinAvailablePhysicalMemoryMB
    , MAX(MemoryGrantsPending) AS PeakMemoryGrantsPending
    , MIN(TotalServerMemoryMB) AS MinTotalServerMemoryMB
    , MAX(TargetServerMemoryMB) AS MaxTargetServerMemoryMB
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@Run11B
GROUP BY CaptureRunID;

SELECT *
FROM dbo.RCA_MemoryPressureEvidence
WHERE CaptureRunID=@Run11B;

SELECT
      Run11B_LiveCollection=
        CASE
            WHEN
            (
                SELECT COUNT(*)
                FROM dbo.RCA_ServerSnapshot
                WHERE CaptureRunID=@Run11B
            ) >= 20
            THEN 'PASS'
            ELSE 'REVIEW'
        END

    , LiveClassification=
        (
            SELECT TOP (1) PressureSubtype
            FROM dbo.RCA_MemoryPressureEvidence
            WHERE CaptureRunID=@Run11B
            ORDER BY MemoryPressureEvidenceID DESC
        )

    , Interpretation=
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_MemoryPressureEvidence
                WHERE CaptureRunID=@Run11B
                  AND PressureSubtype<>'MEMORY_HEALTHY'
            )
            THEN 'LIVE MEMORY PRESSURE DETECTED'
            ELSE 'LIVE COLLECTION PASSED; LAB DID NOT SUSTAIN MEMORY-PRESSURE THRESHOLDS'
        END;

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run11B;
GO


/*==============================================================================
    RUN 11C - DETERMINISTIC POSITIVE CONTROL

    IMPORTANT DESIGN
    ----------------
    We first let the REAL RCA sampler create valid RCA_ServerSnapshot rows.

    Then we update ONLY those Run 11C rows to deterministic pressure values.

    This means:
      - no dependency on the full RCA_ServerSnapshot insert schema
      - the real detector reads its real source table
      - final ranking and human output are tested normally

    CONTROLLED PRESSURE
    -------------------
    6+ samples are rewritten to show:

        MemoryGrantsPending          = 4
        AvailablePhysicalMemoryMB    = 768 MB
        BufferCacheHitRatio          = 91%
        TotalServerMemoryMB          = 12288 MB
        TargetServerMemoryMB         = 16384 MB

    PLE is rewritten as a falling sequence:
        1800 -> 1200 -> 800 -> 500 -> 300 -> 200 ...

    This creates:
        sustained grant queue pressure
        sustained severe OS memory pressure
        sustained target-memory deficit
        buffer-pool corroboration

    Expected:
        MEMORY_PRESSURE_MIXED
        PRIMARY
        HIGH
==============================================================================*/

USE DBA;
GO

DECLARE @Run11C bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 11C - deterministic memory pressure validation',
     @CaptureRunID=@Run11C OUTPUT;

SELECT
      CaptureRunID=@Run11C
    , Run11CStatus='STARTED';
GO

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID=@Run11C,
     @DurationMinutes=1,
     @SampleSeconds=5;
GO

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run11C;
GO


/*------------------------------------------------------------------------------
    Rewrite only Run 11C server-state evidence.
------------------------------------------------------------------------------*/

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

;WITH x AS
(
    SELECT
          ServerSnapshotID
        , rn=ROW_NUMBER() OVER (ORDER BY CaptureTimeUTC,ServerSnapshotID)
    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID=@Run11C
)
UPDATE s
SET
      MemoryGrantsPending=4
    , AvailablePhysicalMemoryMB=768.00
    , BufferCacheHitRatio=91.0000
    , TotalServerMemoryMB=12288.00
    , TargetServerMemoryMB=16384.00

    , PageLifeExpectancySeconds=
        CASE x.rn
            WHEN 1 THEN 1800
            WHEN 2 THEN 1200
            WHEN 3 THEN 800
            WHEN 4 THEN 500
            WHEN 5 THEN 300
            ELSE 200
        END
FROM dbo.RCA_ServerSnapshot AS s
JOIN x
  ON x.ServerSnapshotID=s.ServerSnapshotID;
GO


/*------------------------------------------------------------------------------
    Prove deterministic source evidence.
------------------------------------------------------------------------------*/

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

SELECT
      CaptureRunID
    , CaptureTimeUTC
    , BufferCacheHitRatio
    , PageLifeExpectancySeconds
    , TotalServerMemoryMB
    , TargetServerMemoryMB
    , AvailablePhysicalMemoryMB
    , MemoryGrantsPending
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@Run11C
ORDER BY CaptureTimeUTC,ServerSnapshotID;
GO


/*------------------------------------------------------------------------------
    Build deterministic memory evidence.
------------------------------------------------------------------------------*/

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

EXEC dbo.usp_RCA_BuildMemoryPressureEvidence
     @CaptureRunID=@Run11C;
GO

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

SELECT *
FROM dbo.RCA_MemoryPressureEvidence
WHERE CaptureRunID=@Run11C;
GO


/*------------------------------------------------------------------------------
    Authoritative final cause.
------------------------------------------------------------------------------*/

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

SELECT
      CaptureRunID
    , CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , CorrelationKey
    , ImpactedRequestCount
    , EvidenceCount
    , PrimaryEvidence
    , RecommendedAction
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID=@Run11C
ORDER BY
      RoleRank
    , ConfidenceRank
    , ImpactRank
    , EvidenceStrengthRank;
GO


/*------------------------------------------------------------------------------
    Run 11C acceptance.
------------------------------------------------------------------------------*/

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

SELECT
      Run11C_MemoryPositive=
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_MemoryPressureEvidence
                WHERE CaptureRunID=@Run11C
                  AND PressureSubtype='MEMORY_PRESSURE_MIXED'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
                  AND GrantQueuePressure=1
                  AND OSMemoryPressure=1
            )
            AND EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run11C
                  AND CauseCategory='INSTANCE_MEMORY_PRESSURE'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
            )
            THEN 'PASS'
            ELSE 'FAIL'
        END

    , ExpectedCause='INSTANCE_MEMORY_PRESSURE'
    , ExpectedSubtype='MEMORY_PRESSURE_MIXED'
    , ExpectedRole='PRIMARY'
    , ExpectedConfidence='HIGH';
GO


/*------------------------------------------------------------------------------
    HUMAN-FACING ACCEPTANCE

    This is the output Will / Bhuvan / junior DBA should consume.
------------------------------------------------------------------------------*/

DECLARE @Run11C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
);

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run11C;
GO


/*==============================================================================
    STEP 3 - CLEAN UP RUN 11 SQL AGENT TEST JOBS
==============================================================================*/

USE msdb;
GO

DECLARE
      @JobName sysname
    , @CurrentAgentSessionID int;

SELECT @CurrentAgentSessionID=MAX(session_id)
FROM dbo.syssessions;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run11_Memory_%';

OPEN JobCleanup;
FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS=0
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs AS j
        JOIN dbo.sysjobactivity AS a
          ON a.job_id=j.job_id
         AND a.session_id=@CurrentAgentSessionID
        WHERE j.name=@JobName
          AND a.start_execution_date IS NOT NULL
          AND a.stop_execution_date IS NULL
    )
    BEGIN
        EXEC dbo.sp_stop_job @job_name=@JobName;
        WAITFOR DELAY '00:00:02';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs
        WHERE name=@JobName
    )
    BEGIN
        EXEC dbo.sp_delete_job
             @job_name=@JobName,
             @delete_unused_schedule=1;
    END;

    FETCH NEXT FROM JobCleanup INTO @JobName;
END;

CLOSE JobCleanup;
DEALLOCATE JobCleanup;

SELECT Run11JobsRemaining=COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run11_Memory_%';
GO


/*==============================================================================
    STEP 4 - FINAL REGRESSION MATRIX
==============================================================================*/

USE DBA;
GO

;WITH TestRuns AS
(
    SELECT CONVERT(bigint,3) AS CaptureRunID,
           CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE') AS ExpectedCause
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 16, 'CPU_SCHEDULER_PRESSURE'
    UNION ALL SELECT 20, 'IO_STORAGE_PRESSURE'
    UNION ALL SELECT 26, 'TEMPDB_PRESSURE_CONTENTION'
    UNION ALL
    SELECT
          (
              SELECT MAX(CaptureRunID)
              FROM dbo.RCA_CaptureRun
              WHERE CaptureReason=N'Run 11C - deterministic memory pressure validation'
          )
        , 'INSTANCE_MEMORY_PRESSURE'
),
Ranked AS
(
    SELECT
          t.CaptureRunID
        , t.ExpectedCause
        , r.CauseCategory
        , r.CauseDisplayName
        , r.RootCauseRole
        , r.Confidence
        , rn=
            ROW_NUMBER() OVER
            (
                PARTITION BY t.CaptureRunID
                ORDER BY
                      r.RoleRank
                    , r.ConfidenceRank
                    , r.ImpactRank
                    , r.EvidenceStrengthRank
            )
    FROM TestRuns AS t
    LEFT JOIN dbo.vw_RCA_FinalCauseRanking AS r
      ON r.CaptureRunID=t.CaptureRunID
)
SELECT
      CaptureRunID
    , ExpectedCause
    , DetectedTopCause=CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , ValidationResult=
        CASE
            WHEN CauseCategory=ExpectedCause THEN 'PASS'
            ELSE 'REVIEW'
        END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO


/*==============================================================================
    FINAL EXPECTATIONS

    RUN 11A
    -------
    Normal memory state:
        MEMORY_HEALTHY
        not PRIMARY
        no false memory RCA

    RUN 11B
    -------
    Live collection must work.
    A positive memory diagnosis is optional.

    RUN 11C
    -------
    MUST PASS:
        INSTANCE_MEMORY_PRESSURE
        MEMORY_PRESSURE_MIXED
        PRIMARY
        HIGH

    Human output must show:
        Memory Grants Pending
        Available Physical Memory
        Buffer Cache Hit Ratio
        Page Life Expectancy
        Target Server Memory
        Total Server Memory

    Existing validated domains must remain unchanged.
==============================================================================*/
