USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  58_RCA_Transaction_Aware_DBA_Answer_v1.sql

  PURPOSE
  -------
  Extend the DBA-facing human-readable RCA answer so that, when persisted
  blocker transaction evidence exists, the report explains:

      - who blocked whom
      - the blocking wait and duration
      - the head blocker
      - the blocker SQL / submitted command
      - whether an open transaction was observed
      - transaction id
      - transaction begin time
      - transaction age
      - why the victim had to wait

  SAFETY
  ------
  Presentation layer only.
  This script does NOT:
      - start a capture
      - rebuild findings
      - change detector thresholds
      - change root-cause domains/ranking
      - modify persisted source evidence
      - manufacture historical transaction evidence

  IMPORTANT
  ---------
  Run Script 57 to completion first. Capture 42 should contain fresh transaction
  evidence. This script will still deploy safely if Capture 42 has no transaction
  evidence; it will explicitly preserve that uncertainty.
==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PRE-FLIGHT / DISCOVERY
-------------------------------------------------------------------------------
DECLARE @TransactionTable sysname =
    CASE
        WHEN OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence', N'U') IS NOT NULL
            THEN N'RCA_BlockerTransactionEvidence'
        WHEN OBJECT_ID(N'dbo.RCA_TransactionEvidence', N'U') IS NOT NULL
            THEN N'RCA_TransactionEvidence'
        ELSE NULL
    END;

SELECT
      ValidationSection          = N'0 - SCRIPT 58 PRE-FLIGHT'
    , CaptureRun                 = CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , BlockingEvidence           = CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , ExecutionEvidence          = CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , TransactionEvidenceTable   = COALESCE(@TransactionTable,N'NOT FOUND')
    , ExistingDBAAnswer          = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN N'PASS' ELSE N'REVIEW' END
    , PresentationLayerOnly      = N'YES'
    , SourceEvidenceModified     = N'NO'
    , FindingsRebuilt            = N'NO'
    , DetectorThresholdsChanged  = N'NO'
    , RootCauseLogicChanged      = N'NO'
    , NewCaptureStarted          = N'NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 58001, N'dbo.RCA_CaptureRun was not found.', 1;

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    THROW 58002, N'dbo.RCA_BlockingEvidence was not found.', 1;

IF @TransactionTable IS NULL
    THROW 58003, N'No blocker transaction evidence table was found. Run/verify Scripts 51-57 first.', 1;
GO

-------------------------------------------------------------------------------
-- 1. NORMALIZED TRANSACTION-ATTRIBUTION VIEW
--
-- Build dynamically so the script tolerates minor column-name evolution while
-- refusing to invent values that do not exist.
-------------------------------------------------------------------------------
DECLARE @T nvarchar(300) =
    CASE
        WHEN OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence', N'U') IS NOT NULL
            THEN N'dbo.RCA_BlockerTransactionEvidence'
        WHEN OBJECT_ID(N'dbo.RCA_TransactionEvidence', N'U') IS NOT NULL
            THEN N'dbo.RCA_TransactionEvidence'
    END;

DECLARE @obj int = OBJECT_ID(@T);

DECLARE @CaptureRunIDCol sysname =
    CASE WHEN COL_LENGTH(@T,'CaptureRunID') IS NOT NULL THEN 'CaptureRunID' END;
DECLARE @SampleTimeCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'SampleTimeUTC') IS NOT NULL THEN 'SampleTimeUTC'
        WHEN COL_LENGTH(@T,'CaptureTimeUTC') IS NOT NULL THEN 'CaptureTimeUTC'
        WHEN COL_LENGTH(@T,'EventTimeUTC') IS NOT NULL THEN 'EventTimeUTC'
    END;
DECLARE @VictimCol sysname =
    CASE WHEN COL_LENGTH(@T,'VictimSessionID') IS NOT NULL THEN 'VictimSessionID' END;
DECLARE @HeadCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'HeadBlockerSessionID') IS NOT NULL THEN 'HeadBlockerSessionID'
        WHEN COL_LENGTH(@T,'BlockerSessionID') IS NOT NULL THEN 'BlockerSessionID'
    END;
DECLARE @OpenTranCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'BlockerOpenTransactionCount') IS NOT NULL THEN 'BlockerOpenTransactionCount'
        WHEN COL_LENGTH(@T,'OpenTransactionCount') IS NOT NULL THEN 'OpenTransactionCount'
    END;
DECLARE @TranIDCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'TransactionID') IS NOT NULL THEN 'TransactionID'
        WHEN COL_LENGTH(@T,'BlockerTransactionID') IS NOT NULL THEN 'BlockerTransactionID'
    END;
DECLARE @TranBeginCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'TransactionBeginTimeUTC') IS NOT NULL THEN 'TransactionBeginTimeUTC'
        WHEN COL_LENGTH(@T,'TransactionBeginTime') IS NOT NULL THEN 'TransactionBeginTime'
    END;
DECLARE @TranAgeCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'TransactionAgeMs') IS NOT NULL THEN 'TransactionAgeMs'
        WHEN COL_LENGTH(@T,'BlockerTransactionAgeMs') IS NOT NULL THEN 'BlockerTransactionAgeMs'
    END;
DECLARE @HostCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'HeadBlockerHostName') IS NOT NULL THEN 'HeadBlockerHostName'
        WHEN COL_LENGTH(@T,'BlockerHostName') IS NOT NULL THEN 'BlockerHostName'
    END;
DECLARE @ProgramCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'HeadBlockerProgramName') IS NOT NULL THEN 'HeadBlockerProgramName'
        WHEN COL_LENGTH(@T,'BlockerProgramName') IS NOT NULL THEN 'BlockerProgramName'
    END;
DECLARE @LoginCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'HeadBlockerLoginName') IS NOT NULL THEN 'HeadBlockerLoginName'
        WHEN COL_LENGTH(@T,'BlockerLoginName') IS NOT NULL THEN 'BlockerLoginName'
    END;
DECLARE @CommandCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'HeadBlockerCommand') IS NOT NULL THEN 'HeadBlockerCommand'
        WHEN COL_LENGTH(@T,'BlockerCommand') IS NOT NULL THEN 'BlockerCommand'
        WHEN COL_LENGTH(@T,'SubmittedCommand') IS NOT NULL THEN 'SubmittedCommand'
    END;
DECLARE @StatementCol sysname =
    CASE
        WHEN COL_LENGTH(@T,'HeadBlockerStatement') IS NOT NULL THEN 'HeadBlockerStatement'
        WHEN COL_LENGTH(@T,'BlockerStatement') IS NOT NULL THEN 'BlockerStatement'
        WHEN COL_LENGTH(@T,'StatementText') IS NOT NULL THEN 'StatementText'
    END;

IF @CaptureRunIDCol IS NULL OR @VictimCol IS NULL OR @HeadCol IS NULL
    THROW 58004, N'Transaction evidence table is missing CaptureRunID, VictimSessionID, or blocker session identity.', 1;

DECLARE @sql nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_RCA_BlockerTransactionAttribution
AS
SELECT
      CaptureRunID = ' + QUOTENAME(@CaptureRunIDCol) + N'
    , SampleTimeUTC = ' + COALESCE(QUOTENAME(@SampleTimeCol),N'CAST(NULL AS datetime2(3))') + N'
    , VictimSessionID = ' + QUOTENAME(@VictimCol) + N'
    , HeadBlockerSessionID = ' + QUOTENAME(@HeadCol) + N'
    , BlockerOpenTransactionCount = ' + COALESCE(QUOTENAME(@OpenTranCol),N'CAST(NULL AS int)') + N'
    , TransactionID = ' + COALESCE(QUOTENAME(@TranIDCol),N'CAST(NULL AS bigint)') + N'
    , TransactionBeginTimeUTC = ' + COALESCE(QUOTENAME(@TranBeginCol),N'CAST(NULL AS datetime2(3))') + N'
    , TransactionAgeMs = ' + COALESCE(QUOTENAME(@TranAgeCol),N'CAST(NULL AS bigint)') + N'
    , HeadBlockerHostName = ' + COALESCE(QUOTENAME(@HostCol),N'CAST(NULL AS nvarchar(512))') + N'
    , HeadBlockerProgramName = ' + COALESCE(QUOTENAME(@ProgramCol),N'CAST(NULL AS nvarchar(1024))') + N'
    , HeadBlockerLoginName = ' + COALESCE(QUOTENAME(@LoginCol),N'CAST(NULL AS nvarchar(512))') + N'
    , HeadBlockerCommand = ' + COALESCE(QUOTENAME(@CommandCol),N'CAST(NULL AS nvarchar(max))') + N'
    , HeadBlockerStatement = ' + COALESCE(QUOTENAME(@StatementCol),N'CAST(NULL AS nvarchar(max))') + N'
FROM ' + @T + N';';

EXEC sys.sp_executesql @sql;
GO

-------------------------------------------------------------------------------
-- 2. TRANSACTION-AWARE DBA REPORT
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer_TransactionAware
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
    )
        THROW 58010, N'CaptureRunID does not exist.', 1;

    DECLARE
          @DatabaseName sysname
        , @CaptureStatus nvarchar(60)
        , @VictimSessionID int
        , @HeadBlockerSessionID int
        , @ImmediateBlockerSessionID int
        , @WaitType nvarchar(512)
        , @WaitDurationMs bigint
        , @BlockingDepth int
        , @SampleCount int
        , @BlockerStatement nvarchar(max)
        , @VictimStatement nvarchar(max)
        , @BlockerHost nvarchar(512)
        , @BlockerProgram nvarchar(1024)
        , @BlockerLogin nvarchar(512)
        , @TranRows int = 0
        , @OpenTranCount int
        , @TransactionID bigint
        , @TransactionBeginTimeUTC datetime2(3)
        , @TransactionAgeMs bigint
        , @TranHost nvarchar(512)
        , @TranProgram nvarchar(1024)
        , @TranLogin nvarchar(512)
        , @TranCommand nvarchar(max)
        , @TranStatement nvarchar(max);

    SELECT
          @DatabaseName = TargetDatabase
        , @CaptureStatus = CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = @CaptureRunID;

    /* Highest-quality persisted blocking observation for the capture. */
    SELECT TOP (1)
          @VictimSessionID = b.VictimSessionID
        , @HeadBlockerSessionID = b.HeadBlockerSessionID
        , @ImmediateBlockerSessionID = b.ImmediateBlockerSessionID
        , @WaitType = b.WaitType
        , @WaitDurationMs = b.WaitDurationMs
        , @BlockingDepth = b.BlockingDepth
        , @SampleCount = b.SampleCount
        , @BlockerStatement = b.HeadBlockerStatement
        , @VictimStatement = b.VictimStatement
        , @BlockerHost = b.HeadBlockerHostName
        , @BlockerProgram = b.HeadBlockerProgramName
        , @BlockerLogin = b.HeadBlockerLoginName
    FROM dbo.RCA_BlockingEvidence AS b
    WHERE b.CaptureRunID = @CaptureRunID
    ORDER BY
          ISNULL(b.SampleCount,0) DESC
        , ISNULL(b.WaitDurationMs,0) DESC
        , b.BlockingEvidenceID DESC;

    SELECT @TranRows = COUNT(*)
    FROM dbo.vw_RCA_BlockerTransactionAttribution
    WHERE CaptureRunID = @CaptureRunID
      AND (@HeadBlockerSessionID IS NULL
           OR HeadBlockerSessionID = @HeadBlockerSessionID);

    SELECT TOP (1)
          @OpenTranCount = BlockerOpenTransactionCount
        , @TransactionID = TransactionID
        , @TransactionBeginTimeUTC = TransactionBeginTimeUTC
        , @TransactionAgeMs = TransactionAgeMs
        , @TranHost = HeadBlockerHostName
        , @TranProgram = HeadBlockerProgramName
        , @TranLogin = HeadBlockerLoginName
        , @TranCommand = HeadBlockerCommand
        , @TranStatement = HeadBlockerStatement
    FROM dbo.vw_RCA_BlockerTransactionAttribution
    WHERE CaptureRunID = @CaptureRunID
      AND (@HeadBlockerSessionID IS NULL
           OR HeadBlockerSessionID = @HeadBlockerSessionID)
    ORDER BY
          CASE WHEN TransactionID IS NOT NULL THEN 0 ELSE 1 END
        , CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 0 ELSE 1 END
        , TransactionAgeMs DESC
        , SampleTimeUTC DESC;

    DECLARE @Rows TABLE
    (
        SectionOrder int NOT NULL,
        ReportSection nvarchar(100) NOT NULL,
        Narrative nvarchar(max) NOT NULL
    );

    INSERT @Rows VALUES
    (1, N'QUESTION',
        N'Why is ' + COALESCE(@DatabaseName,N'the database') + N' slow?');

    IF @HeadBlockerSessionID IS NULL
    BEGIN
        INSERT @Rows VALUES
        (2, N'ANSWER', N'ROOT CAUSE NOT CONFIRMED'),
        (3, N'ROOT CAUSE', N'No supported blocking cause was found in persisted blocking evidence.'),
        (4, N'WHAT HAPPENED?',
             N'The capture was analyzed, but this report does not have persisted blocking evidence sufficient to attribute the slowdown to a blocking transaction.'),
        (5, N'WHO OR WHAT CAUSED IT?',
             N'Not confirmed. The RCA system will not manufacture blocker attribution when persisted evidence is absent.'),
        (6, N'WHY DO WE BELIEVE THIS?',
             N'No persisted head-blocker relationship was available for this capture.'),
        (7, N'WHAT WAS THE IMPACT?',
             N'Impact cannot be attributed to a blocking transaction from the evidence available to this report.'),
        (8, N'WHAT SHOULD I DO?',
             N'Correlate the reported slowdown window with captured execution, waits, server health, and application activity.'),
        (9, N'WHAT SHOULD I NOT CHANGE YET?',
             N'Do not make server-wide configuration, indexing, statistics, or query changes without evidence that those changes address the incident.');
    END
    ELSE
    BEGIN
        INSERT @Rows VALUES
        (2, N'ANSWER', N'ROOT CAUSE IDENTIFIED'),
        (3, N'ROOT CAUSE',
             N'Blocking / wait-chain contention | Head blocker session '
             + CONVERT(nvarchar(20),@HeadBlockerSessionID)
             + N' | Confidence: HIGH'),
        (4, N'WHAT HAPPENED?',
             COALESCE(@DatabaseName,N'The database')
             + N' experienced blocking. Victim session '
             + COALESCE(CONVERT(nvarchar(20),@VictimSessionID),N'unknown')
             + N' was blocked by session '
             + COALESCE(CONVERT(nvarchar(20),@ImmediateBlockerSessionID),N'unknown')
             + N', with head blocker session '
             + CONVERT(nvarchar(20),@HeadBlockerSessionID)
             + N'. The victim waited on '
             + COALESCE(@WaitType,N'an observed lock/wait')
             + CASE WHEN @WaitDurationMs IS NOT NULL
                    THEN N' for as much as ' + CONVERT(nvarchar(30),CAST(@WaitDurationMs/1000.0 AS decimal(18,1))) + N' seconds'
                    ELSE N'' END
             + CASE WHEN @SampleCount IS NOT NULL
                    THEN N', and the condition persisted across ' + CONVERT(nvarchar(20),@SampleCount) + N' sample(s).'
                    ELSE N'.' END),
        (5, N'WHO OR WHAT CAUSED IT?',
             N'Head blocker session ' + CONVERT(nvarchar(20),@HeadBlockerSessionID)
             + N'. Host: ' + COALESCE(@TranHost,@BlockerHost,N'unknown')
             + N'. Program: ' + COALESCE(@TranProgram,@BlockerProgram,N'unknown')
             + N'. Login: ' + COALESCE(@TranLogin,@BlockerLogin,N'unknown')
             + N'.'
             + CASE
                 WHEN COALESCE(@TranCommand,@TranStatement,@BlockerStatement) IS NOT NULL
                 THEN N' Captured blocker SQL: '
                      + LEFT(REPLACE(REPLACE(COALESCE(@TranCommand,@TranStatement,@BlockerStatement),
                                            CHAR(13),N' '),CHAR(10),N' '),2000)
                 ELSE N' No blocker SQL text was persisted for this observation.'
               END),
        (6, N'WHAT TRANSACTION WAS OPEN?',
             CASE
                 WHEN @TranRows = 0 THEN
                     N'Blocking was captured, but no blocker transaction evidence was persisted for this capture. '
                     + N'The RCA can identify the blocker, but it cannot defensibly state the transaction ID, begin time, or age.'
                 ELSE
                     N'Transaction evidence was persisted while the blocker was live.'
                     + CASE WHEN @OpenTranCount IS NOT NULL
                            THEN N' Open transaction count: ' + CONVERT(nvarchar(20),@OpenTranCount) + N'.'
                            ELSE N'' END
                     + CASE WHEN @TransactionID IS NOT NULL
                            THEN N' Transaction ID: ' + CONVERT(nvarchar(30),@TransactionID) + N'.'
                            ELSE N' Transaction ID was not available in the captured sample.' END
                     + CASE WHEN @TransactionBeginTimeUTC IS NOT NULL
                            THEN N' Transaction began at '
                                 + CONVERT(nvarchar(33),@TransactionBeginTimeUTC,126) + N' UTC.'
                            ELSE N' Transaction begin time was not available in the captured sample.' END
                     + CASE WHEN @TransactionAgeMs IS NOT NULL
                            THEN N' Observed transaction age: '
                                 + CONVERT(nvarchar(30),CAST(@TransactionAgeMs/1000.0 AS decimal(18,1))) + N' seconds.'
                            ELSE N'' END
             END),
        (7, N'WHY DID THE VICTIM HAVE TO WAIT?',
             N'Victim session '
             + COALESCE(CONVERT(nvarchar(20),@VictimSessionID),N'unknown')
             + N' requested a resource that could not be granted while head blocker session '
             + CONVERT(nvarchar(20),@HeadBlockerSessionID)
             + N' retained the conflicting lock/transaction state. The observed victim wait was '
             + COALESCE(@WaitType,N'unknown')
             + N'.'
             + CASE WHEN @VictimStatement IS NOT NULL
                    THEN N' Victim SQL: '
                         + LEFT(REPLACE(REPLACE(@VictimStatement,CHAR(13),N' '),CHAR(10),N' '),1500)
                    ELSE N'' END),
        (8, N'WHY DO WE BELIEVE THIS?',
             N'The conclusion is based on persisted blocking evidence'
             + CASE WHEN @SampleCount IS NOT NULL
                    THEN N' observed across ' + CONVERT(nvarchar(20),@SampleCount) + N' sample(s)' ELSE N'' END
             + CASE WHEN @TranRows > 0
                    THEN N' plus ' + CONVERT(nvarchar(20),@TranRows)
                         + N' persisted blocker-transaction evidence row(s) captured while the incident was live.'
                    ELSE N'. Transaction-level enrichment was not available for this capture.' END),
        (9, N'WHAT WAS THE IMPACT?',
             CASE WHEN @WaitDurationMs IS NOT NULL
                  THEN N'The maximum observed victim blocking wait was '
                       + CONVERT(nvarchar(30),CAST(@WaitDurationMs/1000.0 AS decimal(18,1))) + N' seconds.'
                  ELSE N'A victim request was blocked during the capture.' END
             + CASE WHEN @SampleCount IS NOT NULL
                    THEN N' Blocking persisted across ' + CONVERT(nvarchar(20),@SampleCount) + N' sample(s).' ELSE N'' END),
        (10, N'WHAT SHOULD I DO?',
             N'Investigate the application or job represented by head blocker session '
             + CONVERT(nvarchar(20),@HeadBlockerSessionID)
             + N'. Determine why the transaction remained open while holding locks, whether work can be committed sooner, '
             + N'and whether less work can be performed inside the transaction. Review the captured blocker SQL and transaction pattern before changing database configuration.'),
        (11, N'WHAT SHOULD I NOT CHANGE YET?',
             N'Do not change MAXDOP, server memory, cost threshold, isolation settings, indexes, or statistics merely because blocking occurred. '
             + N'First correct or validate the transaction/application behavior demonstrated by the persisted causal evidence.');
    END;

    SELECT SectionOrder, ReportSection, Narrative
    FROM @Rows
    ORDER BY SectionOrder;
END;
GO

-------------------------------------------------------------------------------
-- 3. FRIENDLY ALIASES
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlow
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_DBAAnswer_TransactionAware @CaptureRunID = @CaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainDatabaseSlowness
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_DBAAnswer_TransactionAware @CaptureRunID = @CaptureRunID;
END;
GO

-------------------------------------------------------------------------------
-- 4. DEPLOYMENT VALIDATION
-------------------------------------------------------------------------------
SELECT
      ValidationSection             = N'1 - SCRIPT 58 DEPLOYMENT'
    , TransactionAttributionView    = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockerTransactionAttribution',N'V') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , TransactionAwareDBAAnswer     = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , WhyIsDatabaseSlowAlias        = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , ExplainDatabaseSlownessAlias  = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainDatabaseSlowness',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , PresentationLayerOnly         = N'YES'
    , SourceEvidenceModified        = N'NO'
    , FindingsRebuilt               = N'NO'
    , DetectorThresholdsChanged     = N'NO'
    , RootCauseDomainsChanged       = N'NO'
    , RootCauseLogicChanged         = N'NO'
    , NewCaptureStarted             = N'NO';
GO

-------------------------------------------------------------------------------
-- 5. CAPTURE 42 TRANSACTION EVIDENCE CHECK
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID = 42)
BEGIN
    SELECT
          ValidationSection = N'2 - CAPTURE 42 TRANSACTION EVIDENCE'
        , CaptureRunID = 42
        , TransactionEvidenceRows = COUNT(*)
        , SamplesWithTransactionID = SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END)
        , SamplesWithBeginTime = SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END)
        , SamplesWithTransactionAge = SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END)
        , MaxTransactionAgeMs = MAX(TransactionAgeMs)
        , Result =
            CASE
                WHEN COUNT(*) > 0
                 AND SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END) > 0
                 AND SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END) > 0
                 AND SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END) > 0
                    THEN N'PASS - TRANSACTION ATTRIBUTION AVAILABLE'
                WHEN COUNT(*) > 0
                    THEN N'REVIEW - TRANSACTION ROWS EXIST BUT CORE ATTRIBUTES ARE PARTIAL'
                ELSE N'NO TRANSACTION EVIDENCE - DO NOT INVENT ATTRIBUTION'
            END
    FROM dbo.vw_RCA_BlockerTransactionAttribution
    WHERE CaptureRunID = 42;

    EXEC dbo.usp_RCA_DBAAnswer_TransactionAware @CaptureRunID = 42;
END
ELSE
BEGIN
    SELECT
          ValidationSection = N'2 - CAPTURE 42 TRANSACTION EVIDENCE'
        , CaptureRunID = 42
        , Result = N'CAPTURE 42 NOT FOUND';
END;
GO

-------------------------------------------------------------------------------
-- 6. NEGATIVE CONTROL: CAPTURE 38
-- Must preserve uncertainty and must NOT retrofit transaction attribution.
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID = 38)
BEGIN
    SELECT
          ValidationSection = N'3 - CAPTURE 38 NEGATIVE CONTROL'
        , CaptureRunID = 38
        , TransactionEvidenceRows = COUNT(*)
        , ExpectedBehavior =
            CASE WHEN COUNT(*) = 0
                 THEN N'PASS - NO HISTORICAL TRANSACTION ATTRIBUTION MANUFACTURED'
                 ELSE N'REVIEW - TRANSACTION EVIDENCE EXISTS; VERIFY ITS ORIGIN'
            END
    FROM dbo.vw_RCA_BlockerTransactionAttribution
    WHERE CaptureRunID = 38;

    EXEC dbo.usp_RCA_DBAAnswer_TransactionAware @CaptureRunID = 38;
END;
GO

-------------------------------------------------------------------------------
-- 7. SAFETY / ACCEPTANCE
-------------------------------------------------------------------------------
DECLARE @C42Rows int = 0,
        @C42TranID int = 0,
        @C42Begin int = 0,
        @C42Age int = 0;

SELECT
      @C42Rows = COUNT(*)
    , @C42TranID = ISNULL(SUM(CASE WHEN TransactionID IS NOT NULL THEN 1 ELSE 0 END),0)
    , @C42Begin = ISNULL(SUM(CASE WHEN TransactionBeginTimeUTC IS NOT NULL THEN 1 ELSE 0 END),0)
    , @C42Age = ISNULL(SUM(CASE WHEN TransactionAgeMs IS NOT NULL THEN 1 ELSE 0 END),0)
FROM dbo.vw_RCA_BlockerTransactionAttribution
WHERE CaptureRunID = 42;

SELECT
      ValidationSection          = N'4 - SCRIPT 58 ACCEPTANCE'
    , Capture42TransactionRows   = @C42Rows
    , TransactionIDCaptured      = CASE WHEN @C42TranID > 0 THEN N'PASS' ELSE N'REVIEW' END
    , TransactionBeginCaptured   = CASE WHEN @C42Begin > 0 THEN N'PASS' ELSE N'REVIEW' END
    , TransactionAgeCaptured     = CASE WHEN @C42Age > 0 THEN N'PASS' ELSE N'REVIEW' END
    , HumanReadableExplanation   = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL THEN N'PASS' ELSE N'FAIL' END
    , ExistingEvidenceModified   = N'NO'
    , FindingsRebuilt            = N'NO'
    , DetectorThresholdsChanged  = N'NO'
    , RootCauseDomainsChanged    = N'NO'
    , RootCauseLogicChanged      = N'NO'
    , ManualCauseInserted        = N'NO'
    , NewCaptureStarted          = N'NO'
    , OverallResult =
        CASE
            WHEN @C42Rows > 0 AND @C42TranID > 0 AND @C42Begin > 0 AND @C42Age > 0
                THEN N'PASS - RCA CAN EXPLAIN THE BLOCKING TRANSACTION'
            WHEN @C42Rows > 0
                THEN N'REVIEW - TRANSACTION EVIDENCE EXISTS BUT ATTRIBUTES ARE PARTIAL'
            ELSE N'REVIEW - COMPLETE SCRIPT 57 / VERIFY CAPTURE 42 TRANSACTION COLLECTION'
        END
    , NextStep =
        CASE
            WHEN @C42Rows > 0 AND @C42TranID > 0 AND @C42Begin > 0 AND @C42Age > 0
                THEN N'Promote the transaction-aware DBA answer as the primary human-readable RCA entry point.'
            ELSE N'Do not change root-cause logic. First verify why Capture 42 lacks complete persisted transaction attributes.'
        END;
GO
