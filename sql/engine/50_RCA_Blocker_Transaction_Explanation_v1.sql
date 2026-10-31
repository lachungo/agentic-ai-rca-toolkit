USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  50_RCA_Blocker_Transaction_Explanation_v1.sql

  PURPOSE
  -------
  Extend the DBA-facing RCA answer one step further:

      "Why was the head blocker holding the lock?"

  This script consumes ONLY persisted RCA evidence already available from:
      - dbo.RCA_BlockingEvidence
      - dbo.RCA_ExecutionEvidence
      - dbo.vw_RCA_HeadBlockerAttribution
      - dbo.usp_RCA_WhyIsDatabaseSlow

  It DOES NOT infer a transaction begin time or transaction ID when those values
  were not persisted.

  PRIMARY GOAL
  ------------
  For a blocking incident, explain the causal chain in human-readable form:

      Reported slowdown
          -> victim request blocked
          -> lock wait observed
          -> head blocker identified
          -> blocker batch identified
          -> blocker statement identified
          -> transaction/lock-retention explanation
          -> specific DBA next action

  IMPORTANT EVIDENCE RULE
  -----------------------
  The sampler-observed HeadBlockerStatement represents what the blocker was
  executing at the time of observation. It may NOT be the statement that
  originally acquired the lock.

  Example from Capture 39:
      Blocker batch:
          EXEC dbo.usp_RCA_Capture39_Blocker

      Statement observed while locks were retained:
          WAITFOR DELAY '00:00:45'

  The safe interpretation is:
      "The blocker transaction remained open while the session was at WAITFOR,
       and locks acquired earlier in the transaction remained held."

  We do NOT claim that WAITFOR itself acquired the lock.

  NORMAL DBA COMMAND
  ------------------
      EXEC DBA.dbo.usp_RCA_BlockerTransactionExplanation
           @CaptureRunID = 39;

  FINAL HUMAN ANSWER
  ------------------
      EXEC DBA.dbo.usp_RCA_DBAAnswer_v3
           @CaptureRunID = 39;

==============================================================================*/

DECLARE @Missing nvarchar(max) = N'';
DECLARE @Message nvarchar(2048);

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockingEvidence;';

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ExecutionEvidence;';

IF OBJECT_ID(N'dbo.vw_RCA_HeadBlockerAttribution',N'V') IS NULL
    SET @Missing += N' dbo.vw_RCA_HeadBlockerAttribution;';

IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_WhyIsDatabaseSlow;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message = CONCAT(N'Script 50 prerequisites are missing:',@Missing);
    THROW 55000,@Message,1;
END;
GO

CREATE OR ALTER VIEW dbo.vw_RCA_BlockerTransactionExplanation
AS
SELECT
      h.CaptureRunID
    , h.BlockingEvidenceID
    , h.VictimSessionID
    , h.VictimExecutionEvidenceID
    , h.VictimDatabaseName
    , h.VictimHostName
    , h.VictimProgramName
    , h.VictimLoginName
    , h.VictimStatement
    , h.ImmediateBlockerSessionID
    , h.HeadBlockerSessionID
    , h.HeadBlockerHostName
    , h.HeadBlockerProgramName
    , h.HeadBlockerLoginName
    , h.HeadBlockerStatement
    , h.HeadBlockerOpenTransactionCount
    , h.HeadBlockerExecutionEvidenceID
    , h.HeadBlockerExecutionEventUTC
    , h.HeadBlockerExecutionDatabase
    , h.HeadBlockerExecutionObject
    , h.HeadBlockerSubmittedCommand
    , h.HeadBlockerParameterText
    , h.HeadBlockerDurationMs
    , h.WaitType
    , h.WaitDurationMs
    , h.BlockingDepth
    , h.SampleCount
    , h.FirstObservedUTC
    , h.LastObservedUTC
    , h.RootCauseRole
    , h.Confidence
    , h.AttributionStrength
    , TransactionStateAssessment =
        CASE
          WHEN h.HeadBlockerOpenTransactionCount IS NOT NULL
           AND h.HeadBlockerOpenTransactionCount > 0
          THEN 'OPEN TRANSACTION CONFIRMED'
          WHEN h.HeadBlockerOpenTransactionCount = 0
          THEN 'NO OPEN TRANSACTION REPORTED AT CAPTURE POINT'
          WHEN h.HeadBlockerStatement IS NOT NULL
           AND h.WaitType LIKE 'LCK_M_%'
          THEN 'LOCK RETENTION CONFIRMED; OPEN TRANSACTION COUNT NOT PERSISTED'
          ELSE 'TRANSACTION STATE INCOMPLETE'
        END
    , TransactionInterpretation =
        CASE
          WHEN h.WaitType LIKE 'LCK_M_%'
           AND NULLIF(LTRIM(RTRIM(h.HeadBlockerStatement)),N'') IS NOT NULL
          THEN
              CONCAT(
                  N'Session ',
                  h.HeadBlockerSessionID,
                  N' retained locks needed by session ',
                  h.VictimSessionID,
                  N' while the blocker session remained active. ',
                  N'The sampler observed the blocker at statement: ',
                  h.HeadBlockerStatement,
                  N'. This is evidence of what the session was doing while locks remained held; ',
                  N'it does not prove that this statement originally acquired those locks.'
              )
          ELSE
              N'Transaction-level lock retention cannot be explained confidently from the persisted evidence.'
        END
    , MissingTransactionEvidence =
        CONCAT(
            CASE
              WHEN h.HeadBlockerOpenTransactionCount IS NULL
              THEN N'Open transaction count was not populated for this blocking sample. '
              ELSE N''
            END,
            N'Transaction begin time, transaction ID, and exact lock-acquisition statement are not claimed unless separately persisted.'
        )
FROM dbo.vw_RCA_HeadBlockerAttribution AS h;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BlockerTransactionExplanation
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vw_RCA_BlockerTransactionExplanation
        WHERE CaptureRunID = @CaptureRunID
    )
    BEGIN
        SELECT
              ReportSection = 'BLOCKER TRANSACTION EXPLANATION'
            , CaptureRunID = @CaptureRunID
            , Answer = 'No persisted blocking evidence exists for this capture.'
            , Confidence = 'N/A';
        RETURN;
    END;

    SELECT
          ReportSection = 'BLOCKER TRANSACTION EXPLANATION'
        , CaptureRunID
        , BlockingEvidenceID
        , RootCauseRole
        , Confidence
        , VictimSessionID
        , HeadBlockerSessionID
        , WaitType
        , WaitDurationMs
        , BlockingDepth
        , SampleCount
        , HeadBlockerHostName
        , HeadBlockerProgramName
        , HeadBlockerLoginName
        , HeadBlockerExecutionEvidenceID
        , HeadBlockerSubmittedCommand
        , HeadBlockerStatement
        , HeadBlockerOpenTransactionCount
        , TransactionStateAssessment
        , TransactionInterpretation
        , MissingTransactionEvidence
        , DBAAction =
            CONCAT(
                N'Investigate the transaction boundary for head blocker session ',
                HeadBlockerSessionID,
                N'. Review the persisted blocker batch and determine which earlier statement in the same transaction acquired or modified the locked resource. ',
                N'Confirm when the transaction began, why it remained open, and whether commit/rollback can occur sooner. ',
                N'Do not treat the currently sampled blocker statement as the lock-acquisition statement unless separate evidence proves that relationship.'
            )
    FROM dbo.vw_RCA_BlockerTransactionExplanation
    WHERE CaptureRunID = @CaptureRunID
    ORDER BY
          CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 2 END
        , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , WaitDurationMs DESC
        , BlockingEvidenceID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer_v3
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

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
          Question, Answer, RootCause, Confidence, WhatHappened,
          WhyWeBelieveIt, WhoOrWhatCausedIt, Impact, WhatShouldIDo,
          DoNotChangeYet, CaptureRunID, DatabaseName,
          IncidentStartUTC, IncidentEndUTC
    )
    EXEC dbo.usp_RCA_WhyIsDatabaseSlow
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = 0;

    IF (SELECT COUNT(*) FROM #BaseAnswer) <> 1
        THROW 55010,
              'Script 46 did not return exactly one structured RCA answer row.',
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
        , @DoNotChangeYet nvarchar(max);

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
    FROM #BaseAnswer;

    DECLARE
          @HeadBlockerSessionID int
        , @VictimSessionID int
        , @HeadBlockerHostName nvarchar(512)
        , @HeadBlockerProgramName nvarchar(512)
        , @HeadBlockerLoginName nvarchar(512)
        , @HeadBlockerExecutionEvidenceID bigint
        , @HeadBlockerSubmittedCommand nvarchar(max)
        , @HeadBlockerStatement nvarchar(max)
        , @HeadBlockerOpenTransactionCount int
        , @WaitType nvarchar(512)
        , @WaitDurationMs bigint
        , @SampleCount int
        , @TransactionStateAssessment nvarchar(200)
        , @TransactionInterpretation nvarchar(max)
        , @MissingTransactionEvidence nvarchar(max);

    SELECT TOP (1)
          @HeadBlockerSessionID = HeadBlockerSessionID
        , @VictimSessionID = VictimSessionID
        , @HeadBlockerHostName = HeadBlockerHostName
        , @HeadBlockerProgramName = HeadBlockerProgramName
        , @HeadBlockerLoginName = HeadBlockerLoginName
        , @HeadBlockerExecutionEvidenceID = HeadBlockerExecutionEvidenceID
        , @HeadBlockerSubmittedCommand = HeadBlockerSubmittedCommand
        , @HeadBlockerStatement = HeadBlockerStatement
        , @HeadBlockerOpenTransactionCount = HeadBlockerOpenTransactionCount
        , @WaitType = WaitType
        , @WaitDurationMs = WaitDurationMs
        , @SampleCount = SampleCount
        , @TransactionStateAssessment = TransactionStateAssessment
        , @TransactionInterpretation = TransactionInterpretation
        , @MissingTransactionEvidence = MissingTransactionEvidence
    FROM dbo.vw_RCA_BlockerTransactionExplanation
    WHERE CaptureRunID = @CaptureRunID
      AND RootCauseRole = 'PRIMARY'
      AND Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE Confidence WHEN 'HIGH' THEN 1 ELSE 2 END
        , WaitDurationMs DESC
        , SampleCount DESC
        , BlockingEvidenceID;

    IF @Answer = 'ROOT CAUSE IDENTIFIED'
       AND @RootCause LIKE '%Blocking%'
       AND @HeadBlockerSessionID IS NOT NULL
    BEGIN
        SET @WhoOrWhatCausedIt =
            CONCAT(
                N'Head blocker session ',
                @HeadBlockerSessionID,
                N' on host ',
                COALESCE(@HeadBlockerHostName,N'unknown'),
                N' using ',
                COALESCE(@HeadBlockerProgramName,N'unknown'),
                N' under login ',
                COALESCE(@HeadBlockerLoginName,N'unknown'),
                N' blocked victim session ',
                @VictimSessionID,
                N'. Persisted blocker ExecutionEvidenceID ',
                COALESCE(CONVERT(varchar(20),@HeadBlockerExecutionEvidenceID),'unknown'),
                N' shows the blocker batch: ',
                COALESCE(@HeadBlockerSubmittedCommand,N'not captured'),
                N'. At sample time, the blocker was executing: ',
                COALESCE(@HeadBlockerStatement,N'not captured'),
                N'.'
            );

        SET @WhyWeBelieveIt =
            CONCAT(
                @WhyWeBelieveIt,
                N' Transaction interpretation: ',
                @TransactionInterpretation,
                N' Transaction state assessment: ',
                @TransactionStateAssessment,
                N'.'
            );

        SET @WhatShouldIDo =
            CONCAT(
                N'Investigate the transaction boundary for head blocker session ',
                @HeadBlockerSessionID,
                N'. Review the persisted blocker batch ',
                COALESCE(@HeadBlockerSubmittedCommand,N'[not captured]'),
                N' and determine which earlier statement in that same transaction acquired or modified the resource required by victim session ',
                @VictimSessionID,
                N'. Determine when the transaction began, why it remained open, and whether it can commit or roll back sooner. ',
                N'Do not assume the currently sampled statement ',
                COALESCE(@HeadBlockerStatement,N'[not captured]'),
                N' originally acquired the lock unless separate evidence proves it.'
            );
    END;

    DECLARE @Output TABLE
    (
          SectionOrder int NOT NULL
        , ReportSection varchar(100) NOT NULL
        , Narrative nvarchar(max) NULL
    );

    INSERT @Output
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
    , (8,'WHY WAS THE BLOCKER HOLDING THE LOCK?',
        CASE
          WHEN @HeadBlockerSessionID IS NOT NULL
          THEN CONCAT(
                N'Session ',@HeadBlockerSessionID,
                N' remained active while locks needed by session ',
                @VictimSessionID,
                N' were still held. The victim waited on ',
                COALESCE(@WaitType,N'an unknown lock wait'),
                N' for up to ',
                COALESCE(CONVERT(varchar(30),CONVERT(decimal(19,1),@WaitDurationMs/1000.0)),N'unknown'),
                N' seconds across ',
                COALESCE(CONVERT(varchar(20),@SampleCount),N'unknown'),
                N' observations. ',
                COALESCE(@TransactionInterpretation,N''),
                N' ',
                COALESCE(@MissingTransactionEvidence,N'')
              )
          ELSE
              N'No supported blocker transaction explanation exists for this capture.'
        END)
    , (9,'WHAT SHOULD I DO?',@WhatShouldIDo)
    , (10,'WHAT SHOULD I NOT CHANGE YET?',@DoNotChangeYet);

    SELECT
          SectionOrder
        , ReportSection
        , Narrative
    FROM @Output
    ORDER BY SectionOrder;

    IF @IncludeTechnicalDetail = 1
    BEGIN
        SELECT
              TechnicalSection = 'BLOCKER TRANSACTION ATTRIBUTION'
            , HeadBlockerSessionID = @HeadBlockerSessionID
            , VictimSessionID = @VictimSessionID
            , HeadBlockerHostName = @HeadBlockerHostName
            , HeadBlockerProgramName = @HeadBlockerProgramName
            , HeadBlockerLoginName = @HeadBlockerLoginName
            , HeadBlockerExecutionEvidenceID = @HeadBlockerExecutionEvidenceID
            , HeadBlockerSubmittedCommand = @HeadBlockerSubmittedCommand
            , HeadBlockerStatement = @HeadBlockerStatement
            , HeadBlockerOpenTransactionCount = @HeadBlockerOpenTransactionCount
            , WaitType = @WaitType
            , WaitDurationMs = @WaitDurationMs
            , SampleCount = @SampleCount
            , TransactionStateAssessment = @TransactionStateAssessment
            , TransactionInterpretation = @TransactionInterpretation
            , MissingTransactionEvidence = @MissingTransactionEvidence;

        EXEC dbo.usp_RCA_WhyIsDatabaseSlow
             @CaptureRunID = @CaptureRunID,
             @IncludeTechnicalDetail = 1;
    END;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDBSlow_v3
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer_v3
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO

SELECT
      ValidationSection = '1 - SCRIPT 50 DEPLOYMENT'
    , TransactionExplanationView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockerTransactionExplanation',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TransactionExplanationProcedure =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BlockerTransactionExplanation',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , DBAAnswerV3 =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_v3',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDBSlow_v3',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PresentationOnly = 'YES'
    , ExistingEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , NewCaptureStarted = 'NO';
GO

SELECT
      ValidationSection = '2 - CAPTURE 39 TRANSACTION EXPLANATION'
    , CaptureRunID
    , BlockingEvidenceID
    , HeadBlockerSessionID
    , VictimSessionID
    , WaitType
    , WaitDurationMs
    , SampleCount
    , HeadBlockerExecutionEvidenceID
    , HeadBlockerSubmittedCommand
    , HeadBlockerStatement
    , HeadBlockerOpenTransactionCount
    , TransactionStateAssessment
    , TransactionInterpretation
    , MissingTransactionEvidence
    , ValidationResult =
        CASE
          WHEN CaptureRunID = 39
           AND HeadBlockerSessionID = 69
           AND VictimSessionID = 74
           AND WaitType = 'LCK_M_X'
           AND SampleCount = 8
           AND HeadBlockerExecutionEvidenceID = 311
           AND HeadBlockerSubmittedCommand LIKE '%usp_RCA_Capture39_Blocker%'
          THEN 'PASS - BLOCKER TRANSACTION EXPLANATION GROUNDED IN PERSISTED EVIDENCE'
          ELSE 'REVIEW - CAPTURE 39 TRANSACTION ATTRIBUTION DOES NOT MATCH GOLDEN FIXTURE'
        END
FROM dbo.vw_RCA_BlockerTransactionExplanation
WHERE CaptureRunID = 39
ORDER BY BlockingEvidenceID;
GO

EXEC dbo.usp_RCA_DBAAnswer_v3
     @CaptureRunID = 39,
     @IncludeTechnicalDetail = 0;
GO

EXEC dbo.usp_RCA_DBAAnswer_v3
     @CaptureRunID = 38,
     @IncludeTechnicalDetail = 0;
GO

SELECT
      ValidationSection = '3 - SCRIPT 50 SAFETY'
    , Capture39Reused = 'YES'
    , Capture38Reused = 'YES'
    , ExistingEvidenceModified = 'NO'
    , BlockingEvidenceModified = 'NO'
    , ExecutionEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , ManualTransactionAttributionInserted = 'NO'
    , NewCaptureStarted = 'NO'
    , NextStep =
        'Review the new WHY WAS THE BLOCKER HOLDING THE LOCK section. If transaction begin time/ID remains unavailable, preserve that limitation explicitly rather than inferring it.';
GO
