USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  45_RCA_Capture39_End_to_End_Validation.sql

  PURPOSE
  -------
  First FRESH end-to-end validation after the Capture 38 detector and UX work.

  This script deliberately creates a KNOWN blocking incident, but it does NOT
  insert, update, or force any RCA conclusion.  The installed RCA pipeline must
  independently discover the evidence and decide whether blocking is causal.

  END-TO-END PATH UNDER TEST
  --------------------------
      Incident context
        -> core XE capture
        -> live sampler
        -> controlled blocking workload
        -> stop/import
        -> parser/analyzer
        -> blocking detector
        -> final cause ranking
        -> Script 44 final incident report

  EXPECTED RESULT
  ---------------
  For a clean lab run:
      CaptureRunID                 = 39
      Blocking evidence            = present
      BlockingDepth                >= 1
      WaitType                     LIKE LCK_M_%
      SampleCount                  >= 3
      Blocking PRIMARY             = expected
      Blocking confidence          = HIGH expected
      Final RCA verdict            = ROOT CAUSE IDENTIFIED expected

  IMPORTANT
  ---------
  * This is a CONTROLLED LAB validation. Do not run the workload section on a
    production server.
  * No detector thresholds are changed.
  * No root-cause rows are manually manufactured.
  * No evidence tables are manually edited.
  * The test workload is isolated in database RCA.
  * SQL Server Agent is used only to create concurrency for the test.
  * Test Agent jobs are deleted at the end.
  * The test row is rolled back by the blocker, so no business-data mutation
    survives the blocking transaction.

  NORMAL FINAL REPORT
  -------------------
      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 39;

  TECHNICAL DRILL-DOWN
  --------------------
      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;
==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max) = N'';

IF DB_ID(N'RCA') IS NULL
    SET @Missing += N' Database [RCA];';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    SET @Missing += N' dbo.RCA_CaptureRun;';

IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NULL
    SET @Missing += N' dbo.RCA_IncidentContext;';

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockingEvidence;';

IF OBJECT_ID(N'dbo.usp_RCA_Start',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_Start;';

IF OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_Stop;';

IF OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_RunSampler;';

IF OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_BuildBlockingEvidence;';

IF OBJECT_ID(N'dbo.usp_RCA_FinalIncidentReport',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_FinalIncidentReport;';

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    SET @Missing += N' dbo.vw_RCA_FinalCauseRanking;';

IF NULLIF(@Missing,N'') IS NOT NULL
    THROW 54500, CONCAT(N'Script 45 prerequisites are missing:',@Missing), 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_server_services
    WHERE servicename LIKE N'SQL Server Agent%'
      AND status_desc = N'Running'
)
    THROW 54501,
          N'SQL Server Agent must be running for the automated concurrency test.',
          1;

SELECT
      ValidationSection = '0 - SCRIPT 45 PRE-FLIGHT'
    , CoreCapture = 'PASS'
    , EndUserStart = 'PASS'
    , EndUserStopAnalyze = 'PASS'
    , BlockingDetector = 'PASS'
    , FinalCauseRanking = 'PASS'
    , FinalIncidentReport = 'PASS'
    , SQLServerAgent = 'PASS'
    , SourceEvidenceModified = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicPromoted = 'NO';
GO


/*==============================================================================
  1. CREATE ISOLATED CAPTURE 39 TEST FIXTURE
==============================================================================*/
USE RCA;
GO

IF OBJECT_ID(N'dbo.RCA_Capture39_Blocking',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_Capture39_Blocking
    (
          BlockingID int NOT NULL
              CONSTRAINT PK_RCA_Capture39_Blocking PRIMARY KEY
        , StatusCode int NOT NULL
        , Amount decimal(19,4) NOT NULL
        , Payload char(200) NOT NULL
    );
END;
GO

DELETE FROM dbo.RCA_Capture39_Blocking;

INSERT dbo.RCA_Capture39_Blocking
(
      BlockingID
    , StatusCode
    , Amount
    , Payload
)
VALUES
(
      1
    , 0
    , 100.00
    , REPLICATE('C',200)
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture39_Blocker
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Capture39_Blocking
       SET StatusCode = StatusCode + 39
     WHERE BlockingID = 1;

    /*
      Hold an incompatible X lock long enough for repeated sampler observations.
      ROLLBACK ensures the blocker leaves the fixture in its original state.
    */
    WAITFOR DELAY '00:00:45';

    ROLLBACK;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture39_Victim
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
      This statement should wait on the X lock held by the blocker.
      Once the blocker rolls back, this update completes.
    */
    UPDATE dbo.RCA_Capture39_Blocking
       SET Amount = Amount + 1.00
     WHERE BlockingID = 1;

    SELECT
          Role = 'CAPTURE39_VICTIM_COMPLETED'
        , SessionID = @@SPID
        , BlockingID
        , StatusCode
        , Amount
    FROM dbo.RCA_Capture39_Blocking
    WHERE BlockingID = 1;
END;
GO

SELECT
      ValidationSection = '1 - CAPTURE 39 FIXTURE'
    , TestTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Capture39_Blocking',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockerProcedure =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Capture39_Blocker',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , VictimProcedure =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Capture39_Victim',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExpectedCause = 'BLOCKING_WAIT_CHAIN'
    , ExpectedConfidence = 'HIGH';
GO


/*==============================================================================
  2. START THE FRESH INCIDENT

  IMPORTANT:
  Script 44 designated Capture 39 as the first fresh end-to-end validation.
  This script therefore refuses to continue if the newly allocated ID is not 39.
==============================================================================*/
USE DBA;
GO

DECLARE @BeforeMax bigint =
(
    SELECT ISNULL(MAX(CaptureRunID),0)
    FROM dbo.RCA_CaptureRun
);

IF @BeforeMax >= 39
AND NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = 39
      AND CaptureReason LIKE N'End-user RCA%Capture 39%'
)
BEGIN
    THROW 54510,
          N'CaptureRunID 39 has already been consumed by another run. Script 45 will not overwrite or relabel historical evidence.',
          1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = 39
      AND CaptureReason LIKE N'End-user RCA%Capture 39%'
)
BEGIN
    EXEC dbo.usp_RCA_Start
         @DatabaseName = N'RCA',
         @IncidentDescription =
             N'Capture 39 - fresh end-to-end validation - controlled blocking incident';
END;

DECLARE @CaptureRunID bigint =
(
    SELECT MAX(CaptureRunID)
    FROM dbo.RCA_CaptureRun
    WHERE CaptureReason LIKE N'End-user RCA%Capture 39%'
);

IF @CaptureRunID IS NULL
    THROW 54511,N'Capture 39 could not be located after start.',1;

IF @CaptureRunID <> 39
    THROW 54512,N'The fresh validation did not receive CaptureRunID 39. Stop and review capture history.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = @CaptureRunID
      AND CaptureStatus = 'RUNNING'
)
    THROW 54513,N'Capture 39 is not in RUNNING state.',1;

SELECT
      ValidationSection = '2 - CAPTURE 39 STARTED'
    , CaptureRunID = @CaptureRunID
    , CaptureStatus =
        (SELECT CaptureStatus
         FROM dbo.RCA_CaptureRun
         WHERE CaptureRunID = @CaptureRunID)
    , RequestedDatabase =
        (SELECT RequestedDatabaseName
         FROM dbo.RCA_IncidentContext
         WHERE CaptureRunID = @CaptureRunID)
    , TestScenario = 'CONTROLLED BLOCKING / WAIT CHAIN'
    , ExpectedRootCause = 'BLOCKING_WAIT_CHAIN'
    , ExpectedVerdict = 'ROOT CAUSE IDENTIFIED';
GO


/*==============================================================================
  3. CREATE THREE TEMPORARY SQL AGENT JOBS

  Job A: sampler for 75 seconds
  Job B: head blocker holding an X lock for 45 seconds
  Job C: victim that waits behind Job B

  The jobs create real concurrent sessions.  The RCA engine is not told which
  session is the root cause.
==============================================================================*/
USE msdb;
GO

DECLARE @CaptureRunID bigint = 39;
DECLARE @SamplerJob sysname = N'RCA_C39_Sampler';
DECLARE @BlockerJob sysname = N'RCA_C39_Blocker';
DECLARE @VictimJob  sysname = N'RCA_C39_Victim';

-- Remove leftovers from a previously interrupted Script 45 attempt.
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@SamplerJob)
    EXEC msdb.dbo.sp_delete_job @job_name=@SamplerJob, @delete_unused_schedule=1;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@BlockerJob)
    EXEC msdb.dbo.sp_delete_job @job_name=@BlockerJob, @delete_unused_schedule=1;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@VictimJob)
    EXEC msdb.dbo.sp_delete_job @job_name=@VictimJob, @delete_unused_schedule=1;

DECLARE @SamplerCommand nvarchar(max) =
    N'USE DBA;
      EXEC dbo.usp_RCA_RunSampler
           @CaptureRunID = 39,
           @DurationMinutes = 2,
           @SampleSeconds = 5;';

DECLARE @BlockerCommand nvarchar(max) =
    N'USE RCA;
      EXEC dbo.usp_RCA_Capture39_Blocker;';

DECLARE @VictimCommand nvarchar(max) =
    N'USE RCA;
      EXEC dbo.usp_RCA_Capture39_Victim;';

EXEC msdb.dbo.sp_add_job
     @job_name=@SamplerJob,
     @enabled=1,
     @description=N'Script 45 Capture 39 live RCA sampler';

EXEC msdb.dbo.sp_add_jobstep
     @job_name=@SamplerJob,
     @step_name=N'Capture live RCA snapshots',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand,
     @on_success_action=1,
     @on_fail_action=2;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=@SamplerJob;

EXEC msdb.dbo.sp_add_job
     @job_name=@BlockerJob,
     @enabled=1,
     @description=N'Script 45 controlled head blocker';

EXEC msdb.dbo.sp_add_jobstep
     @job_name=@BlockerJob,
     @step_name=N'Hold X lock for 45 seconds',
     @subsystem=N'TSQL',
     @database_name=N'RCA',
     @command=@BlockerCommand,
     @on_success_action=1,
     @on_fail_action=2;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=@BlockerJob;

EXEC msdb.dbo.sp_add_job
     @job_name=@VictimJob,
     @enabled=1,
     @description=N'Script 45 controlled blocked victim';

EXEC msdb.dbo.sp_add_jobstep
     @job_name=@VictimJob,
     @step_name=N'Wait behind Capture 39 blocker',
     @subsystem=N'TSQL',
     @database_name=N'RCA',
     @command=@VictimCommand,
     @on_success_action=1,
     @on_fail_action=2;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=@VictimJob;

SELECT
      ValidationSection = '3 - CONCURRENCY JOBS CREATED'
    , CaptureRunID = @CaptureRunID
    , SamplerJob =
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@SamplerJob)
             THEN 'PASS' ELSE 'FAIL' END
    , BlockerJob =
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@BlockerJob)
             THEN 'PASS' ELSE 'FAIL' END
    , VictimJob =
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@VictimJob)
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
  4. EXECUTE THE CONTROLLED INCIDENT

  Timeline:
      T+00  sampler starts
      T+05  blocker starts
      T+10  victim starts
      T+55  blocker rolls back; victim can complete
      T+70  capture is stopped/analyzed

  The WAITFORs below only coordinate the lab test.
==============================================================================*/
USE msdb;
GO

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C39_Sampler';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C39_Blocker';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C39_Victim';

-- Let the blocking relationship exist long enough for multiple 5-second samples.
WAITFOR DELAY '00:00:15';
GO


/*==============================================================================
  5. MID-INCIDENT PROOF

  Read-only proof that Capture 39 really generated blocking while capture is
  still active.  This does NOT feed or modify RCA conclusions.
==============================================================================*/
USE master;
GO

SELECT
      ValidationSection = '4 - LIVE BLOCKING PROOF'
    , r.session_id
    , r.status
    , r.command
    , r.wait_type
    , r.wait_time
    , r.blocking_session_id
    , DatabaseName = DB_NAME(r.database_id)
    , s.host_name
    , s.program_name
    , s.login_name
    , RunningBatch = txt.text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt
WHERE
       r.blocking_session_id > 0
    OR r.session_id IN
       (
           SELECT blocking_session_id
           FROM sys.dm_exec_requests
           WHERE blocking_session_id > 0
       )
ORDER BY
      CASE WHEN r.blocking_session_id = 0 THEN 1 ELSE 2 END
    , r.session_id;
GO

-- Allow the 45-second blocker to finish and allow several post-event samples.
WAITFOR DELAY '00:00:40';
GO


/*==============================================================================
  6. STOP + IMPORT + ANALYZE THROUGH THE END-USER WORKFLOW

  dbo.usp_RCA_Stop is intentionally used instead of manually calling each
  internal stage.  This validates the user-facing orchestration itself.
==============================================================================*/
USE DBA;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = 39
      AND CaptureStatus = 'RUNNING'
)
BEGIN
    EXEC dbo.usp_RCA_Stop
         @CaptureRunID = 39;
END;
ELSE
BEGIN
    SELECT
          ValidationSection = '5 - STOP / ANALYZE'
        , CaptureRunID = 39
        , Message = 'Capture 39 was already stopped; existing evidence will be validated.';
END;
GO


/*==============================================================================
  7. ENSURE BLOCKING DOMAIN IS BUILT AGAINST FINAL PERSISTED SNAPSHOTS

  The end-user Stop workflow already invokes this detector when installed.
  Re-running the builder is deterministic for the same persisted evidence and
  avoids relying on job timing.  No thresholds are changed.
==============================================================================*/
USE DBA;
GO

EXEC dbo.usp_RCA_BuildBlockingEvidence
     @CaptureRunID = 39;
GO


/*==============================================================================
  8. RAW END-TO-END EVIDENCE COUNTS
==============================================================================*/
DECLARE @CaptureRunID bigint = 39;

SELECT
      ValidationSection = '6 - END-TO-END EVIDENCE COUNTS'
    , CaptureRunID = @CaptureRunID
    , CaptureStatus =
        (SELECT CaptureStatus
         FROM dbo.RCA_CaptureRun
         WHERE CaptureRunID=@CaptureRunID)
    , ServerSnapshots =
        (SELECT COUNT(*)
         FROM dbo.RCA_ServerSnapshot
         WHERE CaptureRunID=@CaptureRunID)
    , ExecutionEvidenceRows =
        (SELECT COUNT(*)
         FROM dbo.RCA_ExecutionEvidence
         WHERE CaptureRunID=@CaptureRunID)
    , ActualPlanRows =
        CASE WHEN OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL THEN 0
             ELSE
             (
                 SELECT COUNT(*)
                 FROM dbo.RCA_PlanEvidence
                 WHERE CaptureRunID=@CaptureRunID
                   AND ActualExecutionPlanXML IS NOT NULL
             )
        END
    , PlanOperatorRows =
        CASE WHEN OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL THEN 0
             ELSE
             (
                 SELECT COUNT(*)
                 FROM dbo.RCA_PlanOperator
                 WHERE CaptureRunID=@CaptureRunID
             )
        END
    , BlockingEvidenceRows =
        (SELECT COUNT(*)
         FROM dbo.RCA_BlockingEvidence
         WHERE CaptureRunID=@CaptureRunID);
GO


/*==============================================================================
  9. BLOCKING EVIDENCE - WHAT THE DETECTOR ACTUALLY FOUND
==============================================================================*/
SELECT
      ValidationSection = '7 - BLOCKING EVIDENCE'
    , *
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = 39
ORDER BY
      CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 2 END
    , CASE WHEN Confidence='HIGH' THEN 1 WHEN Confidence='MEDIUM' THEN 2 ELSE 3 END
    , WaitDurationMs DESC
    , BlockingEvidenceID;
GO


/*==============================================================================
  10. FINAL CAUSE RANKING - NO MANUAL PROMOTION
==============================================================================*/
SELECT
      ValidationSection = '8 - FINAL CAUSE RANKING'
    , *
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID = 39
ORDER BY
      CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 2 END
    , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
    , EvidenceCount DESC
    , ImpactedRequestCount DESC;
GO


/*==============================================================================
  11. CAPTURE 39 ACCEPTANCE GATE

  This gate asks four separate questions:
    A. Did we observe blocking?
    B. Was it material/repeated?
    C. Did the blocking detector classify a PRIMARY HIGH-confidence case?
    D. Did the FINAL cause ranking expose that supported primary cause?

  We do NOT weaken the gate if the run fails.  A failure means inspect evidence.
==============================================================================*/
DECLARE
      @CaptureRunID bigint = 39
    , @BlockingRows int
    , @PrimaryHighBlocking int
    , @MaxBlockingDepth int
    , @MaxSampleCount int
    , @MaxWaitMs bigint
    , @LockWaitRows int
    , @FinalPrimaryBlocking int
    , @FinalAnyPrimary int;

SELECT
      @BlockingRows = COUNT(*)
    , @PrimaryHighBlocking =
        SUM(CASE WHEN RootCauseRole='PRIMARY' AND Confidence='HIGH' THEN 1 ELSE 0 END)
    , @MaxBlockingDepth = MAX(BlockingDepth)
    , @MaxSampleCount = MAX(SampleCount)
    , @MaxWaitMs = MAX(WaitDurationMs)
    , @LockWaitRows =
        SUM(CASE WHEN WaitType LIKE 'LCK_M_%' THEN 1 ELSE 0 END)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT
      @FinalPrimaryBlocking =
        SUM
        (
            CASE
              WHEN RootCauseRole='PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
               AND CauseCategory='BLOCKING_WAIT_CHAIN'
              THEN 1 ELSE 0
            END
        )
    , @FinalAnyPrimary =
        SUM
        (
            CASE
              WHEN RootCauseRole='PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
              THEN 1 ELSE 0
            END
        )
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID=@CaptureRunID;

SET @BlockingRows = ISNULL(@BlockingRows,0);
SET @PrimaryHighBlocking = ISNULL(@PrimaryHighBlocking,0);
SET @MaxBlockingDepth = ISNULL(@MaxBlockingDepth,0);
SET @MaxSampleCount = ISNULL(@MaxSampleCount,0);
SET @MaxWaitMs = ISNULL(@MaxWaitMs,0);
SET @LockWaitRows = ISNULL(@LockWaitRows,0);
SET @FinalPrimaryBlocking = ISNULL(@FinalPrimaryBlocking,0);
SET @FinalAnyPrimary = ISNULL(@FinalAnyPrimary,0);

SELECT
      ValidationSection = '9 - CAPTURE 39 ACCEPTANCE'
    , CaptureRunID = @CaptureRunID
    , BlockingObserved =
        CASE WHEN @BlockingRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , LockWaitObserved =
        CASE WHEN @LockWaitRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , RepeatedSampling =
        CASE WHEN @MaxSampleCount >= 3 THEN 'PASS' ELSE 'FAIL' END
    , BlockingDepth =
        CASE WHEN @MaxBlockingDepth >= 1 THEN 'PASS' ELSE 'FAIL' END
    , PrimaryHighBlocking =
        CASE WHEN @PrimaryHighBlocking > 0 THEN 'PASS' ELSE 'FAIL' END
    , FinalRankingPrimaryBlocking =
        CASE WHEN @FinalPrimaryBlocking > 0 THEN 'PASS' ELSE 'FAIL' END
    , MaxBlockingDepth = @MaxBlockingDepth
    , MaxSampleCount = @MaxSampleCount
    , MaxObservedWaitMs = @MaxWaitMs
    , FinalPrimaryCauseCount = @FinalAnyPrimary
    , OverallResult =
        CASE
          WHEN @BlockingRows > 0
           AND @LockWaitRows > 0
           AND @MaxSampleCount >= 3
           AND @MaxBlockingDepth >= 1
           AND @PrimaryHighBlocking > 0
           AND @FinalPrimaryBlocking > 0
          THEN 'PASS - FRESH END-TO-END ROOT CAUSE IDENTIFICATION'
          ELSE 'REVIEW - DO NOT CHANGE THRESHOLDS; INSPECT THE FAILED EVIDENCE STAGE'
        END;
GO


/*==============================================================================
  12. FINAL USER EXPERIENCE

  This is the same Script 44 presentation procedure a DBA would normally run.
  We expect the verdict to be driven entirely by persisted Capture 39 evidence.
==============================================================================*/
EXEC dbo.usp_RCA_FinalIncidentReport
     @CaptureRunID = 39,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  13. CLEAN UP TEMPORARY SQL AGENT JOBS

  Evidence and the isolated RCA fixture remain for review.
==============================================================================*/
USE msdb;
GO

DECLARE @SamplerJob sysname = N'RCA_C39_Sampler';
DECLARE @BlockerJob sysname = N'RCA_C39_Blocker';
DECLARE @VictimJob  sysname = N'RCA_C39_Victim';

-- Only delete jobs after they are no longer executing.
IF EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobs j
    WHERE j.name=@SamplerJob
      AND NOT EXISTS
      (
          SELECT 1
          FROM msdb.dbo.sysjobactivity a
          WHERE a.job_id=j.job_id
            AND a.start_execution_date IS NOT NULL
            AND a.stop_execution_date IS NULL
            AND a.session_id =
                (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
      )
)
    EXEC msdb.dbo.sp_delete_job
         @job_name=@SamplerJob,
         @delete_unused_schedule=1;

IF EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobs j
    WHERE j.name=@BlockerJob
      AND NOT EXISTS
      (
          SELECT 1
          FROM msdb.dbo.sysjobactivity a
          WHERE a.job_id=j.job_id
            AND a.start_execution_date IS NOT NULL
            AND a.stop_execution_date IS NULL
            AND a.session_id =
                (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
      )
)
    EXEC msdb.dbo.sp_delete_job
         @job_name=@BlockerJob,
         @delete_unused_schedule=1;

IF EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobs j
    WHERE j.name=@VictimJob
      AND NOT EXISTS
      (
          SELECT 1
          FROM msdb.dbo.sysjobactivity a
          WHERE a.job_id=j.job_id
            AND a.start_execution_date IS NOT NULL
            AND a.stop_execution_date IS NULL
            AND a.session_id =
                (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
      )
)
    EXEC msdb.dbo.sp_delete_job
         @job_name=@VictimJob,
         @delete_unused_schedule=1;
GO

USE DBA;
GO

SELECT
      ValidationSection = '10 - SCRIPT 45 SAFETY'
    , CaptureRunID = 39
    , FreshCaptureStarted = 'YES'
    , ControlledIncidentGenerated = 'YES'
    , SourceXEDefinitionChanged = 'NO'
    , ExistingEvidenceModified = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicPromoted = 'NO'
    , ManualCauseInserted = 'NO'
    , Script44PresentationChanged = 'NO'
    , NextStep =
        'Review Section 9 and the final incident report. If OverallResult is PASS, Capture 39 proves the first fresh end-to-end causal RCA workflow. If REVIEW, inspect the failed evidence stage without changing thresholds.';
GO


/*==============================================================================
  OPTIONAL TECHNICAL DRILL-DOWN
  -----------------------------
  Run only after reviewing the default final report:

      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;

  OPTIONAL FIXTURE CLEANUP AFTER ALL REVIEW IS COMPLETE
  -----------------------------------------------------
      USE RCA;
      DROP PROCEDURE IF EXISTS dbo.usp_RCA_Capture39_Blocker;
      DROP PROCEDURE IF EXISTS dbo.usp_RCA_Capture39_Victim;
      DROP TABLE IF EXISTS dbo.RCA_Capture39_Blocking;

  Do NOT delete Capture 39 evidence.  It is the first fresh post-hardening
  end-to-end validation artifact.
==============================================================================*/
