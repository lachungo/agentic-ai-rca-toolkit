USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  45_RCA_Capture39_End_to_End_Validation_v2.sql

  PURPOSE
  -------
  READ-ONLY validation of the EXISTING CaptureRunID 39.

  Capture 39 already completed successfully and contains real persisted blocking
  evidence.  This script does NOT generate another incident and does NOT modify
  any RCA evidence, detector thresholds, findings, root-cause logic, or capture
  state.

  POSITIVE-CONTROL QUESTION
  -------------------------
  Can the existing RCA engine distinguish:

      Capture 38:
          observed workload, but NO supported root cause

  from:

      Capture 39:
          sustained blocking / wait-chain evidence that SHOULD support
          BLOCKING_WAIT_CHAIN as a PRIMARY root cause?

  KNOWN CAPTURE 39 RAW EVIDENCE
  -----------------------------
      CaptureStatus              = ANALYZED
      Server snapshots           = 26
      Blocking evidence rows     = 1
      Victim session             = 74
      Immediate blocker          = 69
      Head blocker               = 69
      Wait type                  = LCK_M_X
      Blocking depth             = 1
      Sample count               = 8
      Max observed wait          = 35426 ms

  ACCEPTANCE TARGET
  -----------------
  The script does not inject this answer.  It verifies whether the current
  persisted RCA pipeline independently exposes:

      CauseCategory   = BLOCKING_WAIT_CHAIN
      RootCauseRole   = PRIMARY
      Confidence      = HIGH or MEDIUM
      Final UX verdict = ROOT CAUSE IDENTIFIED

  PRIMARY REPORT
  --------------
      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 39;

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max) = N'';
DECLARE @ErrorMessage nvarchar(2048);

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    SET @Missing += N' dbo.RCA_CaptureRun;';

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockingEvidence;';

IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ServerSnapshot;';

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ExecutionEvidence;';

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    SET @Missing += N' dbo.vw_RCA_FinalCauseRanking;';

IF OBJECT_ID(N'dbo.usp_RCA_FinalIncidentReport',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_FinalIncidentReport;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @ErrorMessage =
        CONCAT(N'Script 45 v2 prerequisites are missing:',@Missing);

    THROW 54520,@ErrorMessage,1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = 39
)
    THROW 54521,N'CaptureRunID 39 does not exist.',1;

SELECT
      ValidationSection = '0 - SCRIPT 45 v2 PRE-FLIGHT'
    , Capture39Exists = 'PASS'
    , BlockingEvidenceSource = 'PASS'
    , FinalCauseRanking = 'PASS'
    , FinalIncidentReport = 'PASS'
    , ReadOnlyValidation = 'YES'
    , ExistingEvidenceModified = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicPromoted = 'NO'
    , NewCaptureStarted = 'NO';
GO


/*==============================================================================
  1. CAPTURE 39 STATE
==============================================================================*/
SELECT
      ValidationSection = '1 - CAPTURE 39 STATE'
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
    , CreatedBy
    , StateValidation =
        CASE
          WHEN CaptureStatus = 'ANALYZED'
           AND EndTimeUTC IS NOT NULL
          THEN 'PASS - ANALYZED'
          ELSE 'REVIEW - CAPTURE IS NOT IN FINAL ANALYZED STATE'
        END
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID = 39;
GO


/*==============================================================================
  2. RAW EVIDENCE COUNTS
==============================================================================*/
SELECT
      ValidationSection = '2 - RAW EVIDENCE COUNTS'
    , CaptureRunID = 39
    , ServerSnapshotRows =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_ServerSnapshot
            WHERE CaptureRunID = 39
        )
    , ExecutionEvidenceRows =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_ExecutionEvidence
            WHERE CaptureRunID = 39
        )
    , BlockingEvidenceRows =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_BlockingEvidence
            WHERE CaptureRunID = 39
        )
    , FinalCauseRows =
        (
            SELECT COUNT(*)
            FROM dbo.vw_RCA_FinalCauseRanking
            WHERE CaptureRunID = 39
        );
GO


/*==============================================================================
  3. PERSISTED BLOCKING EVIDENCE

  This is the key positive-control evidence.  No synthesis is performed here.
==============================================================================*/
SELECT
      ValidationSection = '3 - PERSISTED BLOCKING EVIDENCE'
    , BlockingEvidenceID
    , CaptureRunID
    , VictimSessionID
    , VictimExecutionEvidenceID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , WaitType
    , WaitDurationMs
    , BlockingDepth
    , VictimDatabaseName
    , VictimHostName
    , VictimProgramName
    , VictimLoginName
    , SampleCount
    , RootCauseRole
    , Confidence
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = 39
ORDER BY
      CASE WHEN RootCauseRole = 'PRIMARY' THEN 1 ELSE 2 END
    , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
    , WaitDurationMs DESC
    , BlockingEvidenceID;
GO


/*==============================================================================
  4. RAW BLOCKING ACCEPTANCE

  This validates only the persisted causal pattern, independently of the final
  cause-ranking layer.
==============================================================================*/
DECLARE
      @BlockingRows int = 0
    , @LockWaitRows int = 0
    , @HeadBlockerRows int = 0
    , @RepeatedRows int = 0
    , @DepthRows int = 0
    , @MaxWaitMs bigint = 0
    , @MaxSampleCount int = 0
    , @MaxBlockingDepth int = 0;

SELECT
      @BlockingRows = COUNT(*)
    , @LockWaitRows =
        SUM(CASE WHEN WaitType LIKE 'LCK_M_%' THEN 1 ELSE 0 END)
    , @HeadBlockerRows =
        SUM
        (
            CASE
              WHEN HeadBlockerSessionID IS NOT NULL
               AND ImmediateBlockerSessionID IS NOT NULL
              THEN 1 ELSE 0
            END
        )
    , @RepeatedRows =
        SUM(CASE WHEN SampleCount >= 3 THEN 1 ELSE 0 END)
    , @DepthRows =
        SUM(CASE WHEN BlockingDepth >= 1 THEN 1 ELSE 0 END)
    , @MaxWaitMs = MAX(WaitDurationMs)
    , @MaxSampleCount = MAX(SampleCount)
    , @MaxBlockingDepth = MAX(BlockingDepth)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = 39;

SET @BlockingRows = ISNULL(@BlockingRows,0);
SET @LockWaitRows = ISNULL(@LockWaitRows,0);
SET @HeadBlockerRows = ISNULL(@HeadBlockerRows,0);
SET @RepeatedRows = ISNULL(@RepeatedRows,0);
SET @DepthRows = ISNULL(@DepthRows,0);
SET @MaxWaitMs = ISNULL(@MaxWaitMs,0);
SET @MaxSampleCount = ISNULL(@MaxSampleCount,0);
SET @MaxBlockingDepth = ISNULL(@MaxBlockingDepth,0);

SELECT
      ValidationSection = '4 - RAW BLOCKING ACCEPTANCE'
    , BlockingObserved =
        CASE WHEN @BlockingRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , LockWaitObserved =
        CASE WHEN @LockWaitRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , HeadBlockerIdentified =
        CASE WHEN @HeadBlockerRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , RepeatedSampling =
        CASE WHEN @RepeatedRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , BlockingDepth =
        CASE WHEN @DepthRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , MaxObservedWaitMs = @MaxWaitMs
    , MaxSampleCount = @MaxSampleCount
    , MaxBlockingDepth = @MaxBlockingDepth
    , RawEvidenceResult =
        CASE
          WHEN @BlockingRows > 0
           AND @LockWaitRows > 0
           AND @HeadBlockerRows > 0
           AND @RepeatedRows > 0
           AND @DepthRows > 0
          THEN 'PASS - SUSTAINED BLOCKING CAUSAL PATTERN CAPTURED'
          ELSE 'FAIL - RAW BLOCKING EVIDENCE IS INCOMPLETE'
        END;
GO


/*==============================================================================
  5. FINAL CAUSE RANKING

  This is the decisive engine-level result.  The view must expose the already
  supported root cause; this script does not insert or update anything.
==============================================================================*/
SELECT
      ValidationSection = '5 - FINAL CAUSE RANKING'
    , CaptureRunID
    , CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , CorrelationKey
    , ImpactedRequestCount
    , EvidenceCount
    , PrimaryEvidence
    , RecommendedAction
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID = 39
ORDER BY
      CASE WHEN RootCauseRole = 'PRIMARY' THEN 1 ELSE 2 END
    , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
    , EvidenceCount DESC
    , ImpactedRequestCount DESC;
GO


/*==============================================================================
  6. ENGINE ATTRIBUTION ACCEPTANCE
==============================================================================*/
DECLARE
      @AnyPrimary int = 0
    , @BlockingPrimary int = 0
    , @BlockingPrimaryHigh int = 0
    , @BlockingPrimaryMedium int = 0
    , @BlockingEvidenceCount int = 0
    , @BlockingImpactedRequests int = 0;

SELECT
      @AnyPrimary =
        SUM
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
              THEN 1 ELSE 0
            END
        )
    , @BlockingPrimary =
        SUM
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
               AND CauseCategory = 'BLOCKING_WAIT_CHAIN'
              THEN 1 ELSE 0
            END
        )
    , @BlockingPrimaryHigh =
        SUM
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence = 'HIGH'
               AND CauseCategory = 'BLOCKING_WAIT_CHAIN'
              THEN 1 ELSE 0
            END
        )
    , @BlockingPrimaryMedium =
        SUM
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence = 'MEDIUM'
               AND CauseCategory = 'BLOCKING_WAIT_CHAIN'
              THEN 1 ELSE 0
            END
        )
    , @BlockingEvidenceCount =
        MAX
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
               AND CauseCategory = 'BLOCKING_WAIT_CHAIN'
              THEN EvidenceCount
            END
        )
    , @BlockingImpactedRequests =
        MAX
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
               AND CauseCategory = 'BLOCKING_WAIT_CHAIN'
              THEN ImpactedRequestCount
            END
        )
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID = 39;

SET @AnyPrimary = ISNULL(@AnyPrimary,0);
SET @BlockingPrimary = ISNULL(@BlockingPrimary,0);
SET @BlockingPrimaryHigh = ISNULL(@BlockingPrimaryHigh,0);
SET @BlockingPrimaryMedium = ISNULL(@BlockingPrimaryMedium,0);
SET @BlockingEvidenceCount = ISNULL(@BlockingEvidenceCount,0);
SET @BlockingImpactedRequests = ISNULL(@BlockingImpactedRequests,0);

SELECT
      ValidationSection = '6 - ENGINE ATTRIBUTION ACCEPTANCE'
    , AnySupportedPrimaryCause =
        CASE WHEN @AnyPrimary > 0 THEN 'PASS' ELSE 'FAIL' END
    , BlockingWaitChainPrimary =
        CASE WHEN @BlockingPrimary > 0 THEN 'PASS' ELSE 'FAIL' END
    , HighConfidenceBlocking =
        CASE WHEN @BlockingPrimaryHigh > 0 THEN 'PASS' ELSE 'NOT HIGH' END
    , MediumConfidenceBlocking =
        CASE WHEN @BlockingPrimaryMedium > 0 THEN 'PASS' ELSE 'NOT MEDIUM' END
    , BlockingEvidenceCount = @BlockingEvidenceCount
    , ImpactedRequestCount = @BlockingImpactedRequests
    , AttributionResult =
        CASE
          WHEN @BlockingPrimaryHigh > 0
          THEN 'PASS - BLOCKING_WAIT_CHAIN IDENTIFIED AS PRIMARY / HIGH'
          WHEN @BlockingPrimaryMedium > 0
          THEN 'PASS - BLOCKING_WAIT_CHAIN IDENTIFIED AS PRIMARY / MEDIUM'
          WHEN @AnyPrimary > 0
          THEN 'REVIEW - A PRIMARY CAUSE EXISTS, BUT IT IS NOT BLOCKING_WAIT_CHAIN'
          ELSE 'FAIL - RAW BLOCKING EXISTS BUT FINAL CAUSE RANKING DID NOT PROMOTE A SUPPORTED PRIMARY CAUSE'
        END;
GO


/*==============================================================================
  7. CAPTURE 38 VS CAPTURE 39 CONTRAST

  This is the most important architecture test:
      38 should remain conservative.
      39 should positively identify blocking if the causal evidence warrants it.
==============================================================================*/
SELECT
      ValidationSection = '7 - NEGATIVE VS POSITIVE CONTROL'
    , CaptureRunID
    , SupportedPrimaryCauses =
        SUM
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
              THEN 1 ELSE 0
            END
        )
    , BlockingPrimaryCauses =
        SUM
        (
            CASE
              WHEN RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
               AND CauseCategory = 'BLOCKING_WAIT_CHAIN'
              THEN 1 ELSE 0
            END
        )
    , ExpectedBehavior =
        CASE
          WHEN CaptureRunID = 38
          THEN 'NEGATIVE CONTROL - NO SUPPORTED PRIMARY EXPECTED'
          WHEN CaptureRunID = 39
          THEN 'POSITIVE CONTROL - BLOCKING PRIMARY EXPECTED'
        END
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID IN (38,39)
GROUP BY CaptureRunID
ORDER BY CaptureRunID;
GO


/*==============================================================================
  8. CAPTURE 39 FINAL ACCEPTANCE GATE
==============================================================================*/
DECLARE
      @CaptureAnalyzed bit = 0
    , @Snapshots int = 0
    , @BlockingRows int = 0
    , @LockWaitRows int = 0
    , @RepeatedBlockingRows int = 0
    , @HeadBlockerRows int = 0
    , @BlockingPrimary int = 0
    , @BlockingHigh int = 0
    , @BlockingMedium int = 0;

SELECT
    @CaptureAnalyzed =
        CASE
          WHEN CaptureStatus = 'ANALYZED'
           AND EndTimeUTC IS NOT NULL
          THEN 1 ELSE 0
        END
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID = 39;

SELECT
    @Snapshots = COUNT(*)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID = 39;

SELECT
      @BlockingRows = COUNT(*)
    , @LockWaitRows =
        SUM(CASE WHEN WaitType LIKE 'LCK_M_%' THEN 1 ELSE 0 END)
    , @RepeatedBlockingRows =
        SUM(CASE WHEN SampleCount >= 3 THEN 1 ELSE 0 END)
    , @HeadBlockerRows =
        SUM
        (
            CASE
              WHEN HeadBlockerSessionID IS NOT NULL
               AND ImmediateBlockerSessionID IS NOT NULL
              THEN 1 ELSE 0
            END
        )
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID = 39;

SELECT
      @BlockingPrimary =
        SUM
        (
            CASE
              WHEN CauseCategory = 'BLOCKING_WAIT_CHAIN'
               AND RootCauseRole = 'PRIMARY'
               AND Confidence IN ('HIGH','MEDIUM')
              THEN 1 ELSE 0
            END
        )
    , @BlockingHigh =
        SUM
        (
            CASE
              WHEN CauseCategory = 'BLOCKING_WAIT_CHAIN'
               AND RootCauseRole = 'PRIMARY'
               AND Confidence = 'HIGH'
              THEN 1 ELSE 0
            END
        )
    , @BlockingMedium =
        SUM
        (
            CASE
              WHEN CauseCategory = 'BLOCKING_WAIT_CHAIN'
               AND RootCauseRole = 'PRIMARY'
               AND Confidence = 'MEDIUM'
              THEN 1 ELSE 0
            END
        )
FROM dbo.vw_RCA_FinalCauseRanking
WHERE CaptureRunID = 39;

SET @BlockingRows = ISNULL(@BlockingRows,0);
SET @LockWaitRows = ISNULL(@LockWaitRows,0);
SET @RepeatedBlockingRows = ISNULL(@RepeatedBlockingRows,0);
SET @HeadBlockerRows = ISNULL(@HeadBlockerRows,0);
SET @BlockingPrimary = ISNULL(@BlockingPrimary,0);
SET @BlockingHigh = ISNULL(@BlockingHigh,0);
SET @BlockingMedium = ISNULL(@BlockingMedium,0);

SELECT
      ValidationSection = '8 - CAPTURE 39 FINAL ACCEPTANCE'
    , CaptureAnalyzed =
        CASE WHEN @CaptureAnalyzed = 1 THEN 'PASS' ELSE 'FAIL' END
    , ServerSnapshots =
        CASE WHEN @Snapshots > 0 THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidence =
        CASE WHEN @BlockingRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , LockWait =
        CASE WHEN @LockWaitRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , RepeatedObservation =
        CASE WHEN @RepeatedBlockingRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , HeadBlocker =
        CASE WHEN @HeadBlockerRows > 0 THEN 'PASS' ELSE 'FAIL' END
    , BlockingPrimary =
        CASE WHEN @BlockingPrimary > 0 THEN 'PASS' ELSE 'FAIL' END
    , BlockingConfidence =
        CASE
          WHEN @BlockingHigh > 0 THEN 'HIGH'
          WHEN @BlockingMedium > 0 THEN 'MEDIUM'
          ELSE 'NOT SUPPORTED'
        END
    , OverallResult =
        CASE
          WHEN @CaptureAnalyzed = 1
           AND @Snapshots > 0
           AND @BlockingRows > 0
           AND @LockWaitRows > 0
           AND @RepeatedBlockingRows > 0
           AND @HeadBlockerRows > 0
           AND @BlockingPrimary > 0
          THEN 'PASS - FRESH END-TO-END ROOT CAUSE IDENTIFICATION'
          ELSE 'REVIEW - RAW EVIDENCE AND FINAL ATTRIBUTION DO NOT YET AGREE'
        END
    , SafetyInstruction =
        'If REVIEW, do not change thresholds. Identify the exact stage where persisted blocking stopped propagating.';
GO


/*==============================================================================
  9. FINAL USER EXPERIENCE

  This is the same final presentation procedure used for normal incidents.
  Expected positive-control presentation:
      Verdict      = ROOT CAUSE IDENTIFIED
      PrimaryCause = Blocking / wait-chain contention
      Confidence   = HIGH or MEDIUM
==============================================================================*/
EXEC dbo.usp_RCA_FinalIncidentReport
     @CaptureRunID = 39,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  10. SAFETY / INTEGRITY
==============================================================================*/
SELECT
      ValidationSection = '10 - SCRIPT 45 v2 SAFETY'
    , CaptureRunID = 39
    , ExistingCaptureReused = 'YES'
    , NewCaptureStarted = 'NO'
    , ControlledWorkloadStarted = 'NO'
    , SourceXEDefinitionChanged = 'NO'
    , ExistingEvidenceModified = 'NO'
    , BlockingEvidenceRebuilt = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicPromoted = 'NO'
    , ManualCauseInserted = 'NO'
    , FinalReportModified = 'NO'
    , ValidationMode = 'READ ONLY'
    , NextStep =
        'If Section 8 passes and the final report says ROOT CAUSE IDENTIFIED for blocking, Capture 39 becomes the first positive-control validation artifact. If it does not, inspect the propagation gap without weakening detector thresholds.';
GO


/*==============================================================================
  OPTIONAL TECHNICAL DRILL-DOWN
  -----------------------------
      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;

  IMPORTANT
  ---------
  Do not delete Capture 39 evidence.  It is the first fresh post-hardening
  positive-control incident and should remain available for regression testing.
==============================================================================*/
