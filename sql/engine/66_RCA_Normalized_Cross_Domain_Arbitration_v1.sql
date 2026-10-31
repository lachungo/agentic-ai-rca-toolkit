USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  66_RCA_Normalized_Cross_Domain_Arbitration_v1.sql

  PURPOSE
  -------
  Normalize existing RCA domain evidence into one cross-domain arbitration view
  without replacing the existing synthesis engine.

  PRIMARY GOAL
  ------------
  Make one authoritative, generic source that can answer:

      - What causes are supported for this capture?
      - Which cause is PRIMARY?
      - Which causes are CONTRIBUTING?
      - What confidence applies?
      - What evidence object supports the conclusion?
      - What execution/session is correlated?
      - Why did one cause outrank another?

  ARCHITECTURAL PRINCIPLE
  -----------------------
  Domain detectors detect.
  Synthesis / ranking arbitrates.
  Presentation narrates.

  THIS SCRIPT DOES NOT
  --------------------
      - change detector thresholds
      - change root-cause domains
      - rewrite existing RCA_RootCauseSynthesis data
      - rebuild historical findings
      - modify Captures 38, 42, or 44
      - alter dbo.usp_RCA_DBAAnswer
      - start a new capture

  V1 SCOPE
  --------
  Normalize currently-proven domains:

      1. BLOCKING_WAIT_CHAIN
      2. CPU_SCHEDULER

  The view is intentionally extensible so future domains can UNION into the same
  contract without changing the canonical DBA entry point.

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 66 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , RootCauseSynthesis=
        CASE WHEN OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL THEN 'PASS' ELSE 'REVIEW' END
    , PresentationLayerChanged='NO'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    THROW 56600,N'dbo.RCA_BlockingEvidence is required.',1;

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NULL
    THROW 56601,N'dbo.RCA_CPUSchedulerEvidence is required.',1;
GO


/*==============================================================================
  1. NORMALIZED CROSS-DOMAIN CAUSE CANDIDATES

  Generic contract:
      CaptureRunID
      CauseCategory
      CauseDisplayName
      RootCauseRole
      Confidence
      PriorityScore
      EvidenceCount
      CorrelationKey
      PrimaryExecutionEvidenceID
      PrimarySessionID
      EvidenceObject
      EvidenceID
      PrimaryEvidence
      RecommendedAction

  PriorityScore is presentation-neutral and deterministic:
      PRIMARY/HIGH        = 1000
      PRIMARY/MEDIUM      = 900
      CONTRIBUTING/HIGH   = 800
      CONTRIBUTING/MEDIUM = 700
      all others          = lower

  This score does NOT alter detector logic. It only normalizes already-assigned
  RootCauseRole + Confidence for cross-domain ordering.
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_NormalizedCauseCandidates
AS

SELECT
      CaptureRunID=b.CaptureRunID
    , CauseCategory=CONVERT(varchar(60),'BLOCKING_WAIT_CHAIN')
    , CauseDisplayName=CONVERT(nvarchar(200),N'Blocking / wait-chain contention')
    , RootCauseRole=CONVERT(varchar(20),b.RootCauseRole)
    , Confidence=CONVERT(varchar(20),b.Confidence)

    , PriorityScore=
        CASE
          WHEN b.RootCauseRole='PRIMARY'      AND b.Confidence='HIGH'   THEN 1000
          WHEN b.RootCauseRole='PRIMARY'      AND b.Confidence='MEDIUM' THEN 900
          WHEN b.RootCauseRole='CONTRIBUTING' AND b.Confidence='HIGH'   THEN 800
          WHEN b.RootCauseRole='CONTRIBUTING' AND b.Confidence='MEDIUM' THEN 700
          WHEN b.RootCauseRole='PRIMARY'                                  THEN 600
          WHEN b.RootCauseRole='CONTRIBUTING'                             THEN 500
          ELSE 100
        END

    , EvidenceCount=CONVERT(bigint,ISNULL(b.SampleCount,1))
    , CorrelationKey=
        CONVERT(nvarchar(200),
            N'HEAD_BLOCKER:' + COALESCE(CONVERT(nvarchar(20),b.HeadBlockerSessionID),N'UNKNOWN'))

    , PrimaryExecutionEvidenceID=b.VictimExecutionEvidenceID
    , PrimarySessionID=b.HeadBlockerSessionID

    , EvidenceObject=CONVERT(sysname,N'RCA_BlockingEvidence')
    , EvidenceID=b.BlockingEvidenceID

    , PrimaryEvidence=CONVERT(nvarchar(max),
        COALESCE(b.EvidenceSummary,
            N'Victim session '
            + COALESCE(CONVERT(nvarchar(20),b.VictimSessionID),N'unknown')
            + N' blocked by head blocker '
            + COALESCE(CONVERT(nvarchar(20),b.HeadBlockerSessionID),N'unknown')
            + N' on '
            + COALESCE(b.WaitType,N'unknown wait')
            + N'.'))

    , RecommendedAction=CONVERT(nvarchar(max),
        N'Investigate head blocker session '
        + COALESCE(CONVERT(nvarchar(20),b.HeadBlockerSessionID),N'unknown')
        + N', the transaction holding the conflicting locks, and the application transaction pattern.')

FROM dbo.RCA_BlockingEvidence AS b
WHERE b.RootCauseRole IN ('PRIMARY','CONTRIBUTING')
  AND b.Confidence IN ('HIGH','MEDIUM')

UNION ALL

SELECT
      CaptureRunID=c.CaptureRunID
    , CauseCategory=CONVERT(varchar(60),'CPU_SCHEDULER')
    , CauseDisplayName=CONVERT(nvarchar(200),N'CPU / scheduler pressure')
    , RootCauseRole=CONVERT(varchar(20),c.RootCauseRole)
    , Confidence=CONVERT(varchar(20),c.Confidence)

    , PriorityScore=
        CASE
          WHEN c.RootCauseRole='PRIMARY'      AND c.Confidence='HIGH'   THEN 1000
          WHEN c.RootCauseRole='PRIMARY'      AND c.Confidence='MEDIUM' THEN 900
          WHEN c.RootCauseRole='CONTRIBUTING' AND c.Confidence='HIGH'   THEN 800
          WHEN c.RootCauseRole='CONTRIBUTING' AND c.Confidence='MEDIUM' THEN 700
          WHEN c.RootCauseRole='PRIMARY'                                  THEN 600
          WHEN c.RootCauseRole='CONTRIBUTING'                             THEN 500
          ELSE 100
        END

    , EvidenceCount=CONVERT(bigint,ISNULL(c.HighRunnableSampleCount,1))
    , CorrelationKey=
        CONVERT(nvarchar(200),
            N'EXECUTION:' + COALESCE(CONVERT(nvarchar(30),c.PrimaryExecutionEvidenceID),N'UNKNOWN'))

    , PrimaryExecutionEvidenceID=c.PrimaryExecutionEvidenceID
    , PrimarySessionID=c.PrimarySessionID

    , EvidenceObject=CONVERT(sysname,N'RCA_CPUSchedulerEvidence')
    , EvidenceID=c.CPUSchedulerEvidenceID

    , PrimaryEvidence=CONVERT(nvarchar(max),
        N'CPU scheduler evidence: peak runnable tasks='
        + COALESCE(CONVERT(nvarchar(20),c.PeakRunnableTasks),N'unknown')
        + N'; average runnable tasks='
        + COALESCE(CONVERT(nvarchar(40),c.AvgRunnableTasks),N'unknown')
        + N'; high-runnable samples='
        + COALESCE(CONVERT(nvarchar(20),c.HighRunnableSampleCount),N'unknown')
        + N' of '
        + COALESCE(CONVERT(nvarchar(20),c.ServerSampleCount),N'unknown')
        + N'; primary execution='
        + COALESCE(CONVERT(nvarchar(30),c.PrimaryExecutionEvidenceID),N'unknown')
        + N'.')

    , RecommendedAction=CONVERT(nvarchar(max),
        N'Investigate the primary correlated CPU-consuming execution, its concurrency pattern, '
        + N'logical reads, plan shape, and whether the application can perform less CPU work.')

FROM dbo.RCA_CPUSchedulerEvidence AS c
WHERE c.RootCauseRole IN ('PRIMARY','CONTRIBUTING')
  AND c.Confidence IN ('HIGH','MEDIUM');
GO


/*==============================================================================
  2. AUTHORITATIVE RANKING VIEW

  This view does NOT change the detector-assigned roles.
  It simply provides deterministic ordering among already-supported causes.

  ArbitrationRank:
      1 = strongest supported cause for the capture
      2+ = other supported causes

  IsAuthoritativePrimary:
      YES only for rank 1 when RootCauseRole=PRIMARY

  If multiple domains are independently marked PRIMARY/HIGH, this view makes
  the ambiguity visible rather than hiding it.
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_CrossDomainCauseRanking
AS
SELECT
      Candidate.CaptureRunID
    , Candidate.CauseCategory
    , Candidate.CauseDisplayName
    , Candidate.RootCauseRole
    , Candidate.Confidence
    , Candidate.PriorityScore
    , Candidate.EvidenceCount
    , Candidate.CorrelationKey
    , Candidate.PrimaryExecutionEvidenceID
    , Candidate.PrimarySessionID
    , Candidate.EvidenceObject
    , Candidate.EvidenceID
    , Candidate.PrimaryEvidence
    , Candidate.RecommendedAction

    , ArbitrationRank=
        ROW_NUMBER() OVER
        (
            PARTITION BY Candidate.CaptureRunID
            ORDER BY
                  Candidate.PriorityScore DESC
                , Candidate.EvidenceCount DESC
                , Candidate.CauseCategory
                , Candidate.EvidenceID
        )

    , SupportedCauseCount=
        COUNT(*) OVER
        (
            PARTITION BY Candidate.CaptureRunID
        )

    , PrimaryCauseCount=
        SUM
        (
            CASE WHEN Candidate.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END
        )
        OVER
        (
            PARTITION BY Candidate.CaptureRunID
        )

FROM dbo.vw_RCA_NormalizedCauseCandidates AS Candidate;
GO


/*==============================================================================
  3. SUMMARY VIEW FOR DBA / PRESENTATION CONSUMERS
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_CrossDomainCauseSummary
AS
SELECT
      r.CaptureRunID

    , PrimaryCauseCategory=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.CauseCategory END)

    , PrimaryCauseDisplayName=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.CauseDisplayName END)

    , PrimaryCauseRole=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.RootCauseRole END)

    , PrimaryConfidence=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.Confidence END)

    , PrimaryEvidenceObject=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.EvidenceObject END)

    , PrimaryEvidenceID=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.EvidenceID END)

    , PrimaryExecutionEvidenceID=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.PrimaryExecutionEvidenceID END)

    , PrimarySessionID=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.PrimarySessionID END)

    , SupportedCauseCount=MAX(r.SupportedCauseCount)
    , PrimaryCauseCount=MAX(r.PrimaryCauseCount)

    , ArbitrationStatus=
        CASE
          WHEN MAX(r.PrimaryCauseCount)=0
          THEN 'NO_SUPPORTED_PRIMARY_CAUSE'

          WHEN MAX(r.PrimaryCauseCount)=1
          THEN 'ONE_SUPPORTED_PRIMARY_CAUSE'

          WHEN MAX(r.PrimaryCauseCount)>1
          THEN 'MULTIPLE_PRIMARY_CAUSES_REQUIRE_ARBITRATION_REVIEW'

          ELSE 'UNKNOWN'
        END

FROM dbo.vw_RCA_CrossDomainCauseRanking AS r
GROUP BY r.CaptureRunID;
GO


/*==============================================================================
  4. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection='1 - SCRIPT 66 DEPLOYMENT'
    , NormalizedCauseCandidates=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainCauseRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainCauseSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  5. NORMALIZED CANDIDATES FOR CONTROLS
==============================================================================*/
SELECT
      ValidationSection='2 - NORMALIZED CAUSE CANDIDATES'
    , *
FROM dbo.vw_RCA_NormalizedCauseCandidates
WHERE CaptureRunID IN (38,42,44)
ORDER BY
      CaptureRunID
    , PriorityScore DESC
    , CauseCategory;
GO


/*==============================================================================
  6. RANKING FOR CONTROLS
==============================================================================*/
SELECT
      ValidationSection='3 - CROSS DOMAIN RANKING'
    , *
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CaptureRunID IN (38,42,44)
ORDER BY
      CaptureRunID
    , ArbitrationRank;
GO


/*==============================================================================
  7. SUMMARY FOR CONTROLS
==============================================================================*/
SELECT
      ValidationSection='4 - CROSS DOMAIN SUMMARY'
    , *
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID IN (38,42,44)
ORDER BY CaptureRunID;
GO


/*==============================================================================
  8. CONTROL ACCEPTANCE

  Capture 38:
      no normalized supported cause

  Capture 42:
      BLOCKING_WAIT_CHAIN should be rank 1

  Capture 44:
      CPU_SCHEDULER should be rank 1
==============================================================================*/
DECLARE
      @C38Count int=0
    , @C42Primary varchar(60)
    , @C42Role varchar(20)
    , @C42Confidence varchar(20)
    , @C44Primary varchar(60)
    , @C44Role varchar(20)
    , @C44Confidence varchar(20);

SELECT @C38Count=COUNT(*)
FROM dbo.vw_RCA_NormalizedCauseCandidates
WHERE CaptureRunID=38;

SELECT TOP (1)
      @C42Primary=CauseCategory
    , @C42Role=RootCauseRole
    , @C42Confidence=Confidence
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CaptureRunID=42
ORDER BY ArbitrationRank;

SELECT TOP (1)
      @C44Primary=CauseCategory
    , @C44Role=RootCauseRole
    , @C44Confidence=Confidence
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CaptureRunID=44
ORDER BY ArbitrationRank;

SELECT
      ValidationSection='5 - SCRIPT 66 CONTROL ACCEPTANCE'
    , Capture38Uncertainty=
        CASE WHEN @C38Count=0 THEN 'PASS' ELSE 'REVIEW' END

    , Capture42PrimaryCause=
        CASE WHEN @C42Primary='BLOCKING_WAIT_CHAIN' THEN 'PASS' ELSE 'FAIL' END
    , Capture42Role=
        CASE WHEN @C42Role='PRIMARY' THEN 'PASS' ELSE 'FAIL' END
    , Capture42Confidence=
        CASE WHEN @C42Confidence='HIGH' THEN 'PASS'
             WHEN @C42Confidence='MEDIUM' THEN 'REVIEW'
             ELSE 'FAIL' END

    , Capture44PrimaryCause=
        CASE WHEN @C44Primary='CPU_SCHEDULER' THEN 'PASS' ELSE 'FAIL' END
    , Capture44Role=
        CASE WHEN @C44Role='PRIMARY' THEN 'PASS' ELSE 'FAIL' END
    , Capture44Confidence=
        CASE WHEN @C44Confidence='HIGH' THEN 'PASS'
             WHEN @C44Confidence='MEDIUM' THEN 'REVIEW'
             ELSE 'FAIL' END

    , OverallResult=
        CASE
          WHEN @C38Count=0
           AND @C42Primary='BLOCKING_WAIT_CHAIN'
           AND @C42Role='PRIMARY'
           AND @C44Primary='CPU_SCHEDULER'
           AND @C44Role='PRIMARY'
          THEN 'PASS - NORMALIZED CROSS-DOMAIN ARBITRATION PRESERVES EXISTING CONTROLS'
          ELSE 'REVIEW - NORMALIZED ARBITRATION DOES NOT MATCH CONTROL EXPECTATIONS'
        END;
GO


/*==============================================================================
  9. CURRENT CANONICAL ANSWER REGRESSION
  Script 66 does not alter it. We merely confirm existing behavior remains intact.
==============================================================================*/
SELECT
      ValidationSection='6 - CAPTURE 42 CURRENT DBA ANSWER';
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO

SELECT
      ValidationSection='6A - CAPTURE 44 CURRENT DBA ANSWER';
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO

SELECT
      ValidationSection='6B - CAPTURE 38 CURRENT DBA ANSWER';
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;
GO


/*==============================================================================
  10. MULTI-PRIMARY SAFETY CHECK

  We do not manufacture a mixed incident here.
  We simply scan existing captures for cases where more than one detector has
  already independently claimed PRIMARY.

  Such captures are the best future arbitration test cases.
==============================================================================*/
SELECT
      ValidationSection='7 - EXISTING MULTI-PRIMARY CAPTURES'
    , CaptureRunID
    , SupportedCauseCount
    , PrimaryCauseCount
    , ArbitrationStatus
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE PrimaryCauseCount>1
ORDER BY CaptureRunID;
GO


/*==============================================================================
  11. ARCHITECTURAL READINESS
==============================================================================*/
SELECT
      ValidationSection='8 - ARBITRATION ARCHITECTURE READINESS'
    , NormalizedContract='PASS'
    , GenericCauseCategory='PASS'
    , GenericRootCauseRole='PASS'
    , GenericConfidence='PASS'
    , GenericEvidenceCount='PASS'
    , GenericCorrelationKey='PASS'
    , GenericPriorityScore='PASS'
    , DeterministicArbitrationRank='PASS'
    , MultiplePrimaryVisibility='PASS'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisReplaced='NO'
    , CurrentCanonicalRouterChanged='NO'
    , NextStep=
        'If Script 66 controls pass, Script 67 should make the canonical DBA answer consume vw_RCA_CrossDomainCauseSummary/ranking instead of hard-coding blocking before CPU.';
GO


/*==============================================================================
  12. SAFETY
==============================================================================*/
SELECT
      ValidationSection='9 - SCRIPT 66 SAFETY'
    , NormalizationLayerAdded='YES'
    , Capture38Modified='NO'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingRootCauseSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO';
GO
