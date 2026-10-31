
USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
16_RCA_Run7_Blocking_Validation.sql

Run 7A: simple blocking
Run 7B: multi-hop blocking

Use separate SSMS windows exactly as labeled below.
==============================================================================*/

DROP TABLE IF EXISTS dbo.RCA_Run7_Blocking;
GO

CREATE TABLE dbo.RCA_Run7_Blocking
(
      BlockingID int NOT NULL CONSTRAINT PK_RCA_Run7_Blocking PRIMARY KEY
    , StatusCode int NOT NULL
    , Amount decimal(19,4) NOT NULL
    , Payload char(200) NOT NULL
);
GO

INSERT dbo.RCA_Run7_Blocking(BlockingID,StatusCode,Amount,Payload)
VALUES
(1,0,100.00,REPLICATE('A',200)),
(2,0,200.00,REPLICATE('B',200)),
(3,0,300.00,REPLICATE('C',200));
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7_ReadVictim
    @BlockingID int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT BlockingID,StatusCode,Amount,Payload
    FROM dbo.RCA_Run7_Blocking
    WHERE BlockingID=@BlockingID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run7_UpdateMiddle
    @BlockingID int
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.RCA_Run7_Blocking
       SET StatusCode=StatusCode+1
    WHERE BlockingID=@BlockingID;
END;
GO

SELECT
    TableRows=(SELECT COUNT_BIG(*) FROM dbo.RCA_Run7_Blocking),
    VictimProc=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7_ReadVictim',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    MiddleProc=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Run7_UpdateMiddle',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

/*==============================================================================
WINDOW 1 - START CAPTURE
==============================================================================*/
USE DBA;
GO
DECLARE @RunID bigint;
EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 7 - blocking / wait-chain validation',
     @CaptureRunID=@RunID OUTPUT;
SELECT @RunID AS CaptureRunID;
GO

/*==============================================================================
WINDOW 2 - SAMPLER
Replace <RUN7_ID>.
==============================================================================*/
USE DBA;
GO
EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID=<RUN7_ID>,
     @DurationMinutes=5,
     @SampleSeconds=5;
GO

/*==============================================================================
RUN 7A - SIMPLE BLOCKING
WINDOW 3 - BLOCKER
==============================================================================*/
USE RCA;
GO
BEGIN TRAN;
UPDATE dbo.RCA_Run7_Blocking
   SET StatusCode=StatusCode+10
WHERE BlockingID=1;

SELECT @@SPID AS Run7A_BlockerSPID;
WAITFOR DELAY '00:00:45';
ROLLBACK;
GO

/*==============================================================================
RUN 7A - SIMPLE BLOCKING
WINDOW 4 - VICTIM
Start this a few seconds AFTER Window 3 begins waiting.
==============================================================================*/
USE RCA;
GO
SELECT @@SPID AS Run7A_VictimSPID;
EXEC dbo.usp_RCA_Run7_ReadVictim @BlockingID=1;
GO

/*==============================================================================
RUN 7B - MULTI-HOP
WINDOW 3 - HEAD BLOCKER
==============================================================================*/
USE RCA;
GO
BEGIN TRAN;
UPDATE dbo.RCA_Run7_Blocking
   SET StatusCode=StatusCode+100
WHERE BlockingID=2;

SELECT @@SPID AS Run7B_HeadBlockerSPID;
WAITFOR DELAY '00:01:00';
ROLLBACK;
GO

/*==============================================================================
RUN 7B - MULTI-HOP
WINDOW 4 - MIDDLE SESSION
Start a few seconds AFTER head blocker begins waiting.
This session first locks row 3, then blocks trying to update row 2.
==============================================================================*/
USE RCA;
GO
BEGIN TRAN;

UPDATE dbo.RCA_Run7_Blocking
   SET StatusCode=StatusCode+1
WHERE BlockingID=3;

SELECT @@SPID AS Run7B_MiddleSPID;

UPDATE dbo.RCA_Run7_Blocking
   SET StatusCode=StatusCode+1
WHERE BlockingID=2;

ROLLBACK;
GO

/*==============================================================================
RUN 7B - MULTI-HOP
WINDOW 5 - VICTIM
Start while middle session is blocked on row 2.
Victim tries to read row 3 and should block behind the middle session.
==============================================================================*/
USE RCA;
GO
SELECT @@SPID AS Run7B_VictimSPID;
EXEC dbo.usp_RCA_Run7_ReadVictim @BlockingID=3;
GO

/*==============================================================================
WINDOW 1 - STOP / IMPORT / ANALYZE
==============================================================================*/
USE DBA;
GO
EXEC dbo.usp_RCA_StopCapture @CaptureRunID=<RUN7_ID>;
GO
EXEC dbo.usp_RCA_ImportXE @CaptureRunID=<RUN7_ID>;
GO
EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID=<RUN7_ID>,
     @Reparse=1;
GO

/*==============================================================================
VALIDATION
==============================================================================*/
SELECT *
FROM dbo.vw_RCA_BlockingEvidence
WHERE CaptureRunID=<RUN7_ID>
ORDER BY BlockingDepth DESC,VictimSessionID;
GO

SELECT
      CaptureRunID=<RUN7_ID>
    , BlockingCases=COUNT(*)
    , PrimaryCases=SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
    , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
    , MaxBlockingDepth=MAX(BlockingDepth)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=<RUN7_ID>;
GO

EXEC dbo.usp_RCA_ShowIncidentReport
     @CaptureRunID=<RUN7_ID>,
     @IncludeTechnicalEvidence=1;
GO

/* EXPECTED:
   Run 7A: PRIMARY/HIGH blocking case with depth >= 1.
   Run 7B: PRIMARY/HIGH case with depth >= 2 and correct HeadBlockerSessionID.
*/
