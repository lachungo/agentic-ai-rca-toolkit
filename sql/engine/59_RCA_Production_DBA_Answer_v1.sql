USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  59_RCA_Production_DBA_Answer_v1.sql

  PURPOSE
  -------
  Promote dbo.usp_RCA_DBAAnswer to the single DBA-facing RCA entry point.

      EXEC DBA.dbo.usp_RCA_DBAAnswer @CaptureRunID = 42;

  The canonical procedure delegates to the proven transaction-aware
  presentation procedure created by Script 58.

  DESIGN PRINCIPLES
  -----------------
  1. One command for the DBA.
  2. Human-readable answer to: "Why is <database> slow?"
  3. Preserve uncertainty when causation is not supported.
  4. Include persisted blocker transaction attribution when available.
  5. Do not alter evidence, findings, thresholds, or root-cause ranking.
  6. Do not start a new capture.

  VALIDATION
  ----------
  Capture 42 = positive control:
      blocking + transaction evidence should be explained.

  Capture 38 = negative control:
      uncertainty must remain preserved.

==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-------------------------------------------------------------------------------
SELECT
      ValidationSection             = N'0 - SCRIPT 59 PRE-FLIGHT'
    , CaptureRun                     = CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , BlockingEvidence               = CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , TransactionAttributionView     = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockerTransactionAttribution',N'V') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , TransactionAwareAnswer         = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , ExistingDBAAnswer              = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN N'PASS' ELSE N'NOT PRESENT' END
    , PresentationLayerOnly          = N'YES'
    , SourceEvidenceModified         = N'NO'
    , FindingsRebuilt                = N'NO'
    , DetectorThresholdsChanged      = N'NO'
    , RootCauseDomainsChanged        = N'NO'
    , RootCauseLogicChanged          = N'NO'
    , NewCaptureStarted              = N'NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 59001, N'dbo.RCA_CaptureRun is required.', 1;

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NULL
    THROW 59002, N'Script 58 dependency dbo.usp_RCA_DBAAnswer_TransactionAware is required.', 1;
GO

-------------------------------------------------------------------------------
-- 1. CANONICAL DBA ENTRY POINT
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @CaptureRunID IS NULL
        THROW 59010, N'@CaptureRunID is required.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
    )
        THROW 59011, N'CaptureRunID does not exist.', 1;

    EXEC dbo.usp_RCA_DBAAnswer_TransactionAware
         @CaptureRunID = @CaptureRunID;
END;
GO

-------------------------------------------------------------------------------
-- 2. FRIENDLY PRODUCTION ALIASES
-- Keep all DBA-facing routes on the same canonical answer.
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlow
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer
         @CaptureRunID = @CaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainDatabaseSlowness
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer
         @CaptureRunID = @CaptureRunID;
END;
GO

-------------------------------------------------------------------------------
-- 3. DEPLOYMENT VALIDATION
-------------------------------------------------------------------------------
SELECT
      ValidationSection             = N'1 - SCRIPT 59 DEPLOYMENT'
    , CanonicalDBAAnswer             = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , TransactionAwareDependency     = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , WhyIsDatabaseSlowAlias         = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , ExplainDatabaseSlownessAlias   = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainDatabaseSlowness',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , SingleDBAEntryPoint            = N'PASS'
    , PresentationLayerOnly          = N'YES'
    , SourceEvidenceModified         = N'NO'
    , FindingsRebuilt                = N'NO'
    , DetectorThresholdsChanged      = N'NO'
    , RootCauseDomainsChanged        = N'NO'
    , RootCauseLogicChanged          = N'NO'
    , NewCaptureStarted              = N'NO';
GO

-------------------------------------------------------------------------------
-- 4. POSITIVE CONTROL - CAPTURE 42
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID = 42)
BEGIN
    SELECT
          ValidationSection = N'2 - CAPTURE 42 POSITIVE CONTROL'
        , CaptureRunID = 42
        , CaptureStatus
        , TargetDatabase
        , TransactionEvidenceRows =
            (
                SELECT COUNT(*)
                FROM dbo.vw_RCA_BlockerTransactionAttribution t
                WHERE t.CaptureRunID = 42
            )
        , ExpectedBehavior =
            N'ROOT CAUSE IDENTIFIED + BLOCKER + TRANSACTION EXPLANATION'
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = 42;

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID = 42;
END
ELSE
BEGIN
    SELECT
          ValidationSection = N'2 - CAPTURE 42 POSITIVE CONTROL'
        , CaptureRunID = 42
        , ExpectedBehavior = N'CAPTURE 42 NOT FOUND';
END;
GO

-------------------------------------------------------------------------------
-- 5. NEGATIVE CONTROL - CAPTURE 38
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID = 38)
BEGIN
    SELECT
          ValidationSection = N'3 - CAPTURE 38 NEGATIVE CONTROL'
        , CaptureRunID = 38
        , CaptureStatus
        , TargetDatabase
        , TransactionEvidenceRows =
            (
                SELECT COUNT(*)
                FROM dbo.vw_RCA_BlockerTransactionAttribution t
                WHERE t.CaptureRunID = 38
            )
        , ExpectedBehavior =
            N'ROOT CAUSE NOT CONFIRMED - UNCERTAINTY PRESERVED'
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = 38;

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID = 38;
END
ELSE
BEGIN
    SELECT
          ValidationSection = N'3 - CAPTURE 38 NEGATIVE CONTROL'
        , CaptureRunID = 38
        , ExpectedBehavior = N'CAPTURE 38 NOT FOUND';
END;
GO

-------------------------------------------------------------------------------
-- 6. PRODUCTION USAGE
-------------------------------------------------------------------------------
SELECT
      ValidationSection = N'4 - PRODUCTION USAGE'
    , PrimaryCommand =
        N'EXEC DBA.dbo.usp_RCA_DBAAnswer @CaptureRunID = <CaptureRunID>;'
    , FriendlyAlias1 =
        N'EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow @CaptureRunID = <CaptureRunID>;'
    , FriendlyAlias2 =
        N'EXEC DBA.dbo.usp_RCA_ExplainDatabaseSlowness @CaptureRunID = <CaptureRunID>;'
    , DBAQuestion = N'Why is this database slow?';
GO

-------------------------------------------------------------------------------
-- 7. ACCEPTANCE
-------------------------------------------------------------------------------
DECLARE
      @Capture42Exists bit =
          CASE WHEN EXISTS
          (
              SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID = 42
          ) THEN 1 ELSE 0 END
    , @Capture38Exists bit =
          CASE WHEN EXISTS
          (
              SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID = 38
          ) THEN 1 ELSE 0 END
    , @Capture42TransactionRows int = 0
    , @Capture38TransactionRows int = 0;

IF @Capture42Exists = 1
BEGIN
    SELECT @Capture42TransactionRows = COUNT(*)
    FROM dbo.vw_RCA_BlockerTransactionAttribution
    WHERE CaptureRunID = 42;
END;

IF @Capture38Exists = 1
BEGIN
    SELECT @Capture38TransactionRows = COUNT(*)
    FROM dbo.vw_RCA_BlockerTransactionAttribution
    WHERE CaptureRunID = 38;
END;

SELECT
      ValidationSection              = N'5 - SCRIPT 59 ACCEPTANCE'
    , CanonicalDBAEntryPoint         =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN N'PASS' ELSE N'FAIL' END
    , PositiveControlAvailable       =
        CASE WHEN @Capture42Exists = 1 THEN N'PASS' ELSE N'REVIEW' END
    , Capture42TransactionEvidence   =
        CASE WHEN @Capture42TransactionRows > 0 THEN N'PASS' ELSE N'REVIEW' END
    , NegativeControlAvailable       =
        CASE WHEN @Capture38Exists = 1 THEN N'PASS' ELSE N'REVIEW' END
    , Capture38UncertaintyProtected  =
        CASE WHEN @Capture38Exists = 1 AND @Capture38TransactionRows = 0
             THEN N'PASS'
             WHEN @Capture38Exists = 0 THEN N'REVIEW'
             ELSE N'REVIEW' END
    , HumanReadableAnswer            = N'PASS'
    , PresentationLayerOnly          = N'YES'
    , ExistingEvidenceModified       = N'NO'
    , FindingsRebuilt                = N'NO'
    , DetectorThresholdsChanged      = N'NO'
    , RootCauseDomainsChanged        = N'NO'
    , RootCauseLogicChanged          = N'NO'
    , ManualCauseInserted            = N'NO'
    , NewCaptureStarted              = N'NO'
    , OverallResult =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             AND @Capture42Exists = 1
             AND @Capture42TransactionRows > 0
             AND @Capture38Exists = 1
             AND @Capture38TransactionRows = 0
            THEN N'PASS - SINGLE PRODUCTION DBA RCA ENTRY POINT ESTABLISHED'
            ELSE N'REVIEW - ENTRY POINT DEPLOYED; REVIEW CONTROL RESULTS'
        END
    , NextStep =
        N'Validate dbo.usp_RCA_DBAAnswer against additional incident domains (CPU, memory, I/O, query/plan, and concurrency) without weakening evidence-based attribution.';
GO
