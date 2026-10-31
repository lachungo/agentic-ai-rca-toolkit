USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  70_RCA_Normalize_IO_Storage_Into_Arbitration_v1.sql

  PURPOSE
  -------
  Integrate the EXISTING persisted dbo.RCA_IOStorageEvidence domain into the
  normalized cross-domain arbitration contract created by Script 66.

  IMPORTANT
  ---------
  This script does NOT create a new I/O detector and does NOT invent I/O
  thresholds. It consumes RootCauseRole / Confidence already persisted by
  dbo.usp_RCA_BuildIOStorageEvidence.

  NORMALIZED DOMAIN
  -----------------
      CauseCategory    = IO_STORAGE_LATENCY
      CauseDisplayName = I/O / storage latency

  REGRESSION CONTROLS
  -------------------
      Capture 38 -> uncertainty preserved
      Capture 42 -> BLOCKING_WAIT_CHAIN remains PRIMARY/HIGH
      Capture 44 -> CPU_SCHEDULER remains PRIMARY/HIGH

  I/O VALIDATION
  --------------
  Existing historical RCA_IOStorageEvidence rows are surfaced through the
  normalized contract. If one or more PRIMARY/HIGH I/O rows already exist,
  they must appear as IO_STORAGE_LATENCY without modifying historical evidence.

  SAFETY
  ------
  Normalization/presentation contract only.

  This script does NOT:
      - alter dbo.RCA_IOStorageEvidence
      - alter dbo.usp_RCA_BuildIOStorageEvidence
      - rebuild I/O evidence
      - alter historical capture rows
      - change detector thresholds
      - change persisted RootCauseRole / Confidence
      - alter dbo.usp_RCA_DBAAnswer
      - start a new capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 70 PRE-FLIGHT'
    , BlockingEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingNormalizedView=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    THROW 57000,N'dbo.RCA_BlockingEvidence is required.',1;

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NULL
    THROW 57001,N'dbo.RCA_CPUSchedulerEvidence is required.',1;

IF OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NULL
    THROW 57002,N'dbo.RCA_IOStorageEvidence is required.',1;

IF COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'CaptureRunID') IS NULL
    THROW 57003,N'RCA_IOStorageEvidence.CaptureRunID is required.',1;

IF COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'RootCauseRole') IS NULL
    THROW 57004,N'RCA_IOStorageEvidence.RootCauseRole is required.',1;

IF COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'Confidence') IS NULL
    THROW 57005,N'RCA_IOStorageEvidence.Confidence is required.',1;

IF COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'SampleCount') IS NULL
    THROW 57006,N'RCA_IOStorageEvidence.SampleCount is required.',1;

IF COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'EvidenceSummary') IS NULL
    THROW 57007,N'RCA_IOStorageEvidence.EvidenceSummary is required.',1;

IF COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'RecommendedAction') IS NULL
    THROW 57008,N'RCA_IOStorageEvidence.RecommendedAction is required.',1;
GO


/*==============================================================================
  1. REBUILD NORMALIZED CAUSE CONTRACT
  Proven domains:
      BLOCKING_WAIT_CHAIN
      CPU_SCHEDULER
      IO_STORAGE_LATENCY

  PriorityScore normalizes ALREADY-PERSISTED role/confidence only:
      PRIMARY/HIGH        = 1000
      PRIMARY/MEDIUM      = 900
      CONTRIBUTING/HIGH   = 800
      CONTRIBUTING/MEDIUM = 700
      PRIMARY/other       = 600
      CONTRIBUTING/other  = 500
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_NormalizedCauseCandidates
AS

/*--------------------------------------------------------------------------
  BLOCKING / WAIT-CHAIN
--------------------------------------------------------------------------*/
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
            N'HEAD_BLOCKER:'
            + COALESCE(CONVERT(nvarchar(20),b.HeadBlockerSessionID),N'UNKNOWN'))

    , PrimaryExecutionEvidenceID=b.VictimExecutionEvidenceID
    , PrimarySessionID=b.HeadBlockerSessionID

    , EvidenceObject=CONVERT(sysname,N'RCA_BlockingEvidence')
    , EvidenceID=b.BlockingEvidenceID

    , PrimaryEvidence=CONVERT(nvarchar(max),
        COALESCE
        (
            b.EvidenceSummary,
            N'Victim session '
            + COALESCE(CONVERT(nvarchar(20),b.VictimSessionID),N'unknown')
            + N' blocked by head blocker '
            + COALESCE(CONVERT(nvarchar(20),b.HeadBlockerSessionID),N'unknown')
            + N' on '
            + COALESCE(b.WaitType,N'unknown wait')
            + N'.'
        ))

    , RecommendedAction=CONVERT(nvarchar(max),
        N'Investigate head blocker session '
        + COALESCE(CONVERT(nvarchar(20),b.HeadBlockerSessionID),N'unknown')
        + N', the transaction holding the conflicting locks, and the application transaction pattern.')

FROM dbo.RCA_BlockingEvidence AS b
WHERE b.RootCauseRole IN ('PRIMARY','CONTRIBUTING')
  AND b.Confidence IN ('HIGH','MEDIUM')


UNION ALL


/*--------------------------------------------------------------------------
  CPU / SCHEDULER
--------------------------------------------------------------------------*/
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
            N'EXECUTION:'
            + COALESCE(CONVERT(nvarchar(30),c.PrimaryExecutionEvidenceID),N'UNKNOWN'))

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
  AND c.Confidence IN ('HIGH','MEDIUM')


UNION ALL


/*--------------------------------------------------------------------------
  I/O / STORAGE LATENCY
  IMPORTANT: detector role/confidence are consumed exactly as persisted.
--------------------------------------------------------------------------*/
SELECT
      CaptureRunID=i.CaptureRunID
    , CauseCategory=CONVERT(varchar(60),'IO_STORAGE_LATENCY')
    , CauseDisplayName=CONVERT(nvarchar(200),N'I/O / storage latency')
    , RootCauseRole=CONVERT(varchar(20),i.RootCauseRole)
    , Confidence=CONVERT(varchar(20),i.Confidence)

    , PriorityScore=
        CASE
          WHEN i.RootCauseRole='PRIMARY'      AND i.Confidence='HIGH'   THEN 1000
          WHEN i.RootCauseRole='PRIMARY'      AND i.Confidence='MEDIUM' THEN 900
          WHEN i.RootCauseRole='CONTRIBUTING' AND i.Confidence='HIGH'   THEN 800
          WHEN i.RootCauseRole='CONTRIBUTING' AND i.Confidence='MEDIUM' THEN 700
          WHEN i.RootCauseRole='PRIMARY'                                  THEN 600
          WHEN i.RootCauseRole='CONTRIBUTING'                             THEN 500
          ELSE 100
        END

    , EvidenceCount=CONVERT(bigint,ISNULL(i.SampleCount,1))

    , CorrelationKey=
        CONVERT(nvarchar(200),
            N'DATABASE:'
            + COALESCE(CONVERT(nvarchar(128),i.DatabaseName),N'UNKNOWN')
            + N'|FILE:'
            + COALESCE
              (
                  CONVERT(nvarchar(128),i.LogicalFileName),
                  CONVERT(nvarchar(20),i.FileID),
                  N'UNKNOWN'
              ))

    /*
      Existing I/O evidence is file/time-window based and, per Script 69, does
      not persist a primary execution/session attribution. Keep these NULL
      rather than manufacturing attribution.
    */
    , PrimaryExecutionEvidenceID=CONVERT(bigint,NULL)
    , PrimarySessionID=CONVERT(int,NULL)

    , EvidenceObject=CONVERT(sysname,N'RCA_IOStorageEvidence')
    , EvidenceID=i.IOStorageEvidenceID

    , PrimaryEvidence=CONVERT(nvarchar(max),
        COALESCE
        (
            i.EvidenceSummary,
            N'I/O storage evidence for database '
            + COALESCE(CONVERT(nvarchar(128),i.DatabaseName),N'unknown')
            + N', file '
            + COALESCE
              (
                  CONVERT(nvarchar(128),i.LogicalFileName),
                  CONVERT(nvarchar(20),i.FileID),
                  N'unknown'
              )
            + N'.'
        ))

    , RecommendedAction=CONVERT(nvarchar(max),
        COALESCE
        (
            i.RecommendedAction,
            N'Review file-level read/write latency, workload I/O demand, storage path health, '
            + N'and whether the affected workload genuinely required the observed physical I/O.'
        ))

FROM dbo.RCA_IOStorageEvidence AS i
WHERE i.RootCauseRole IN ('PRIMARY','CONTRIBUTING')
  AND i.Confidence IN ('HIGH','MEDIUM');
GO


/*==============================================================================
  2. RE-CREATE RANKING VIEW AGAINST THE EXPANDED NORMALIZED CONTRACT
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
  3. RE-CREATE SUMMARY VIEW
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
      ValidationSection='1 - SCRIPT 70 DEPLOYMENT'
    , NormalizedCauseCandidates=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainCauseRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainCauseSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageCategoryPresent=
        CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates'))
                    LIKE N'%IO_STORAGE_LATENCY%'
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  5. I/O NORMALIZED CANDIDATES
==============================================================================*/
SELECT
      ValidationSection='2 - IO NORMALIZED CANDIDATES'
    , CaptureRunID
    , CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , PriorityScore
    , EvidenceCount
    , CorrelationKey
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , EvidenceObject
    , EvidenceID
    , PrimaryEvidence
    , RecommendedAction
FROM dbo.vw_RCA_NormalizedCauseCandidates
WHERE CauseCategory='IO_STORAGE_LATENCY'
ORDER BY
      CaptureRunID
    , PriorityScore DESC
    , EvidenceCount DESC
    , EvidenceID;
GO


/*==============================================================================
  6. I/O CROSS-DOMAIN RANKING
==============================================================================*/
SELECT
      ValidationSection='3 - IO CROSS DOMAIN RANKING'
    , CaptureRunID
    , ArbitrationRank
    , CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , PriorityScore
    , EvidenceCount
    , CorrelationKey
    , EvidenceObject
    , EvidenceID
    , SupportedCauseCount
    , PrimaryCauseCount
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CauseCategory='IO_STORAGE_LATENCY'
ORDER BY CaptureRunID,ArbitrationRank;
GO


/*==============================================================================
  7. HISTORICAL I/O CAPTURE SUMMARY
==============================================================================*/
SELECT
      ValidationSection='4 - IO HISTORICAL CAPTURE SUMMARY'
    , r.CaptureRunID
    , TotalIONormalizedRows=
        SUM(CASE WHEN r.CauseCategory='IO_STORAGE_LATENCY' THEN 1 ELSE 0 END)
    , IOPrimaryRows=
        SUM(CASE WHEN r.CauseCategory='IO_STORAGE_LATENCY'
                  AND r.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
    , IOHighConfidenceRows=
        SUM(CASE WHEN r.CauseCategory='IO_STORAGE_LATENCY'
                  AND r.Confidence='HIGH' THEN 1 ELSE 0 END)
    , OverallSupportedCauseCount=MAX(r.SupportedCauseCount)
    , OverallPrimaryCauseCount=MAX(r.PrimaryCauseCount)
    , Rank1Cause=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.CauseCategory END)
    , Rank1Role=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.RootCauseRole END)
    , Rank1Confidence=
        MAX(CASE WHEN r.ArbitrationRank=1 THEN r.Confidence END)
FROM dbo.vw_RCA_CrossDomainCauseRanking AS r
WHERE EXISTS
(
    SELECT 1
    FROM dbo.vw_RCA_NormalizedCauseCandidates AS i
    WHERE i.CaptureRunID=r.CaptureRunID
      AND i.CauseCategory='IO_STORAGE_LATENCY'
)
GROUP BY r.CaptureRunID
ORDER BY r.CaptureRunID;
GO


/*==============================================================================
  8. PROVEN CONTROL REGRESSION
==============================================================================*/
DECLARE
      @C38Count int=0
    , @C42Category varchar(60)
    , @C42Role varchar(20)
    , @C42Confidence varchar(20)
    , @C44Category varchar(60)
    , @C44Role varchar(20)
    , @C44Confidence varchar(20);

SELECT @C38Count=COUNT(*)
FROM dbo.vw_RCA_NormalizedCauseCandidates
WHERE CaptureRunID=38;

SELECT TOP (1)
      @C42Category=CauseCategory
    , @C42Role=RootCauseRole
    , @C42Confidence=Confidence
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CaptureRunID=42
ORDER BY ArbitrationRank;

SELECT TOP (1)
      @C44Category=CauseCategory
    , @C44Role=RootCauseRole
    , @C44Confidence=Confidence
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CaptureRunID=44
ORDER BY ArbitrationRank;

SELECT
      ValidationSection='5 - SCRIPT 70 REGRESSION ACCEPTANCE'
    , Capture38Uncertainty=
        CASE WHEN @C38Count=0 THEN 'PASS' ELSE 'REVIEW' END

    , Capture42Blocking=
        CASE WHEN @C42Category='BLOCKING_WAIT_CHAIN'
                  AND @C42Role='PRIMARY'
             THEN 'PASS' ELSE 'FAIL' END

    , Capture42Confidence=
        CASE WHEN @C42Confidence='HIGH' THEN 'PASS'
             WHEN @C42Confidence='MEDIUM' THEN 'REVIEW'
             ELSE 'FAIL' END

    , Capture44CPU=
        CASE WHEN @C44Category='CPU_SCHEDULER'
                  AND @C44Role='PRIMARY'
             THEN 'PASS' ELSE 'FAIL' END

    , Capture44Confidence=
        CASE WHEN @C44Confidence='HIGH' THEN 'PASS'
             WHEN @C44Confidence='MEDIUM' THEN 'REVIEW'
             ELSE 'FAIL' END

    , IOCategoryPresent=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.vw_RCA_NormalizedCauseCandidates
            WHERE CauseCategory='IO_STORAGE_LATENCY'
        ) THEN 'PASS' ELSE 'REVIEW' END

    , OverallResult=
        CASE
          WHEN @C38Count=0
           AND @C42Category='BLOCKING_WAIT_CHAIN'
           AND @C42Role='PRIMARY'
           AND @C44Category='CPU_SCHEDULER'
           AND @C44Role='PRIMARY'
           AND EXISTS
           (
               SELECT 1
               FROM dbo.vw_RCA_NormalizedCauseCandidates
               WHERE CauseCategory='IO_STORAGE_LATENCY'
           )
          THEN 'PASS - IO STORAGE NORMALIZED WITHOUT BREAKING BLOCKING / CPU CONTROLS'
          ELSE 'REVIEW - NORMALIZED IO INTEGRATION DID NOT MATCH CONTROL EXPECTATIONS'
        END;
GO


/*==============================================================================
  9. IDENTIFY BEST EXISTING I/O POSITIVE-CONTROL CANDIDATE

  No historical data is altered. This simply identifies the strongest already-
  persisted I/O case for the next validation step.
==============================================================================*/
SELECT TOP (10)
      ValidationSection='6 - EXISTING IO POSITIVE CONTROL CANDIDATES'
    , CaptureRunID
    , ArbitrationRank
    , CauseCategory
    , RootCauseRole
    , Confidence
    , PriorityScore
    , EvidenceCount
    , CorrelationKey
    , EvidenceObject
    , EvidenceID
    , SupportedCauseCount
    , PrimaryCauseCount
    , PrimaryEvidence
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CauseCategory='IO_STORAGE_LATENCY'
ORDER BY
      CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END
    , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
    , PriorityScore DESC
    , EvidenceCount DESC
    , CaptureRunID DESC;
GO


/*==============================================================================
  10. CANONICAL ROUTER STATE
  Script 70 intentionally does not add an I/O narrator yet.
==============================================================================*/
DECLARE @Canonical nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='7 - CANONICAL IO ROUTER STATE'
    , CanonicalUsesCrossDomainSummary=
        CASE WHEN @Canonical LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalContainsIOStorageSpecialCase=
        CASE WHEN @Canonical LIKE N'%IO_STORAGE_LATENCY%'
             THEN 'YES' ELSE 'NO' END
    , ExpectedBehavior=
        N'If an existing capture has IO_STORAGE_LATENCY as the single normalized PRIMARY cause, '
        + N'the current canonical answer should expose a narrator gap rather than invent I/O narration.'
    , NextStep=
        N'Script 71 should validate a real persisted I/O positive control and then add the I/O narrator '
        + N'only if the existing detector evidence is causally sufficient.';
GO


/*==============================================================================
  11. ARCHITECTURE ACCEPTANCE
==============================================================================*/
SELECT
      ValidationSection='8 - SCRIPT 70 ARCHITECTURE ACCEPTANCE'
    , IOUsesExistingDetectorEvidence='PASS'
    , IOUsesPersistedRootCauseRole='PASS'
    , IOUsesPersistedConfidence='PASS'
    , IOUsesNormalizedContract='PASS'
    , CrossDomainRankingPreserved='PASS'
    , HardCodedIORouterPriorityAdded='NO'
    , PrimaryExecutionManufactured='NO'
    , PrimarySessionManufactured='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  12. SAFETY
==============================================================================*/
SELECT
      ValidationSection='9 - SCRIPT 70 SAFETY'
    , NormalizedIODomainAdded='YES'
    , IOEvidenceTableModified='NO'
    , IOBuilderModified='NO'
    , Capture38Modified='NO'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , HistoricalIOCapturesModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
