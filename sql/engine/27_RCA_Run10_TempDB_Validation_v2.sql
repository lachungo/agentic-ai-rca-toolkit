USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    27_RCA_Run10_TempDB_Validation_v2.sql

    PURPOSE
    -------
    End-to-end validation of the TEMPDB_PRESSURE_CONTENTION root-cause domain.

    TESTS
    -----
    Run 10A - LIVE NEGATIVE CONTROL
        Normal / light TempDB activity.
        Expected:
            TempDB evidence exists.
            PressureSubtype = TEMPDB_ACTIVITY_ONLY.
            TempDB must NOT become PRIMARY.

    Run 10B - LIVE TEMPDB PRESSURE ATTEMPT
        Several concurrent SQL Agent workers create/drop temp tables while the
        TempDB sampler is running.
        Expected:
            The engine should classify only what is actually observed.
            A positive TempDB result is acceptable.
            A negative result is also acceptable if the lab does not sustain
            the configured pressure thresholds.

        IMPORTANT:
            We do NOT lower thresholds merely to force PASS.

    Run 10C - DETERMINISTIC POSITIVE CONTROL
        Inserts controlled TempDB snapshot evidence into a fresh capture.
        Expected:
            TEMPDB_PRESSURE_CONTENTION
            TEMPDB_SPACE_PRESSURE
            PRIMARY / HIGH
            Human output must explain the TempDB cause.

    LAB ONLY
    --------
    Run 10B intentionally creates TempDB workload.
    Do not execute this validation harness on production.

    V2 CORRECTIONS
    --------------
    - Corrected tempdb.sys.database_files pre-flight (no database_id column).
    - SQL Agent cleanup is state-aware; stopped jobs are not stopped again.
    - Job completion output reports current Agent-session state and last status.
    - Added hard pre-flight guard before any capture is created.

    DESIGN PRINCIPLE
    ----------------
    The live test proves collection.
    The deterministic test proves classification, ranking and human output.
==============================================================================*/


/*==============================================================================
    STEP 0 - PRE-FLIGHT
==============================================================================*/

SELECT
      TempDBSnapshotTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_TempDBSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBSampler =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunTempDBSampler',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBEvidence =
        CASE WHEN OBJECT_ID(N'dbo.RCA_TempDBEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildTempDBEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseRanking =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HumanOutput =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO

IF OBJECT_ID(N'dbo.RCA_TempDBSnapshot',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_RunTempDBSampler',N'P') IS NULL
 OR OBJECT_ID(N'dbo.RCA_TempDBEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_BuildTempDBEvidence',N'P') IS NULL
 OR OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NULL
BEGIN
    THROW 51510,N'Run 10 pre-flight failed. One or more required TempDB RCA objects are missing.',1;
END;
GO

SELECT
      DatabaseName = CONVERT(sysname,N'tempdb')
    , FileID = file_id
    , LogicalFileName = name
    , FileType = type_desc
    , PhysicalName = physical_name
    , SizeMB = CONVERT(decimal(19,2),size / 128.0)
    , GrowthSetting =
        CASE
            WHEN is_percent_growth = 1
                THEN CONCAT(growth,'%')
            ELSE CONCAT(CONVERT(decimal(19,2),growth/128.0),' MB')
        END
FROM tempdb.sys.database_files
ORDER BY file_id;
GO


/*==============================================================================
    STEP 1 - CREATE LIVE TEST WORKLOAD PROCEDURE

    Created in RCA so SQL Agent workers can call it.

    Each worker:
      - creates a local temp table
      - inserts a controlled amount of data
      - scans / aggregates it
      - briefly holds it
      - drops it
      - repeats

    The workload is intentionally bounded.
==============================================================================*/

USE RCA;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run10_TempDBWorker
      @DurationSeconds int = 90
    , @RowsPerCycle int = 3000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationSeconds < 10 OR @DurationSeconds > 300
        THROW 51500,N'@DurationSeconds must be between 10 and 300.',1;

    IF @RowsPerCycle < 500 OR @RowsPerCycle > 10000
        THROW 51501,N'@RowsPerCycle must be between 500 and 10000.',1;

    DECLARE
          @StopAt datetime2(3)=DATEADD(second,@DurationSeconds,SYSUTCDATETIME())
        , @Cycle int=0
        , @Checksum bigint;

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        CREATE TABLE #Run10TempDB
        (
              RowID bigint IDENTITY(1,1) NOT NULL
            , SortKey int NOT NULL
            , Amount decimal(19,4) NOT NULL
            , Payload char(3500) NOT NULL
        );

        ;WITH n AS
        (
            SELECT TOP (@RowsPerCycle)
                  rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
            FROM sys.all_objects AS a
            CROSS JOIN sys.all_objects AS b
        )
        INSERT #Run10TempDB
        (
              SortKey
            , Amount
            , Payload
        )
        SELECT
              CONVERT(int,(rn * 37) % 100000)
            , CONVERT(decimal(19,4),(rn % 10000) * 1.0173)
            , REPLICATE(CHAR(65 + (rn % 20)),3500)
        FROM n;

        /* Force real work against the TempDB object. */
        SELECT
            @Checksum =
                CHECKSUM_AGG
                (
                    CHECKSUM
                    (
                          SortKey
                        , Amount
                        , Payload
                    )
                )
        FROM #Run10TempDB
        WHERE SortKey >= 0;

        /* Keep allocation alive briefly so concurrent workers overlap. */
        WAITFOR DELAY '00:00:02';

        DROP TABLE #Run10TempDB;

        SET @Cycle += 1;
    END;

    SELECT
          WorkerSessionID = @@SPID
        , CyclesCompleted = @Cycle
        , LastChecksum = @Checksum;
END;
GO


/*==============================================================================
    STEP 2 - CLEAN UP ANY OLD RUN 10 SQL AGENT JOBS
==============================================================================*/

USE msdb;
GO

DECLARE
      @JobName sysname
    , @CurrentAgentSessionID int;

SELECT @CurrentAgentSessionID = MAX(session_id)
FROM dbo.syssessions;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run10_TempDB_%';

OPEN JobCleanup;

FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs AS j
        JOIN dbo.sysjobactivity AS a
          ON a.job_id = j.job_id
         AND a.session_id = @CurrentAgentSessionID
        WHERE j.name = @JobName
          AND a.start_execution_date IS NOT NULL
          AND a.stop_execution_date IS NULL
    )
    BEGIN
        EXEC dbo.sp_stop_job @job_name=@JobName;

        /* Give SQL Agent a moment to record stop_execution_date. */
        WAITFOR DELAY '00:00:02';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs
        WHERE name = @JobName
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

SELECT OldRun10JobsRemaining = COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run10_TempDB_%';
GO


/*==============================================================================
    RUN 10A - LIVE NEGATIVE CONTROL
==============================================================================*/

USE DBA;
GO

DECLARE @Run10A bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 10A - TempDB negative control',
     @CaptureRunID=@Run10A OUTPUT;

SELECT
      CaptureRunID=@Run10A
    , Run10AStatus='STARTED';
GO

/*------------------------------------------------------------------------------
    10A sampler.

    We intentionally capture TempDB without launching the pressure workload.
------------------------------------------------------------------------------*/

DECLARE @Run10A bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10A - TempDB negative control'
);

EXEC dbo.usp_RCA_RunTempDBSampler
     @CaptureRunID=@Run10A,
     @DurationMinutes=1,
     @SampleSeconds=5;
GO

DECLARE @Run10A bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10A - TempDB negative control'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run10A;

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID=@Run10A;

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID=@Run10A;

EXEC dbo.usp_RCA_BuildTempDBEvidence
     @CaptureRunID=@Run10A;
GO

DECLARE @Run10A bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10A - TempDB negative control'
);

SELECT *
FROM dbo.RCA_TempDBEvidence
WHERE CaptureRunID=@Run10A;

SELECT
      Run10A_NegativeControl =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_TempDBEvidence
                WHERE CaptureRunID=@Run10A
                  AND PressureSubtype='TEMPDB_ACTIVITY_ONLY'
                  AND RootCauseRole='CONTRIBUTING'
                  AND Confidence='LOW'
            )
            AND NOT EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run10A
                  AND CauseCategory='TEMPDB_PRESSURE_CONTENTION'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence IN ('HIGH','MEDIUM')
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END;

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run10A;
GO


/*==============================================================================
    RUN 10B - LIVE TEMPDB PRESSURE ATTEMPT

    The script uses SQL Agent so sampler and workload execute concurrently.

    Worker count: 6
    Worker duration: 90 seconds
    Sampler duration: 2 minutes
    Sample interval: 5 seconds

    EXPECTATION
    -----------
    Collection must PASS.

    Classification may legitimately be:
        TEMPDB pressure detected
    OR
        no TempDB root cause

    depending on the local machine and TempDB growth behavior.

    We do NOT lower thresholds to manufacture a positive result.
==============================================================================*/

USE DBA;
GO

DECLARE @Run10B bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 10B - live TempDB pressure attempt',
     @CaptureRunID=@Run10B OUTPUT;

SELECT
      CaptureRunID=@Run10B
    , Run10BStatus='STARTED';
GO


/*------------------------------------------------------------------------------
    Create sampler SQL Agent job.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE @Run10B bigint =
(
    SELECT MAX(CaptureRunID)
    FROM DBA.dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10B - live TempDB pressure attempt'
);

DECLARE @SamplerCommand nvarchar(max) =
    N'USE DBA;
      EXEC dbo.usp_RCA_RunTempDBSampler
           @CaptureRunID=' + CONVERT(nvarchar(30),@Run10B) + N',
           @DurationMinutes=2,
           @SampleSeconds=5;';

EXEC dbo.sp_add_job
     @job_name=N'RCA_Run10_TempDB_Sampler',
     @enabled=1,
     @description=N'Run 10B TempDB sampler';

EXEC dbo.sp_add_jobstep
     @job_name=N'RCA_Run10_TempDB_Sampler',
     @step_name=N'Run TempDB sampler',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand,
     @on_success_action=1,
     @on_fail_action=2;

EXEC dbo.sp_add_jobserver
     @job_name=N'RCA_Run10_TempDB_Sampler';

EXEC dbo.sp_start_job
     @job_name=N'RCA_Run10_TempDB_Sampler';
GO


/*------------------------------------------------------------------------------
    Give sampler time to establish baseline.
------------------------------------------------------------------------------*/

WAITFOR DELAY '00:00:10';
GO


/*------------------------------------------------------------------------------
    Create and launch six concurrent TempDB workers.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE
      @i int=1
    , @WorkerJob sysname
    , @WorkerCommand nvarchar(max);

WHILE @i <= 6
BEGIN
    SET @WorkerJob =
        CONCAT(N'RCA_Run10_TempDB_Worker_',RIGHT('00'+CONVERT(varchar(2),@i),2));

    SET @WorkerCommand =
        N'USE RCA;
          EXEC dbo.usp_RCA_Run10_TempDBWorker
               @DurationSeconds=90,
               @RowsPerCycle=3000;';

    EXEC dbo.sp_add_job
         @job_name=@WorkerJob,
         @enabled=1,
         @description=N'Run 10B concurrent TempDB workload worker';

    EXEC dbo.sp_add_jobstep
         @job_name=@WorkerJob,
         @step_name=N'Run TempDB workload',
         @subsystem=N'TSQL',
         @database_name=N'RCA',
         @command=@WorkerCommand,
         @on_success_action=1,
         @on_fail_action=2;

    EXEC dbo.sp_add_jobserver
         @job_name=@WorkerJob;

    EXEC dbo.sp_start_job
         @job_name=@WorkerJob;

    SET @i += 1;
END;

SELECT
      CreatedWorkerJobs=6
    , Run10B='STARTED';
GO


/*------------------------------------------------------------------------------
    Wait long enough for workers and sampler to finish.
------------------------------------------------------------------------------*/

WAITFOR DELAY '00:02:10';
GO


/*------------------------------------------------------------------------------
    Verify live jobs completed.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE @CurrentAgentSessionID int =
(
    SELECT MAX(session_id)
    FROM dbo.syssessions
);

SELECT
      j.name
    , a.start_execution_date
    , a.stop_execution_date
    , JobState =
        CASE
            WHEN a.start_execution_date IS NOT NULL
             AND a.stop_execution_date IS NULL
                THEN 'RUNNING'
            WHEN a.start_execution_date IS NOT NULL
             AND a.stop_execution_date IS NOT NULL
                THEN 'COMPLETED'
            ELSE 'NOT STARTED'
        END
    , LastRunStatus =
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
            WHERE h.job_id = j.job_id
              AND h.step_id = 0
            ORDER BY h.instance_id DESC
        )
FROM dbo.sysjobs AS j
LEFT JOIN dbo.sysjobactivity AS a
  ON a.job_id = j.job_id
 AND a.session_id = @CurrentAgentSessionID
WHERE j.name LIKE N'RCA_Run10_TempDB_%'
ORDER BY j.name;
GO


/*------------------------------------------------------------------------------
    Stop capture and build evidence.
------------------------------------------------------------------------------*/

USE DBA;
GO

DECLARE @Run10B bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10B - live TempDB pressure attempt'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run10B;

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID=@Run10B;

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID=@Run10B;

EXEC dbo.usp_RCA_BuildTempDBEvidence
     @CaptureRunID=@Run10B;
GO


/*------------------------------------------------------------------------------
    Run 10B evidence.
------------------------------------------------------------------------------*/

DECLARE @Run10B bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10B - live TempDB pressure attempt'
);

SELECT
      CaptureRunID
    , COUNT(*) AS SnapshotRows
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MAX(UsedPercent) AS PeakUsedPercent
    , MAX(InternalObjectMB) AS PeakInternalObjectMB
    , MAX(VersionStoreMB) AS PeakVersionStoreMB
    , MAX(TempDBLatchWaiterCount) AS PeakLatchWaiters
    , MAX(TempDBPFSWaiterCount) AS PeakPFSWaiters
    , MAX(TempDBGAMWaiterCount) AS PeakGAMWaiters
    , MAX(TempDBSGAMWaiterCount) AS PeakSGAMWaiters
FROM dbo.RCA_TempDBSnapshot
WHERE CaptureRunID=@Run10B
GROUP BY CaptureRunID;

SELECT *
FROM dbo.RCA_TempDBEvidence
WHERE CaptureRunID=@Run10B;

SELECT
      Run10B_LiveCollection =
        CASE
            WHEN
            (
                SELECT COUNT(*)
                FROM dbo.RCA_TempDBSnapshot
                WHERE CaptureRunID=@Run10B
            ) >= 20
            THEN 'PASS'
            ELSE 'REVIEW'
        END

    , LiveClassification =
        (
            SELECT TOP (1) PressureSubtype
            FROM dbo.RCA_TempDBEvidence
            WHERE CaptureRunID=@Run10B
            ORDER BY TempDBEvidenceID DESC
        )

    , Interpretation =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_TempDBEvidence
                WHERE CaptureRunID=@Run10B
                  AND PressureSubtype<>'TEMPDB_ACTIVITY_ONLY'
            )
            THEN 'LIVE PRESSURE DETECTED'
            ELSE 'LIVE COLLECTION PASSED; LAB DID NOT SUSTAIN PRESSURE THRESHOLD'
        END;

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run10B;
GO


/*==============================================================================
    RUN 10C - DETERMINISTIC POSITIVE CONTROL

    PURPOSE
    -------
    Prove classification, final ranking and human output independently of
    whether the laptop can physically sustain a TempDB pressure condition.

    This follows the same philosophy used for deterministic I/O validation:
    do not weaken production-oriented thresholds just to make a lab pass.

    Controlled evidence:
        6 samples
        95% TempDB used
        1.2 GB internal objects
        0 latch waiters
        no stronger upstream cause

    Expected:
        PressureSubtype = TEMPDB_SPACE_PRESSURE
        RootCauseRole   = PRIMARY
        Confidence      = HIGH
==============================================================================*/

USE DBA;
GO

DECLARE @Run10C bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 10C - deterministic TempDB space pressure validation',
     @CaptureRunID=@Run10C OUTPUT;

SELECT
      CaptureRunID=@Run10C
    , Run10CStatus='STARTED';
GO


/*------------------------------------------------------------------------------
    Inject deterministic TempDB snapshots.
------------------------------------------------------------------------------*/

DECLARE @Run10C bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
);

DELETE FROM dbo.RCA_TempDBSnapshot
WHERE CaptureRunID=@Run10C;

DECLARE @BaseTime datetime2(3)='2026-08-15T12:00:00.000';

INSERT dbo.RCA_TempDBSnapshot
(
      CaptureRunID
    , CaptureTimeUTC
    , TotalSizeMB
    , UnallocatedMB
    , UsedMB
    , UsedPercent
    , UserObjectMB
    , InternalObjectMB
    , VersionStoreMB
    , MixedExtentMB
    , TempDBLatchWaiterCount
    , TempDBPFSWaiterCount
    , TempDBGAMWaiterCount
    , TempDBSGAMWaiterCount
)
VALUES
(@Run10C,DATEADD(second, 0,@BaseTime),2048.00,102.40,1945.60,95.0000,500.00,1200.00,200.00,45.60,0,0,0,0),
(@Run10C,DATEADD(second, 5,@BaseTime),2048.00, 92.16,1955.84,95.5000,510.00,1210.00,200.00,35.84,0,0,0,0),
(@Run10C,DATEADD(second,10,@BaseTime),2048.00, 81.92,1966.08,96.0000,520.00,1220.00,200.00,26.08,0,0,0,0),
(@Run10C,DATEADD(second,15,@BaseTime),2048.00, 71.68,1976.32,96.5000,530.00,1230.00,200.00,16.32,0,0,0,0),
(@Run10C,DATEADD(second,20,@BaseTime),2048.00, 61.44,1986.56,97.0000,540.00,1240.00,200.00, 6.56,0,0,0,0),
(@Run10C,DATEADD(second,25,@BaseTime),2048.00, 71.68,1976.32,96.5000,530.00,1230.00,200.00,16.32,0,0,0,0);

SELECT
      CaptureRunID
    , COUNT(*) AS DeterministicSamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MAX(UsedPercent) AS PeakUsedPercent
    , MAX(InternalObjectMB) AS PeakInternalObjectMB
FROM dbo.RCA_TempDBSnapshot
WHERE CaptureRunID=@Run10C
GROUP BY CaptureRunID;
GO


/*------------------------------------------------------------------------------
    Stop the capture before final assessment so human output is FINAL.
------------------------------------------------------------------------------*/

DECLARE @Run10C bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run10C;

EXEC dbo.usp_RCA_BuildTempDBEvidence
     @CaptureRunID=@Run10C;
GO


/*------------------------------------------------------------------------------
    Run 10C detector evidence.
------------------------------------------------------------------------------*/

DECLARE @Run10C bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
);

SELECT *
FROM dbo.RCA_TempDBEvidence
WHERE CaptureRunID=@Run10C;
GO


/*------------------------------------------------------------------------------
    Run 10C authoritative final cause.
------------------------------------------------------------------------------*/

DECLARE @Run10C bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
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
WHERE CaptureRunID=@Run10C
ORDER BY
      RoleRank
    , ConfidenceRank
    , ImpactRank
    , EvidenceStrengthRank;
GO


/*------------------------------------------------------------------------------
    Run 10C acceptance.
------------------------------------------------------------------------------*/

DECLARE @Run10C bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
);

SELECT
      Run10C_TempDBPositive =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_TempDBEvidence
                WHERE CaptureRunID=@Run10C
                  AND PressureSubtype='TEMPDB_SPACE_PRESSURE'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
            )
            AND EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run10C
                  AND CauseCategory='TEMPDB_PRESSURE_CONTENTION'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
            )
            THEN 'PASS'
            ELSE 'FAIL'
        END

    , ExpectedCause='TEMPDB_PRESSURE_CONTENTION'
    , ExpectedSubtype='TEMPDB_SPACE_PRESSURE'
    , ExpectedRole='PRIMARY'
    , ExpectedConfidence='HIGH';
GO


/*------------------------------------------------------------------------------
    Human-facing acceptance.

    This is the most important result for Will/Bhuvan/Junior DBA workflow.
------------------------------------------------------------------------------*/

DECLARE @Run10C bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
);

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run10C;
GO


/*==============================================================================
    STEP 3 - CLEAN UP SQL AGENT TEST JOBS

    The RCA evidence remains.
    Only the temporary SQL Agent validation jobs are removed.
==============================================================================*/

USE msdb;
GO

DECLARE
      @JobName sysname
    , @CurrentAgentSessionID int;

SELECT @CurrentAgentSessionID = MAX(session_id)
FROM dbo.syssessions;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run10_TempDB_%';

OPEN JobCleanup;

FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs AS j
        JOIN dbo.sysjobactivity AS a
          ON a.job_id = j.job_id
         AND a.session_id = @CurrentAgentSessionID
        WHERE j.name = @JobName
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
        WHERE name = @JobName
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

SELECT Run10JobsRemaining = COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run10_TempDB_%';
GO


/*==============================================================================
    STEP 4 - FINAL REGRESSION MATRIX

    Existing validated root-cause domains must still rank correctly.
    Run 10C must now add TEMPDB_PRESSURE_CONTENTION.
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
    UNION ALL
    SELECT
          (
              SELECT MAX(CaptureRunID)
              FROM dbo.RCA_CaptureRun
              WHERE CaptureReason=N'Run 10C - deterministic TempDB space pressure validation'
          )
        , 'TEMPDB_PRESSURE_CONTENTION'
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
        , rn =
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

    RUN 10A
    -------
    TempDB collection works.
    TempDB activity alone does not become a root cause.

    RUN 10B
    -------
    Live collection must work.
    Positive TempDB pressure is optional because the machine may not sustain
    the configured thresholds.

    RUN 10C
    -------
    MUST PASS:
        TEMPDB_PRESSURE_CONTENTION
        TEMPDB_SPACE_PRESSURE
        PRIMARY
        HIGH

    Human output should read approximately:

        ROOT CAUSE IDENTIFIED
        TempDB pressure / contention
        HIGH confidence
        AttributionType = TEMPDB

    And Section 2 should expose:
        pressure subtype
        peak used %
        internal object MB
        sample persistence

    Existing validated domains must remain unchanged.
==============================================================================*/
