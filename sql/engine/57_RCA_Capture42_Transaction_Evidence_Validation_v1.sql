USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  57_RCA_Capture42_Transaction_Evidence_Validation_v1.sql

  PURPOSE
  -------
  Fresh positive-control validation AFTER Script 56 fixed the recursive CTE
  defect in dbo.usp_RCA_CaptureBlockerTransactionEvidence.

  PRIMARY QUESTION
  ----------------
      During a controlled blocking incident, can the RCA engine now persist:

          - victim session
          - immediate blocker
          - head blocker
          - wait type / duration
          - blocker open transaction count
          - transaction ID
          - transaction begin time
          - transaction age
          - blocker host / program / login
          - blocker batch / statement
          - victim statement
          - representative granted lock resource

  EXPECTED RESULT
  ---------------
      TransactionEvidenceRows > 0
      CollectorErrorRows = 0
      TransactionID populated
      TransactionBeginTimeUTC populated
      TransactionAgeMs populated

  IMPORTANT
  ---------
  This script does NOT:
      - change detector thresholds
      - change root-cause domains
      - change root-cause ranking logic
      - modify Capture 38/39/40/41
      - backfill historical transaction evidence

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max)=N'';
DECLARE @Message nvarchar(2048);

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

IF OBJECT_ID(N'dbo.RCA_CollectorError',N'U') IS NULL
    SET @Missing += N' dbo.RCA_CollectorError;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message=CONCAT(N'Script 57 prerequisites are missing:',@Missing);
    THROW 55700,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 57 PRE-FLIGHT'
    , StartProcedure='PASS'
    , StopProcedure='PASS'
    , Sampler='PASS'
    , FixedTransactionCollector='PASS'
    , TransactionEvidenceTable='PASS'
    , CollectorErrorTelemetry='PASS'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  1. CREATE / RESET CONTROLLED TEST FIXTURE
==============================================================================*/
USE RCA;
GO

IF OBJECT_ID(N'dbo.RCA_Capture42_Blocking',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_Capture42_Blocking
    (
          BlockingID int NOT NULL
              CONSTRAINT PK_RCA_Capture42_Blocking PRIMARY KEY
        , Amount decimal(19,2) NOT NULL
        , Payload char(200) NULL
    );
END;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_Capture42_Blocking
    WHERE BlockingID=1
)
BEGIN
    UPDATE dbo.RCA_Capture42_Blocking
       SET Amount=100.00,
           Payload=REPLICATE('X',200)
     WHERE BlockingID=1;
END
ELSE
BEGIN
    INSERT dbo.RCA_Capture42_Blocking
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


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture42_Blocker
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Capture42_Blocking
       SET Amount=Amount+1.00
     WHERE BlockingID=1;

    WAITFOR DELAY '00:00:45';

    COMMIT TRAN;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture42_Victim
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.RCA_Capture42_Blocking
       SET Amount=Amount+5.00
     WHERE BlockingID=1;
END;
GO


/*==============================================================================
  2. CLEAN UP LEFTOVER C42 CONTROL JOBS
==============================================================================*/
USE DBA;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Sampler')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C42_Sampler';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Blocker')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C42_Blocker';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Victim')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C42_Victim';
GO


/*==============================================================================
  3. START FRESH CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint;

EXEC dbo.usp_RCA_Start
     @DatabaseName=N'RCA',
     @IncidentDescription=
         N'Capture 42 - transaction evidence validation after recursive collector fix';

SELECT TOP (1)
    @CaptureRunID=CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE CaptureStatus=N'RUNNING'
  AND TargetDatabase=N'RCA'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
    THROW 55710,N'Capture 42 start failed: no RUNNING capture could be resolved.',1;

EXEC sys.sp_set_session_context
     @key=N'RCA_Capture42_RunID',
     @value=@CaptureRunID;

SELECT
      ValidationSection='1 - CAPTURE 42 STARTED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus='RUNNING'
    , TestScenario='CONTROLLED BLOCKING AFTER RECURSIVE COLLECTOR FIX'
    , ExpectedRootCause='BLOCKING_WAIT_CHAIN'
    , ExpectedConfidence='HIGH';
GO


/*==============================================================================
  4. CREATE SQL AGENT CONTROL JOBS
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'))
    , @SamplerCommand nvarchar(max)
    , @BlockerCommand nvarchar(max)
    , @VictimCommand nvarchar(max);

IF @CaptureRunID IS NULL
    THROW 55711,N'Capture 42 session context is missing before job creation.',1;

SET @SamplerCommand=
      N'USE DBA; '
    + N'EXEC dbo.usp_RCA_RunSampler '
    + N'@CaptureRunID = '+CONVERT(nvarchar(30),@CaptureRunID)+N', '
    + N'@DurationMinutes = 2, '
    + N'@SampleSeconds = 5;';

SET @BlockerCommand=
      N'USE RCA; '
    + N'EXEC dbo.usp_RCA_Capture42_Blocker;';

SET @VictimCommand=
      N'USE RCA; '
    + N'EXEC dbo.usp_RCA_Capture42_Victim;';

EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C42_Sampler',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C42_Sampler',
     @step_name=N'Capture RCA snapshots with fixed transaction collector',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C42_Sampler';


EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C42_Blocker',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C42_Blocker',
     @step_name=N'Open controlled blocking transaction',
     @subsystem=N'TSQL',
     @database_name=N'RCA',
     @command=@BlockerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C42_Blocker';


EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C42_Victim',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C42_Victim',
     @step_name=N'Run blocked victim',
     @subsystem=N'TSQL',
     @database_name=N'RCA',
     @command=@VictimCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C42_Victim';


SELECT
      ValidationSection='2 - CONTROL JOBS CREATED'
    , CaptureRunID=@CaptureRunID
    , SamplerJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Sampler')
             THEN 'PASS' ELSE 'FAIL' END
    , BlockerJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Blocker')
             THEN 'PASS' ELSE 'FAIL' END
    , VictimJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Victim')
             THEN 'PASS' ELSE 'FAIL' END
    , SamplerCommand=@SamplerCommand;
GO


/*==============================================================================
  5. RUN CONTROLLED BLOCKING SCENARIO
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'));

IF @CaptureRunID IS NULL
    THROW 55712,N'Capture 42 session context is missing before job start.',1;

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C42_Sampler';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C42_Blocker';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C42_Victim';

SELECT
      ValidationSection='3 - CONTROL JOBS STARTED'
    , CaptureRunID=@CaptureRunID
    , Sampler='STARTED'
    , Blocker='STARTED'
    , Victim='STARTED';

WAITFOR DELAY '00:01:05';
GO


/*==============================================================================
  6. LIVE EVIDENCE CHECK BEFORE STOP/ANALYZE
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'))
    , @TxnRows bigint
    , @ErrorRows bigint;

IF @CaptureRunID IS NULL
    THROW 55713,N'Capture 42 session context missing during live evidence check.',1;

SELECT @TxnRows=COUNT_BIG(*)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT @ErrorRows=COUNT_BIG(*)
FROM dbo.RCA_CollectorError
WHERE CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='4 - LIVE TRANSACTION EVIDENCE CHECK'
    , CaptureRunID=@CaptureRunID
    , TransactionEvidenceRows=@TxnRows
    , CollectorErrorRows=@ErrorRows
    , Result=
        CASE
          WHEN @TxnRows>0 AND @ErrorRows=0
          THEN 'PASS - TRANSACTION EVIDENCE EXISTS AND COLLECTOR HAS NO ERRORS'
          WHEN @TxnRows>0 AND @ErrorRows>0
          THEN 'REVIEW - TRANSACTION EVIDENCE EXISTS BUT COLLECTOR LOGGED ERRORS'
          WHEN @TxnRows=0 AND @ErrorRows>0
          THEN 'FAIL - NO TRANSACTION EVIDENCE; COLLECTOR ERROR LOGGED'
          ELSE 'FAIL - NO TRANSACTION EVIDENCE AND NO COLLECTOR ERROR'
        END;

IF @TxnRows=0
BEGIN
    SELECT
          ValidationSection='4A - COLLECTOR ERRORS'
        , *
    FROM dbo.RCA_CollectorError
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY ErrorTimeUTC,CollectorErrorID;

    THROW 55714,
          N'Capture 42 produced no blocker transaction evidence. Review collector telemetry before continuing.',
          1;
END;
GO


/*==============================================================================
  7. STOP / ANALYZE CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'));

IF @CaptureRunID IS NULL
    THROW 55715,N'Capture 42 session context missing before stop.',1;

EXEC dbo.usp_RCA_Stop
     @CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='5 - CAPTURE 42 STOPPED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus=
        (
            SELECT CaptureStatus
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@CaptureRunID
        );
GO


/*==============================================================================
  8. CORE EVIDENCE SUMMARY
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'));

IF @CaptureRunID IS NULL
    THROW 55716,N'Capture 42 context missing during summary.',1;

SELECT
      ValidationSection='6 - SERVER SNAPSHOT SUMMARY'
    , CaptureRunID=@CaptureRunID
    , ServerSnapshotRows=COUNT(*)
    , FirstSampleUTC=MIN(CaptureTimeUTC)
    , LastSampleUTC=MAX(CaptureTimeUTC)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;


SELECT
      ValidationSection='7 - BLOCKING EVIDENCE SUMMARY'
    , CaptureRunID=@CaptureRunID
    , BlockingEvidenceRows=COUNT(*)
    , FirstObservedUTC=MIN(FirstObservedUTC)
    , LastObservedUTC=MAX(LastObservedUTC)
    , MaxWaitDurationMs=MAX(WaitDurationMs)
    , MaxSampleCount=MAX(SampleCount)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;


SELECT
      ValidationSection='8 - TRANSACTION EVIDENCE SUMMARY'
    , CaptureRunID=@CaptureRunID
    , TransactionEvidenceRows=COUNT(*)
    , DistinctVictims=COUNT(DISTINCT VictimSessionID)
    , DistinctHeadBlockers=COUNT(DISTINCT HeadBlockerSessionID)
    , DistinctTransactions=COUNT(DISTINCT TransactionID)

    , RowsWithOpenTransactionCount=
        SUM(CASE WHEN BlockerOpenTransactionCount IS NOT NULL THEN 1 ELSE 0 END)

    , RowsWithTransactionID=
        SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END)

    , RowsWithTransactionBeginTime=
        SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END)

    , RowsWithTransactionAge=
        SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END)

    , RowsWithLockResource=
        SUM(CASE WHEN LockResourceType IS NOT NULL THEN 1 ELSE 0 END)

    , RowsWithBlockerBatch=
        SUM(CASE WHEN NULLIF(LTRIM(RTRIM(BlockerBatchText)),N'') IS NOT NULL THEN 1 ELSE 0 END)

    , RowsWithBlockerStatement=
        SUM(CASE WHEN NULLIF(LTRIM(RTRIM(BlockerStatementText)),N'') IS NOT NULL THEN 1 ELSE 0 END)

    , MaxTransactionAgeMs=MAX(TransactionAgeMs)
    , MaxVictimWaitMs=MAX(VictimWaitDurationMs)

FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  9. DETAILED BLOCKER TRANSACTION EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'));

SELECT
      ValidationSection='9 - BLOCKER TRANSACTION EVIDENCE'
    , BlockerTransactionEvidenceID
    , SampleTimeUTC
    , VictimSessionID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , BlockingDepth
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
    , LockResourceSubtype
    , LockDatabaseID
    , LockDatabaseName
    , LockRequestMode
    , LockRequestStatus
    , LockRequestOwnerType
    , ResourceAssociatedEntityID
    , ResourceDescription

    , BlockerHostName
    , BlockerProgramName
    , BlockerLoginName
    , BlockerBatchText
    , BlockerStatementText

    , VictimHostName
    , VictimProgramName
    , VictimLoginName
    , VictimStatementText

    , EvidenceIntegrityNote

FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID
ORDER BY
      SampleTimeUTC
    , VictimSessionID
    , HeadBlockerSessionID
    , BlockerTransactionEvidenceID;
GO


/*==============================================================================
  10. COLLECTOR HEALTH
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'));

SELECT
      ValidationSection='10 - COLLECTOR HEALTH'
    , CollectorErrorID
    , ErrorTimeUTC
    , CollectorName
    , ErrorNumber
    , ErrorSeverity
    , ErrorState
    , ErrorProcedure
    , ErrorLine
    , ErrorMessage
    , ContextMessage
FROM dbo.RCA_CollectorError
WHERE CaptureRunID=@CaptureRunID
ORDER BY ErrorTimeUTC,CollectorErrorID;
GO


/*==============================================================================
  11. CAPTURE 42 ACCEPTANCE GATE
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'))
    , @BlockingRows int=0
    , @TxnEvidenceRows int=0
    , @HeadBlockerRows int=0
    , @OpenTranRows int=0
    , @TransactionIDRows int=0
    , @BeginRows int=0
    , @AgeRows int=0
    , @LockRows int=0
    , @CollectorErrors int=0;

SELECT @BlockingRows=COUNT(*)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT
      @TxnEvidenceRows=COUNT(*)
    , @HeadBlockerRows=SUM(CASE WHEN HeadBlockerSessionID IS NOT NULL THEN 1 ELSE 0 END)
    , @OpenTranRows=SUM(CASE WHEN BlockerOpenTransactionCount IS NOT NULL THEN 1 ELSE 0 END)
    , @TransactionIDRows=SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END)
    , @BeginRows=SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END)
    , @AgeRows=SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END)
    , @LockRows=SUM(CASE WHEN LockResourceType IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT @CollectorErrors=COUNT(*)
FROM dbo.RCA_CollectorError
WHERE CaptureRunID=@CaptureRunID;

SET @BlockingRows=ISNULL(@BlockingRows,0);
SET @TxnEvidenceRows=ISNULL(@TxnEvidenceRows,0);
SET @HeadBlockerRows=ISNULL(@HeadBlockerRows,0);
SET @OpenTranRows=ISNULL(@OpenTranRows,0);
SET @TransactionIDRows=ISNULL(@TransactionIDRows,0);
SET @BeginRows=ISNULL(@BeginRows,0);
SET @AgeRows=ISNULL(@AgeRows,0);
SET @LockRows=ISNULL(@LockRows,0);
SET @CollectorErrors=ISNULL(@CollectorErrors,0);

SELECT
      ValidationSection='11 - CAPTURE 42 ACCEPTANCE'
    , CaptureRunID=@CaptureRunID
    , BlockingEvidenceCaptured=
        CASE WHEN @BlockingRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionEvidenceCaptured=
        CASE WHEN @TxnEvidenceRows>0 THEN 'PASS' ELSE 'FAIL' END
    , HeadBlockerCaptured=
        CASE WHEN @HeadBlockerRows>0 THEN 'PASS' ELSE 'FAIL' END
    , OpenTransactionCountCaptured=
        CASE WHEN @OpenTranRows>0 THEN 'PASS' ELSE 'REVIEW' END
    , TransactionIDCaptured=
        CASE WHEN @TransactionIDRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionBeginTimeCaptured=
        CASE WHEN @BeginRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionAgeCaptured=
        CASE WHEN @AgeRows>0 THEN 'PASS' ELSE 'FAIL' END
    , LockResourceCaptured=
        CASE WHEN @LockRows>0 THEN 'PASS' ELSE 'REVIEW' END
    , CollectorErrors=
        CASE WHEN @CollectorErrors=0 THEN 'PASS - NONE' ELSE 'FAIL' END
    , OverallResult=
        CASE
          WHEN @BlockingRows>0
           AND @TxnEvidenceRows>0
           AND @HeadBlockerRows>0
           AND @TransactionIDRows>0
           AND @BeginRows>0
           AND @AgeRows>0
           AND @CollectorErrors=0
          THEN 'PASS - TRANSACTION EVIDENCE PIPELINE WORKS AFTER SCRIPT 56'
          ELSE 'REVIEW - ONE OR MORE CORE TRANSACTION EVIDENCE DIMENSIONS ARE MISSING'
        END;
GO


/*==============================================================================
  12. HUMAN-READABLE DBA ANSWER
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture42_RunID'));

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
  13. CLEANUP CONTROL JOBS
==============================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Sampler')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C42_Sampler';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Blocker')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C42_Blocker';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C42_Victim')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C42_Victim';
GO


/*==============================================================================
  14. SAFETY
==============================================================================*/
SELECT
      ValidationSection='12 - SCRIPT 57 SAFETY'
    , FreshCaptureCreated='YES'
    , NewTransactionEvidenceCollected='YES'
    , Capture38Modified='NO'
    , Capture39Modified='NO'
    , Capture40Modified='NO'
    , Capture41Modified='NO'
    , HistoricalEvidenceBackfilled='NO'
    , FindingsRebuiltByScript='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , ControlledJobsRemoved='YES'
    , NextStep=
        'If Capture 42 passes, stop changing transaction collection and integrate the persisted transaction evidence into the human-readable Why-is-DB-slow narrative.';
GO
