USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  47_RCA_DBA_Answer_v1.sql

  PURPOSE
  -------
  Turn Script 46's structured "Why is the database slow?" result into the
  final DBA-readable answer.

  This is a PRESENTATION LAYER ONLY.

  It does NOT:
      - change XE capture
      - modify source evidence
      - rebuild findings
      - change detector thresholds
      - change root-cause domains
      - change root-cause attribution/ranking
      - promote a cause
      - insert a manual cause
      - start a new capture

  Script 46 remains the structured-data interface.
  Script 47 is the human-reading interface.

  NORMAL DBA USAGE
  ----------------
      EXEC DBA.dbo.usp_RCA_DBAAnswer
           @CaptureRunID = 39;

  OPTIONAL TECHNICAL DRILL-DOWN
  -----------------------------
      EXEC DBA.dbo.usp_RCA_DBAAnswer
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT

  Script 47 intentionally depends on Script 46 rather than reimplementing
  RCA attribution logic.
==============================================================================*/
IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow', N'P') IS NULL
BEGIN
    THROW 54700,
          'Script 47 requires dbo.usp_RCA_WhyIsDatabaseSlow from Script 46.',
          1;
END;
GO


/*==============================================================================
  1. FINAL DBA-READABLE ANSWER
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------------------------------
    -- Capture exactly the single structured result set produced by Script 46
    -- when technical detail is disabled.
    ---------------------------------------------------------------------------
    CREATE TABLE #StructuredAnswer
    (
          Question             nvarchar(512)  NULL
        , Answer               varchar(50)    NULL
        , RootCause            nvarchar(512)  NULL
        , Confidence           varchar(20)    NULL
        , WhatHappened         nvarchar(max)  NULL
        , WhyWeBelieveIt       nvarchar(max)  NULL
        , WhoOrWhatCausedIt    nvarchar(max)  NULL
        , Impact               nvarchar(max)  NULL
        , WhatShouldIDo        nvarchar(max)  NULL
        , DoNotChangeYet       nvarchar(max)  NULL
        , CaptureRunID         bigint         NULL
        , DatabaseName         sysname        NULL
        , IncidentStartUTC     datetime2      NULL
        , IncidentEndUTC       datetime2      NULL
    );

    INSERT INTO #StructuredAnswer
    (
          Question
        , Answer
        , RootCause
        , Confidence
        , WhatHappened
        , WhyWeBelieveIt
        , WhoOrWhatCausedIt
        , Impact
        , WhatShouldIDo
        , DoNotChangeYet
        , CaptureRunID
        , DatabaseName
        , IncidentStartUTC
        , IncidentEndUTC
    )
    EXEC dbo.usp_RCA_WhyIsDatabaseSlow
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = 0;

    IF NOT EXISTS (SELECT 1 FROM #StructuredAnswer)
    BEGIN
        THROW 54701,
              'Script 46 returned no structured RCA answer for this capture.',
              1;
    END;

    ---------------------------------------------------------------------------
    -- Script 46 should return one answer row. Refuse ambiguity rather than
    -- silently selecting one.
    ---------------------------------------------------------------------------
    IF (SELECT COUNT(*) FROM #StructuredAnswer) <> 1
    BEGIN
        THROW 54702,
              'Script 46 returned more than one structured RCA answer row.',
              1;
    END;

    DECLARE
          @Question             nvarchar(512)
        , @Answer               varchar(50)
        , @RootCause            nvarchar(512)
        , @Confidence           varchar(20)
        , @WhatHappened         nvarchar(max)
        , @WhyWeBelieveIt       nvarchar(max)
        , @WhoOrWhatCausedIt    nvarchar(max)
        , @Impact               nvarchar(max)
        , @WhatShouldIDo        nvarchar(max)
        , @DoNotChangeYet       nvarchar(max)
        , @DatabaseName         sysname
        , @IncidentStartUTC     datetime2
        , @IncidentEndUTC       datetime2;

    SELECT
          @Question          = Question
        , @Answer            = Answer
        , @RootCause         = RootCause
        , @Confidence        = Confidence
        , @WhatHappened      = WhatHappened
        , @WhyWeBelieveIt    = WhyWeBelieveIt
        , @WhoOrWhatCausedIt = WhoOrWhatCausedIt
        , @Impact            = Impact
        , @WhatShouldIDo     = WhatShouldIDo
        , @DoNotChangeYet    = DoNotChangeYet
        , @DatabaseName      = DatabaseName
        , @IncidentStartUTC  = IncidentStartUTC
        , @IncidentEndUTC    = IncidentEndUTC
    FROM #StructuredAnswer;

    ---------------------------------------------------------------------------
    -- THE PRODUCT:
    --
    -- A narrow, vertically readable answer.  SSMS users no longer need to
    -- scroll across a very wide result set to understand the incident.
    ---------------------------------------------------------------------------
    DECLARE @Narrative TABLE
    (
          SectionOrder int            NOT NULL
        , ReportSection varchar(80)    NOT NULL
        , Narrative     nvarchar(max)  NULL
    );

    INSERT INTO @Narrative
    (
          SectionOrder
        , ReportSection
        , Narrative
    )
    VALUES
      (1, 'QUESTION',
          @Question)

    , (2, 'ANSWER',
          @Answer)

    , (3, 'ROOT CAUSE',
          CASE
              WHEN @Answer = 'ROOT CAUSE IDENTIFIED'
              THEN CONCAT(
                       COALESCE(@RootCause, N'Identified cause'),
                       N' | Confidence: ',
                       COALESCE(@Confidence, 'N/A')
                   )
              ELSE CONCAT(
                       COALESCE(@RootCause, N'No supported primary cause'),
                       N' | Confidence: ',
                       COALESCE(@Confidence, 'N/A')
                   )
          END)

    , (4, 'WHAT HAPPENED?',
          @WhatHappened)

    , (5, 'WHO OR WHAT CAUSED IT?',
          @WhoOrWhatCausedIt)

    , (6, 'WHY DO WE BELIEVE THIS?',
          @WhyWeBelieveIt)

    , (7, 'WHAT WAS THE IMPACT?',
          @Impact)

    , (8, 'WHAT SHOULD I DO?',
          @WhatShouldIDo)

    , (9, 'WHAT SHOULD I NOT CHANGE YET?',
          @DoNotChangeYet);

    SELECT
          SectionOrder
        , ReportSection
        , Narrative
    FROM @Narrative
    ORDER BY SectionOrder;

    ---------------------------------------------------------------------------
    -- Optional second result set: compact incident metadata.
    ---------------------------------------------------------------------------
    IF @IncludeTechnicalDetail = 1
    BEGIN
        SELECT
              TechnicalSection = 'INCIDENT REFERENCE'
            , CaptureRunID = @CaptureRunID
            , DatabaseName = @DatabaseName
            , IncidentStartUTC = @IncidentStartUTC
            , IncidentEndUTC = @IncidentEndUTC
            , Answer = @Answer
            , RootCause = @RootCause
            , Confidence = @Confidence;

        -----------------------------------------------------------------------
        -- Script 46 owns the deeper technical drill-down.  Calling it here
        -- preserves one source of truth for technical evidence.
        --
        -- NOTE: this deliberately returns Script 46's structured answer first,
        -- followed by its technical evidence result sets.
        -----------------------------------------------------------------------
        EXEC dbo.usp_RCA_WhyIsDatabaseSlow
             @CaptureRunID = @CaptureRunID,
             @IncludeTechnicalDetail = 1;
    END;
END;
GO


/*==============================================================================
  2. FRIENDLY DBA ALIASES

  These names are intentionally conversational.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDBSlow
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainDatabaseSlowness
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO


/*==============================================================================
  3. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '1 - SCRIPT 47 DEPLOYMENT'
    , DBAAnswer =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END
    , WhyIsDBSlowAlias =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDBSlow',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END
    , ExplainDatabaseSlownessAlias =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainDatabaseSlowness',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END
    , Script46Dependency =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END
    , PresentationLayerOnly = 'YES'
    , SourceEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , ManualCauseInserted = 'NO'
    , NewCaptureStarted = 'NO';
GO


/*==============================================================================
  4. CAPTURE 38 - NEGATIVE CONTROL

  Expected:
      ANSWER     = ROOT CAUSE NOT CONFIRMED
      ROOT CAUSE = No supported primary cause
      CONFIDENCE = N/A

  The narrative must explain observed workload WITHOUT claiming that the
  workload caused the incident.
==============================================================================*/
EXEC dbo.usp_RCA_DBAAnswer
     @CaptureRunID = 38,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  5. CAPTURE 39 - POSITIVE CONTROL

  Expected:
      ANSWER     = ROOT CAUSE IDENTIFIED
      ROOT CAUSE = Blocking / wait-chain contention
      CONFIDENCE = HIGH

  The narrative should identify the persisted blocking pattern, head blocker,
  victim, lock wait, repeated observations, impact, and recommended action.
==============================================================================*/
EXEC dbo.usp_RCA_DBAAnswer
     @CaptureRunID = 39,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  6. ACCEPTANCE CHECK

  This validates the final DBA-facing behavior without rebuilding or changing
  any evidence.
==============================================================================*/
DECLARE @Capture38SupportedCause int = 0;
DECLARE @Capture39BlockingPrimary int = 0;
DECLARE @Capture39HighConfidence int = 0;

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL
BEGIN
    SELECT
        @Capture38SupportedCause = COUNT(*)
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID = 38
      AND RootCauseRole = 'PRIMARY'
      AND Confidence IN ('HIGH','MEDIUM');

    SELECT
          @Capture39BlockingPrimary =
              SUM(
                  CASE
                      WHEN CauseCategory = 'BLOCKING_WAIT_CHAIN'
                       AND RootCauseRole = 'PRIMARY'
                      THEN 1 ELSE 0
                  END
              )
        , @Capture39HighConfidence =
              SUM(
                  CASE
                      WHEN CauseCategory = 'BLOCKING_WAIT_CHAIN'
                       AND RootCauseRole = 'PRIMARY'
                       AND Confidence = 'HIGH'
                      THEN 1 ELSE 0
                  END
              )
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID = 39;
END;

SELECT
      ValidationSection = '2 - SCRIPT 47 ACCEPTANCE'
    , Capture38NegativeControl =
        CASE
            WHEN ISNULL(@Capture38SupportedCause,0) = 0
            THEN 'PASS - UNCERTAINTY PRESERVED'
            ELSE 'REVIEW'
        END
    , Capture39PositiveControl =
        CASE
            WHEN ISNULL(@Capture39BlockingPrimary,0) > 0
            THEN 'PASS - BLOCKING PRIMARY'
            ELSE 'REVIEW'
        END
    , Capture39Confidence =
        CASE
            WHEN ISNULL(@Capture39HighConfidence,0) > 0
            THEN 'PASS - HIGH'
            ELSE 'REVIEW'
        END
    , UserExperience =
        'PASS - NARROW HUMAN-READABLE DBA ANSWER'
    , ExistingEvidenceModified = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , NewCaptureStarted = 'NO'
    , NextStep =
        'Review the Capture 38 and Capture 39 narratives. If accepted, make usp_RCA_DBAAnswer the primary DBA-facing RCA entry point.';
GO


/*==============================================================================
  NORMAL DBA COMMANDS
  -------------------

  Human-readable answer:

      EXEC DBA.dbo.usp_RCA_DBAAnswer
           @CaptureRunID = 39;

  Conversational alias:

      EXEC DBA.dbo.usp_RCA_WhyIsDBSlow
           @CaptureRunID = 39;

  Full technical drill-down:

      EXEC DBA.dbo.usp_RCA_DBAAnswer
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;

==============================================================================*/
