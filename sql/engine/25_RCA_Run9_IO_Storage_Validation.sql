USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
25_RCA_Run9_IO_Storage_Validation.sql

PURPOSE
-------
Controlled I/O-pressure validation.

DESIGN
------
- Reuse RCA_Run8_CPU as a large source table.
- Force cold-cache reads in the lab.
- Run several concurrent serial scans to create physical I/O.
- Run the new independent I/O sampler alongside the proven RCA sampler.

IMPORTANT
---------
LAB ONLY.
DBCC DROPCLEANBUFFERS affects the SQL Server instance buffer pool.
Do NOT use this validation harness on production.

EXPECTED
--------
The first pass is primarily to prove:
1. File-level deltas are captured correctly.
2. Physical read volume is attributed to the RCA data file.
3. The detector does NOT falsely call storage latency if latency remains low.

If the local SSD remains fast, the acceptance result may correctly be REVIEW
rather than PASS. We will not lower storage-latency thresholds just to force
a synthetic pass.
==============================================================================*/


/*==============================================================================
STEP 1 - PRE-FLIGHT
==============================================================================*/

SELECT
      SourceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Run8_CPU',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , SourceRows =
        CASE WHEN OBJECT_ID(N'dbo.RCA_Run8_CPU',N'U') IS NOT NULL
             THEN CONVERT(varchar(30),(SELECT COUNT_BIG(*) FROM dbo.RCA_Run8_CPU))
             ELSE '0' END;
GO


/*==============================================================================
STEP 2 - START NEW CAPTURE

Run and record the returned CaptureRunID.
==============================================================================*/

USE DBA;
GO

DECLARE @RunID bigint;

EXEC dbo.usp_RCA_StartCapture
     @CaptureReason=N'Run 9 - IO storage pressure validation',
     @CaptureRunID=@RunID OUTPUT;

SELECT
      @RunID AS CaptureRunID
    , 'STARTED' AS Run9Status;
GO


/*==============================================================================
STEP 3 - START BOTH SAMPLERS IN SEPARATE WINDOWS

WINDOW A - EXISTING RCA SAMPLER
Replace <RUN9_ID>.
==============================================================================*/
/*
USE DBA;
GO
EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID=<RUN9_ID>,
     @DurationMinutes=3,
     @SampleSeconds=5;
GO
*/


/*==============================================================================
WINDOW B - IO SAMPLER
==============================================================================*/
/*
USE DBA;
GO
EXEC dbo.usp_RCA_RunIOSampler
     @CaptureRunID=<RUN9_ID>,
     @DurationMinutes=3,
     @SampleSeconds=5;
GO
*/


/*==============================================================================
STEP 4 - COLD CACHE

LAB ONLY.
Run once after both samplers have started.
==============================================================================*/
/*
USE RCA;
GO
CHECKPOINT;
GO
DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
GO
*/


/*==============================================================================
STEP 5 - IO WORKLOAD

Open 6 separate SSMS windows and start this query in each.
The checksum forces the rows to be touched without returning millions of rows.
==============================================================================*/
/*
USE RCA;
GO

SELECT
      CheckValue = CHECKSUM_AGG
      (
          CHECKSUM
          (
                RowID
              , GroupID
              , SortKey
              , Amount
              , Payload
          )
      )
FROM dbo.RCA_Run8_CPU WITH (INDEX(0))
OPTION (MAXDOP 1, RECOMPILE);
GO
*/


/*==============================================================================
STEP 6 - LIVE FILE-IO PROOF

Run 20-30 seconds after workload launch.
==============================================================================*/
/*
USE DBA;
GO

SELECT TOP (40)
      CaptureTimeUTC
    , DatabaseName
    , LogicalFileName
    , FileTypeDesc
    , NumReads
    , BytesRead
    , IoStallReadMs
    , NumWrites
    , BytesWritten
    , IoStallWriteMs
FROM dbo.RCA_IOFileSnapshot
WHERE CaptureRunID=<RUN9_ID>
  AND DatabaseName='RCA'
ORDER BY
      CaptureTimeUTC DESC
    , FileID;
GO
*/


/*==============================================================================
STEP 7 - AFTER WORKLOAD AND BOTH SAMPLERS FINISH
==============================================================================*/
/*
USE DBA;
GO

EXEC dbo.usp_RCA_StopCapture
     @CaptureRunID=<RUN9_ID>;
GO

EXEC dbo.usp_RCA_ImportXE
     @CaptureRunID=<RUN9_ID>;
GO

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID=<RUN9_ID>;
GO

EXEC dbo.usp_RCA_BuildIOStorageEvidence
     @CaptureRunID=<RUN9_ID>;
GO
*/


/*==============================================================================
STEP 8 - EVIDENCE
==============================================================================*/
/*
SELECT *
FROM dbo.vw_RCA_IOStorageEvidence
WHERE CaptureRunID=<RUN9_ID>
ORDER BY
      CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END,
      CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
      DeltaReadMB DESC,
      DeltaWriteMB DESC;
GO
*/


/*==============================================================================
STEP 9 - ACCEPTANCE

PASS means real >=20ms average file latency was produced.
REVIEW with large I/O volume + low latency means the detector correctly did
NOT falsely blame storage.
==============================================================================*/
/*
SELECT
      Run9_IO_Latency =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_IOStorageEvidence
                WHERE CaptureRunID=<RUN9_ID>
                  AND RootCauseRole='PRIMARY'
                  AND Confidence IN ('HIGH','MEDIUM')
                  AND
                  (
                       ReadLatencyPressure=1
                       OR WriteLatencyPressure=1
                  )
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END
    , CorrectNoFalsePositive =
        CASE
            WHEN NOT EXISTS
            (
                SELECT 1
                FROM dbo.RCA_IOStorageEvidence
                WHERE CaptureRunID=<RUN9_ID>
                  AND
                  (
                       ReadLatencyPressure=1
                       OR WriteLatencyPressure=1
                  )
            )
            THEN 'PASS'
            ELSE 'N/A'
        END
    , MaxReadLatencyMs =
        (
            SELECT MAX(AvgReadLatencyMs)
            FROM dbo.RCA_IOStorageEvidence
            WHERE CaptureRunID=<RUN9_ID>
              AND DatabaseName='RCA'
        )
    , MaxWriteLatencyMs =
        (
            SELECT MAX(AvgWriteLatencyMs)
            FROM dbo.RCA_IOStorageEvidence
            WHERE CaptureRunID=<RUN9_ID>
              AND DatabaseName='RCA'
        )
    , ReadMB =
        (
            SELECT SUM(DeltaReadMB)
            FROM dbo.RCA_IOStorageEvidence
            WHERE CaptureRunID=<RUN9_ID>
              AND DatabaseName='RCA'
        );
GO
*/


/*==============================================================================
STEP 10 - FINAL CAUSE OUTPUT
==============================================================================*/
/*
SELECT *
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID=<RUN9_ID>
ORDER BY
      RoleRank,
      ConfidenceRank,
      ImpactRank,
      EvidenceStrengthRank;
GO

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=<RUN9_ID>,
     @IncludeTechnicalEvidence=1;
GO
*/
