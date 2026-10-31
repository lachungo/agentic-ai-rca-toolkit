USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  67_RCA_Canonical_DBA_Answer_Uses_Arbitration_v1.sql

  PURPOSE
  -------
  Replace hard-coded domain ordering inside dbo.usp_RCA_DBAAnswer with the
  normalized cross-domain arbitration layer created by Script 66.

  AUTHORITATIVE INPUTS
  --------------------
      dbo.vw_RCA_CrossDomainCauseSummary
      dbo.vw_RCA_CrossDomainCauseRanking

  ROUTING BEHAVIOR
  ----------------
  1. No supported normalized cause
        -> preserve existing uncertainty behavior.

  2. Exactly one supported PRIMARY cause
        BLOCKING_WAIT_CHAIN -> existing transaction-aware blocking narrator.
        CPU_SCHEDULER       -> existing CPU narrator.

  3. Multiple PRIMARY causes
        -> DO NOT silently choose the first domain.
        -> return a human-readable arbitration-review narrative showing the
           ranked supported causes and their evidence.

  ARCHITECTURAL PRINCIPLE
  -----------------------
      Domain detectors detect.
      Synthesis / ranking arbitrates.
      Presentation narrates.

  SAFETY
  ------
  This script does NOT:
      - change detector thresholds
      - change detector root-cause roles/confidence
      - rebuild findings
      - modify historical evidence
      - modify Captures 38, 42, or 44
      - change normalized candidate/ranking logic
      - start a new capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 67 PRE-FLIGHT'
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PresentationLayerOnly='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NULL
    THROW 56700,N'Script 66 dependency dbo.vw_RCA_CrossDomainCauseSummary is required.',1;

IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NULL
    THROW 56701,N'Script 66 dependency dbo.vw_RCA_CrossDomainCauseRanking is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NULL
    THROW 56702,N'Blocking narrator is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NULL
    THROW 56703,N'CPU narrator is required.',1;
GO


/*==============================================================================
  1. MULTIPLE-PRIMARY ARBITRATION REVIEW NARRATOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer_ArbitrationReview
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 56710,N'CaptureRunID does not exist.',1;

    DECLARE
          @DatabaseName sysname
        , @PrimaryCount int=0
        , @SupportedCount int=0
        , @TopCause nvarchar(200)
        , @TopConfidence varchar(20)
        , @CauseList nvarchar(max)=N''
        , @EvidenceList nvarchar(max)=N'';

    SELECT @DatabaseName=TargetDatabase
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SELECT
          @PrimaryCount=ISNULL(MAX(PrimaryCauseCount),0)
        , @SupportedCount=ISNULL(MAX(SupportedCauseCount),0)
        , @TopCause=MAX(CASE WHEN ArbitrationRank=1 THEN CauseDisplayName END)
        , @TopConfidence=MAX(CASE WHEN ArbitrationRank=1 THEN Confidence END)
    FROM dbo.vw_RCA_CrossDomainCauseRanking
    WHERE CaptureRunID=@CaptureRunID;

    /*
      Build compact ranked text without STRING_AGG so we avoid the 8,000-byte
      issue discovered during Script 63.
    */
    DECLARE
          @Rank int
        , @CauseDisplayName nvarchar(200)
        , @Role varchar(20)
        , @Confidence varchar(20)
        , @EvidenceCount bigint
        , @EvidenceObject sysname
        , @EvidenceID bigint
        , @PrimaryEvidence nvarchar(max);

    DECLARE CauseCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT
          ArbitrationRank
        , CauseDisplayName
        , RootCauseRole
        , Confidence
        , EvidenceCount
        , EvidenceObject
        , EvidenceID
        , PrimaryEvidence
    FROM dbo.vw_RCA_CrossDomainCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY ArbitrationRank;

    OPEN CauseCursor;

    FETCH NEXT FROM CauseCursor
    INTO
          @Rank
        , @CauseDisplayName
        , @Role
        , @Confidence
        , @EvidenceCount
        , @EvidenceObject
        , @EvidenceID
        , @PrimaryEvidence;

    WHILE @@FETCH_STATUS=0
    BEGIN
        SET @CauseList =
            @CauseList
            + CASE WHEN LEN(@CauseList)>0 THEN N'; ' ELSE N'' END
            + N'#' + CONVERT(nvarchar(20),@Rank)
            + N' ' + COALESCE(@CauseDisplayName,N'Unknown cause')
            + N' [' + COALESCE(@Role,N'UNKNOWN')
            + N'/' + COALESCE(@Confidence,N'UNKNOWN') + N']'
            + N' evidence=' + COALESCE(CONVERT(nvarchar(30),@EvidenceCount),N'0');

        SET @EvidenceList =
            @EvidenceList
            + CASE WHEN LEN(@EvidenceList)>0 THEN N' | ' ELSE N'' END
            + N'#' + CONVERT(nvarchar(20),@Rank)
            + N' ' + COALESCE(@EvidenceObject,N'unknown evidence object')
            + N' ID ' + COALESCE(CONVERT(nvarchar(30),@EvidenceID),N'unknown')
            + N': '
            + LEFT(COALESCE(@PrimaryEvidence,N'No evidence text available.'),1500);

        FETCH NEXT FROM CauseCursor
        INTO
              @Rank
            , @CauseDisplayName
            , @Role
            , @Confidence
            , @EvidenceCount
            , @EvidenceObject
            , @EvidenceID
            , @PrimaryEvidence;
    END;

    CLOSE CauseCursor;
    DEALLOCATE CauseCursor;

    DECLARE @Rows TABLE
    (
          SectionOrder int NOT NULL
        , ReportSection nvarchar(100) NOT NULL
        , Narrative nvarchar(max) NOT NULL
    );

    INSERT @Rows VALUES
    (
        1,
        N'QUESTION',
        N'Why is ' + COALESCE(@DatabaseName,N'the database') + N' slow?'
    );

    INSERT @Rows VALUES
    (
        2,
        N'ANSWER',
        N'MULTIPLE SUPPORTED PRIMARY CAUSES - ARBITRATION REVIEW REQUIRED'
    );

    INSERT @Rows VALUES
    (
        3,
        N'ROOT CAUSE',
        N'The RCA engine has more than one independently-supported PRIMARY cause. '
        + N'The presentation layer will not silently manufacture a winner.'
    );

    INSERT @Rows VALUES
    (
        4,
        N'WHAT HAPPENED?',
        N'This capture contains '
        + CONVERT(nvarchar(20),@PrimaryCount)
        + N' PRIMARY cause(s) across '
        + CONVERT(nvarchar(20),@SupportedCount)
        + N' supported cause(s). Current normalized ordering places '
        + COALESCE(@TopCause,N'an unknown cause')
        + N' first with confidence '
        + COALESCE(CONVERT(nvarchar(20),@TopConfidence),N'UNKNOWN')
        + N', but multiple detector domains independently claimed PRIMARY.'
    );

    INSERT @Rows VALUES
    (
        5,
        N'SUPPORTED CAUSES',
        COALESCE(NULLIF(@CauseList,N''),N'No normalized cause rows were available.')
    );

    INSERT @Rows VALUES
    (
        6,
        N'WHY DO WE BELIEVE THIS?',
        COALESCE(NULLIF(@EvidenceList,N''),N'No normalized evidence text was available.')
    );

    INSERT @Rows VALUES
    (
        7,
        N'WHAT SHOULD I DO?',
        N'Review timing, correlation keys, impacted executions, evidence persistence, '
        + N'and causal direction across the supported domains. Decide whether one cause '
        + N'initiated the incident and the others were downstream effects before changing '
        + N'detector roles or confidence.'
    );

    INSERT @Rows VALUES
    (
        8,
        N'WHAT SHOULD I NOT CHANGE YET?',
        N'Do not change detector thresholds or instance-wide SQL configuration merely '
        + N'to force one cause to win. Resolve the cross-domain causal relationship first.'
    );

    SELECT
          SectionOrder
        , ReportSection
        , Narrative
    FROM @Rows
    ORDER BY SectionOrder;
END;
GO


/*==============================================================================
  2. CANONICAL DBA ANSWER - ARBITRATION-DRIVEN
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @CaptureRunID IS NULL
        THROW 56720,N'@CaptureRunID is required.',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 56721,N'CaptureRunID does not exist.',1;

    DECLARE
          @PrimaryCauseCategory varchar(60)
        , @PrimaryCauseRole varchar(20)
        , @PrimaryConfidence varchar(20)
        , @SupportedCauseCount int=0
        , @PrimaryCauseCount int=0
        , @ArbitrationStatus varchar(100);

    SELECT
          @PrimaryCauseCategory=PrimaryCauseCategory
        , @PrimaryCauseRole=PrimaryCauseRole
        , @PrimaryConfidence=PrimaryConfidence
        , @SupportedCauseCount=SupportedCauseCount
        , @PrimaryCauseCount=PrimaryCauseCount
        , @ArbitrationStatus=ArbitrationStatus
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=@CaptureRunID;

    /*----------------------------------------------------------------------
      No supported normalized primary cause:
      Preserve the already-proven uncertainty behavior.
    ----------------------------------------------------------------------*/
    IF @PrimaryCauseCategory IS NULL
       OR ISNULL(@PrimaryCauseCount,0)=0
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_TransactionAware
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    /*----------------------------------------------------------------------
      More than one detector independently claimed PRIMARY.
      Do not silently select based on procedural IF order.
    ----------------------------------------------------------------------*/
    IF @PrimaryCauseCount>1
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_ArbitrationReview
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    /*----------------------------------------------------------------------
      Exactly one supported PRIMARY.
      Route by the authoritative normalized cause category.
    ----------------------------------------------------------------------*/
    IF @PrimaryCauseCategory='BLOCKING_WAIT_CHAIN'
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_TransactionAware
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    IF @PrimaryCauseCategory='CPU_SCHEDULER'
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_CPU
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    /*----------------------------------------------------------------------
      Future domain exists in normalized ranking but has no narrator yet.
      Preserve evidence and expose the presentation gap explicitly.
    ----------------------------------------------------------------------*/
    SELECT
          SectionOrder=1
        , ReportSection=N'QUESTION'
        , Narrative=
            N'Why is '
            + COALESCE
              (
                  (SELECT TargetDatabase
                   FROM dbo.RCA_CaptureRun
                   WHERE CaptureRunID=@CaptureRunID),
                  N'the database'
              )
            + N' slow?'

    UNION ALL

    SELECT
          2
        , N'ANSWER'
        , N'ROOT CAUSE IDENTIFIED - PRESENTATION NARRATOR NOT YET IMPLEMENTED'

    UNION ALL

    SELECT
          3
        , N'ROOT CAUSE'
        , N'Cause category: '
          + COALESCE(CONVERT(nvarchar(60),@PrimaryCauseCategory),N'UNKNOWN')
          + N' | Role: '
          + COALESCE(CONVERT(nvarchar(20),@PrimaryCauseRole),N'UNKNOWN')
          + N' | Confidence: '
          + COALESCE(CONVERT(nvarchar(20),@PrimaryConfidence),N'UNKNOWN')

    UNION ALL

    SELECT
          4
        , N'WHAT SHOULD I DO?'
        , N'The detector/ranking layer has established a supported cause, but the DBA '
          + N'presentation layer does not yet have a narrator for this cause category. '
          + N'Add a narrator without changing detector thresholds or root-cause ranking.'
    ORDER BY SectionOrder;
END;
GO


/*==============================================================================
  3. KEEP FRIENDLY ALIASES ON CANONICAL ROUTER
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlow
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=@CaptureRunID;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainDatabaseSlowness
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
  4. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection='1 - SCRIPT 67 DEPLOYMENT'
    , ArbitrationReviewNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_ArbitrationReview',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , WhyIsDatabaseSlowAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExplainDatabaseSlownessAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainDatabaseSlowness',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , UsesNormalizedArbitration='YES'
    , HardCodedBlockingBeforeCPU='NO'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  5. ROUTING MATRIX FOR CONTROL CAPTURES
==============================================================================*/
SELECT
      ValidationSection='2 - ARBITRATION ROUTING MATRIX'
    , c.CaptureRunID
    , s.PrimaryCauseCategory
    , s.PrimaryCauseRole
    , s.PrimaryConfidence
    , s.SupportedCauseCount
    , s.PrimaryCauseCount
    , s.ArbitrationStatus
    , ExpectedNarrator=
        CASE
          WHEN s.PrimaryCauseCount>1
              THEN 'ARBITRATION REVIEW'
          WHEN s.PrimaryCauseCategory='BLOCKING_WAIT_CHAIN'
              THEN 'BLOCKING / TRANSACTION'
          WHEN s.PrimaryCauseCategory='CPU_SCHEDULER'
              THEN 'CPU / SCHEDULER'
          WHEN s.PrimaryCauseCategory IS NULL
              THEN 'UNCERTAINTY / FALLBACK'
          ELSE 'FUTURE DOMAIN - NARRATOR GAP'
        END
FROM dbo.RCA_CaptureRun AS c
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=c.CaptureRunID
WHERE c.CaptureRunID IN (38,42,44)
ORDER BY c.CaptureRunID;
GO


/*==============================================================================
  6. CAPTURE 42 REGRESSION
==============================================================================*/
SELECT
      ValidationSection='3 - CAPTURE 42 ARBITRATION-DRIVEN ANSWER'
    , ExpectedResult='ROOT CAUSE IDENTIFIED - BLOCKING / WAIT-CHAIN';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO


/*==============================================================================
  7. CAPTURE 44 REGRESSION
==============================================================================*/
SELECT
      ValidationSection='4 - CAPTURE 44 ARBITRATION-DRIVEN ANSWER'
    , ExpectedResult='ROOT CAUSE IDENTIFIED - CPU / SCHEDULER';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO


/*==============================================================================
  8. CAPTURE 38 NEGATIVE CONTROL
==============================================================================*/
SELECT
      ValidationSection='5 - CAPTURE 38 ARBITRATION-DRIVEN ANSWER'
    , ExpectedResult='ROOT CAUSE NOT CONFIRMED';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;
GO


/*==============================================================================
  9. EXISTING MULTI-PRIMARY TEST CASES
  Script 66 discovered captures 8 and 13 with multiple PRIMARY causes.
  Run them only if they still exist.
==============================================================================*/
IF EXISTS
(
    SELECT 1
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=8
      AND PrimaryCauseCount>1
)
BEGIN
    SELECT
          ValidationSection='6 - CAPTURE 8 MULTI-PRIMARY REVIEW'
        , ExpectedResult='MULTIPLE SUPPORTED PRIMARY CAUSES - ARBITRATION REVIEW REQUIRED';

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
          ValidationSection='6A - CAPTURE 13 MULTI-PRIMARY REVIEW'
        , ExpectedResult='MULTIPLE SUPPORTED PRIMARY CAUSES - ARBITRATION REVIEW REQUIRED';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=13;
END;
GO


/*==============================================================================
  10. CANONICAL PROCEDURE ARCHITECTURE CHECK
==============================================================================*/
DECLARE @Definition nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='7 - CANONICAL ARCHITECTURE CHECK'
    , ReferencesCrossDomainSummary=
        CASE WHEN @Definition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , ReferencesBlockingEvidenceDirectly=
        CASE WHEN @Definition LIKE N'%RCA_BlockingEvidence%'
             THEN 'REVIEW' ELSE 'PASS' END
    , ReferencesCPUEvidenceDirectly=
        CASE WHEN @Definition LIKE N'%RCA_CPUSchedulerEvidence%'
             THEN 'REVIEW' ELSE 'PASS' END
    , SupportsMultiplePrimaryReview=
        CASE WHEN @Definition LIKE N'%usp_RCA_DBAAnswer_ArbitrationReview%'
             THEN 'PASS' ELSE 'FAIL' END
    , Interpretation=
        N'Canonical DBA answer should consume normalized arbitration and delegate narration; it should not independently rank raw detector tables.';
GO


/*==============================================================================
  11. ACCEPTANCE
==============================================================================*/
DECLARE
      @C38PrimaryCount int=0
    , @C42Category varchar(60)
    , @C42PrimaryCount int=0
    , @C44Category varchar(60)
    , @C44PrimaryCount int=0;

SELECT
      @C38PrimaryCount=ISNULL(PrimaryCauseCount,0)
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=38;

SELECT
      @C42Category=PrimaryCauseCategory
    , @C42PrimaryCount=PrimaryCauseCount
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=42;

SELECT
      @C44Category=PrimaryCauseCategory
    , @C44PrimaryCount=PrimaryCauseCount
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=44;

SELECT
      ValidationSection='8 - SCRIPT 67 ACCEPTANCE'
    , Capture38Uncertainty=
        CASE WHEN ISNULL(@C38PrimaryCount,0)=0 THEN 'PASS' ELSE 'FAIL' END
    , Capture42Blocking=
        CASE WHEN @C42Category='BLOCKING_WAIT_CHAIN'
                  AND @C42PrimaryCount=1
             THEN 'PASS' ELSE 'FAIL' END
    , Capture44CPU=
        CASE WHEN @C44Category='CPU_SCHEDULER'
                  AND @C44PrimaryCount=1
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalUsesArbitration=
        CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'))
                    LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , MultiplePrimarySafety=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_ArbitrationReview',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO'
    , OverallResult=
        CASE
          WHEN ISNULL(@C38PrimaryCount,0)=0
           AND @C42Category='BLOCKING_WAIT_CHAIN'
           AND @C42PrimaryCount=1
           AND @C44Category='CPU_SCHEDULER'
           AND @C44PrimaryCount=1
           AND OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'))
                    LIKE N'%vw_RCA_CrossDomainCauseSummary%'
          THEN
              'PASS - CANONICAL DBA ANSWER NOW CONSUMES CROSS-DOMAIN ARBITRATION'
          ELSE
              'REVIEW - CANONICAL ARBITRATION ROUTING DID NOT MATCH CONTROL EXPECTATIONS'
        END
    , NextStep=
        N'If accepted, freeze arbitration routing and begin the next root-cause domain. '
        + N'Future narrators should plug into normalized CauseCategory rather than add detector-specific ranking inside usp_RCA_DBAAnswer.';
GO


/*==============================================================================
  12. SAFETY
==============================================================================*/
SELECT
      ValidationSection='9 - SCRIPT 67 SAFETY'
    , ArbitrationDrivenRouter='YES'
    , MultiplePrimaryReviewNarrator='YES'
    , Capture38Modified='NO'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
