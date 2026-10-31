USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    31_RCA_Run12_TransactionLog_Validation.sql

    PURPOSE
    -------
    End-to-end validation of the TRANSACTION_LOG_PRESSURE root-cause domain.

    TESTS
    -----
    Run 12A - LIVE NEGATIVE CONTROL
        Capture ordinary transaction-log activity.
        Expected:
            LOG_ACTIVITY_ONLY
            CONTRIBUTING / LOW
            Transaction log must NOT become PRIMARY.

    Run 12B - LIVE LOG-WORKLOAD ATTEMPT
        Run several concurrent SQL Agent workers that generate transactional
        log activity while the independent log sampler runs.
        Expected:
            The live collector must work.
            A positive transaction-log diagnosis is optional because local SSD
            latency may remain healthy.

        IMPORTANT:
            Do NOT lower production-oriented thresholds just to force a pass.

    Run 12C - DETERMINISTIC POSITIVE CONTROL
        Populate dbo.RCA_LogSnapshot with controlled, sustained log-write
        latency and WRITELOG waiter evidence.

        Expected:
            TRANSACTION_LOG_PRESSURE
            LOG_PRESSURE_MIXED
            PRIMARY
            HIGH

    HUMAN ACCEPTANCE
    ----------------
    dbo.usp_RCA_WhyWasItSlow must expose:
        database
        logical log file
        physical log path
        recovery model
        log-used %
        log MB generated
        average log-write latency
        WRITELOG / log-governor waiter evidence

    LAB ONLY
    --------
    Run 12B creates write-heavy workload and uses SQL Agent workers.
    Do not execute the live workload section on production.
==============================================================================*/


/*==============================================================================
    STEP 0 - PRE-FLIGHT
==============================================================================*/

SELECT
      CaptureRunTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogSnapshotTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_LogSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogSampler =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunLogSampler',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_TransactionLogEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildTransactionLogEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseRanking =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HumanOutput =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_LogSnapshot',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_RunLogSampler',N'P') IS NULL
 OR OBJECT_ID(N'dbo.RCA_TransactionLogEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_BuildTransactionLogEvidence',N'P') IS NULL
 OR OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NULL
BEGIN
    THROW 51900,N'Run 12 pre-flight failed. Required transaction-log RCA objects are missing.',1;
END;
GO

SELECT
      DatabaseName=d.name
    , RecoveryModel=d.recovery_model_desc
    , LogicalLogFile=mf.name
    , PhysicalLogFile=mf.physical_name
    , SizeMB=CONVERT(decimal(19,2),mf.size/128.0)
    , GrowthSetting=
        CASE
            WHEN mf.is_percent_growth=1
                THEN CONCAT(mf.growth,'%')
            ELSE CONCAT(CONVERT(decimal(19,2),mf.growth/128.0),' MB')
        END
FROM sys.databases AS d
JOIN sys.master_files AS mf
  ON mf.database_id=d.database_id
WHERE mf.type_desc='LOG'
  AND d.name IN (N'DBA',N'RCA')
ORDER BY d.name,mf.file_id;
GO


/*==============================================================================
    STEP 1 - CLEAN UP ANY OLD RUN 12 SQL AGENT JOBS
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
WHERE name LIKE N'RCA_Run12_Log_%';

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

SELECT OldRun12JobsRemaining=COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run12_Log_%';
GO


/*==============================================================================
    STEP 2 - CREATE BOUNDED LOG-WORKLOAD OBJECTS
==============================================================================*/

USE RCA;
GO

IF OBJECT_ID(N'dbo.RCA_Run12_LogWorkload',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_Run12_LogWorkload
    (
          LogWorkloadID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_Run12_LogWorkload PRIMARY KEY
        , WorkerID int NOT NULL
        , CycleNo int NOT NULL
        , Payload char(2000) NOT NULL
        , Amount decimal(19,4) NOT NULL
        , CreatedUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_Run12_LogWorkload_CreatedUTC
            DEFAULT SYSUTCDATETIME()
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run12_LogWorker
      @WorkerID int
    , @DurationSeconds int=90
    , @RowsPerBatch int=1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationSeconds < 10 OR @DurationSeconds > 300
        THROW 51901,N'@DurationSeconds must be between 10 and 300.',1;

    IF @RowsPerBatch < 100 OR @RowsPerBatch > 5000
        THROW 51902,N'@RowsPerBatch must be between 100 and 5000.',1;

    DECLARE
          @StopAt datetime2(3)=DATEADD(second,@DurationSeconds,SYSUTCDATETIME())
        , @Cycle int=0
        , @Inserted bigint=0;

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        SET @Cycle+=1;

        BEGIN TRAN;

        ;WITH n AS
        (
            SELECT TOP (@RowsPerBatch)
                rn=ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
            FROM sys.all_objects AS a
            CROSS JOIN sys.all_objects AS b
        )
        INSERT dbo.RCA_Run12_LogWorkload
        (
              WorkerID
            , CycleNo
            , Payload
            , Amount
        )
        SELECT
              @WorkerID
            , @Cycle
            , REPLICATE(CHAR(65+(@WorkerID%20)),2000)
            , CONVERT(decimal(19,4),(rn%10000)*1.0173)
        FROM n;

        SET @Inserted+=@@ROWCOUNT;

        UPDATE dbo.RCA_Run12_LogWorkload
        SET Amount=Amount+0.01
        WHERE WorkerID=@WorkerID
          AND CycleNo=@Cycle;

        COMMIT;

        CHECKPOINT;
    END;

    SELECT
          WorkerSessionID=@@SPID
        , WorkerID=@WorkerID
        , CyclesCompleted=@Cycle
        , RowsInserted=@Inserted;
END;
GO


/*==============================================================================
    RUN 12A - LIVE NEGATIVE CONTROL
==============================================================================*/

USE DBA;
GO

DECLARE @Run12A bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 12A - transaction log negative control',
     @CaptureRunID=@Run12A OUTPUT;

SELECT
      CaptureRunID=@Run12A
    , Run12AStatus='STARTED';
GO

DECLARE @Run12A bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12A - transaction log negative control'
);

EXEC dbo.usp_RCA_RunLogSampler
     @CaptureRunID=@Run12A,
     @DurationMinutes=1,
     @SampleSeconds=5;
GO

DECLARE @Run12A bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12A - transaction log negative control'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run12A;

EXEC dbo.usp_RCA_BuildTransactionLogEvidence
     @CaptureRunID=@Run12A;
GO

DECLARE @Run12A bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12A - transaction log negative control'
);

SELECT *
FROM dbo.RCA_TransactionLogEvidence
WHERE CaptureRunID=@Run12A
ORDER BY DatabaseName,FileID;

SELECT
      Run12A_NegativeControl=
        CASE
            WHEN NOT EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run12A
                  AND CauseCategory='TRANSACTION_LOG_PRESSURE'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence IN ('HIGH','MEDIUM')
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END;

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run12A;
GO


/*==============================================================================
    RUN 12B - LIVE TRANSACTION LOG WORKLOAD ATTEMPT
==============================================================================*/

USE RCA;
GO
TRUNCATE TABLE dbo.RCA_Run12_LogWorkload;
GO

USE DBA;
GO

DECLARE @Run12B bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 12B - live transaction log pressure attempt',
     @CaptureRunID=@Run12B OUTPUT;

SELECT
      CaptureRunID=@Run12B
    , Run12BStatus='STARTED';
GO


/*------------------------------------------------------------------------------
    Create log sampler SQL Agent job.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE @Run12B bigint=
(
    SELECT MAX(CaptureRunID)
    FROM DBA.dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12B - live transaction log pressure attempt'
);

DECLARE @SamplerCommand nvarchar(max)=
    N'USE DBA;
      EXEC dbo.usp_RCA_RunLogSampler
           @CaptureRunID=' + CONVERT(nvarchar(30),@Run12B) + N',
           @DurationMinutes=2,
           @SampleSeconds=5;';

EXEC dbo.sp_add_job
     @job_name=N'RCA_Run12_Log_Sampler',
     @enabled=1,
     @description=N'Run 12B transaction-log sampler';

EXEC dbo.sp_add_jobstep
     @job_name=N'RCA_Run12_Log_Sampler',
     @step_name=N'Run transaction-log sampler',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand,
     @on_success_action=1,
     @on_fail_action=2;

EXEC dbo.sp_add_jobserver
     @job_name=N'RCA_Run12_Log_Sampler';

EXEC dbo.sp_start_job
     @job_name=N'RCA_Run12_Log_Sampler';
GO

WAITFOR DELAY '00:00:10';
GO


/*------------------------------------------------------------------------------
    Create six concurrent log-generating worker jobs.
------------------------------------------------------------------------------*/

USE msdb;
GO

DECLARE
      @i int=1
    , @WorkerJob sysname
    , @WorkerCommand nvarchar(max);

WHILE @i<=6
BEGIN
    SET @WorkerJob=
        CONCAT(N'RCA_Run12_Log_Worker_',RIGHT('00'+CONVERT(varchar(2),@i),2));

    SET @WorkerCommand=
        N'USE RCA;
          EXEC dbo.usp_RCA_Run12_LogWorker
               @WorkerID=' + CONVERT(nvarchar(10),@i) + N',
               @DurationSeconds=90,
               @RowsPerBatch=1000;';

    EXEC dbo.sp_add_job
         @job_name=@WorkerJob,
         @enabled=1,
         @description=N'Run 12B concurrent transaction-log workload worker';

    EXEC dbo.sp_add_jobstep
         @job_name=@WorkerJob,
         @step_name=N'Generate transaction-log workload',
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
    , Run12B='STARTED';
GO

WAITFOR DELAY '00:02:10';
GO


/*------------------------------------------------------------------------------
    Verify SQL Agent outcomes.
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
WHERE j.name LIKE N'RCA_Run12_Log_%'
ORDER BY j.name;
GO


/*------------------------------------------------------------------------------
    Stop capture and build evidence.
------------------------------------------------------------------------------*/

USE DBA;
GO

DECLARE @Run12B bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12B - live transaction log pressure attempt'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run12B;

EXEC dbo.usp_RCA_BuildTransactionLogEvidence
     @CaptureRunID=@Run12B;
GO

DECLARE @Run12B bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12B - live transaction log pressure attempt'
);

SELECT *
FROM dbo.RCA_TransactionLogEvidence
WHERE CaptureRunID=@Run12B
ORDER BY
      CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END
    , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
    , DeltaWriteMB DESC;

SELECT
      Run12B_LiveCollection=
        CASE
            WHEN
            (
                SELECT COUNT(*)
                FROM dbo.RCA_LogSnapshot
                WHERE CaptureRunID=@Run12B
            ) >= 20
            THEN 'PASS'
            ELSE 'REVIEW'
        END
    , RCA_LogClassification=
        (
            SELECT TOP (1) PressureSubtype
            FROM dbo.RCA_TransactionLogEvidence
            WHERE CaptureRunID=@Run12B
              AND DatabaseName='RCA'
            ORDER BY TransactionLogEvidenceID DESC
        )
    , Interpretation=
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_TransactionLogEvidence
                WHERE CaptureRunID=@Run12B
                  AND DatabaseName='RCA'
                  AND PressureSubtype<>'LOG_ACTIVITY_ONLY'
            )
            THEN 'LIVE TRANSACTION LOG PRESSURE DETECTED'
            ELSE 'LIVE COLLECTION PASSED; LAB DID NOT SUSTAIN LOG-PRESSURE THRESHOLDS'
        END;

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run12B;
GO


/*==============================================================================
    RUN 12C - DETERMINISTIC POSITIVE CONTROL

    CONTROLLED EVIDENCE
    -------------------
    RCA transaction log:
      6 samples
      25-second observation
      1000 writes
      500 MB generated
      35 ms average write latency
      90-94% log used
      WRITELOG waiters in all 6 samples

    Expected:
        LOG_PRESSURE_MIXED
        PRIMARY
        HIGH
==============================================================================*/

USE DBA;
GO

DECLARE @Run12C bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 12C - deterministic transaction log pressure validation',
     @CaptureRunID=@Run12C OUTPUT;

SELECT
      CaptureRunID=@Run12C
    , Run12CStatus='STARTED';
GO

DECLARE @Run12C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
);

DELETE FROM dbo.RCA_LogSnapshot
WHERE CaptureRunID=@Run12C;

DECLARE
      @DatabaseID int=DB_ID(N'RCA')
    , @FileID int
    , @LogicalFileName sysname
    , @PhysicalName nvarchar(520)
    , @RecoveryModelDesc nvarchar(60);

SELECT TOP (1)
      @FileID=mf.file_id
    , @LogicalFileName=mf.name
    , @PhysicalName=mf.physical_name
    , @RecoveryModelDesc=d.recovery_model_desc
FROM sys.master_files AS mf
JOIN sys.databases AS d
  ON d.database_id=mf.database_id
WHERE mf.database_id=@DatabaseID
  AND mf.type_desc='LOG'
ORDER BY mf.file_id;

IF @FileID IS NULL
    THROW 51910,N'Run 12C could not resolve the RCA transaction-log file.',1;

DECLARE @BaseTime datetime2(3)='2026-08-15T13:00:00.000';

INSERT dbo.RCA_LogSnapshot
(
      CaptureRunID
    , CaptureTimeUTC
    , DatabaseID
    , DatabaseName
    , RecoveryModelDesc
    , FileID
    , LogicalFileName
    , PhysicalName
    , LogSizeMB
    , LogSpaceUsedPercent
    , NumWrites
    , BytesWritten
    , IoStallWriteMs
    , LogWaiterCount
    , WriteLogWaiterCount
    , LogRateGovernorWaiterCount
)
VALUES
(@Run12C,DATEADD(second, 0,@BaseTime),@DatabaseID,N'RCA',@RecoveryModelDesc,@FileID,@LogicalFileName,@PhysicalName,1992.00,90.0000,10000,1048576000,100000,3,3,0),
(@Run12C,DATEADD(second, 5,@BaseTime),@DatabaseID,N'RCA',@RecoveryModelDesc,@FileID,@LogicalFileName,@PhysicalName,1992.00,91.0000,10200,1153433600,107000,4,4,0),
(@Run12C,DATEADD(second,10,@BaseTime),@DatabaseID,N'RCA',@RecoveryModelDesc,@FileID,@LogicalFileName,@PhysicalName,1992.00,92.0000,10400,1258291200,114000,4,4,0),
(@Run12C,DATEADD(second,15,@BaseTime),@DatabaseID,N'RCA',@RecoveryModelDesc,@FileID,@LogicalFileName,@PhysicalName,1992.00,93.0000,10600,1363148800,121000,5,5,0),
(@Run12C,DATEADD(second,20,@BaseTime),@DatabaseID,N'RCA',@RecoveryModelDesc,@FileID,@LogicalFileName,@PhysicalName,1992.00,94.0000,10800,1468006400,128000,5,5,0),
(@Run12C,DATEADD(second,25,@BaseTime),@DatabaseID,N'RCA',@RecoveryModelDesc,@FileID,@LogicalFileName,@PhysicalName,1992.00,94.0000,11000,1572864000,135000,5,5,0);

SELECT
      CaptureRunID
    , COUNT(*) AS DeterministicSamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MAX(LogSpaceUsedPercent) AS PeakLogUsedPercent
    , MAX(WriteLogWaiterCount) AS PeakWriteLogWaiters
FROM dbo.RCA_LogSnapshot
WHERE CaptureRunID=@Run12C
GROUP BY CaptureRunID;
GO

DECLARE @Run12C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
);

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=@Run12C;

EXEC dbo.usp_RCA_BuildTransactionLogEvidence
     @CaptureRunID=@Run12C;
GO

DECLARE @Run12C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
);

SELECT *
FROM dbo.RCA_TransactionLogEvidence
WHERE CaptureRunID=@Run12C;
GO


/*------------------------------------------------------------------------------
    Authoritative final cause.
------------------------------------------------------------------------------*/

DECLARE @Run12C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
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
WHERE CaptureRunID=@Run12C
ORDER BY
      RoleRank
    , ConfidenceRank
    , ImpactRank
    , EvidenceStrengthRank;
GO


/*------------------------------------------------------------------------------
    Run 12C acceptance.
------------------------------------------------------------------------------*/

DECLARE @Run12C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
);

SELECT
      Run12C_LogPositive=
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_TransactionLogEvidence
                WHERE CaptureRunID=@Run12C
                  AND DatabaseName='RCA'
                  AND PressureSubtype='LOG_PRESSURE_MIXED'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
                  AND WriteLatencyPressure=1
                  AND LogSpacePressure=1
                  AND LogWaitPressure=1
            )
            AND EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run12C
                  AND CauseCategory='TRANSACTION_LOG_PRESSURE'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
            )
            THEN 'PASS'
            ELSE 'FAIL'
        END
    , ExpectedCause='TRANSACTION_LOG_PRESSURE'
    , ExpectedSubtype='LOG_PRESSURE_MIXED'
    , ExpectedRole='PRIMARY'
    , ExpectedConfidence='HIGH';
GO


/*------------------------------------------------------------------------------
    Human-facing acceptance.
------------------------------------------------------------------------------*/

DECLARE @Run12C bigint=
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
);

EXEC dbo.usp_RCA_WhyWasItSlow
     @CaptureRunID=@Run12C;
GO


/*==============================================================================
    STEP 3 - CLEAN UP SQL AGENT TEST JOBS
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
WHERE name LIKE N'RCA_Run12_Log_%';

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

SELECT Run12JobsRemaining=COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run12_Log_%';
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
    UNION ALL SELECT 29, 'INSTANCE_MEMORY_PRESSURE'
    UNION ALL
    SELECT
          (
              SELECT MAX(CaptureRunID)
              FROM dbo.RCA_CaptureRun
              WHERE CaptureReason=N'Run 12C - deterministic transaction log pressure validation'
          )
        , 'TRANSACTION_LOG_PRESSURE'
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
        CASE WHEN CauseCategory=ExpectedCause THEN 'PASS' ELSE 'REVIEW' END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO


/*==============================================================================
    FINAL EXPECTATIONS

    RUN 12A
    -------
    Normal transaction-log activity must not become a root cause.

    RUN 12B
    -------
    Live collection must work.
    A positive log diagnosis is optional.

    RUN 12C
    -------
    MUST PASS:
        TRANSACTION_LOG_PRESSURE
        LOG_PRESSURE_MIXED
        PRIMARY
        HIGH

    Human output must expose:
        DatabaseName
        RecoveryModelDesc
        LogicalFileName
        PhysicalName
        PeakLogSpaceUsedPercent
        DeltaWriteMB
        AvgWriteLatencyMs
        PeakWriteLogWaiters

    Existing validated domains must remain unchanged.
==============================================================================*/
