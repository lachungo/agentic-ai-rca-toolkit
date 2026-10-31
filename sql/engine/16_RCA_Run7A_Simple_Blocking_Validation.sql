USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
16_RCA_Run7A_Simple_Blocking_Validation.sql

PURPOSE
-------
Controlled validation of the blocking/wait-chain detector.

SCENARIO
--------
One head blocker holds an X lock on a known row.
One victim attempts to update the same row and waits on LCK_M_X.
The existing RCA sampler captures the blocking relationship every 5 seconds.

EXPECTED
--------
- One primary blocking case
- HIGH confidence
- BlockingDepth = 1
- VictimSessionID <> HeadBlockerSessionID
- ImmediateBlockerSessionID = HeadBlockerSessionID
- WaitType LIKE LCK_M_%
- SampleCount >= 3
- Blocking evidence links to victim execution evidence when available
==============================================================================*/


/*==============================================================================
0. BUILD CONTROLLED TEST OBJECT
==============================================================================*/

DROP TABLE IF EXISTS dbo.RCA_Run7A_Blocking;
GO

CREATE TABLE dbo.RCA_Run7A_Blocking
(
      BlockingID int NOT NULL
          CONSTRAINT PK_RCA_Run7A_Blocking PRIMARY KEY
    , StatusCode int NOT NULL
    , Amount decimal(19,4) NOT NULL
    , Payload char(200) NOT NULL
);
GO

INSERT dbo.RCA_Run7A_Blocking
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
    , REPLICATE('A',200)
);
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7A_Blocker
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Run7A_Blocking
       SET StatusCode = StatusCode + 10
     WHERE BlockingID = 1;

    SELECT
          Role = 'RUN7A_HEAD_BLOCKER'
        , SessionID = @@SPID
        , TranCount = @@TRANCOUNT;

    /*
      Hold the X lock long enough for the 5-second sampler to observe
      multiple blocking snapshots.
    */
    WAITFOR DELAY '00:00:45';

    ROLLBACK;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7A_Victim
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          Role = 'RUN7A_VICTIM'
        , SessionID = @@SPID;

    UPDATE dbo.RCA_Run7A_Blocking
       SET Amount = Amount + 1.00
     WHERE BlockingID = 1;

    SELECT
          BlockingID
        , StatusCode
        , Amount
    FROM dbo.RCA_Run7A_Blocking
    WHERE BlockingID = 1;
END;
GO


SELECT
      TableExists =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Run7A_Blocking',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockerProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7A_Blocker',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , VictimProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7A_Victim',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
WINDOW 1 - START CAPTURE

Run this first.
Write down the returned CaptureRunID.
==============================================================================*/

USE DBA;
GO

DECLARE @RunID bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason =
        N'Run 7A - simple blocking / wait-chain validation',
     @CaptureRunID = @RunID OUTPUT;

SELECT
      @RunID AS CaptureRunID
    , 'STARTED' AS Run7AStatus;
GO


/*==============================================================================
WINDOW 2 - START SAMPLER

Open a SECOND SSMS window.
Replace <RUN7A_ID> with the CaptureRunID returned above.

Leave this running.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID = <RUN7A_ID>,
     @DurationMinutes = 2,
     @SampleSeconds = 5;
GO


/*==============================================================================
WINDOW 3 - HEAD BLOCKER

Open a THIRD SSMS window.

Start this AFTER the sampler is running.
This procedure waits 45 seconds while holding an X lock.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7A_Blocker;
GO


/*==============================================================================
WINDOW 4 - VICTIM

Open a FOURTH SSMS window.

Start this about 5 seconds AFTER Window 3 begins.
This window SHOULD APPEAR TO HANG until the blocker rolls back.
That is expected.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7A_Victim;
GO


/*==============================================================================
OPTIONAL LIVE PROOF

While Window 4 is blocked, run this in a FIFTH window.
This is read-only.
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
    , s.host_name
    , s.program_name
    , s.login_name
    , txt.text AS RunningBatch
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


/*==============================================================================
WAIT FOR COMPLETION

Do not stop capture immediately.

Let:
1. blocker finish its 45-second WAITFOR and ROLLBACK;
2. victim complete;
3. sampler collect at least a few more snapshots.

The 2-minute sampler may still be running. That is okay.
You may wait for it to finish before continuing.
==============================================================================*/


/*==============================================================================
WINDOW 1 - STOP CAPTURE

Only after blocker/victim are complete.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID = <RUN7A_ID>;
GO


/*==============================================================================
IMPORT
==============================================================================*/

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID = <RUN7A_ID>;
GO


/*==============================================================================
ANALYZE EXISTING RCA EVIDENCE

Reparse=1 imports/parses the execution/plan evidence exactly as in prior runs.
==============================================================================*/

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID = <RUN7A_ID>,
     @Reparse = 1;
GO


/*==============================================================================
RUN THE NEW BLOCKING DETECTOR EXPLICITLY

We are keeping Run 7A independent from the global orchestration until the
detector proves itself.
==============================================================================*/

EXEC dbo.usp_RCA_BuildBlockingEvidence
     @CaptureRunID = <RUN7A_ID>;
GO


/*==============================================================================
1. RAW SAMPLER PROOF
==============================================================================*/

SELECT
      CaptureTimeUTC
    , SessionID
    , DatabaseName
    , Status
    , Command
    , WaitType
    , WaitTimeMs
    , BlockingSessionID
    , CPUms
    , ElapsedMs
    , HostName
    , ProgramName
    , LoginName
    , RunningStatement
FROM dbo.RCA_LiveRequestSnapshot
WHERE CaptureRunID = <RUN7A_ID>
  AND
  (
       ISNULL(BlockingSessionID,0) > 0
       OR SessionID IN
          (
              SELECT BlockingSessionID
              FROM dbo.RCA_LiveRequestSnapshot
              WHERE CaptureRunID = <RUN7A_ID>
                AND ISNULL(BlockingSessionID,0) > 0
          )
  )
ORDER BY CaptureTimeUTC,SessionID;
GO


/*==============================================================================
2. BLOCKING EVIDENCE
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
    , HeadBlockerHostName
    , HeadBlockerProgramName
    , HeadBlockerLoginName
    , HeadBlockerStatement
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
FROM dbo.vw_RCA_BlockingEvidence
WHERE CaptureRunID = <RUN7A_ID>
ORDER BY
      CASE RootCauseRole
          WHEN 'PRIMARY' THEN 1
          ELSE 2
      END
    , CASE Confidence
          WHEN 'HIGH' THEN 1
          WHEN 'MEDIUM' THEN 2
          ELSE 3
      END
    , VictimSessionID;
GO


/*==============================================================================
3. DETECTOR ACCEPTANCE TEST
==============================================================================*/

SELECT
      CaptureRunID = <RUN7A_ID>

    , BlockingCases =
        COUNT(*)

    , PrimaryCases =
        SUM
        (
            CASE
                WHEN RootCauseRole = 'PRIMARY'
                THEN 1 ELSE 0
            END
        )

    , HighConfidenceCases =
        SUM
        (
            CASE
                WHEN Confidence = 'HIGH'
                THEN 1 ELSE 0
            END
        )

    , Depth1Cases =
        SUM
        (
            CASE
                WHEN BlockingDepth = 1
                THEN 1 ELSE 0
            END
        )

    , LockWaitCases =
        SUM
        (
            CASE
                WHEN WaitType LIKE 'LCK[_]M[_]%'
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

    , CorrectHeadBlockerCases =
        SUM
        (
            CASE
                WHEN ImmediateBlockerSessionID =
                     HeadBlockerSessionID
                THEN 1 ELSE 0
            END
        )

FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = <RUN7A_ID>;
GO


/*==============================================================================
4. PASS / FAIL
==============================================================================*/

SELECT
    Run7A =
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM dbo.RCA_BlockingEvidence
            WHERE CaptureRunID = <RUN7A_ID>

              AND RootCauseRole = 'PRIMARY'

              AND Confidence = 'HIGH'

              AND BlockingDepth = 1

              AND ImmediateBlockerSessionID =
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
     @CaptureRunID = <RUN7A_ID>;
GO


/*==============================================================================
EXPECTED RCA STORY
------------------
PRIMARY CAUSE:
Blocking / wait-chain contention.

WHY:
The victim session repeatedly waited on a SQL Server lock wait.
The same immediate blocker was also the terminal/head blocker.
The condition persisted across multiple sampler snapshots.

EXPECTED SHAPE:
Victim
   ↓ LCK_M_X
Head Blocker

BlockingDepth = 1
Confidence    = HIGH
RootCauseRole = PRIMARY
==============================================================================*/
