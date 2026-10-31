USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  53_RCA_Capture40_Transaction_Validation_v2.sql

  PURPOSE
  -------
  Corrected Capture 40 end-to-end validation.

  Fixes v1 dynamic SQL Agent job-step command construction and adds strict
  abort guards so a failed capture start cannot cascade into misleading
  "CaptureRunID does not exist" errors.

  This script:
      1. Validates prerequisites.
      2. Creates/reset controlled blocking test objects in database RCA.
      3. Starts a fresh RCA capture.
      4. Creates SQL Agent jobs using prebuilt command strings.
      5. Starts sampler -> blocker -> victim in sequence.
      6. Waits for the blocking scenario to complete.
      7. Stops/analyzes the capture.
      8. Validates persisted blocker transaction evidence.
      9. Prints the human-readable RCA answer.

  It does NOT:
      - change detector thresholds
      - change root-cause domains
      - change root-cause ranking logic
      - modify Capture 38 or 39
==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max)=N'';
DECLARE @msg nvarchar(2048);

IF DB_ID(N'RCA') IS NULL
    SET @Missing += N' database RCA;';

IF OBJECT_ID(N'dbo.usp_RCA_Start',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_Start;';

IF OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_Stop;';

IF OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_RunSampler;';

IF OBJECT_ID(N'dbo.usp_RCA_CaptureBlockerTransactionEvidence',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_CaptureBlockerTransactionEvidence;';

IF OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockerTransactionEvidence;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @msg=CONCAT(N'Script 53 v2 prerequisites are missing:',@Missing);
    THROW 55300,@msg,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 53 v2 PRE-FLIGHT'
    , StartProcedure='PASS'
    , StopProcedure='PASS'
    , Sampler='PASS'
    , TransactionCollector='PASS'
    , TransactionEvidenceTable='PASS'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO';
GO


/*==============================================================================
  1. CREATE / RESET CONTROLLED TEST FIXTURE
==============================================================================*/
USE RCA;
GO

IF OBJECT_ID(N'dbo.RCA_Capture40_Blocking',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_Capture40_Blocking
    (
          BlockingID int NOT NULL
              CONSTRAINT PK_RCA_Capture40_Blocking PRIMARY KEY
        , Amount decimal(19,2) NOT NULL
        , Payload char(200) NULL
    );
END;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_Capture40_Blocking
    WHERE BlockingID = 1
)
BEGIN
    UPDATE dbo.RCA_Capture40_Blocking
       SET Amount = 100.00,
           Payload = REPLICATE('X',200)
     WHERE BlockingID = 1;
END
ELSE
BEGIN
    INSERT dbo.RCA_Capture40_Blocking
    (
          BlockingID
        , Amount
        , Payload
    )
    VALUES
    (
          1
        , 100.00
        , REPLICATE('X',200)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture40_Blocker
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Capture40_Blocking
       SET Amount = Amount + 1.00
     WHERE BlockingID = 1;

    WAITFOR DELAY '00:00:45';

    COMMIT TRAN;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture40_Victim
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.RCA_Capture40_Blocking
       SET Amount = Amount + 5.00
     WHERE BlockingID = 1;
END;
GO


/*==============================================================================
  2. START FRESH CAPTURE AND RESOLVE ITS ID
==============================================================================*/
USE DBA;
GO

DECLARE @CaptureRunID bigint;

EXEC dbo.usp_RCA_Start
     @DatabaseName = N'RCA',
     @IncidentDescription =
         N'Capture 40 - transaction evidence validation - controlled blocking';

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE CaptureStatus = N'RUNNING'
  AND TargetDatabase = N'RCA'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
BEGIN
    THROW 55310,
          N'Capture 40 start failed: no RUNNING capture could be resolved.',
          1;
END;

IF OBJECT_ID(N'tempdb..#Capture40Context') IS NOT NULL
    DROP TABLE #Capture40Context;

CREATE TABLE #Capture40Context
(
    CaptureRunID bigint NOT NULL
);

INSERT #Capture40Context(CaptureRunID)
VALUES(@CaptureRunID);

SELECT
      ValidationSection='1 - CAPTURE 40 STARTED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus='RUNNING'
    , TestScenario='CONTROLLED BLOCKING WITH TRANSACTION EVIDENCE'
    , ExpectedRootCause='BLOCKING_WAIT_CHAIN'
    , ExpectedConfidence='HIGH';
GO


/*==============================================================================
  3. PERSIST CAPTURE ID FOR LATER BATCHES
     Use SESSION_CONTEXT rather than relying on temp table scope across GO.
==============================================================================*/
DECLARE @CaptureRunID bigint;

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE CaptureStatus = N'RUNNING'
  AND TargetDatabase = N'RCA'
  AND CaptureReason LIKE N'%Capture 40%'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
    THROW 55311,N'Capture 40 RUNNING row not found before job creation.',1;

EXEC sys.sp_set_session_context
     @key = N'RCA_Capture40_RunID',
     @value = @CaptureRunID;

SELECT
      ValidationSection='2 - CAPTURE 40 CONTEXT'
    , CaptureRunID=@CaptureRunID
    , SessionContextStored='PASS';
GO


/*==============================================================================
  4. CLEAN UP ANY LEFTOVER CONTROL JOBS
==============================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Sampler')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C40_Sampler';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Blocker')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C40_Blocker';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Victim')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C40_Victim';
GO


/*==============================================================================
  5. CREATE CONTROL JOBS
  FIX: build complete command strings BEFORE calling sp_add_jobstep.
==============================================================================*/
DECLARE
      @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'))
    , @SamplerCommand nvarchar(max)
    , @BlockerCommand nvarchar(max)
    , @VictimCommand nvarchar(max);

IF @CaptureRunID IS NULL
    THROW 55312,N'Capture 40 session context is missing.',1;

SET @SamplerCommand =
      N'USE DBA; '
    + N'EXEC dbo.usp_RCA_RunSampler '
    + N'@CaptureRunID = ' + CONVERT(nvarchar(30),@CaptureRunID) + N', '
    + N'@DurationMinutes = 2, '
    + N'@SampleSeconds = 5;';

SET @BlockerCommand =
      N'USE RCA; '
    + N'EXEC dbo.usp_RCA_Capture40_Blocker;';

SET @VictimCommand =
      N'USE RCA; '
    + N'EXEC dbo.usp_RCA_Capture40_Victim;';

EXEC msdb.dbo.sp_add_job
     @job_name = N'RCA_C40_Sampler',
     @enabled = 1,
     @delete_level = 0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'RCA_C40_Sampler',
     @step_name = N'Capture RCA snapshots with transaction evidence',
     @subsystem = N'TSQL',
     @database_name = N'DBA',
     @command = @SamplerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name = N'RCA_C40_Sampler';

EXEC msdb.dbo.sp_add_job
     @job_name = N'RCA_C40_Blocker',
     @enabled = 1,
     @delete_level = 0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'RCA_C40_Blocker',
     @step_name = N'Open blocking transaction',
     @subsystem = N'TSQL',
     @database_name = N'RCA',
     @command = @BlockerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name = N'RCA_C40_Blocker';

EXEC msdb.dbo.sp_add_job
     @job_name = N'RCA_C40_Victim',
     @enabled = 1,
     @delete_level = 0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'RCA_C40_Victim',
     @step_name = N'Run blocked victim',
     @subsystem = N'TSQL',
     @database_name = N'RCA',
     @command = @VictimCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name = N'RCA_C40_Victim';

SELECT
      ValidationSection='3 - CONTROL JOBS CREATED'
    , CaptureRunID=@CaptureRunID
    , SamplerJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Sampler')
             THEN 'PASS' ELSE 'FAIL' END
    , BlockerJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Blocker')
             THEN 'PASS' ELSE 'FAIL' END
    , VictimJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Victim')
             THEN 'PASS' ELSE 'FAIL' END
    , SamplerCommand=@SamplerCommand;
GO


/*==============================================================================
  6. START THE CONTROLLED SCENARIO
==============================================================================*/
DECLARE @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'));

IF @CaptureRunID IS NULL
    THROW 55313,N'Capture 40 session context is missing before job start.',1;

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C40_Sampler';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C40_Blocker';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C40_Victim';

SELECT
      ValidationSection='4 - CONTROL JOBS STARTED'
    , CaptureRunID=@CaptureRunID
    , Sampler='STARTED'
    , Blocker='STARTED'
    , Victim='STARTED';

WAITFOR DELAY '00:01:05';
GO


/*==============================================================================
  7. VERIFY TRANSACTION EVIDENCE EXISTS BEFORE STOPPING CAPTURE
==============================================================================*/
DECLARE
      @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'))
    , @EvidenceRows bigint;

IF @CaptureRunID IS NULL
    THROW 55314,N'Capture 40 session context is missing before evidence check.',1;

SELECT @EvidenceRows = COUNT_BIG(*)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='5 - LIVE TRANSACTION EVIDENCE CHECK'
    , CaptureRunID=@CaptureRunID
    , TransactionEvidenceRows=@EvidenceRows
    , Result=
        CASE WHEN @EvidenceRows>0
             THEN 'PASS - TRANSACTION EVIDENCE CAPTURED'
             ELSE 'FAIL - NO TRANSACTION EVIDENCE CAPTURED'
        END;

IF @EvidenceRows = 0
BEGIN
    THROW 55315,
          N'Capture 40 produced no blocker transaction evidence. Aborting before RCA stop/analyze.',
          1;
END;
GO


/*==============================================================================
  8. STOP / ANALYZE EXISTING RCA CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'));

IF @CaptureRunID IS NULL
    THROW 55316,N'Capture 40 session context is missing before stop.',1;

EXEC dbo.usp_RCA_Stop
     @CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='6 - CAPTURE 40 STOPPED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus=
        (
            SELECT CaptureStatus
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@CaptureRunID
        );
GO


/*==============================================================================
  9. TRANSACTION EVIDENCE SUMMARY
==============================================================================*/
DECLARE @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'));

IF @CaptureRunID IS NULL
    THROW 55317,N'Capture 40 session context is missing during summary.',1;

SELECT
      ValidationSection='7 - TRANSACTION EVIDENCE SUMMARY'
    , CaptureRunID=@CaptureRunID
    , TransactionEvidenceRows=COUNT(*)
    , DistinctVictims=COUNT(DISTINCT VictimSessionID)
    , DistinctHeadBlockers=COUNT(DISTINCT HeadBlockerSessionID)
    , DistinctTransactions=COUNT(DISTINCT TransactionID)
    , RowsWithTransactionBeginTime=
        SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END)
    , RowsWithTransactionAge=
        SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END)
    , RowsWithLockResource=
        SUM(CASE WHEN LockResourceType IS NOT NULL THEN 1 ELSE 0 END)
    , RowsWithMappedObject=
        SUM(CASE WHEN LockedObjectName IS NOT NULL THEN 1 ELSE 0 END)
    , MaxTransactionAgeMs=MAX(TransactionAgeMs)
    , MaxVictimWaitMs=MAX(VictimWaitDurationMs)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  10. DETAILED TRANSACTION / LOCK EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'));

IF @CaptureRunID IS NULL
    THROW 55318,N'Capture 40 session context is missing during detail output.',1;

SELECT
      ValidationSection='8 - BLOCKER TRANSACTION EVIDENCE'
    , BlockerTransactionEvidenceID
    , SampleTimeUTC
    , VictimSessionID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , VictimWaitType
    , VictimWaitDurationMs
    , BlockerOpenTransactionCount
    , TransactionID
    , TransactionBeginTimeUTC
    , TransactionAgeMs
    , TransactionType
    , TransactionState
    , TransactionName
    , LockResourceType
    , LockDatabaseName
    , LockRequestMode
    , LockRequestStatus
    , LockedSchemaName
    , LockedObjectName
    , LockedIndexName
    , BlockerHostName
    , BlockerProgramName
    , BlockerLoginName
    , BlockerBatchText
    , BlockerStatementText
    , VictimStatementText
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID
ORDER BY
      SampleTimeUTC
    , VictimSessionID
    , HeadBlockerSessionID
    , BlockerTransactionEvidenceID;
GO


/*==============================================================================
  11. ACCEPTANCE GATE
==============================================================================*/
DECLARE
      @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'))
    , @Rows int=0
    , @TxnRows int=0
    , @BeginRows int=0
    , @AgeRows int=0
    , @LockRows int=0
    , @BlockerRows int=0;

IF @CaptureRunID IS NULL
    THROW 55319,N'Capture 40 session context is missing during acceptance.',1;

SELECT
      @Rows=COUNT(*)
    , @TxnRows=SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END)
    , @BeginRows=SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END)
    , @AgeRows=SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END)
    , @LockRows=SUM(CASE WHEN LockResourceType IS NOT NULL THEN 1 ELSE 0 END)
    , @BlockerRows=SUM(CASE WHEN HeadBlockerSessionID IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;

SET @Rows=ISNULL(@Rows,0);
SET @TxnRows=ISNULL(@TxnRows,0);
SET @BeginRows=ISNULL(@BeginRows,0);
SET @AgeRows=ISNULL(@AgeRows,0);
SET @LockRows=ISNULL(@LockRows,0);
SET @BlockerRows=ISNULL(@BlockerRows,0);

SELECT
      ValidationSection='9 - CAPTURE 40 TRANSACTION ACCEPTANCE'
    , CaptureRunID=@CaptureRunID
    , EvidenceRows=
        CASE WHEN @Rows>0 THEN 'PASS' ELSE 'FAIL' END
    , HeadBlockerCaptured=
        CASE WHEN @BlockerRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionIDCaptured=
        CASE WHEN @TxnRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionBeginTimeCaptured=
        CASE WHEN @BeginRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionAgeCaptured=
        CASE WHEN @AgeRows>0 THEN 'PASS' ELSE 'FAIL' END
    , LockResourceCaptured=
        CASE WHEN @LockRows>0 THEN 'PASS' ELSE 'FAIL' END
    , OverallResult=
        CASE
          WHEN @Rows>0
           AND @BlockerRows>0
           AND @TxnRows>0
           AND @BeginRows>0
           AND @AgeRows>0
           AND @LockRows>0
          THEN 'PASS - TRANSACTION LEVEL BLOCKER EVIDENCE PERSISTED'
          ELSE 'REVIEW - ONE OR MORE TRANSACTION EVIDENCE DIMENSIONS ARE MISSING'
        END;
GO


/*==============================================================================
  12. HUMAN-READABLE RCA ANSWER
==============================================================================*/
DECLARE @CaptureRunID bigint = TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture40_RunID'));

IF @CaptureRunID IS NULL
    THROW 55320,N'Capture 40 session context is missing before final RCA answer.',1;

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_v3',N'P') IS NOT NULL
BEGIN
    EXEC dbo.usp_RCA_DBAAnswer_v3
         @CaptureRunID=@CaptureRunID,
         @IncludeTechnicalDetail=0;
END
ELSE IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_v2',N'P') IS NOT NULL
BEGIN
    EXEC dbo.usp_RCA_DBAAnswer_v2
         @CaptureRunID=@CaptureRunID,
         @IncludeTechnicalDetail=0;
END
ELSE
BEGIN
    EXEC dbo.usp_RCA_WhyIsDatabaseSlow
         @CaptureRunID=@CaptureRunID,
         @IncludeTechnicalDetail=0;
END;
GO


/*==============================================================================
  13. CLEAN UP CONTROL JOBS
==============================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Sampler')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C40_Sampler';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Blocker')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C40_Blocker';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C40_Victim')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C40_Victim';

SELECT
      ValidationSection='10 - SCRIPT 53 v2 SAFETY'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , HistoricalEvidenceModified='NO'
    , ControlledJobsRemoved='YES'
    , NewEvidenceCollected='YES'
    , ControlledCaptureCreated='YES';
GO
