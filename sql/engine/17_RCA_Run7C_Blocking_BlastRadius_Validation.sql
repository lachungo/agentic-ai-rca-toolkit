USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
17_RCA_Run7C_Blocking_BlastRadius_Validation.sql

PURPOSE
-------
Validate blocking blast-radius intelligence.

SCENARIO
--------
One head blocker holds an X lock on a known row.
Three victim sessions attempt to update that same row.

EXPECTED TOPOLOGY
-----------------
                 HEAD BLOCKER
                     |
          +----------+----------+
          |          |          |
        VICTIM 1   VICTIM 2   VICTIM 3

EXPECTED DETECTOR RESULT
------------------------
- Same HeadBlockerSessionID across all victim cases
- BlockingDepth = 1 for each victim
- WaitType LIKE LCK_M_%
- SampleCount >= 3 for each sustained victim
- RootCauseRole = PRIMARY
- Confidence = HIGH
- Blast radius = at least 3 distinct victims

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

DROP TABLE IF EXISTS dbo.RCA_Run7C_Blocking;
GO

CREATE TABLE dbo.RCA_Run7C_Blocking
(
      BlockingID int NOT NULL
          CONSTRAINT PK_RCA_Run7C_Blocking PRIMARY KEY
    , StatusCode int NOT NULL
    , Amount decimal(19,4) NOT NULL
    , Payload char(200) NOT NULL
);
GO

INSERT dbo.RCA_Run7C_Blocking
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


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7C_HeadBlocker
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRAN;

    UPDATE dbo.RCA_Run7C_Blocking
       SET StatusCode = StatusCode + 100
     WHERE BlockingID = 1;

    SELECT
          Role      = 'RUN7C_HEAD_BLOCKER'
        , SessionID = @@SPID
        , TranCount = @@TRANCOUNT;

    /*
      Hold long enough for three victims to queue and for the 5-second sampler
      to collect multiple observations.
    */
    WAITFOR DELAY '00:01:00';

    ROLLBACK;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7C_Victim
    @VictimLabel varchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          Role        = 'RUN7C_VICTIM'
        , VictimLabel = @VictimLabel
        , SessionID   = @@SPID;

    UPDATE dbo.RCA_Run7C_Blocking
       SET Amount = Amount + 1.00
     WHERE BlockingID = 1;

    SELECT
          VictimLabel = @VictimLabel
        , BlockingID
        , StatusCode
        , Amount
    FROM dbo.RCA_Run7C_Blocking
    WHERE BlockingID = 1;
END;
GO


SELECT
      TableExists =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Run7C_Blocking',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HeadBlockerProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7C_HeadBlocker',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , VictimProc =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7C_Victim',N'P') IS NOT NULL
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
        N'Run 7C - blocking blast-radius validation',
     @CaptureRunID = @RunID OUTPUT;

SELECT
      @RunID AS CaptureRunID
    , 'STARTED' AS Run7CStatus;
GO


/*==============================================================================
WINDOW 2 - SAMPLER
Open a SECOND SSMS window.
Replace <RUN7C_ID> with the CaptureRunID returned above.

Start this and leave it running.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID = <RUN7C_ID>,
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

EXEC dbo.usp_RCA_Run7C_HeadBlocker;
GO


/*==============================================================================
WINDOW 4 - VICTIM A
Start about 5 seconds after the head blocker.
This should hang until the blocker releases.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7C_Victim
     @VictimLabel='A';
GO


/*==============================================================================
WINDOW 5 - VICTIM B
Start about 2 seconds after Victim A.
This should also hang.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7C_Victim
     @VictimLabel='B';
GO


/*==============================================================================
WINDOW 6 - VICTIM C
Start about 2 seconds after Victim B.
This should also hang.
==============================================================================*/

USE RCA;
GO

EXEC dbo.usp_RCA_Run7C_Victim
     @VictimLabel='C';
GO


/*==============================================================================
WINDOW 7 - LIVE PROOF
Run while all three victims are blocked.
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
60          WAITFOR    0      <-- HEAD
71          LCK_M_X    60     <-- VICTIM A
72          LCK_M_X    60     <-- VICTIM B
73          LCK_M_X    60     <-- VICTIM C
==============================================================================*/


/*==============================================================================
WAIT FOR COMPLETION
-------------------
1. Let the head blocker finish its 60-second WAITFOR and roll back.
2. All three victims should complete.
3. Let the sampler finish its 3-minute run.
==============================================================================*/


/*==============================================================================
WINDOW 1 - STOP CAPTURE
Only after blocker and all three victims are complete.
==============================================================================*/

USE DBA;
GO

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID = <RUN7C_ID>;
GO


/*==============================================================================
IMPORT
==============================================================================*/

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID = <RUN7C_ID>;
GO


/*==============================================================================
ANALYZE EXISTING RCA EVIDENCE
==============================================================================*/

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID = <RUN7C_ID>,
     @Reparse = 1;
GO


/*==============================================================================
RUN BLOCKING DETECTOR EXPLICITLY
==============================================================================*/

EXEC dbo.usp_RCA_BuildBlockingEvidence
     @CaptureRunID = <RUN7C_ID>;
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
WHERE CaptureRunID = <RUN7C_ID>
  AND
  (
       ISNULL(BlockingSessionID,0) > 0
       OR SessionID IN
          (
              SELECT BlockingSessionID
              FROM dbo.RCA_LiveRequestSnapshot
              WHERE CaptureRunID = <RUN7C_ID>
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
    , RootCauseRole
    , Confidence
    , UpstreamCauseCategory
    , EvidenceSummary
FROM dbo.vw_RCA_BlockingEvidence
WHERE CaptureRunID = <RUN7C_ID>
ORDER BY HeadBlockerSessionID,VictimSessionID;
GO


/*==============================================================================
3. BLAST-RADIUS SUMMARY
==============================================================================*/

SELECT
      HeadBlockerSessionID
    , DistinctVictims =
        COUNT(DISTINCT VictimSessionID)
    , PrimaryVictims =
        SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
    , HighConfidenceVictims =
        SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
    , PersistentVictims =
        SUM(CASE WHEN SampleCount>=3 THEN 1 ELSE 0 END)
    , MaxObservedWaitMs =
        MAX(WaitDurationMs)
    , MaxSampleCount =
        MAX(SampleCount)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = <RUN7C_ID>
GROUP BY HeadBlockerSessionID
ORDER BY DistinctVictims DESC,HeadBlockerSessionID;
GO


/*==============================================================================
4. ACCEPTANCE TEST
==============================================================================*/

;WITH BlastRadius AS
(
    SELECT
          HeadBlockerSessionID
        , DistinctVictims =
            COUNT(DISTINCT VictimSessionID)
        , HighPrimaryPersistentVictims =
            SUM
            (
                CASE
                    WHEN RootCauseRole='PRIMARY'
                     AND Confidence='HIGH'
                     AND BlockingDepth=1
                     AND WaitType LIKE 'LCK[_]M[_]%'
                     AND SampleCount>=3
                     AND ImmediateBlockerSessionID=HeadBlockerSessionID
                    THEN 1 ELSE 0
                END
            )
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID = <RUN7C_ID>
    GROUP BY HeadBlockerSessionID
)
SELECT
    Run7C =
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM BlastRadius
            WHERE DistinctVictims>=3
              AND HighPrimaryPersistentVictims>=3
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END;
GO


/*==============================================================================
5. BLOCKING-SPECIFIC SYNTHESIS
==============================================================================*/

EXEC dbo.usp_RCA_ApplyBlockingSynthesis
     @CaptureRunID = <RUN7C_ID>;
GO


/*==============================================================================
EXPECTED RCA STORY
------------------

PRIMARY CAUSE:
Blocking / wait-chain contention.

EXPECTED BLAST RADIUS:
One head blocker caused at least three distinct application requests to wait.

EXPECTED TOPOLOGY:

             Head Blocker
             /    |    \
            /     |     \
        Victim A Victim B Victim C

The final output engine should eventually summarize these as ONE blocking
incident with multiple affected requests, not three unrelated root causes.
==============================================================================*/
