USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
16_RCA_Run7B_MultiLevel_Blocking_Validation.sql

PURPOSE
-------
Validate true multi-hop blocking-chain intelligence.

TOPOLOGY
--------
Session A = HEAD BLOCKER
    holds X lock on BlockingID = 1

Session B = MIDDLE BLOCKER
    begins a transaction
    locks BlockingID = 2
    then attempts to update BlockingID = 1
    and becomes blocked by Session A

Session C = VICTIM
    attempts to update BlockingID = 2
    and becomes blocked by Session B

EXPECTED CHAIN
--------------
Victim Session C
        ↓
Immediate Blocker Session B
        ↓
Head Blocker Session A

EXPECTED DETECTOR RESULT
------------------------
BlockingDepth             = 2
ImmediateBlockerSessionID = middle session
HeadBlockerSessionID      = head session
WaitType                  LIKE LCK_M_%
SampleCount               >= 3
RootCauseRole             = PRIMARY
Confidence                = HIGH

IMPORTANT
---------
Run each labeled section in a SEPARATE SSMS window exactly as instructed.
Do not execute this entire file as one batch because the test requires
concurrent sessions.
==============================================================================*/


/*==============================================================================
0. BUILD CONTROLLED TEST OBJECTS
Run this setup section once.
==============================================================================*/

DROP TABLE IF EXISTS dbo.RCA_Run7B_Blocking;
GO

CREATE TABLE dbo.RCA_Run7B_Blocking
(
      BlockingID int NOT NULL
          CONSTRAINT PK_RCA_Run7B_Blocking PRIMARY KEY
    , StatusCode int NOT NULL
    , Amount decimal(19,4) NOT NULL
    , Payload char(200) NOT NULL
);
GO

INSERT dbo.RCA_Run7B_Blocking
(
      BlockingID
    , StatusCode
    , Amount
    , Payload
)
VALUES
      (1,0,100.00,REPLICATE('A',200))
    , (2,0,200.00,REPLICATE('B',200));
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7B_HeadBlocker
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Run7B_Blocking
       SET StatusCode = StatusCode + 100
     WHERE BlockingID = 1;

    SELECT
          Role      = 'RUN7B_HEAD_BLOCKER'
        , SessionID = @@SPID
        , TranCount = @@TRANCOUNT;

    /*
      Hold row 1 long enough for the middle session to block behind us,
      and for the victim to block behind the middle session.
    */
    WAITFOR DELAY '00:01:00';

    ROLLBACK;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7B_MiddleBlocker
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRAN;

    /*
      First acquire an X lock on row 2.
      This lock remains owned while this session later blocks on row 1.
    */
    UPDATE dbo.RCA_Run7B_Blocking
       SET StatusCode = StatusCode + 10
     WHERE BlockingID = 2;

    SELECT
          Role      = 'RUN7B_MIDDLE_BLOCKER'
        , SessionID = @@SPID
        , TranCount = @@TRANCOUNT;

    /*
      Now request row 1.
      The head blocker already owns row 1, so this session should suspend.
      While suspended, it still owns the row-2 lock.
    */
    UPDATE dbo.RCA_Run7B_Blocking
       SET StatusCode = StatusCode + 1
     WHERE BlockingID = 1;

    /*
      After the head blocker releases row 1, keep this transaction open
      briefly so the victim remains blocked long enough to be observable.
    */
    WAITFOR DELAY '00:00:15';

    ROLLBACK;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7B_Victim
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          Role      = 'RUN7B_VICTIM'
        , SessionID = @@SPID;

    /*
      Row 2 is locked by the middle blocker.
      This should wait behind Session B.
    */
    UPDATE dbo.RCA_Run7B_Blocking
       SET Amount = Amount + 1.00
     WHERE BlockingID = 2;

    SELECT
          BlockingID
        , StatusCode
        , Amount
    FROM dbo.RCA_Run7B_Blocking
    WHERE BlockingID = 2;
END;
GO


SELECT
      TableExists =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Run7B_Blocking',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HeadBlockerProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7B_HeadBlocker',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , MiddleBlockerProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7B_MiddleBlocker',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , VictimProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7B_Victim',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
WINDOW 1 - START CAPTURE
Run this first and record the returned CaptureRunID.
==============================================================================*/

USE DBA;
GO

DECLARE @RunID bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason =
        N'Run 7B - multi-level blocking / wait-chain validation',
     @CaptureRunID = @RunID OUTPUT;

SELECT
      @RunID AS CaptureRunID
    , 'STARTED' AS Run7BStatus;
GO


/*==============================================================================
WINDOW 2 - SAMPLER
Open a SECOND SSMS window.
Replace <RUN7B_ID> with the CaptureRunID returned above.

Start this and leave it running.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID = <RUN7B_ID>,
     @DurationMinutes = 3,
     @SampleSeconds = 5;
GO


/*==============================================================================
WINDOW 3 - HEAD BLOCKER
Open a THIRD SSMS window.
Start this AFTER Window 2 is visibly executing.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7B_HeadBlocker;
GO


/*==============================================================================
WINDOW 4 - MIDDLE BLOCKER
Open a FOURTH SSMS window.

Start this about 5 seconds AFTER the head blocker begins.
This window should return its SessionID, then appear to hang on the second
UPDATE because row 1 is locked by the head blocker.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7B_MiddleBlocker;
GO


/*==============================================================================
WINDOW 5 - VICTIM
Open a FIFTH SSMS window.

Start this about 5 seconds AFTER Window 4 becomes blocked.
This should appear to hang because row 2 is locked by the middle blocker.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7B_Victim;
GO


/*==============================================================================
WINDOW 6 - OPTIONAL LIVE PROOF
Run while both middle and victim sessions are suspended.
==============================================================================*/

USE master;
GO

SELECT
      r.session_id
    , r.status
    , r.command
    , r.wait_type
    , r.wait_time
    , r.blocking_session_id
    , DB_NAME(r.database_id) AS DatabaseName
    , s.open_transaction_count
    , s.host_name
    , s.program_name
    , s.login_name
    , txt.text AS RunningBatch
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt
WHERE r.blocking_session_id > 0
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


/*==============================================================================
EXPECTED LIVE SHAPE

Example only:

session_id  wait_type  blocking_session_id
----------  ---------  -------------------
56          NULL       0       <-- HEAD
67          LCK_M_X    56      <-- MIDDLE
72          LCK_M_X    67      <-- VICTIM

The actual session IDs will differ.
==============================================================================*/


/*==============================================================================
WAIT FOR COMPLETION
-------------------
1. Let the head blocker finish its 60-second WAITFOR and roll back.
2. The middle blocker will acquire row 1, then deliberately wait another
   15 seconds while still holding row 2.
3. The middle blocker rolls back.
4. The victim completes.
5. Let the sampler finish its 3-minute run.
==============================================================================*/


/*==============================================================================
WINDOW 1 - STOP CAPTURE
Only after blocker/middle/victim are complete.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID = <RUN7B_ID>;
GO


/*==============================================================================
IMPORT
==============================================================================*/

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID = <RUN7B_ID>;
GO


/*==============================================================================
ANALYZE EXISTING RCA EVIDENCE
==============================================================================*/

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID = <RUN7B_ID>,
     @Reparse = 1;
GO


/*==============================================================================
RUN BLOCKING DETECTOR EXPLICITLY
==============================================================================*/

EXEC dbo.usp_RCA_BuildBlockingEvidence
     @CaptureRunID = <RUN7B_ID>;
GO


/*==============================================================================
1. RAW SAMPLER PROOF
==============================================================================*/

SELECT
      CaptureTimeUTC
    , SessionID
    , Status
    , Command
    , WaitType
    , WaitTimeMs
    , BlockingSessionID
    , DatabaseName
    , ElapsedMs
    , HostName
    , ProgramName
    , LoginName
    , RunningStatement
FROM dbo.RCA_LiveRequestSnapshot
WHERE CaptureRunID = <RUN7B_ID>
  AND
  (
       ISNULL(BlockingSessionID,0) > 0
       OR SessionID IN
          (
              SELECT BlockingSessionID
              FROM dbo.RCA_LiveRequestSnapshot
              WHERE CaptureRunID = <RUN7B_ID>
                AND ISNULL(BlockingSessionID,0) > 0
          )
  )
ORDER BY CaptureTimeUTC,SessionID;
GO


/*==============================================================================
2. MULTI-HOP BLOCKING EVIDENCE
==============================================================================*/

SELECT
      BlockingEvidenceID
    , CaptureRunID
    , VictimSessionID
    , VictimExecutionEvidenceID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , BlockingDepth
    , WaitType
    , WaitDurationMs
    , FirstObservedUTC
    , LastObservedUTC
    , SampleCount
    , VictimDatabaseName
    , VictimHostName
    , VictimProgramName
    , VictimLoginName
    , VictimStatement
    , BlockerHostName
    , BlockerProgramName
    , BlockerLoginName
    , BlockerStatement
    , HeadBlockerHostName
    , HeadBlockerProgramName
    , HeadBlockerLoginName
    , HeadBlockerStatement
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
FROM dbo.vw_RCA_BlockingEvidence
WHERE CaptureRunID = <RUN7B_ID>
ORDER BY
      BlockingDepth DESC
    , VictimSessionID;
GO


/*==============================================================================
3. DEPTH-2 ACCEPTANCE TEST

We specifically require a victim whose immediate blocker differs from the
head blocker and whose chain depth is at least 2.
==============================================================================*/

SELECT
      CaptureRunID = <RUN7B_ID>

    , BlockingCases =
        COUNT(*)

    , Depth2OrGreaterCases =
        SUM
        (
            CASE
                WHEN BlockingDepth >= 2
                THEN 1 ELSE 0
            END
        )

    , CorrectMultiHopCases =
        SUM
        (
            CASE
                WHEN BlockingDepth >= 2
                 AND ImmediateBlockerSessionID IS NOT NULL
                 AND HeadBlockerSessionID IS NOT NULL
                 AND ImmediateBlockerSessionID <>
                     HeadBlockerSessionID
                THEN 1 ELSE 0
            END
        )

    , PrimaryCases =
        SUM
        (
            CASE
                WHEN RootCauseRole='PRIMARY'
                THEN 1 ELSE 0
            END
        )

    , HighConfidenceCases =
        SUM
        (
            CASE
                WHEN Confidence='HIGH'
                THEN 1 ELSE 0
            END
        )

    , PersistentCases =
        SUM
        (
            CASE
                WHEN SampleCount >= 3
                THEN 1 ELSE 0
            END
        )

    , MaxBlockingDepth =
        MAX(BlockingDepth)

    , MaxSamples =
        MAX(SampleCount)

    , MaxObservedWaitMs =
        MAX(WaitDurationMs)

FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = <RUN7B_ID>;
GO


/*==============================================================================
4. PASS / FAIL

The key requirement is one HIGH-confidence PRIMARY depth-2 chain whose
immediate blocker is NOT the head blocker.
==============================================================================*/

SELECT
    Run7B =
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM dbo.RCA_BlockingEvidence
            WHERE CaptureRunID = <RUN7B_ID>
              AND RootCauseRole = 'PRIMARY'
              AND Confidence = 'HIGH'
              AND BlockingDepth >= 2
              AND ImmediateBlockerSessionID IS NOT NULL
              AND HeadBlockerSessionID IS NOT NULL
              AND ImmediateBlockerSessionID <>
                  HeadBlockerSessionID
              AND WaitType LIKE 'LCK[_]M[_]%'
              AND SampleCount >= 3
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END;
GO


/*==============================================================================
5. BLOCKING-SPECIFIC SYNTHESIS
==============================================================================*/

EXEC dbo.usp_RCA_ApplyBlockingSynthesis
     @CaptureRunID = <RUN7B_ID>;
GO


/*==============================================================================
EXPECTED RCA STORY
------------------

PRIMARY CAUSE:
Blocking / wait-chain contention.

EXPECTED TOPOLOGY:

Victim
   |
   | LCK_M_X
   v
Middle Blocker
   |
   | LCK_M_X
   v
Head Blocker

The detector must NOT incorrectly report the middle blocker as the head
blocker for the downstream victim.

For the downstream victim:
    BlockingDepth >= 2
    ImmediateBlockerSessionID <> HeadBlockerSessionID
    RootCauseRole = PRIMARY
    Confidence = HIGH
==============================================================================*/
