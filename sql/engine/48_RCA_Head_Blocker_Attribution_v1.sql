USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  48_RCA_Head_Blocker_Attribution_v1.sql

  PURPOSE
  -------
  Enrich the human-readable RCA answer with persisted HEAD BLOCKER attribution.

  Capture 39 proved that the evidence already exists:

      Victim session                  = 74
      Head blocker session            = 69
      Wait type                       = LCK_M_X
      Max observed wait               = 35426 ms
      Sample count                    = 8

      Blocking evidence already holds:
          BlockerHostName
          BlockerProgramName
          BlockerLoginName
          BlockerStatement
          HeadBlockerHostName
          HeadBlockerProgramName
          HeadBlockerLoginName
          HeadBlockerStatement

      Execution evidence also holds meaningful blocker execution:
          ExecutionEvidenceID 311
          SessionID 69
          SubmittedCommand:
              USE RCA;
              EXEC dbo.usp_RCA_Capture39_Blocker;
          DurationMs = 45012.925

  GOAL
  ----
  Answer not only:

      "Blocking caused the slowdown."

  but also:

      "Who blocked it?"
      "What application/login/host submitted the blocker?"
      "What SQL/batch was the head blocker executing?"
      "What statement was holding the lock?"
      "How long did it persist?"
      "What should the DBA investigate next?"

  DESIGN
  ------
  1. Evidence-first.
  2. No detector changes.
  3. No root-cause promotion.
  4. No source evidence changes.
  5. No new capture.
  6. Meaningful blocker execution is selected from persisted execution evidence.
  7. SET/USE connection-noise batches are deprioritized.
  8. Script 47 remains available; Script 48 becomes the enriched DBA answer.

  PRIMARY COMMAND
  ---------------
      EXEC DBA.dbo.usp_RCA_DBAAnswer_v2
           @CaptureRunID = 39;

  FRIENDLY COMMAND
  ----------------
      EXEC DBA.dbo.usp_RCA_WhyIsDBSlow_v2
           @CaptureRunID = 39;

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max) = N'';
DECLARE @Message nvarchar(2048);

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockingEvidence;';

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ExecutionEvidence;';

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    SET @Missing += N' dbo.vw_RCA_FinalCauseRanking;';

IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_WhyIsDatabaseSlow;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message = CONCAT(N'Script 48 prerequisites are missing:',@Missing);
    THROW 54800,@Message,1;
END;

DECLARE @RequiredBlockingColumns TABLE(ColumnName sysname);
INSERT @RequiredBlockingColumns(ColumnName)
VALUES
    ('CaptureRunID'),
    ('VictimSessionID'),
    ('VictimExecutionEvidenceID'),
    ('ImmediateBlockerSessionID'),
    ('HeadBlockerSessionID'),
    ('WaitType'),
    ('WaitDurationMs'),
    ('BlockingDepth'),
    ('VictimDatabaseName'),
    ('VictimHostName'),
    ('VictimProgramName'),
    ('VictimLoginName'),
    ('VictimStatement'),
    ('BlockerHostName'),
    ('BlockerProgramName'),
    ('BlockerLoginName'),
    ('BlockerStatement'),
    ('HeadBlockerHostName'),
    ('HeadBlockerProgramName'),
    ('HeadBlockerLoginName'),
    ('HeadBlockerStatement'),
    ('HeadBlockerOpenTransactionCount'),
    ('RootCauseRole'),
    ('Confidence'),
    ('FirstObservedUTC'),
    ('LastObservedUTC'),
    ('SampleCount');

IF EXISTS
(
    SELECT 1
    FROM @RequiredBlockingColumns r
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.RCA_BlockingEvidence')
          AND c.name = r.ColumnName
    )
)
BEGIN
    THROW 54801,
          'RCA_BlockingEvidence does not contain all columns required by Script 48.',
          1;
END;

SELECT
      ValidationSection = '0 - SCRIPT 48 PRE-FLIGHT'
    , BlockingEvidence = 'PASS'
    , ExecutionEvidence = 'PASS'
    , FinalCauseRanking = 'PASS'
    , Script46Dependency = 'PASS'
    , EvidenceSchema = 'PASS'
    , PresentationOnly = 'YES'
    , SourceEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , NewCaptureStarted = 'NO';
GO


/*==============================================================================
  1. HEAD BLOCKER ATTRIBUTION VIEW

  Correlation rules:
  ------------------
  A. Start from persisted BlockingEvidence.
  B. Correlate ExecutionEvidence by CaptureRunID + HeadBlockerSessionID.
  C. Prefer meaningful batches over connection/session setup statements.
  D. Prefer execution rows occurring at/near the blocking observation window.
  E. Prefer longer-duration executions, which are more likely to represent
     the blocker workload rather than SET/USE metadata chatter.

  IMPORTANT:
  This view does not claim that every batch in the head-blocker session caused
  the lock. It exposes the BEST PERSISTED EXECUTION ATTRIBUTION alongside the
  exact blocker statement already captured by the sampler.
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_HeadBlockerAttribution
AS
SELECT
      b.BlockingEvidenceID
    , b.CaptureRunID

    , b.VictimSessionID
    , b.VictimExecutionEvidenceID
    , b.VictimDatabaseName
    , b.VictimHostName
    , b.VictimProgramName
    , b.VictimLoginName
    , b.VictimStatement

    , b.ImmediateBlockerSessionID
    , b.BlockerHostName
    , b.BlockerProgramName
    , b.BlockerLoginName
    , b.BlockerStatement

    , b.HeadBlockerSessionID
    , b.HeadBlockerHostName
    , b.HeadBlockerProgramName
    , b.HeadBlockerLoginName
    , b.HeadBlockerStatement
    , b.HeadBlockerOpenTransactionCount

    , b.WaitType
    , b.WaitDurationMs
    , b.BlockingDepth
    , b.FirstObservedUTC
    , b.LastObservedUTC
    , b.SampleCount
    , b.RootCauseRole
    , b.Confidence

    , HeadBlockerExecutionEvidenceID = x.ExecutionEvidenceID
    , HeadBlockerExecutionEventUTC   = x.EventTimeUTC
    , HeadBlockerExecutionDatabase   = x.DatabaseName
    , HeadBlockerExecutionObject     = x.ObjectName
    , HeadBlockerSubmittedCommand    = x.SubmittedCommand
    , HeadBlockerParameterText       = x.ParameterText
    , HeadBlockerParameterStatus     = x.ParameterEvidenceStatus
    , HeadBlockerExecutionHost       = x.HostName
    , HeadBlockerExecutionProgram    = x.ProgramName
    , HeadBlockerExecutionLogin      = x.LoginName
    , HeadBlockerCPUms               = x.CPUms
    , HeadBlockerDurationMs          = x.DurationMs
    , HeadBlockerLogicalReads        = x.LogicalReads
    , HeadBlockerPhysicalReads       = x.PhysicalReads
    , HeadBlockerWrites              = x.Writes
    , HeadBlockerTotalRows           = x.TotalRows

    , BlockerExecutionCorrelation =
        CASE
          WHEN x.ExecutionEvidenceID IS NULL
          THEN 'NO EXECUTION EVIDENCE'
          WHEN x.IsNoiseBatch = 0
          THEN 'MEANINGFUL SESSION EXECUTION'
          ELSE 'SESSION EXECUTION - SETUP/NOISE ONLY'
        END

    , AttributionStrength =
        CASE
          WHEN x.ExecutionEvidenceID IS NOT NULL
           AND x.IsNoiseBatch = 0
           AND b.HeadBlockerStatement IS NOT NULL
           AND COALESCE(x.HostName,b.HeadBlockerHostName) IS NOT NULL
           AND COALESCE(x.ProgramName,b.HeadBlockerProgramName) IS NOT NULL
           AND COALESCE(x.LoginName,b.HeadBlockerLoginName) IS NOT NULL
          THEN 'HIGH'
          WHEN x.ExecutionEvidenceID IS NOT NULL
            OR b.HeadBlockerStatement IS NOT NULL
          THEN 'MEDIUM'
          ELSE 'LOW'
        END
FROM dbo.RCA_BlockingEvidence AS b
OUTER APPLY
(
    SELECT TOP (1)
          e.ExecutionEvidenceID
        , e.EventTimeUTC
        , e.DatabaseName
        , e.ObjectName
        , e.SubmittedCommand
        , e.ParameterText
        , e.ParameterEvidenceStatus
        , e.HostName
        , e.ProgramName
        , e.LoginName
        , e.CPUms
        , e.DurationMs
        , e.LogicalReads
        , e.PhysicalReads
        , e.Writes
        , e.TotalRows

        , IsNoiseBatch =
            CASE
              WHEN LTRIM(RTRIM(ISNULL(e.SubmittedCommand,N''))) = N''
                THEN 1
              WHEN UPPER(LTRIM(RTRIM(e.SubmittedCommand))) LIKE N'SET %'
                THEN 1
              WHEN UPPER(LTRIM(RTRIM(e.SubmittedCommand))) LIKE N'USE %'
               AND UPPER(e.SubmittedCommand) NOT LIKE N'%EXEC %'
               AND UPPER(e.SubmittedCommand) NOT LIKE N'%UPDATE %'
               AND UPPER(e.SubmittedCommand) NOT LIKE N'%INSERT %'
               AND UPPER(e.SubmittedCommand) NOT LIKE N'%DELETE %'
               AND UPPER(e.SubmittedCommand) NOT LIKE N'%SELECT %'
                THEN 1
              ELSE 0
            END

    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.CaptureRunID = b.CaptureRunID
      AND e.SessionID = b.HeadBlockerSessionID

    ORDER BY
          CASE
            WHEN LTRIM(RTRIM(ISNULL(e.SubmittedCommand,N''))) = N'' THEN 2
            WHEN UPPER(LTRIM(RTRIM(e.SubmittedCommand))) LIKE N'SET %' THEN 2
            WHEN UPPER(LTRIM(RTRIM(e.SubmittedCommand))) LIKE N'USE %'
             AND UPPER(e.SubmittedCommand) NOT LIKE N'%EXEC %'
             AND UPPER(e.SubmittedCommand) NOT LIKE N'%UPDATE %'
             AND UPPER(e.SubmittedCommand) NOT LIKE N'%INSERT %'
             AND UPPER(e.SubmittedCommand) NOT LIKE N'%DELETE %'
             AND UPPER(e.SubmittedCommand) NOT LIKE N'%SELECT %'
            THEN 2
            ELSE 0
          END

        , CASE
            WHEN e.EventTimeUTC BETWEEN
                 DATEADD(second,-5,b.FirstObservedUTC)
                 AND
                 DATEADD(second,60,b.LastObservedUTC)
            THEN 0
            ELSE 1
          END

        , ISNULL(e.DurationMs,0) DESC
        , ISNULL(e.CPUms,0) DESC
        , e.ExecutionEvidenceID DESC
) AS x;
GO


/*==============================================================================
  2. BLOCKER ATTRIBUTION PROCEDURE

  This is useful independently of the human-readable RCA answer.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_HeadBlockerAttribution
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          ReportSection = 'HEAD BLOCKER ATTRIBUTION'
        , CaptureRunID
        , BlockingEvidenceID
        , RootCauseRole
        , Confidence

        , VictimSessionID
        , VictimDatabaseName
        , VictimHostName
        , VictimProgramName
        , VictimLoginName
        , VictimStatement

        , ImmediateBlockerSessionID
        , HeadBlockerSessionID
        , HeadBlockerHostName
        , HeadBlockerProgramName
        , HeadBlockerLoginName
        , HeadBlockerStatement
        , HeadBlockerOpenTransactionCount

        , WaitType
        , WaitDurationMs
        , BlockingDepth
        , SampleCount
        , FirstObservedUTC
        , LastObservedUTC

        , HeadBlockerExecutionEvidenceID
        , HeadBlockerExecutionEventUTC
        , HeadBlockerExecutionDatabase
        , HeadBlockerExecutionObject
        , HeadBlockerSubmittedCommand
        , HeadBlockerParameterText
        , HeadBlockerParameterStatus
        , HeadBlockerCPUms
        , HeadBlockerDurationMs
        , HeadBlockerLogicalReads
        , HeadBlockerPhysicalReads
        , HeadBlockerWrites
        , HeadBlockerTotalRows

        , BlockerExecutionCorrelation
        , AttributionStrength

        , AttributionNarrative =
            CONCAT(
                N'Head blocker session ',
                COALESCE(CONVERT(varchar(20),HeadBlockerSessionID),'unknown'),
                N' on host ',
                COALESCE(HeadBlockerHostName,HeadBlockerExecutionHost,N'unknown'),
                N' using ',
                COALESCE(HeadBlockerProgramName,HeadBlockerExecutionProgram,N'unknown'),
                N' under login ',
                COALESCE(HeadBlockerLoginName,HeadBlockerExecutionLogin,N'unknown'),
                N' blocked victim session ',
                COALESCE(CONVERT(varchar(20),VictimSessionID),'unknown'),
                N' on ',
                COALESCE(WaitType,N'an unknown lock wait'),
                N'. Maximum observed wait was ',
                COALESCE(CONVERT(varchar(30),CONVERT(decimal(19,1),WaitDurationMs/1000.0)),'unknown'),
                N' seconds across ',
                COALESCE(CONVERT(varchar(20),SampleCount),'unknown'),
                N' sampler observations. ',
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(HeadBlockerSubmittedCommand)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'Persisted execution evidence shows the blocker session submitted: ',
                        HeadBlockerSubmittedCommand,
                        N'. '
                       )
                  ELSE N''
                END,
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(HeadBlockerStatement)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'The sampler observed the head blocker at statement: ',
                        HeadBlockerStatement,
                        N'.'
                       )
                  ELSE N''
                END
            )

    FROM dbo.vw_RCA_HeadBlockerAttribution
    WHERE CaptureRunID = @CaptureRunID
    ORDER BY
          CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 2 END
        , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , WaitDurationMs DESC
        , BlockingEvidenceID;
END;
GO


/*==============================================================================
  3. ENRICHED DBA ANSWER

  Script 46 remains the source of truth for:
      - answer
      - root cause
      - confidence
      - general evidence narrative
      - impact
      - recommendation

  Script 48 enriches ONLY the WHO/WHAT CAUSED IT and blocking-specific action
  when persisted blocker attribution is available.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer_v2
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------------------------------
    -- Capture Script 46's one-row structured answer.
    ---------------------------------------------------------------------------
    CREATE TABLE #BaseAnswer
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

    INSERT #BaseAnswer
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

    IF (SELECT COUNT(*) FROM #BaseAnswer) <> 1
        THROW 54810,
              'Script 46 did not return exactly one structured answer row.',
              1;

    DECLARE
          @Question nvarchar(512)
        , @Answer varchar(50)
        , @RootCause nvarchar(512)
        , @Confidence varchar(20)
        , @WhatHappened nvarchar(max)
        , @WhyWeBelieveIt nvarchar(max)
        , @WhoOrWhatCausedIt nvarchar(max)
        , @Impact nvarchar(max)
        , @WhatShouldIDo nvarchar(max)
        , @DoNotChangeYet nvarchar(max)
        , @DatabaseName sysname
        , @IncidentStartUTC datetime2
        , @IncidentEndUTC datetime2;

    SELECT
          @Question = Question
        , @Answer = Answer
        , @RootCause = RootCause
        , @Confidence = Confidence
        , @WhatHappened = WhatHappened
        , @WhyWeBelieveIt = WhyWeBelieveIt
        , @WhoOrWhatCausedIt = WhoOrWhatCausedIt
        , @Impact = Impact
        , @WhatShouldIDo = WhatShouldIDo
        , @DoNotChangeYet = DoNotChangeYet
        , @DatabaseName = DatabaseName
        , @IncidentStartUTC = IncidentStartUTC
        , @IncidentEndUTC = IncidentEndUTC
    FROM #BaseAnswer;

    ---------------------------------------------------------------------------
    -- Best persisted PRIMARY blocker attribution, if applicable.
    ---------------------------------------------------------------------------
    DECLARE
          @BlockingEvidenceID bigint
        , @VictimSessionID int
        , @VictimStatement nvarchar(max)
        , @HeadBlockerSessionID int
        , @HeadBlockerHostName nvarchar(512)
        , @HeadBlockerProgramName nvarchar(512)
        , @HeadBlockerLoginName nvarchar(512)
        , @HeadBlockerStatement nvarchar(max)
        , @HeadBlockerOpenTransactionCount int
        , @HeadBlockerExecutionEvidenceID bigint
        , @HeadBlockerSubmittedCommand nvarchar(max)
        , @HeadBlockerDurationMs decimal(19,3)
        , @WaitType nvarchar(512)
        , @WaitDurationMs bigint
        , @BlockingDepth int
        , @SampleCount int
        , @AttributionStrength varchar(20);

    SELECT TOP (1)
          @BlockingEvidenceID = BlockingEvidenceID
        , @VictimSessionID = VictimSessionID
        , @VictimStatement = VictimStatement
        , @HeadBlockerSessionID = HeadBlockerSessionID
        , @HeadBlockerHostName =
            COALESCE(HeadBlockerHostName,HeadBlockerExecutionHost)
        , @HeadBlockerProgramName =
            COALESCE(HeadBlockerProgramName,HeadBlockerExecutionProgram)
        , @HeadBlockerLoginName =
            COALESCE(HeadBlockerLoginName,HeadBlockerExecutionLogin)
        , @HeadBlockerStatement = HeadBlockerStatement
        , @HeadBlockerOpenTransactionCount = HeadBlockerOpenTransactionCount
        , @HeadBlockerExecutionEvidenceID = HeadBlockerExecutionEvidenceID
        , @HeadBlockerSubmittedCommand = HeadBlockerSubmittedCommand
        , @HeadBlockerDurationMs = HeadBlockerDurationMs
        , @WaitType = WaitType
        , @WaitDurationMs = WaitDurationMs
        , @BlockingDepth = BlockingDepth
        , @SampleCount = SampleCount
        , @AttributionStrength = AttributionStrength
    FROM dbo.vw_RCA_HeadBlockerAttribution
    WHERE CaptureRunID = @CaptureRunID
      AND RootCauseRole = 'PRIMARY'
      AND Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE Confidence WHEN 'HIGH' THEN 1 ELSE 2 END
        , WaitDurationMs DESC
        , SampleCount DESC
        , BlockingEvidenceID;

    ---------------------------------------------------------------------------
    -- Enrich blocker-specific RCA answer.
    ---------------------------------------------------------------------------
    IF @Answer = 'ROOT CAUSE IDENTIFIED'
       AND @RootCause LIKE '%Blocking%'
       AND @HeadBlockerSessionID IS NOT NULL
    BEGIN
        SET @WhoOrWhatCausedIt =
            CONCAT(
                N'Head blocker: session ',@HeadBlockerSessionID,N'. ',
                N'Host: ',COALESCE(@HeadBlockerHostName,N'unknown'),N'. ',
                N'Program: ',COALESCE(@HeadBlockerProgramName,N'unknown'),N'. ',
                N'Login: ',COALESCE(@HeadBlockerLoginName,N'unknown'),N'. ',
                CASE
                  WHEN @HeadBlockerExecutionEvidenceID IS NOT NULL
                  THEN CONCAT(
                        N'Persisted blocker ExecutionEvidenceID: ',
                        @HeadBlockerExecutionEvidenceID,N'. '
                       )
                  ELSE N''
                END,
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(@HeadBlockerSubmittedCommand)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'Blocker batch: ',
                        @HeadBlockerSubmittedCommand,N'. '
                       )
                  ELSE N''
                END,
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(@HeadBlockerStatement)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'Blocker statement observed while locks were held: ',
                        @HeadBlockerStatement,N'. '
                       )
                  ELSE N''
                END,
                N'Victim session: ',@VictimSessionID,N'. ',
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(@VictimStatement)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'Blocked victim statement: ',
                        @VictimStatement,N'.'
                       )
                  ELSE N''
                END
            );

        SET @WhatShouldIDo =
            CONCAT(
                N'Investigate head blocker session ',@HeadBlockerSessionID,
                N' and the workload that submitted it. ',
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(@HeadBlockerSubmittedCommand)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'Start with the persisted blocker batch: ',
                        @HeadBlockerSubmittedCommand,N'. '
                       )
                  ELSE N''
                END,
                CASE
                  WHEN NULLIF(LTRIM(RTRIM(@HeadBlockerStatement)),N'') IS NOT NULL
                  THEN CONCAT(
                        N'The sampler observed the blocker at: ',
                        @HeadBlockerStatement,N'. '
                       )
                  ELSE N''
                END,
                N'Determine why the transaction retained locks needed by victim session ',
                @VictimSessionID,N', whether the transaction can commit sooner, ',
                N'and whether less work can be performed inside the transaction. ',
                N'Review the application transaction boundary before changing indexes ',
                N'or SQL Server instance configuration.'
            );

        SET @WhyWeBelieveIt =
            CONCAT(
                @WhyWeBelieveIt,
                N' Blocker attribution is also supported by persisted execution evidence',
                CASE
                  WHEN @HeadBlockerExecutionEvidenceID IS NOT NULL
                  THEN CONCAT(
                        N' (ExecutionEvidenceID ',
                        @HeadBlockerExecutionEvidenceID,
                        N')'
                       )
                  ELSE N''
                END,
                N' from the same head-blocker session. Attribution strength: ',
                COALESCE(@AttributionStrength,'UNKNOWN'),
                N'.'
            );
    END;

    ---------------------------------------------------------------------------
    -- Final DBA-readable vertical answer.
    ---------------------------------------------------------------------------
    DECLARE @Output TABLE
    (
          SectionOrder int NOT NULL
        , ReportSection varchar(100) NOT NULL
        , Narrative nvarchar(max) NULL
    );

    INSERT @Output
    (
          SectionOrder
        , ReportSection
        , Narrative
    )
    VALUES
      (1,'QUESTION',@Question)
    , (2,'ANSWER',@Answer)
    , (3,'ROOT CAUSE',
        CONCAT(
            COALESCE(@RootCause,N'No supported primary cause'),
            N' | Confidence: ',
            COALESCE(@Confidence,'N/A')
        ))
    , (4,'WHAT HAPPENED?',@WhatHappened)
    , (5,'WHO OR WHAT CAUSED IT?',@WhoOrWhatCausedIt)
    , (6,'WHY DO WE BELIEVE THIS?',@WhyWeBelieveIt)
    , (7,'WHAT WAS THE IMPACT?',@Impact)
    , (8,'WHAT SHOULD I DO?',@WhatShouldIDo)
    , (9,'WHAT SHOULD I NOT CHANGE YET?',@DoNotChangeYet);

    SELECT
          SectionOrder
        , ReportSection
        , Narrative
    FROM @Output
    ORDER BY SectionOrder;

    ---------------------------------------------------------------------------
    -- Optional compact blocker attribution.
    ---------------------------------------------------------------------------
    IF @IncludeTechnicalDetail = 1
    BEGIN
        SELECT
              TechnicalSection = 'HEAD BLOCKER ATTRIBUTION'
            , BlockingEvidenceID = @BlockingEvidenceID
            , HeadBlockerSessionID = @HeadBlockerSessionID
            , HeadBlockerHostName = @HeadBlockerHostName
            , HeadBlockerProgramName = @HeadBlockerProgramName
            , HeadBlockerLoginName = @HeadBlockerLoginName
            , HeadBlockerOpenTransactionCount = @HeadBlockerOpenTransactionCount
            , HeadBlockerExecutionEvidenceID = @HeadBlockerExecutionEvidenceID
            , HeadBlockerSubmittedCommand = @HeadBlockerSubmittedCommand
            , HeadBlockerStatement = @HeadBlockerStatement
            , HeadBlockerDurationMs = @HeadBlockerDurationMs
            , VictimSessionID = @VictimSessionID
            , VictimStatement = @VictimStatement
            , WaitType = @WaitType
            , WaitDurationMs = @WaitDurationMs
            , BlockingDepth = @BlockingDepth
            , SampleCount = @SampleCount
            , AttributionStrength = @AttributionStrength;

        EXEC dbo.usp_RCA_WhyIsDatabaseSlow
             @CaptureRunID = @CaptureRunID,
             @IncludeTechnicalDetail = 1;
    END;
END;
GO


/*==============================================================================
  4. FRIENDLY ENTRY POINT
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDBSlow_v2
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer_v2
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO


/*==============================================================================
  5. OPTIONAL PROMOTION OF THE DBA-FACING ALIAS

  We do NOT overwrite Script 47's usp_RCA_DBAAnswer automatically.
  This keeps rollback trivial.

  After acceptance, the recommended DBA-facing command is:

      EXEC dbo.usp_RCA_WhyIsDBSlow_v2 @CaptureRunID = 39;

  A later small deployment can repoint the old alias if desired.
==============================================================================*/


/*==============================================================================
  6. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '1 - SCRIPT 48 DEPLOYMENT'
    , AttributionView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_HeadBlockerAttribution',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , AttributionProcedure =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_HeadBlockerAttribution',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , DBAAnswerV2 =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_v2',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDBSlow_v2',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PresentationOnly = 'YES'
    , SourceEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , ManualCauseInserted = 'NO'
    , NewCaptureStarted = 'NO';
GO


/*==============================================================================
  7. CAPTURE 39 BLOCKER ATTRIBUTION VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '2 - CAPTURE 39 BLOCKER ATTRIBUTION'
    , CaptureRunID
    , BlockingEvidenceID
    , HeadBlockerSessionID
    , HeadBlockerExecutionEvidenceID
    , HeadBlockerExecutionDatabase
    , HeadBlockerHostName =
        COALESCE(HeadBlockerHostName,HeadBlockerExecutionHost)
    , HeadBlockerProgramName =
        COALESCE(HeadBlockerProgramName,HeadBlockerExecutionProgram)
    , HeadBlockerLoginName =
        COALESCE(HeadBlockerLoginName,HeadBlockerExecutionLogin)
    , HeadBlockerSubmittedCommand
    , HeadBlockerStatement
    , VictimSessionID
    , VictimStatement
    , WaitType
    , WaitDurationMs
    , SampleCount
    , BlockerExecutionCorrelation
    , AttributionStrength
    , ValidationResult =
        CASE
          WHEN HeadBlockerSessionID = 69
           AND HeadBlockerExecutionEvidenceID = 311
           AND HeadBlockerSubmittedCommand LIKE '%usp_RCA_Capture39_Blocker%'
           AND VictimSessionID = 74
           AND WaitType = 'LCK_M_X'
           AND SampleCount = 8
          THEN 'PASS - BLOCKER SQL AND IDENTITY ATTRIBUTED'
          ELSE 'REVIEW - BLOCKER EVIDENCE DID NOT MATCH CAPTURE 39 GOLDEN FIXTURE'
        END
FROM dbo.vw_RCA_HeadBlockerAttribution
WHERE CaptureRunID = 39
ORDER BY BlockingEvidenceID;
GO


/*==============================================================================
  8. FINAL HUMAN-READABLE CAPTURE 39 ANSWER
==============================================================================*/
EXEC dbo.usp_RCA_DBAAnswer_v2
     @CaptureRunID = 39,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  9. NEGATIVE-CONTROL CHECK: CAPTURE 38

  Script 48 must not invent blocker attribution where none is supported.
==============================================================================*/
EXEC dbo.usp_RCA_DBAAnswer_v2
     @CaptureRunID = 38,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  10. SAFETY
==============================================================================*/
SELECT
      ValidationSection = '3 - SCRIPT 48 SAFETY'
    , Capture39Reused = 'YES'
    , Capture38Reused = 'YES'
    , SourceXEEvidenceChanged = 'NO'
    , ExistingEvidenceModified = 'NO'
    , BlockingEvidenceModified = 'NO'
    , ExecutionEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , ManualCauseInserted = 'NO'
    , NewCaptureStarted = 'NO'
    , NextStep =
        'Review WHO OR WHAT CAUSED IT for Capture 39. It should name session 69, host/program/login, ExecutionEvidenceID 311, blocker batch, blocker statement, victim statement, LCK_M_X, and the recommended transaction-level investigation.';
GO


/*==============================================================================
  NORMAL DBA USAGE
  ----------------

  Human-readable enriched answer:

      EXEC DBA.dbo.usp_RCA_DBAAnswer_v2
           @CaptureRunID = 39;

  Friendly command:

      EXEC DBA.dbo.usp_RCA_WhyIsDBSlow_v2
           @CaptureRunID = 39;

  Full drill-down:

      EXEC DBA.dbo.usp_RCA_DBAAnswer_v2
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;

==============================================================================*/
