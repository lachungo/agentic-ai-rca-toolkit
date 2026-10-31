USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  53_RCA_Capture40_Transaction_Validation_v1.sql

  PURPOSE
  -------
  Create one fresh controlled blocking incident AFTER Script 52 integrated
  blocker-transaction evidence into the RCA sampler.

  PRIMARY QUESTION
  ----------------
      Can the RCA system preserve enough evidence to explain, after the live
      sessions are gone:

          - who blocked whom
          - what wait occurred
          - what transaction was open
          - when that transaction began
          - how old it was
          - what SQL/app/login/host owned it
          - what lock/resource/object was involved

  IMPORTANT
  ---------
  This script does NOT change detector thresholds or root-cause ranking logic.
  It only:
      1. creates a controlled test fixture in database RCA
      2. starts a fresh RCA capture
      3. runs the normal sampler
      4. runs blocker and victim workloads
      5. stops/analyzes the capture using the existing RCA pipeline
      6. validates transaction evidence persistence
      7. prints the human-readable RCA answer

  EXPECTED ROOT CAUSE
  -------------------
      BLOCKING_WAIT_CHAIN
      PRIMARY
      HIGH confidence

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
    SET @msg=CONCAT(N'Script 53 prerequisites are missing:',@Missing);
    THROW 55300,@msg,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 53 PRE-FLIGHT'
    , StartProcedure='PASS'
    , StopProcedure='PASS'
    , Sampler='PASS'
    , TransactionCollector='PASS'
    , TransactionEvidenceTable='PASS'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO';
GO


/*==============================================================================
  1. CREATE/RESET CONTROLLED TEST FIXTURE IN RCA DATABASE
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
END
ELSE
BEGIN
    UPDATE dbo.RCA_Capture40_Blocking
       SET Amount = 100.00,
           Payload = REPLICATE('X',200)
     WHERE BlockingID = 1;

    IF @@ROWCOUNT = 0
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

    /*
      Hold the transaction open long enough for repeated sampler observations.
      The UPDATE acquires the lock. WAITFOR merely keeps the transaction open.
    */
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
  2. RETURN TO DBA AND START A FRESH CAPTURE
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
    THROW 55310,N'Could not resolve the newly started CaptureRunID.',1;

SELECT
      ValidationSection='1 - CAPTURE STARTED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus='RUNNING'
    , TestScenario='CONTROLLED BLOCKING WITH TRANSACTION EVIDENCE'
    , ExpectedRootCause='BLOCKING_WAIT_CHAIN'
    , ExpectedConfidence='HIGH';

DECLARE @CaptureRunIDText varchar(30)=CONVERT(varchar(30),@CaptureRunID);

EXEC msdb.dbo.sp_add_job
     @job_name = N'RCA_C40_Sampler',
     @enabled = 1,
     @delete_level = 3;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'RCA_C40_Sampler',
     @step_name = N'Capture RCA snapshots with transaction evidence',
     @subsystem = N'TSQL',
     @database_name = N'DBA',
     @command =
         N'USE DBA;
           EXEC dbo.usp_RCA_RunSampler
                @CaptureRunID = ' + @CaptureRunIDText + N',
                @DurationMinutes = 2,
                @SampleSeconds = 5;';

EXEC msdb.dbo.sp_add_jobserver
     @job_name = N'RCA_C40_Sampler';

EXEC msdb.dbo.sp_add_job
     @job_name = N'RCA_C40_Blocker',
     @enabled = 1,
     @delete_level = 3;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'RCA_C40_Blocker',
     @step_name = N'Open blocking transaction',
     @subsystem = N'TSQL',
     @database_name = N'RCA',
     @command =
         N'USE RCA;
           EXEC dbo.usp_RCA_Capture40_Blocker;';

EXEC msdb.dbo.sp_add_jobserver
     @job_name = N'RCA_C40_Blocker';

EXEC msdb.dbo.sp_add_job
     @job_name = N'RCA_C40_Victim',
     @enabled = 1,
     @delete_level = 3;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'RCA_C40_Victim',
     @step_name = N'Run blocked victim',
     @subsystem = N'TSQL',
     @database_name = N'RCA',
     @command =
         N'USE RCA;
           EXEC dbo.usp_RCA_Capture40_Victim;';

EXEC msdb.dbo.sp_add_jobserver
     @job_name = N'RCA_C40_Victim';

SELECT
      ValidationSection='2 - CONTROL JOBS CREATED'
    , CaptureRunID=@CaptureRunID
    , SamplerJob='PASS'
    , BlockerJob='PASS'
    , VictimJob='PASS';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C40_Sampler';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C40_Blocker';

WAITFOR DELAY '00:00:05';

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C40_Victim';

SELECT
      ValidationSection='3 - CONTROL JOBS STARTED'
    , CaptureRunID=@CaptureRunID
    , Sampler='STARTED'
    , Blocker='STARTED'
    , Victim='STARTED';

-- Allow blocker/victim and sampler to run.
WAITFOR DELAY '00:01:05';

-- Stop/analyze using existing RCA workflow.
EXEC dbo.usp_RCA_Stop
     @CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='4 - CAPTURE STOPPED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus=
        (
            SELECT CaptureStatus
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@CaptureRunID
        );
GO


/*==============================================================================
  3. RESOLVE THE MOST RECENT CAPTURE 40 RUN
==============================================================================*/
DECLARE @CaptureRunID bigint;

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE TargetDatabase=N'RCA'
  AND CaptureReason LIKE N'%Capture 40%'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
    THROW 55320,N'Could not find Capture 40 after execution.',1;

SELECT
      ValidationSection='5 - CAPTURE 40 STATE'
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  4. TRANSACTION EVIDENCE SUMMARY
==============================================================================*/
DECLARE @CaptureRunID bigint;

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE TargetDatabase=N'RCA'
  AND CaptureReason LIKE N'%Capture 40%'
ORDER BY CaptureRunID DESC;

SELECT
      ValidationSection='6 - TRANSACTION EVIDENCE SUMMARY'
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
  5. DETAILED TRANSACTION / LOCK EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint;

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE TargetDatabase=N'RCA'
  AND CaptureReason LIKE N'%Capture 40%'
ORDER BY CaptureRunID DESC;

SELECT
      ValidationSection='7 - BLOCKER TRANSACTION EVIDENCE'
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
  6. ACCEPTANCE GATE
==============================================================================*/
DECLARE
      @CaptureRunID bigint
    , @Rows int=0
    , @TxnRows int=0
    , @BeginRows int=0
    , @AgeRows int=0
    , @LockRows int=0
    , @BlockerRows int=0;

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE TargetDatabase=N'RCA'
  AND CaptureReason LIKE N'%Capture 40%'
ORDER BY CaptureRunID DESC;

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
      ValidationSection='8 - CAPTURE 40 TRANSACTION ACCEPTANCE'
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
  7. FINAL HUMAN-READABLE RCA ANSWER

  Prefer the most recent human-readable procedure if available.
==============================================================================*/
DECLARE @CaptureRunID bigint;

SELECT TOP (1)
    @CaptureRunID = CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE TargetDatabase=N'RCA'
  AND CaptureReason LIKE N'%Capture 40%'
ORDER BY CaptureRunID DESC;

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
  8. SAFETY
==============================================================================*/
SELECT
      ValidationSection='9 - SCRIPT 53 SAFETY'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , HistoricalEvidenceModified='NO'
    , NewEvidenceCollected='YES'
    , ControlledCaptureCreated='YES'
    , Purpose='Validate persisted blocker transaction and lock evidence end-to-end.';
GO
