USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    33_RCA_Run13_Connection_Network_Validation.sql

    PURPOSE
    -------
    End-to-end validation of the CLIENT_CONNECTION_NETWORK_PRESSURE domain.

    TESTS
    -----
    Run 13A - LIVE NEGATIVE CONTROL
        Observe normal connectivity for one minute.
        Expected: CONNECTIVITY_ACTIVITY_ONLY, CONTRIBUTING / LOW,
        and no PRIMARY connectivity root cause.

    Run 13B - LIVE CONNECTIVITY / CLIENT-PRESSURE ATTEMPT
        Run several concurrent result-producing SQL Agent workers while the
        connectivity sampler runs. A positive result is optional because SQL
        Agent is not a perfect substitute for a genuinely slow external client.

    Run 13C - DETERMINISTIC POSITIVE CONTROL
        Controlled evidence of sustained ASYNC_NETWORK_IO, a connection surge,
        and heavy login/logout churn.

        Expected:
            CLIENT_CONNECTION_NETWORK_PRESSURE
            CONNECTIVITY_PRESSURE_MIXED
            PRIMARY
            HIGH

    IMPORTANT
    ---------
    ASYNC_NETWORK_IO does NOT automatically mean "bad network." It means SQL
    Server is waiting for the client/network path to consume rows. Potential
    causes include slow client consumption, oversized result sets, application
    processing delays, client pressure, or actual network backpressure.

    Authentication failures such as error 18456 are not inferred here; those
    require explicit error-log or XE evidence.

    LAB ONLY.
==============================================================================*/

/*==============================================================================
    STEP 0 - PRE-FLIGHT
==============================================================================*/

SELECT
      CaptureRunTable = CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ConnectivitySnapshotTable = CASE WHEN OBJECT_ID(N'dbo.RCA_ConnectivitySnapshot',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ConnectivitySampler = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunConnectivitySampler',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ConnectivityEvidenceTable = CASE WHEN OBJECT_ID(N'dbo.RCA_ConnectivityEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ConnectivityDetector = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildConnectivityEvidence',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseRanking = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , HumanOutput = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_ConnectivitySnapshot',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_RunConnectivitySampler',N'P') IS NULL
 OR OBJECT_ID(N'dbo.RCA_ConnectivityEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_BuildConnectivityEvidence',N'P') IS NULL
 OR OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NULL
BEGIN
    THROW 52100,N'Run 13 pre-flight failed. Required connectivity RCA objects are missing.',1;
END;
GO

/*==============================================================================
    STEP 1 - CLEAN UP OLD RUN 13 SQL AGENT JOBS
==============================================================================*/
USE msdb;
GO

DECLARE @JobName sysname, @CurrentAgentSessionID int;
SELECT @CurrentAgentSessionID=MAX(session_id) FROM dbo.syssessions;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM dbo.sysjobs WHERE name LIKE N'RCA_Run13_Connectivity_%';

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

    IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=@JobName)
    BEGIN
        EXEC dbo.sp_delete_job @job_name=@JobName,@delete_unused_schedule=1;
    END;

    FETCH NEXT FROM JobCleanup INTO @JobName;
END;
CLOSE JobCleanup;
DEALLOCATE JobCleanup;

SELECT OldRun13JobsRemaining=COUNT(*)
FROM dbo.sysjobs
WHERE name LIKE N'RCA_Run13_Connectivity_%';
GO

/*==============================================================================
    STEP 2 - CREATE BOUNDED LIVE RESULT-PRODUCING WORKER
==============================================================================*/
USE RCA;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run13_NetworkWorker
      @DurationSeconds int=90
    , @RowsPerCycle int=20000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationSeconds < 10 OR @DurationSeconds > 300
        THROW 52101,N'@DurationSeconds must be between 10 and 300.',1;

    IF @RowsPerCycle < 1000 OR @RowsPerCycle > 50000
        THROW 52102,N'@RowsPerCycle must be between 1000 and 50000.',1;

    IF OBJECT_ID(N'dbo.RCA_Run8_CPU',N'U') IS NULL
        THROW 52103,N'RCA.dbo.RCA_Run8_CPU is required for the Run 13B live workload.',1;

    DECLARE @StopAt datetime2(3)=DATEADD(second,@DurationSeconds,SYSUTCDATETIME()), @Cycles int=0;

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        SELECT TOP (@RowsPerCycle)
              RowID, GroupID, SortKey, Amount, Payload
        FROM dbo.RCA_Run8_CPU
        ORDER BY SortKey DESC
        OPTION (MAXDOP 1,RECOMPILE);

        SET @Cycles+=1;
    END;

    SELECT WorkerSessionID=@@SPID,CyclesCompleted=@Cycles;
END;
GO

/*==============================================================================
    RUN 13A - LIVE NEGATIVE CONTROL
==============================================================================*/
USE DBA;
GO

DECLARE @Run13A bigint;
EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 13A - connectivity negative control',
     @CaptureRunID=@Run13A OUTPUT;
SELECT CaptureRunID=@Run13A,Run13AStatus='STARTED';
GO

DECLARE @Run13A bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13A - connectivity negative control');
EXEC dbo.usp_RCA_RunConnectivitySampler @CaptureRunID=@Run13A,@DurationMinutes=1,@SampleSeconds=5;
GO

DECLARE @Run13A bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13A - connectivity negative control');
EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@Run13A;
EXEC dbo.usp_RCA_BuildConnectivityEvidence @CaptureRunID=@Run13A;
GO

DECLARE @Run13A bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13A - connectivity negative control');
SELECT
      CaptureRunID
    , COUNT(*) AS ConnectivitySamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MIN(ActiveConnectionCount) AS MinActiveConnections
    , AVG(CONVERT(decimal(19,2),ActiveConnectionCount)) AS AvgActiveConnections
    , MAX(ActiveConnectionCount) AS PeakActiveConnections
    , MAX(ActiveRequestCount) AS PeakActiveRequests
    , MAX(AsyncNetworkIOWaiterCount) AS PeakAsyncNetworkIOWaiters
    , MAX(MaxAsyncNetworkIOWaitMs) AS MaxAsyncNetworkIOWaitMs
FROM dbo.RCA_ConnectivitySnapshot
WHERE CaptureRunID=@Run13A
GROUP BY CaptureRunID;

SELECT * FROM dbo.RCA_ConnectivityEvidence WHERE CaptureRunID=@Run13A;

SELECT Run13A_NegativeControl=
CASE
    WHEN EXISTS
    (
        SELECT 1 FROM dbo.RCA_ConnectivityEvidence
        WHERE CaptureRunID=@Run13A
          AND PressureSubtype='CONNECTIVITY_ACTIVITY_ONLY'
          AND RootCauseRole='CONTRIBUTING'
          AND Confidence='LOW'
    )
    AND NOT EXISTS
    (
        SELECT 1 FROM dbo.vw_RCA_FinalCauseRanking
        WHERE CaptureRunID=@Run13A
          AND CauseCategory='CLIENT_CONNECTION_NETWORK_PRESSURE'
          AND RootCauseRole='PRIMARY'
          AND Confidence IN ('HIGH','MEDIUM')
    )
    THEN 'PASS' ELSE 'REVIEW'
END;

EXEC dbo.usp_RCA_WhyWasItSlow @CaptureRunID=@Run13A;
GO

/*==============================================================================
    RUN 13B - LIVE CONNECTIVITY / CLIENT-PRESSURE ATTEMPT
==============================================================================*/
USE DBA;
GO

DECLARE @Run13B bigint;
EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 13B - live connectivity pressure attempt',
     @CaptureRunID=@Run13B OUTPUT;
SELECT CaptureRunID=@Run13B,Run13BStatus='STARTED';
GO

USE msdb;
GO
DECLARE @Run13B bigint=(SELECT MAX(CaptureRunID) FROM DBA.dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13B - live connectivity pressure attempt');
DECLARE @SamplerCommand nvarchar(max)=N'USE DBA; EXEC dbo.usp_RCA_RunConnectivitySampler @CaptureRunID='+CONVERT(nvarchar(30),@Run13B)+N',@DurationMinutes=2,@SampleSeconds=5;';

EXEC dbo.sp_add_job @job_name=N'RCA_Run13_Connectivity_Sampler',@enabled=1,@description=N'Run 13B connectivity sampler';
EXEC dbo.sp_add_jobstep @job_name=N'RCA_Run13_Connectivity_Sampler',@step_name=N'Run connectivity sampler',@subsystem=N'TSQL',@database_name=N'DBA',@command=@SamplerCommand,@on_success_action=1,@on_fail_action=2;
EXEC dbo.sp_add_jobserver @job_name=N'RCA_Run13_Connectivity_Sampler';
EXEC dbo.sp_start_job @job_name=N'RCA_Run13_Connectivity_Sampler';
GO

WAITFOR DELAY '00:00:10';
GO

USE msdb;
GO
DECLARE @i int=1,@WorkerJob sysname,@WorkerCommand nvarchar(max);
WHILE @i<=6
BEGIN
    SET @WorkerJob=CONCAT(N'RCA_Run13_Connectivity_Worker_',RIGHT('00'+CONVERT(varchar(2),@i),2));
    SET @WorkerCommand=N'USE RCA; EXEC dbo.usp_RCA_Run13_NetworkWorker @DurationSeconds=90,@RowsPerCycle=20000;';

    EXEC dbo.sp_add_job @job_name=@WorkerJob,@enabled=1,@description=N'Run 13B result-producing worker';
    EXEC dbo.sp_add_jobstep @job_name=@WorkerJob,@step_name=N'Generate result traffic',@subsystem=N'TSQL',@database_name=N'RCA',@command=@WorkerCommand,@on_success_action=1,@on_fail_action=2;
    EXEC dbo.sp_add_jobserver @job_name=@WorkerJob;
    EXEC dbo.sp_start_job @job_name=@WorkerJob;

    SET @i+=1;
END;
SELECT CreatedWorkerJobs=6,Run13B='STARTED';
GO

WAITFOR DELAY '00:02:10';
GO

USE msdb;
GO
DECLARE @CurrentAgentSessionID int=(SELECT MAX(session_id) FROM dbo.syssessions);
SELECT
      j.name
    , a.start_execution_date
    , a.stop_execution_date
    , JobState=CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'RUNNING'
                    WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NOT NULL THEN 'COMPLETED'
                    ELSE 'NOT STARTED' END
    , LastRunStatus=(SELECT TOP (1) CASE h.run_status WHEN 0 THEN 'FAILED' WHEN 1 THEN 'SUCCEEDED' WHEN 2 THEN 'RETRY' WHEN 3 THEN 'CANCELED' WHEN 4 THEN 'IN PROGRESS' ELSE 'UNKNOWN' END
                     FROM dbo.sysjobhistory AS h WHERE h.job_id=j.job_id AND h.step_id=0 ORDER BY h.instance_id DESC)
FROM dbo.sysjobs AS j
LEFT JOIN dbo.sysjobactivity AS a ON a.job_id=j.job_id AND a.session_id=@CurrentAgentSessionID
WHERE j.name LIKE N'RCA_Run13_Connectivity_%'
ORDER BY j.name;
GO

USE DBA;
GO
DECLARE @Run13B bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13B - live connectivity pressure attempt');
EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@Run13B;
EXEC dbo.usp_RCA_BuildConnectivityEvidence @CaptureRunID=@Run13B;
GO

DECLARE @Run13B bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13B - live connectivity pressure attempt');
SELECT
      CaptureRunID
    , COUNT(*) AS ConnectivitySamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MIN(ActiveConnectionCount) AS MinActiveConnections
    , AVG(CONVERT(decimal(19,2),ActiveConnectionCount)) AS AvgActiveConnections
    , MAX(ActiveConnectionCount) AS PeakActiveConnections
    , MAX(ActiveRequestCount) AS PeakActiveRequests
    , MAX(AsyncNetworkIOWaiterCount) AS PeakAsyncNetworkIOWaiters
    , MAX(MaxAsyncNetworkIOWaitMs) AS MaxAsyncNetworkIOWaitMs
FROM dbo.RCA_ConnectivitySnapshot
WHERE CaptureRunID=@Run13B
GROUP BY CaptureRunID;

SELECT * FROM dbo.RCA_ConnectivityEvidence WHERE CaptureRunID=@Run13B;

SELECT
      Run13B_LiveCollection=CASE WHEN (SELECT COUNT(*) FROM dbo.RCA_ConnectivitySnapshot WHERE CaptureRunID=@Run13B)>=20 THEN 'PASS' ELSE 'REVIEW' END
    , LiveClassification=(SELECT TOP (1) PressureSubtype FROM dbo.RCA_ConnectivityEvidence WHERE CaptureRunID=@Run13B ORDER BY ConnectivityEvidenceID DESC)
    , Interpretation=CASE WHEN EXISTS (SELECT 1 FROM dbo.RCA_ConnectivityEvidence WHERE CaptureRunID=@Run13B AND PressureSubtype<>'CONNECTIVITY_ACTIVITY_ONLY')
                          THEN 'LIVE CLIENT / NETWORK PRESSURE DETECTED'
                          ELSE 'LIVE COLLECTION PASSED; LAB DID NOT SUSTAIN CONNECTIVITY-PRESSURE THRESHOLDS' END;

EXEC dbo.usp_RCA_WhyWasItSlow @CaptureRunID=@Run13B;
GO

/*==============================================================================
    RUN 13C - DETERMINISTIC POSITIVE CONTROL

    6 samples / 25 seconds
      Connections: 20 -> 90
      Logins:      1000 -> 4000 = 120/sec
      Logouts:      500 -> 2500 = 80/sec
      ASYNC_NETWORK_IO present in every sample
      Max observed ASYNC_NETWORK_IO wait = 7000 ms

    Expected:
        CONNECTIVITY_PRESSURE_MIXED
        PRIMARY
        HIGH
==============================================================================*/
USE DBA;
GO

DECLARE @Run13C bigint;
EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 13C - deterministic connectivity pressure validation',
     @CaptureRunID=@Run13C OUTPUT;
SELECT CaptureRunID=@Run13C,Run13CStatus='STARTED';
GO

DECLARE @Run13C bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation');
DELETE FROM dbo.RCA_ConnectivitySnapshot WHERE CaptureRunID=@Run13C;
DECLARE @BaseTime datetime2(3)='2026-08-15T14:00:00.000';

INSERT dbo.RCA_ConnectivitySnapshot
(
      CaptureRunID,CaptureTimeUTC,ActiveConnectionCount,ActiveRequestCount
    , UserConnectionsCounter,LoginCounterRaw,LogoutCounterRaw
    , AsyncNetworkIOWaiterCount,MaxAsyncNetworkIOWaitMs
)
VALUES
(@Run13C,DATEADD(second, 0,@BaseTime),20, 5,20,1000, 500,3,2000),
(@Run13C,DATEADD(second, 5,@BaseTime),35, 8,35,1600, 900,4,3000),
(@Run13C,DATEADD(second,10,@BaseTime),55,12,55,2200,1300,5,4000),
(@Run13C,DATEADD(second,15,@BaseTime),70,15,70,2800,1700,6,5000),
(@Run13C,DATEADD(second,20,@BaseTime),85,18,85,3400,2100,7,6000),
(@Run13C,DATEADD(second,25,@BaseTime),90,20,90,4000,2500,7,7000);

SELECT
      CaptureRunID
    , COUNT(*) AS DeterministicSamples
    , MIN(CaptureTimeUTC) AS FirstSampleUTC
    , MAX(CaptureTimeUTC) AS LastSampleUTC
    , MIN(ActiveConnectionCount) AS MinActiveConnections
    , MAX(ActiveConnectionCount) AS PeakActiveConnections
    , MAX(AsyncNetworkIOWaiterCount) AS PeakAsyncNetworkIOWaiters
    , MAX(MaxAsyncNetworkIOWaitMs) AS MaxAsyncNetworkIOWaitMs
    , MIN(LoginCounterRaw) AS FirstLoginCounter
    , MAX(LoginCounterRaw) AS LastLoginCounter
FROM dbo.RCA_ConnectivitySnapshot
WHERE CaptureRunID=@Run13C
GROUP BY CaptureRunID;
GO

DECLARE @Run13C bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation');
EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@Run13C;
EXEC dbo.usp_RCA_BuildConnectivityEvidence @CaptureRunID=@Run13C;
GO

DECLARE @Run13C bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation');
SELECT * FROM dbo.RCA_ConnectivityEvidence WHERE CaptureRunID=@Run13C;
GO

DECLARE @Run13C bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation');
SELECT
      CaptureRunID,CauseCategory,CauseDisplayName,RootCauseRole,Confidence
    , CorrelationKey,ImpactedRequestCount,EvidenceCount,PrimaryEvidence,RecommendedAction
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID=@Run13C
ORDER BY RoleRank,ConfidenceRank,ImpactRank,EvidenceStrengthRank;
GO

DECLARE @Run13C bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation');
SELECT
      Run13C_ConnectivityPositive=
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_ConnectivityEvidence
                WHERE CaptureRunID=@Run13C
                  AND PressureSubtype='CONNECTIVITY_PRESSURE_MIXED'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
                  AND AsyncNetworkPressure=1
                  AND ConnectionSurge=1
                  AND LoginChurnPressure=1
            )
            AND EXISTS
            (
                SELECT 1
                FROM dbo.vw_RCA_FinalCauseRanking
                WHERE CaptureRunID=@Run13C
                  AND CauseCategory='CLIENT_CONNECTION_NETWORK_PRESSURE'
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
            )
            THEN 'PASS' ELSE 'FAIL'
        END
    , ExpectedCause='CLIENT_CONNECTION_NETWORK_PRESSURE'
    , ExpectedSubtype='CONNECTIVITY_PRESSURE_MIXED'
    , ExpectedRole='PRIMARY'
    , ExpectedConfidence='HIGH';
GO

DECLARE @Run13C bigint=(SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation');
EXEC dbo.usp_RCA_WhyWasItSlow @CaptureRunID=@Run13C;
GO

/*==============================================================================
    STEP 3 - CLEAN UP RUN 13 SQL AGENT JOBS
==============================================================================*/
USE msdb;
GO
DECLARE @JobName sysname,@CurrentAgentSessionID int;
SELECT @CurrentAgentSessionID=MAX(session_id) FROM dbo.syssessions;
DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM dbo.sysjobs WHERE name LIKE N'RCA_Run13_Connectivity_%';
OPEN JobCleanup;
FETCH NEXT FROM JobCleanup INTO @JobName;
WHILE @@FETCH_STATUS=0
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM dbo.sysjobs AS j
        JOIN dbo.sysjobactivity AS a ON a.job_id=j.job_id AND a.session_id=@CurrentAgentSessionID
        WHERE j.name=@JobName AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL
    )
    BEGIN
        EXEC dbo.sp_stop_job @job_name=@JobName;
        WAITFOR DELAY '00:00:02';
    END;

    IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=@JobName)
        EXEC dbo.sp_delete_job @job_name=@JobName,@delete_unused_schedule=1;

    FETCH NEXT FROM JobCleanup INTO @JobName;
END;
CLOSE JobCleanup;
DEALLOCATE JobCleanup;

SELECT Run13JobsRemaining=COUNT(*) FROM dbo.sysjobs WHERE name LIKE N'RCA_Run13_Connectivity_%';
GO

/*==============================================================================
    STEP 4 - FINAL REGRESSION MATRIX
==============================================================================*/
USE DBA;
GO

;WITH TestRuns AS
(
    SELECT CONVERT(bigint,3) AS CaptureRunID,CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE') AS ExpectedCause
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 16, 'CPU_SCHEDULER_PRESSURE'
    UNION ALL SELECT 20, 'IO_STORAGE_PRESSURE'
    UNION ALL SELECT 26, 'TEMPDB_PRESSURE_CONTENTION'
    UNION ALL SELECT 29, 'INSTANCE_MEMORY_PRESSURE'
    UNION ALL SELECT 32, 'TRANSACTION_LOG_PRESSURE'
    UNION ALL
    SELECT
          (SELECT MAX(CaptureRunID) FROM dbo.RCA_CaptureRun WHERE CaptureReason=N'Run 13C - deterministic connectivity pressure validation')
        , 'CLIENT_CONNECTION_NETWORK_PRESSURE'
),
Ranked AS
(
    SELECT
          t.CaptureRunID,t.ExpectedCause,r.CauseCategory,r.CauseDisplayName,r.RootCauseRole,r.Confidence
        , rn=ROW_NUMBER() OVER
          (
              PARTITION BY t.CaptureRunID
              ORDER BY r.RoleRank,r.ConfidenceRank,r.ImpactRank,r.EvidenceStrengthRank
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
    , ValidationResult=CASE WHEN CauseCategory=ExpectedCause THEN 'PASS' ELSE 'REVIEW' END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO

/*==============================================================================
    FINAL EXPECTATIONS

    RUN 13A
        CONNECTIVITY_ACTIVITY_ONLY
        no PRIMARY connectivity root cause

    RUN 13B
        live collection must work
        live positive diagnosis optional

    RUN 13C
        CLIENT_CONNECTION_NETWORK_PRESSURE
        CONNECTIVITY_PRESSURE_MIXED
        PRIMARY
        HIGH
        PASS

    Human output must expose:
        MinActiveConnections
        AvgActiveConnections
        PeakActiveConnections
        PeakActiveRequests
        DeltaLogins / LoginRatePerSecond
        DeltaLogouts / LogoutRatePerSecond
        PeakAsyncNetworkIOWaiters
        AsyncNetworkPressureSampleCount
        MaxAsyncNetworkIOWaitMs

    Existing validated domains must remain unchanged.
==============================================================================*/
