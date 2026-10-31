USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  72_RCA_Final_End_to_End_Regression_and_Production_Readiness_v1.sql

  PURPOSE
  -------
  Final end-to-end regression and production-readiness gate for RCA Engine v1.

  THIS SCRIPT VALIDATES THE RCA ENGINE AS ONE PRODUCT
  ---------------------------------------------------
      1. Blocking / wait-chain positive control
      2. CPU / scheduler positive control
      3. I/O / storage latency positive control
      4. Negative control / uncertainty preservation
      5. Multi-primary arbitration safety
      6. Evidence provenance
      7. No fabricated session/execution attribution
      8. Canonical routing through normalized arbitration
      9. Deterministic repeat execution
     10. Safety / immutability of historical evidence

  PROVEN CONTROL CAPTURES
  -----------------------
      Capture 20 -> IO_STORAGE_LATENCY      PRIMARY / MEDIUM
      Capture 38 -> no supported primary    uncertainty preserved
      Capture 42 -> BLOCKING_WAIT_CHAIN     PRIMARY / HIGH
      Capture 44 -> CPU_SCHEDULER           PRIMARY / HIGH

  MULTI-PRIMARY CONTROLS
  ----------------------
      Existing captures 8 and/or 13 are used when they still contain more than
      one normalized PRIMARY cause.

  ARCHITECTURAL PRINCIPLE
  -----------------------
      Domain detectors detect.
      Normalized synthesis/ranking arbitrates.
      Canonical DBA presentation narrates.

  SAFETY
  ------
  This script is validation-only. It does NOT:
      - alter evidence tables
      - rebuild findings
      - change thresholds
      - change root-cause logic
      - modify historical captures
      - modify canonical procedures/views
      - insert manual causes
      - start a new capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 72 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , NormalizedCandidates=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IONarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_IOStorage',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ArbitrationReviewNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_ArbitrationReview',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ValidationOnly='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 57200,N'dbo.RCA_CaptureRun is required.',1;

IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NULL
    THROW 57201,N'dbo.vw_RCA_CrossDomainCauseSummary is required.',1;

IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NULL
    THROW 57202,N'dbo.vw_RCA_CrossDomainCauseRanking is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NULL
    THROW 57203,N'dbo.usp_RCA_DBAAnswer is required.',1;
GO


/*==============================================================================
  1. CONTROL-CAPTURE STATE
==============================================================================*/
SELECT
      ValidationSection='1 - CONTROL CAPTURE STATE'
    , c.CaptureRunID
    , c.TargetDatabase
    , c.CaptureReason
    , c.StartTimeUTC
    , c.EndTimeUTC
    , c.CaptureStatus
    , s.PrimaryCauseCategory
    , s.PrimaryCauseRole
    , s.PrimaryConfidence
    , s.SupportedCauseCount
    , s.PrimaryCauseCount
    , s.ArbitrationStatus
FROM dbo.RCA_CaptureRun AS c
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=c.CaptureRunID
WHERE c.CaptureRunID IN (20,38,42,44)
ORDER BY c.CaptureRunID;
GO


/*==============================================================================
  2. NORMALIZED EVIDENCE PROVENANCE
==============================================================================*/
SELECT
      ValidationSection='2 - NORMALIZED EVIDENCE PROVENANCE'
    , CaptureRunID
    , ArbitrationRank
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
    , SupportedCauseCount
    , PrimaryCauseCount
FROM dbo.vw_RCA_CrossDomainCauseRanking
WHERE CaptureRunID IN (20,38,42,44)
ORDER BY CaptureRunID,ArbitrationRank;
GO


/*==============================================================================
  3. CONTROL EXPECTATION MATRIX
==============================================================================*/
SELECT
      ValidationSection='3 - CONTROL EXPECTATION MATRIX'
    , CaptureRunID=v.CaptureRunID
    , ExpectedCause=v.ExpectedCause
    , ExpectedRole=v.ExpectedRole
    , ExpectedConfidence=v.ExpectedConfidence
    , ActualCause=s.PrimaryCauseCategory
    , ActualRole=s.PrimaryCauseRole
    , ActualConfidence=s.PrimaryConfidence
    , Result=
        CASE
          WHEN v.CaptureRunID=38
               AND ISNULL(s.PrimaryCauseCount,0)=0
          THEN 'PASS'

          WHEN s.PrimaryCauseCategory=v.ExpectedCause
           AND s.PrimaryCauseRole=v.ExpectedRole
           AND s.PrimaryConfidence=v.ExpectedConfidence
          THEN 'PASS'

          ELSE 'FAIL'
        END
FROM
(
    VALUES
          (20,CONVERT(varchar(60),'IO_STORAGE_LATENCY'),CONVERT(varchar(20),'PRIMARY'),CONVERT(varchar(20),'MEDIUM'))
        , (38,CONVERT(varchar(60),NULL),CONVERT(varchar(20),NULL),CONVERT(varchar(20),NULL))
        , (42,CONVERT(varchar(60),'BLOCKING_WAIT_CHAIN'),CONVERT(varchar(20),'PRIMARY'),CONVERT(varchar(20),'HIGH'))
        , (44,CONVERT(varchar(60),'CPU_SCHEDULER'),CONVERT(varchar(20),'PRIMARY'),CONVERT(varchar(20),'HIGH'))
) AS v(CaptureRunID,ExpectedCause,ExpectedRole,ExpectedConfidence)
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=v.CaptureRunID
ORDER BY v.CaptureRunID;
GO


/*==============================================================================
  4. CANONICAL ANSWER - I/O
==============================================================================*/
SELECT
      ValidationSection='4 - CAPTURE 20 CANONICAL ANSWER'
    , Expected='ROOT CAUSE IDENTIFIED - IO / STORAGE LATENCY - MEDIUM';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=20;
GO


/*==============================================================================
  5. CANONICAL ANSWER - NEGATIVE CONTROL
==============================================================================*/
SELECT
      ValidationSection='5 - CAPTURE 38 CANONICAL ANSWER'
    , Expected='ROOT CAUSE NOT CONFIRMED';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;
GO


/*==============================================================================
  6. CANONICAL ANSWER - BLOCKING
==============================================================================*/
SELECT
      ValidationSection='6 - CAPTURE 42 CANONICAL ANSWER'
    , Expected='ROOT CAUSE IDENTIFIED - BLOCKING / WAIT-CHAIN - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO


/*==============================================================================
  7. CANONICAL ANSWER - CPU
==============================================================================*/
SELECT
      ValidationSection='7 - CAPTURE 44 CANONICAL ANSWER'
    , Expected='ROOT CAUSE IDENTIFIED - CPU / SCHEDULER - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO


/*==============================================================================
  8. NO-FABRICATED-ATTRIBUTION CHECK
  I/O evidence is file-level in the proven positive control and should not
  manufacture a session/execution identifier.
==============================================================================*/
SELECT
      ValidationSection='8 - NO FABRICATED ATTRIBUTION'
    , CaptureRunID=20
    , PrimaryCauseCategory=s.PrimaryCauseCategory
    , PrimaryExecutionEvidenceID=s.PrimaryExecutionEvidenceID
    , PrimarySessionID=s.PrimarySessionID
    , Result=
        CASE
          WHEN s.PrimaryCauseCategory='IO_STORAGE_LATENCY'
           AND s.PrimaryExecutionEvidenceID IS NULL
           AND s.PrimarySessionID IS NULL
          THEN 'PASS - IO ATTRIBUTION REMAINS FILE LEVEL'
          ELSE 'REVIEW'
        END
FROM dbo.vw_RCA_CrossDomainCauseSummary AS s
WHERE s.CaptureRunID=20;
GO


/*==============================================================================
  9. CANONICAL ROUTER ARCHITECTURE
==============================================================================*/
DECLARE @CanonicalDefinition nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='9 - CANONICAL ROUTER ARCHITECTURE'
    , UsesCrossDomainSummary=
        CASE WHEN @CanonicalDefinition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , SupportsBlockingCategory=
        CASE WHEN @CanonicalDefinition LIKE N'%BLOCKING_WAIT_CHAIN%'
             THEN 'PASS' ELSE 'FAIL' END
    , SupportsCPUCategory=
        CASE WHEN @CanonicalDefinition LIKE N'%CPU_SCHEDULER%'
             THEN 'PASS' ELSE 'FAIL' END
    , SupportsIOCategory=
        CASE WHEN @CanonicalDefinition LIKE N'%IO_STORAGE_LATENCY%'
             THEN 'PASS' ELSE 'FAIL' END
    , SupportsMultiPrimaryReview=
        CASE WHEN @CanonicalDefinition LIKE N'%usp_RCA_DBAAnswer_ArbitrationReview%'
             THEN 'PASS' ELSE 'FAIL' END
    , DirectlyRanksBlockingEvidence=
        CASE WHEN @CanonicalDefinition LIKE N'%FROM dbo.RCA_BlockingEvidence%'
             THEN 'REVIEW' ELSE 'PASS' END
    , DirectlyRanksCPUEvidence=
        CASE WHEN @CanonicalDefinition LIKE N'%FROM dbo.RCA_CPUSchedulerEvidence%'
             THEN 'REVIEW' ELSE 'PASS' END
    , DirectlyRanksIOEvidence=
        CASE WHEN @CanonicalDefinition LIKE N'%FROM dbo.RCA_IOStorageEvidence%'
             THEN 'REVIEW' ELSE 'PASS' END;
GO


/*==============================================================================
  10. MULTI-PRIMARY SAFETY
==============================================================================*/
SELECT
      ValidationSection='10 - MULTI-PRIMARY INVENTORY'
    , CaptureRunID
    , SupportedCauseCount
    , PrimaryCauseCount
    , ArbitrationStatus
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE PrimaryCauseCount>1
ORDER BY CaptureRunID;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=8
      AND PrimaryCauseCount>1
)
BEGIN
    SELECT
          ValidationSection='10A - CAPTURE 8 MULTI-PRIMARY ANSWER'
        , Expected='MULTIPLE SUPPORTED PRIMARY CAUSES - ARBITRATION REVIEW REQUIRED';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=8;
END;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=13
      AND PrimaryCauseCount>1
)
BEGIN
    SELECT
          ValidationSection='10B - CAPTURE 13 MULTI-PRIMARY ANSWER'
        , Expected='MULTIPLE SUPPORTED PRIMARY CAUSES - ARBITRATION REVIEW REQUIRED';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=13;
END;
GO


/*==============================================================================
  11. DETERMINISTIC REPEATABILITY CHECK

  We avoid trying to compare procedure result sets directly. Instead, verify
  that normalized/ranked state for each control is stable across two reads
  within the same validation run.
==============================================================================*/
IF OBJECT_ID(N'tempdb..#RCARepeatA',N'U') IS NOT NULL DROP TABLE #RCARepeatA;
IF OBJECT_ID(N'tempdb..#RCARepeatB',N'U') IS NOT NULL DROP TABLE #RCARepeatB;

SELECT
      CaptureRunID
    , PrimaryCauseCategory
    , PrimaryCauseRole
    , PrimaryConfidence
    , PrimaryEvidenceObject
    , PrimaryEvidenceID
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , SupportedCauseCount
    , PrimaryCauseCount
    , ArbitrationStatus
INTO #RCARepeatA
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID IN (20,38,42,44);

WAITFOR DELAY '00:00:01';

SELECT
      CaptureRunID
    , PrimaryCauseCategory
    , PrimaryCauseRole
    , PrimaryConfidence
    , PrimaryEvidenceObject
    , PrimaryEvidenceID
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , SupportedCauseCount
    , PrimaryCauseCount
    , ArbitrationStatus
INTO #RCARepeatB
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID IN (20,38,42,44);

DECLARE @RepeatDifferences int;

SELECT @RepeatDifferences=COUNT(*)
FROM
(
    SELECT * FROM #RCARepeatA
    EXCEPT
    SELECT * FROM #RCARepeatB

    UNION ALL

    SELECT * FROM #RCARepeatB
    EXCEPT
    SELECT * FROM #RCARepeatA
) AS d;

SELECT
      ValidationSection='11 - DETERMINISTIC REPEATABILITY'
    , DifferenceRows=@RepeatDifferences
    , Result=
        CASE WHEN @RepeatDifferences=0
             THEN 'PASS - ARBITRATION STATE IS STABLE ACROSS REPEATED READS'
             ELSE 'REVIEW - ARBITRATION STATE CHANGED DURING VALIDATION'
        END;
GO


/*==============================================================================
  12. EVIDENCE SOURCE INTEGRITY
==============================================================================*/
SELECT
      ValidationSection='12 - EVIDENCE SOURCE INTEGRITY'
    , Capture20IOEvidence=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.vw_RCA_CrossDomainCauseRanking
            WHERE CaptureRunID=20
              AND CauseCategory='IO_STORAGE_LATENCY'
              AND EvidenceObject='RCA_IOStorageEvidence'
              AND RootCauseRole='PRIMARY'
              AND Confidence IN ('HIGH','MEDIUM')
        ) THEN 'PASS' ELSE 'FAIL' END

    , Capture42BlockingEvidence=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.vw_RCA_CrossDomainCauseRanking
            WHERE CaptureRunID=42
              AND CauseCategory='BLOCKING_WAIT_CHAIN'
              AND EvidenceObject='RCA_BlockingEvidence'
              AND RootCauseRole='PRIMARY'
              AND Confidence='HIGH'
        ) THEN 'PASS' ELSE 'FAIL' END

    , Capture44CPUEvidence=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.vw_RCA_CrossDomainCauseRanking
            WHERE CaptureRunID=44
              AND CauseCategory='CPU_SCHEDULER'
              AND EvidenceObject='RCA_CPUSchedulerEvidence'
              AND RootCauseRole='PRIMARY'
              AND Confidence='HIGH'
        ) THEN 'PASS' ELSE 'FAIL' END

    , Capture38NoSupportedPrimary=
        CASE WHEN NOT EXISTS
        (
            SELECT 1
            FROM dbo.vw_RCA_CrossDomainCauseRanking
            WHERE CaptureRunID=38
              AND RootCauseRole='PRIMARY'
        ) THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
  13. FINAL ACCEPTANCE
==============================================================================*/
DECLARE
      @C20Cause varchar(60)
    , @C20Role varchar(20)
    , @C20Confidence varchar(20)
    , @C20Exec bigint
    , @C20Session int
    , @C38PrimaryCount int=0
    , @C42Cause varchar(60)
    , @C42Role varchar(20)
    , @C42Confidence varchar(20)
    , @C44Cause varchar(60)
    , @C44Role varchar(20)
    , @C44Confidence varchar(20)
    , @CanonicalDefinition2 nvarchar(max);

SELECT
      @C20Cause=PrimaryCauseCategory
    , @C20Role=PrimaryCauseRole
    , @C20Confidence=PrimaryConfidence
    , @C20Exec=PrimaryExecutionEvidenceID
    , @C20Session=PrimarySessionID
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=20;

SELECT
      @C38PrimaryCount=ISNULL(PrimaryCauseCount,0)
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=38;

SELECT
      @C42Cause=PrimaryCauseCategory
    , @C42Role=PrimaryCauseRole
    , @C42Confidence=PrimaryConfidence
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=42;

SELECT
      @C44Cause=PrimaryCauseCategory
    , @C44Role=PrimaryCauseRole
    , @C44Confidence=PrimaryConfidence
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=44;

SET @CanonicalDefinition2=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='13 - SCRIPT 72 FINAL ACCEPTANCE'

    , Capture20IO=
        CASE WHEN @C20Cause='IO_STORAGE_LATENCY'
                  AND @C20Role='PRIMARY'
                  AND @C20Confidence IN ('HIGH','MEDIUM')
             THEN 'PASS' ELSE 'FAIL' END

    , Capture20NoFabricatedSession=
        CASE WHEN @C20Exec IS NULL AND @C20Session IS NULL
             THEN 'PASS' ELSE 'FAIL' END

    , Capture38Uncertainty=
        CASE WHEN ISNULL(@C38PrimaryCount,0)=0
             THEN 'PASS' ELSE 'FAIL' END

    , Capture42Blocking=
        CASE WHEN @C42Cause='BLOCKING_WAIT_CHAIN'
                  AND @C42Role='PRIMARY'
                  AND @C42Confidence='HIGH'
             THEN 'PASS' ELSE 'FAIL' END

    , Capture44CPU=
        CASE WHEN @C44Cause='CPU_SCHEDULER'
                  AND @C44Role='PRIMARY'
                  AND @C44Confidence='HIGH'
             THEN 'PASS' ELSE 'FAIL' END

    , CanonicalUsesArbitration=
        CASE WHEN @CanonicalDefinition2 LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END

    , MultiPrimaryReviewAvailable=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_ArbitrationReview',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END

    , BlockingNarratorAvailable=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END

    , CPUNarratorAvailable=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END

    , IONarratorAvailable=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_IOStorage',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END

    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO'

    , OverallResult=
        CASE
          WHEN @C20Cause='IO_STORAGE_LATENCY'
           AND @C20Role='PRIMARY'
           AND @C20Confidence IN ('HIGH','MEDIUM')
           AND @C20Exec IS NULL
           AND @C20Session IS NULL
           AND ISNULL(@C38PrimaryCount,0)=0
           AND @C42Cause='BLOCKING_WAIT_CHAIN'
           AND @C42Role='PRIMARY'
           AND @C42Confidence='HIGH'
           AND @C44Cause='CPU_SCHEDULER'
           AND @C44Role='PRIMARY'
           AND @C44Confidence='HIGH'
           AND @CanonicalDefinition2 LIKE N'%vw_RCA_CrossDomainCauseSummary%'
           AND OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_ArbitrationReview',N'P') IS NOT NULL
           AND OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL
           AND OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NOT NULL
           AND OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_IOStorage',N'P') IS NOT NULL
          THEN
              'PASS - RCA ENGINE V1 END-TO-END REGRESSION COMPLETE'
          ELSE
              'REVIEW - RCA ENGINE V1 FINAL ACCEPTANCE DID NOT PASS ALL GATES'
        END

    , ProductionReadiness=
        CASE
          WHEN @C20Cause='IO_STORAGE_LATENCY'
           AND @C20Role='PRIMARY'
           AND @C20Confidence IN ('HIGH','MEDIUM')
           AND @C20Exec IS NULL
           AND @C20Session IS NULL
           AND ISNULL(@C38PrimaryCount,0)=0
           AND @C42Cause='BLOCKING_WAIT_CHAIN'
           AND @C42Role='PRIMARY'
           AND @C42Confidence='HIGH'
           AND @C44Cause='CPU_SCHEDULER'
           AND @C44Role='PRIMARY'
           AND @C44Confidence='HIGH'
           AND @CanonicalDefinition2 LIKE N'%vw_RCA_CrossDomainCauseSummary%'
          THEN 'READY FOR V1 FREEZE / OPERATIONALIZATION'
          ELSE 'NOT READY - REVIEW FAILED GATES'
        END;
GO


/*==============================================================================
  14. PRODUCTION USAGE
==============================================================================*/
SELECT
      ValidationSection='14 - PRODUCTION USAGE'
    , PrimaryDBACommand=
        N'EXEC DBA.dbo.usp_RCA_DBAAnswer @CaptureRunID = <CaptureRunID>;'
    , FriendlyAlias1=
        N'EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow @CaptureRunID = <CaptureRunID>;'
    , FriendlyAlias2=
        N'EXEC DBA.dbo.usp_RCA_ExplainDatabaseSlowness @CaptureRunID = <CaptureRunID>;'
    , SupportedV1Domains=
        N'BLOCKING_WAIT_CHAIN; CPU_SCHEDULER; IO_STORAGE_LATENCY; UNCERTAINTY; MULTI-PRIMARY REVIEW'
    , OperationalPrinciple=
        N'Trust persisted evidence and normalized arbitration. Do not infer unsupported causes from isolated counters or plan observations.';
GO


/*==============================================================================
  15. FINAL SAFETY
==============================================================================*/
SELECT
      ValidationSection='15 - SCRIPT 72 FINAL SAFETY'
    , ValidationOnly='YES'
    , Capture20Modified='NO'
    , Capture38Modified='NO'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , HistoricalCapturesModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        N'If Section 13 returns PASS - RCA ENGINE V1 END-TO-END REGRESSION COMPLETE, freeze the RCA v1 architecture and move to deployment documentation, runbook, and operational packaging.';
GO
