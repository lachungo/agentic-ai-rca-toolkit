USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  71_RCA_IO_Storage_Canonical_Narrator_v1.sql

  PURPOSE
  -------
  Add a human-readable I/O / storage latency narrator to the canonical RCA
  presentation layer using the normalized cross-domain arbitration contract.

  POSITIVE CONTROL
  ----------------
  Capture 20 is the existing persisted I/O positive control discovered by
  Scripts 69-70:

      CauseCategory   = IO_STORAGE_LATENCY
      RootCauseRole   = PRIMARY
      Confidence      = MEDIUM
      ArbitrationRank = 1
      EvidenceObject  = RCA_IOStorageEvidence

  REGRESSION CONTROLS
  -------------------
      Capture 38 -> ROOT CAUSE NOT CONFIRMED
      Capture 42 -> Blocking / wait-chain contention
      Capture 44 -> CPU / scheduler pressure
      Capture 20 -> I/O / storage latency

  ARCHITECTURAL RULE
  ------------------
  The canonical router consumes normalized arbitration. It does not rank raw
  domain tables itself.

  SAFETY
  ------
  Presentation layer only.

  This script does NOT:
      - alter dbo.RCA_IOStorageEvidence
      - alter dbo.usp_RCA_BuildIOStorageEvidence
      - change I/O thresholds
      - change RootCauseRole / Confidence
      - rebuild historical evidence
      - modify Captures 20, 38, 42, or 44
      - change normalized arbitration ranking
      - start a new capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 71 PRE-FLIGHT'
    , IOStorageEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , NormalizedCauseCandidates=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
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
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NULL
    THROW 57100,N'dbo.RCA_IOStorageEvidence is required.',1;

IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NULL
    THROW 57101,N'dbo.vw_RCA_CrossDomainCauseSummary is required.',1;

IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NULL
    THROW 57102,N'dbo.vw_RCA_CrossDomainCauseRanking is required.',1;
GO


/*==============================================================================
  1. I/O / STORAGE HUMAN-READABLE NARRATOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer_IOStorage
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
        THROW 57110,N'CaptureRunID does not exist.',1;

    DECLARE
          @DatabaseName sysname
        , @CaptureStatus nvarchar(60)
        , @IncidentStartUTC datetime2(3)
        , @IncidentEndUTC datetime2(3)

        , @IOStorageEvidenceID bigint
        , @EvidenceDatabaseName sysname
        , @DatabaseID int
        , @FileID int
        , @LogicalFileName sysname
        , @FileTypeDesc nvarchar(120)
        , @PhysicalName nvarchar(520)
        , @SampleCount int
        , @DeltaReads bigint
        , @DeltaReadMB decimal(19,4)
        , @DeltaReadStallMs bigint
        , @AvgReadLatencyMs decimal(19,4)
        , @DeltaWrites bigint
        , @DeltaWriteMB decimal(19,4)
        , @DeltaWriteStallMs bigint
        , @AvgWriteLatencyMs decimal(19,4)
        , @RootCauseRole varchar(20)
        , @Confidence varchar(20)
        , @EvidenceSummary nvarchar(max)
        , @RecommendedAction nvarchar(max);

    SELECT
          @DatabaseName=TargetDatabase
        , @CaptureStatus=CaptureStatus
        , @IncidentStartUTC=StartTimeUTC
        , @IncidentEndUTC=EndTimeUTC
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SELECT TOP (1)
          @IOStorageEvidenceID=i.IOStorageEvidenceID
        , @EvidenceDatabaseName=i.DatabaseName
        , @DatabaseID=i.DatabaseID
        , @FileID=i.FileID
        , @LogicalFileName=i.LogicalFileName
        , @FileTypeDesc=i.FileTypeDesc
        , @PhysicalName=i.PhysicalName
        , @SampleCount=i.SampleCount
        , @DeltaReads=i.DeltaReads
        , @DeltaReadMB=i.DeltaReadMB
        , @DeltaReadStallMs=i.DeltaReadStallMs
        , @AvgReadLatencyMs=i.AvgReadLatencyMs
        , @DeltaWrites=i.DeltaWrites
        , @DeltaWriteMB=i.DeltaWriteMB
        , @DeltaWriteStallMs=i.DeltaWriteStallMs
        , @AvgWriteLatencyMs=i.AvgWriteLatencyMs
        , @RootCauseRole=i.RootCauseRole
        , @Confidence=i.Confidence
        , @EvidenceSummary=i.EvidenceSummary
        , @RecommendedAction=i.RecommendedAction
    FROM dbo.RCA_IOStorageEvidence AS i
    WHERE i.CaptureRunID=@CaptureRunID
      AND i.RootCauseRole='PRIMARY'
      AND i.Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE i.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , ISNULL(i.SampleCount,0) DESC
        , i.IOStorageEvidenceID DESC;

    IF @IOStorageEvidenceID IS NULL
        THROW 57111,N'No PRIMARY MEDIUM/HIGH I/O storage evidence exists for this capture.',1;

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
        N'ROOT CAUSE IDENTIFIED'
    );

    INSERT @Rows VALUES
    (
        3,
        N'ROOT CAUSE',
        N'I/O / storage latency | Confidence: '
        + COALESCE(CONVERT(nvarchar(20),@Confidence),N'UNKNOWN')
    );

    INSERT @Rows VALUES
    (
        4,
        N'WHAT HAPPENED?',
        N'The RCA engine identified persisted I/O / storage latency evidence as the PRIMARY cause for '
        + COALESCE(@DatabaseName,N'the database')
        + N'. The affected file was '
        + COALESCE(@LogicalFileName,N'unknown')
        + N' ('
        + COALESCE(@FileTypeDesc,N'unknown file type')
        + N') in database '
        + COALESCE(@EvidenceDatabaseName,@DatabaseName,N'unknown')
        + N'. The condition was evaluated across '
        + COALESCE(CONVERT(nvarchar(20),@SampleCount),N'unknown')
        + N' sample(s).'
    );

    INSERT @Rows VALUES
    (
        5,
        N'WHO OR WHAT CAUSED IT?',
        N'The supported evidence is file-level rather than session-level. Database: '
        + COALESCE(@EvidenceDatabaseName,@DatabaseName,N'unknown')
        + N'. File: '
        + COALESCE(@LogicalFileName,N'unknown')
        + CASE
            WHEN @FileID IS NOT NULL
                THEN N' (FileID ' + CONVERT(nvarchar(20),@FileID) + N')'
            ELSE N''
          END
        + CASE
            WHEN @PhysicalName IS NOT NULL
                THEN N'. Physical path: ' + @PhysicalName
            ELSE N''
          END
        + N'. No primary execution/session attribution was manufactured because the persisted I/O evidence does not provide one.'
    );

    INSERT @Rows VALUES
    (
        6,
        N'WHY DO WE BELIEVE THIS?',
        COALESCE
        (
            @EvidenceSummary,
            N'RCA_IOStorageEvidence ID '
            + CONVERT(nvarchar(30),@IOStorageEvidenceID)
            + N' was persisted as '
            + COALESCE(CONVERT(nvarchar(20),@RootCauseRole),N'UNKNOWN')
            + N' with '
            + COALESCE(CONVERT(nvarchar(20),@Confidence),N'UNKNOWN')
            + N' confidence.'
        )
    );

    INSERT @Rows VALUES
    (
        7,
        N'WHAT WAS THE IMPACT?',
        N'Observed file activity during the evidence window: reads='
        + COALESCE(CONVERT(nvarchar(30),@DeltaReads),N'unknown')
        + N', read MB='
        + COALESCE(CONVERT(nvarchar(40),@DeltaReadMB),N'unknown')
        + N', read stall ms='
        + COALESCE(CONVERT(nvarchar(30),@DeltaReadStallMs),N'unknown')
        + N', average read latency='
        + COALESCE(CONVERT(nvarchar(40),@AvgReadLatencyMs),N'unknown')
        + N' ms; writes='
        + COALESCE(CONVERT(nvarchar(30),@DeltaWrites),N'unknown')
        + N', write MB='
        + COALESCE(CONVERT(nvarchar(40),@DeltaWriteMB),N'unknown')
        + N', write stall ms='
        + COALESCE(CONVERT(nvarchar(30),@DeltaWriteStallMs),N'unknown')
        + N', average write latency='
        + COALESCE(CONVERT(nvarchar(40),@AvgWriteLatencyMs),N'unknown')
        + N' ms.'
    );

    INSERT @Rows VALUES
    (
        8,
        N'WHAT SHOULD I DO?',
        COALESCE
        (
            @RecommendedAction,
            N'Correlate the affected database/file with workload I/O demand, storage path health, '
            + N'file placement, read/write latency, and any storage-side events during the incident window. '
            + N'Validate whether the workload legitimately required the observed physical I/O before changing configuration.'
        )
    );

    INSERT @Rows VALUES
    (
        9,
        N'WHAT SHOULD I NOT CHANGE YET?',
        N'Do not change MAXDOP, server memory, cost threshold, file layout, or storage configuration solely because cumulative waits or a single file-stat snapshot look high. '
        + N'The RCA conclusion must remain tied to persisted interval evidence from the incident window.'
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
  2. CANONICAL ROUTER - ADD I/O NARRATOR PLUG-IN
  Ranking remains owned by vw_RCA_CrossDomainCauseSummary.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @CaptureRunID IS NULL
        THROW 57120,N'@CaptureRunID is required.',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 57121,N'CaptureRunID does not exist.',1;

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

    IF @PrimaryCauseCategory IS NULL
       OR ISNULL(@PrimaryCauseCount,0)=0
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_TransactionAware
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    IF @PrimaryCauseCount>1
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_ArbitrationReview
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

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

    IF @PrimaryCauseCategory='IO_STORAGE_LATENCY'
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_IOStorage
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

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
        , N'The detector/ranking layer has established a supported cause, but the DBA presentation layer does not yet have a narrator for this cause category. '
          + N'Add a narrator without changing detector thresholds or root-cause ranking.'
    ORDER BY SectionOrder;
END;
GO


/*==============================================================================
  3. FRIENDLY ALIASES
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
      ValidationSection='1 - SCRIPT 71 DEPLOYMENT'
    , IONarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_IOStorage',N'P') IS NOT NULL
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
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  5. ROUTING MATRIX
==============================================================================*/
SELECT
      ValidationSection='2 - FOUR-WAY ROUTING MATRIX'
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
          WHEN s.PrimaryCauseCategory='IO_STORAGE_LATENCY'
              THEN 'IO / STORAGE'
          WHEN s.PrimaryCauseCategory IS NULL
              THEN 'UNCERTAINTY / FALLBACK'
          ELSE 'FUTURE DOMAIN - NARRATOR GAP'
        END
FROM dbo.RCA_CaptureRun AS c
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=c.CaptureRunID
WHERE c.CaptureRunID IN (20,38,42,44)
ORDER BY c.CaptureRunID;
GO


/*==============================================================================
  6. CAPTURE 20 I/O POSITIVE CONTROL
==============================================================================*/
SELECT
      ValidationSection='3 - CAPTURE 20 IO POSITIVE CONTROL'
    , CaptureRunID=20
    , ExpectedResult='ROOT CAUSE IDENTIFIED - IO / STORAGE LATENCY - MEDIUM';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=20;
GO


/*==============================================================================
  7. CAPTURE 42 BLOCKING REGRESSION
==============================================================================*/
SELECT
      ValidationSection='4 - CAPTURE 42 BLOCKING REGRESSION'
    , CaptureRunID=42
    , ExpectedResult='ROOT CAUSE IDENTIFIED - BLOCKING / WAIT-CHAIN - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO


/*==============================================================================
  8. CAPTURE 44 CPU REGRESSION
==============================================================================*/
SELECT
      ValidationSection='5 - CAPTURE 44 CPU REGRESSION'
    , CaptureRunID=44
    , ExpectedResult='ROOT CAUSE IDENTIFIED - CPU / SCHEDULER - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO


/*==============================================================================
  9. CAPTURE 38 NEGATIVE CONTROL
==============================================================================*/
SELECT
      ValidationSection='6 - CAPTURE 38 NEGATIVE CONTROL'
    , CaptureRunID=38
    , ExpectedResult='ROOT CAUSE NOT CONFIRMED';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;
GO


/*==============================================================================
  10. CANONICAL ARCHITECTURE CHECK
==============================================================================*/
DECLARE @CanonicalDefinition nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='7 - CANONICAL ARCHITECTURE CHECK'
    , ReferencesCrossDomainSummary=
        CASE WHEN @CanonicalDefinition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , RoutesBlockingByCategory=
        CASE WHEN @CanonicalDefinition LIKE N'%BLOCKING_WAIT_CHAIN%'
             THEN 'PASS' ELSE 'FAIL' END
    , RoutesCPUByCategory=
        CASE WHEN @CanonicalDefinition LIKE N'%CPU_SCHEDULER%'
             THEN 'PASS' ELSE 'FAIL' END
    , RoutesIOByCategory=
        CASE WHEN @CanonicalDefinition LIKE N'%IO_STORAGE_LATENCY%'
             THEN 'PASS' ELSE 'FAIL' END
    , SupportsMultiplePrimaryReview=
        CASE WHEN @CanonicalDefinition LIKE N'%usp_RCA_DBAAnswer_ArbitrationReview%'
             THEN 'PASS' ELSE 'FAIL' END
    , Interpretation=
        N'Canonical routing is category-based after normalized arbitration; detector tables are not independently ranked here.';
GO


/*==============================================================================
  11. ACCEPTANCE
==============================================================================*/
DECLARE
      @C20Category varchar(60)
    , @C20Role varchar(20)
    , @C20Confidence varchar(20)
    , @C20PrimaryCount int=0
    , @C38PrimaryCount int=0
    , @C42Category varchar(60)
    , @C44Category varchar(60);

SELECT
      @C20Category=PrimaryCauseCategory
    , @C20Role=PrimaryCauseRole
    , @C20Confidence=PrimaryConfidence
    , @C20PrimaryCount=PrimaryCauseCount
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=20;

SELECT
      @C38PrimaryCount=ISNULL(PrimaryCauseCount,0)
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=38;

SELECT @C42Category=PrimaryCauseCategory
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=42;

SELECT @C44Category=PrimaryCauseCategory
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=44;

SELECT
      ValidationSection='8 - SCRIPT 71 ACCEPTANCE'
    , Capture20IOPrimary=
        CASE WHEN @C20Category='IO_STORAGE_LATENCY'
                  AND @C20Role='PRIMARY'
                  AND @C20PrimaryCount=1
             THEN 'PASS' ELSE 'FAIL' END
    , Capture20Confidence=
        CASE WHEN @C20Confidence='MEDIUM' THEN 'PASS'
             WHEN @C20Confidence='HIGH' THEN 'PASS'
             ELSE 'FAIL' END
    , Capture42Blocking=
        CASE WHEN @C42Category='BLOCKING_WAIT_CHAIN' THEN 'PASS' ELSE 'FAIL' END
    , Capture44CPU=
        CASE WHEN @C44Category='CPU_SCHEDULER' THEN 'PASS' ELSE 'FAIL' END
    , Capture38Uncertainty=
        CASE WHEN ISNULL(@C38PrimaryCount,0)=0 THEN 'PASS' ELSE 'FAIL' END
    , IONarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_IOStorage',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalUsesArbitration=
        CASE WHEN @CanonicalDefinition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO'
    , OverallResult=
        CASE
          WHEN @C20Category='IO_STORAGE_LATENCY'
           AND @C20Role='PRIMARY'
           AND @C20PrimaryCount=1
           AND @C20Confidence IN ('HIGH','MEDIUM')
           AND @C42Category='BLOCKING_WAIT_CHAIN'
           AND @C44Category='CPU_SCHEDULER'
           AND ISNULL(@C38PrimaryCount,0)=0
           AND OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_IOStorage',N'P') IS NOT NULL
           AND @CanonicalDefinition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
          THEN
              'PASS - CANONICAL DBA ANSWER NOW SUPPORTS BLOCKING, CPU, IO, AND UNCERTAINTY'
          ELSE
              'REVIEW - FOUR-WAY CANONICAL ROUTING DID NOT MATCH EXPECTATIONS'
        END
    , NextStep=
        N'If accepted, freeze I/O presentation and move to final cross-domain regression / production acceptance.';
GO


/*==============================================================================
  12. SAFETY
==============================================================================*/
SELECT
      ValidationSection='9 - SCRIPT 71 SAFETY'
    , IONarratorAdded='YES'
    , CanonicalIORouteAdded='YES'
    , Capture20Modified='NO'
    , Capture38Modified='NO'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , IOEvidenceModified='NO'
    , IOBuilderModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
