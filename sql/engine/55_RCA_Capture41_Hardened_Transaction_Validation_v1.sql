USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  55_RCA_Capture41_Hardened_Transaction_Validation_v1.sql

  PURPOSE
  -------
  Fresh end-to-end validation AFTER Script 54 hardened blocker-transaction
  evidence collection.

  PRIMARY QUESTION
  ----------------
      Can the RCA system now preserve enough evidence to explain:

          "Why is RCA slow?"

      with a complete blocking chain including:

          - victim session
          - head blocker
          - wait type / duration
          - open transaction count
          - transaction ID
          - transaction begin time
          - transaction age
          - blocker host / program / login
          - blocker batch / statement
          - victim statement
          - representative lock resource
          - final RCA root cause
          - human-readable DBA answer

  EXPECTED ROOT CAUSE
  -------------------
      BLOCKING_WAIT_CHAIN
      PRIMARY
      HIGH confidence

  SAFETY
  ------
  This script DOES NOT:
      - change detector thresholds
      - change root-cause domains
      - change root-cause ranking logic
      - modify Capture 38/39/40
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
    SET @Message=CONCAT(N'Script 55 prerequisites are missing:',@Missing);
    THROW 55500,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 55 PRE-FLIGHT'
    , StartProcedure='PASS'
    , StopProcedure='PASS'
    , Sampler='PASS'
    , HardenedTransactionCollector='PASS'
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

IF OBJECT_ID(N'dbo.RCA_Capture41_Blocking',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_Capture41_Blocking
    (
          BlockingID int NOT NULL
              CONSTRAINT PK_RCA_Capture41_Blocking PRIMARY KEY
        , Amount decimal(19,2) NOT NULL
        , Payload char(200) NULL
    );
END;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_Capture41_Blocking
    WHERE BlockingID=1
)
BEGIN
    UPDATE dbo.RCA_Capture41_Blocking
       SET Amount=100.00,
           Payload=REPLICATE('X',200)
     WHERE BlockingID=1;
END
ELSE
BEGIN
    INSERT dbo.RCA_Capture41_Blocking
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


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture41_Blocker
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Capture41_Blocking
       SET Amount=Amount+1.00
     WHERE BlockingID=1;

    /*
      This delay intentionally occurs INSIDE the open transaction.

      The UPDATE acquires the lock.
      WAITFOR keeps the transaction open long enough for repeated sampling.
    */
    WAITFOR DELAY '00:00:45';

    COMMIT TRAN;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Capture41_Victim
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE dbo.RCA_Capture41_Blocking
       SET Amount=Amount+5.00
     WHERE BlockingID=1;
END;
GO


/*==============================================================================
  2. CLEAN UP LEFTOVER C41 CONTROL JOBS BEFORE STARTING
==============================================================================*/
USE DBA;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Sampler')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C41_Sampler';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Blocker')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C41_Blocker';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Victim')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C41_Victim';
GO


/*==============================================================================
  3. START FRESH CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint;

EXEC dbo.usp_RCA_Start
     @DatabaseName=N'RCA',
     @IncidentDescription=
         N'Capture 41 - hardened blocker transaction validation - controlled blocking';

SELECT TOP (1)
    @CaptureRunID=CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE CaptureStatus=N'RUNNING'
  AND TargetDatabase=N'RCA'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
    THROW 55510,N'Capture 41 start failed: no RUNNING capture could be resolved.',1;

EXEC sys.sp_set_session_context
     @key=N'RCA_Capture41_RunID',
     @value=@CaptureRunID;

SELECT
      ValidationSection='1 - CAPTURE 41 STARTED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus='RUNNING'
    , TestScenario='CONTROLLED BLOCKING WITH HARDENED TRANSACTION EVIDENCE'
    , ExpectedRootCause='BLOCKING_WAIT_CHAIN'
    , ExpectedConfidence='HIGH';
GO


/*==============================================================================
  4. CREATE SQL AGENT CONTROL JOBS
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'))
    , @SamplerCommand nvarchar(max)
    , @BlockerCommand nvarchar(max)
    , @VictimCommand nvarchar(max);

IF @CaptureRunID IS NULL
    THROW 55511,N'Capture 41 session context is missing before job creation.',1;

SET @SamplerCommand=
      N'USE DBA; '
    + N'EXEC dbo.usp_RCA_RunSampler '
    + N'@CaptureRunID = '+CONVERT(nvarchar(30),@CaptureRunID)+N', '
    + N'@DurationMinutes = 2, '
    + N'@SampleSeconds = 5;';

SET @BlockerCommand=
      N'USE RCA; '
    + N'EXEC dbo.usp_RCA_Capture41_Blocker;';

SET @VictimCommand=
      N'USE RCA; '
    + N'EXEC dbo.usp_RCA_Capture41_Victim;';

EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C41_Sampler',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C41_Sampler',
     @step_name=N'Capture RCA snapshots with hardened transaction evidence',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C41_Sampler';


EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C41_Blocker',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C41_Blocker',
     @step_name=N'Open controlled blocking transaction',
     @subsystem=N'TSQL',
     @database_name=N'RCA',
     @command=@BlockerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C41_Blocker';


EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C41_Victim',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C41_Victim',
     @step_name=N'Run blocked victim',
     @subsystem=N'TSQL',
     @database_name=N'RCA',
     @command=@VictimCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C41_Victim';


SELECT
      ValidationSection='2 - CONTROL JOBS CREATED'
    , CaptureRunID=@CaptureRunID
    , SamplerJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Sampler')
             THEN 'PASS' ELSE 'FAIL' END
    , BlockerJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Blocker')
             THEN 'PASS' ELSE 'FAIL' END
    , VictimJob=
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Victim')
             THEN 'PASS' ELSE 'FAIL' END
    , SamplerCommand=@SamplerCommand;
GO


/*==============================================================================
  5. RUN CONTROLLED BLOCKING SCENARIO
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

IF @CaptureRunID IS NULL
    THROW 55512,N'Capture 41 session context is missing before job start.',1;

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C41_Sampler';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C41_Blocker';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C41_Victim';

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
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'))
    , @TxnRows bigint
    , @ErrorRows bigint;

IF @CaptureRunID IS NULL
    THROW 55513,N'Capture 41 session context missing during live evidence check.',1;

SELECT @TxnRows=COUNT_BIG(*)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT @ErrorRows=COUNT_BIG(*)
FROM dbo.RCA_CollectorError
WHERE CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='4 - LIVE HARDENED COLLECTOR CHECK'
    , CaptureRunID=@CaptureRunID
    , TransactionEvidenceRows=@TxnRows
    , CollectorErrorRows=@ErrorRows
    , Result=
        CASE
          WHEN @TxnRows>0
          THEN 'PASS - TRANSACTION EVIDENCE EXISTS'
          WHEN @TxnRows=0 AND @ErrorRows>0
          THEN 'FAIL - COLLECTOR ERROR LOGGED; REVIEW ERROR TELEMETRY'
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

    THROW 55514,
          N'Capture 41 produced no blocker transaction evidence. Review collector telemetry before continuing.',
          1;
END;
GO


/*==============================================================================
  7. STOP / ANALYZE CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

IF @CaptureRunID IS NULL
    THROW 55515,N'Capture 41 session context missing before stop.',1;

EXEC dbo.usp_RCA_Stop
     @CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='5 - CAPTURE 41 STOPPED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus=
        (
            SELECT CaptureStatus
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@CaptureRunID
        );
GO


/*==============================================================================
  8. CAPTURE STATE / SERVER SNAPSHOTS / BLOCKING EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

IF @CaptureRunID IS NULL
    THROW 55516,N'Capture 41 context missing during evidence summary.',1;

SELECT
      ValidationSection='6 - CAPTURE 41 STATE'
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=@CaptureRunID;


SELECT
      ValidationSection='7 - SERVER SNAPSHOT SUMMARY'
    , CaptureRunID=@CaptureRunID
    , ServerSnapshotRows=COUNT(*)
    , FirstSampleUTC=MIN(CaptureTimeUTC)
    , LastSampleUTC=MAX(CaptureTimeUTC)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;


SELECT
      ValidationSection='8 - BLOCKING EVIDENCE SUMMARY'
    , CaptureRunID=@CaptureRunID
    , BlockingEvidenceRows=COUNT(*)
    , FirstObservedUTC=MIN(FirstObservedUTC)
    , LastObservedUTC=MAX(LastObservedUTC)
    , MaxWaitDurationMs=MAX(WaitDurationMs)
    , MaxSampleCount=MAX(SampleCount)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  9. TRANSACTION EVIDENCE SUMMARY
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

SELECT
      ValidationSection='9 - TRANSACTION EVIDENCE SUMMARY'
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
  10. DETAILED TRANSACTION EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

SELECT
      ValidationSection='10 - BLOCKER TRANSACTION EVIDENCE'
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
  11. COLLECTOR HEALTH
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

SELECT
      ValidationSection='11 - COLLECTOR HEALTH'
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
  12. FINAL ROOT-CAUSE RANKING
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

IF OBJECT_ID(N'dbo.RCA_FinalCauseRanking',N'U') IS NOT NULL
BEGIN
    SELECT
          ValidationSection='12 - FINAL CAUSE RANKING'
        , *
    FROM dbo.RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          CASE PrimaryRole WHEN 'PRIMARY' THEN 1 ELSE 2 END,
          CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
END
ELSE
BEGIN
    SELECT
          ValidationSection='12 - FINAL CAUSE RANKING'
        , Result='dbo.RCA_FinalCauseRanking table not found';
END;
GO


/*==============================================================================
  13. ACCEPTANCE GATE
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'))
    , @EvidenceRows int=0
    , @BlockerRows int=0
    , @OpenTranRows int=0
    , @TxnRows int=0
    , @BeginRows int=0
    , @AgeRows int=0
    , @LockRows int=0
    , @ErrorRows int=0
    , @BlockingRows int=0;

SELECT
      @EvidenceRows=COUNT(*)
    , @BlockerRows=SUM(CASE WHEN HeadBlockerSessionID IS NOT NULL THEN 1 ELSE 0 END)
    , @OpenTranRows=SUM(CASE WHEN BlockerOpenTransactionCount IS NOT NULL THEN 1 ELSE 0 END)
    , @TxnRows=SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END)
    , @BeginRows=SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END)
    , @AgeRows=SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END)
    , @LockRows=SUM(CASE WHEN LockResourceType IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.RCA_BlockerTransactionEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT @ErrorRows=COUNT(*)
FROM dbo.RCA_CollectorError
WHERE CaptureRunID=@CaptureRunID;

SELECT @BlockingRows=COUNT(*)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;

SET @EvidenceRows=ISNULL(@EvidenceRows,0);
SET @BlockerRows=ISNULL(@BlockerRows,0);
SET @OpenTranRows=ISNULL(@OpenTranRows,0);
SET @TxnRows=ISNULL(@TxnRows,0);
SET @BeginRows=ISNULL(@BeginRows,0);
SET @AgeRows=ISNULL(@AgeRows,0);
SET @LockRows=ISNULL(@LockRows,0);
SET @ErrorRows=ISNULL(@ErrorRows,0);
SET @BlockingRows=ISNULL(@BlockingRows,0);

SELECT
      ValidationSection='13 - CAPTURE 41 ACCEPTANCE'
    , CaptureRunID=@CaptureRunID
    , BlockingEvidenceCaptured=
        CASE WHEN @BlockingRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionEvidenceCaptured=
        CASE WHEN @EvidenceRows>0 THEN 'PASS' ELSE 'FAIL' END
    , HeadBlockerCaptured=
        CASE WHEN @BlockerRows>0 THEN 'PASS' ELSE 'FAIL' END
    , OpenTransactionCountCaptured=
        CASE WHEN @OpenTranRows>0 THEN 'PASS' ELSE 'REVIEW' END
    , TransactionIDCaptured=
        CASE WHEN @TxnRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionBeginTimeCaptured=
        CASE WHEN @BeginRows>0 THEN 'PASS' ELSE 'FAIL' END
    , TransactionAgeCaptured=
        CASE WHEN @AgeRows>0 THEN 'PASS' ELSE 'FAIL' END
    , LockResourceCaptured=
        CASE WHEN @LockRows>0 THEN 'PASS' ELSE 'REVIEW' END
    , CollectorErrors=
        CASE WHEN @ErrorRows=0 THEN 'PASS - NONE' ELSE 'REVIEW' END
    , OverallResult=
        CASE
          WHEN @BlockingRows>0
           AND @EvidenceRows>0
           AND @BlockerRows>0
           AND @TxnRows>0
           AND @BeginRows>0
           AND @AgeRows>0
          THEN
              'PASS - HARDENED BLOCKER TRANSACTION EVIDENCE PERSISTED'
          ELSE
              'REVIEW - ONE OR MORE CORE TRANSACTION EVIDENCE DIMENSIONS ARE MISSING'
        END;
GO


/*==============================================================================
  14. HUMAN-READABLE DBA ANSWER
==============================================================================*/
DECLARE @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_Capture41_RunID'));

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
  15. CLEANUP CONTROL JOBS
==============================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Sampler')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C41_Sampler';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Blocker')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C41_Blocker';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_C41_Victim')
    EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_C41_Victim';
GO


/*==============================================================================
  16. SAFETY
==============================================================================*/
SELECT
      ValidationSection='14 - SCRIPT 55 SAFETY'
    , FreshCaptureCreated='YES'
    , NewEvidenceCollected='YES'
    , Capture38Modified='NO'
    , Capture39Modified='NO'
    , Capture40Modified='NO'
    , HistoricalTransactionEvidenceBackfilled='NO'
    , FindingsRebuiltByScript='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , ControlledJobsRemoved='YES'
    , NextStep=
        'Review Sections 9, 10, 11, 13, and the human-readable DBA answer. If core transaction evidence passes, integrate it into the final Why-is-DB-slow narrative without changing root-cause ranking.';
GO
