USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  64_RCA_Multi_Domain_Canonical_DBA_Answer_v1.sql

  PURPOSE
  -------
  Extend the canonical DBA-facing RCA answer so it can explain more than the
  already-proven blocking/transaction domain.

  THIS VERSION ADDS
  ----------------
  CPU / scheduler narration based on persisted RCA_CPUSchedulerEvidence.

  A/B ACCEPTANCE
  --------------
  Capture 42:
      Must continue to return the existing blocking / wait-chain explanation.

  Capture 44:
      Must change from ROOT CAUSE NOT CONFIRMED to a CPU / scheduler explanation
      when persisted CPU evidence is PRIMARY + HIGH confidence.

  SAFETY
  ------
  Presentation / routing layer only.

  This script does NOT:
      - change detector thresholds
      - change root-cause ranking logic
      - rebuild findings
      - modify historical evidence
      - alter blocking evidence
      - alter transaction evidence
      - alter CPU evidence
      - start a new capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 64 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ExecutionEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , TransactionAwareAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , PresentationLayerOnly='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 56400,N'dbo.RCA_CaptureRun is required.',1;

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NULL
    THROW 56401,N'dbo.RCA_CPUSchedulerEvidence is required.',1;

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    THROW 56402,N'dbo.RCA_ExecutionEvidence is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware',N'P') IS NULL
    THROW 56403,N'dbo.usp_RCA_DBAAnswer_TransactionAware is required.',1;
GO


/*==============================================================================
  1. CPU-SPECIFIC HUMAN-READABLE NARRATOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer_CPU
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
        THROW 56410,N'CaptureRunID does not exist.',1;

    DECLARE
          @DatabaseName sysname
        , @CaptureStatus nvarchar(60)
        , @IncidentStartUTC datetime2(3)
        , @IncidentEndUTC datetime2(3)

        , @CPUSchedulerEvidenceID bigint
        , @PrimaryExecutionEvidenceID bigint
        , @PrimarySessionID int
        , @Confidence varchar(20)
        , @RootCauseRole varchar(20)

        , @PeakSqlCpuPercent decimal(18,4)
        , @AvgSqlCpuPercent decimal(18,4)
        , @PeakOtherCpuPercent decimal(18,4)
        , @AvgOtherCpuPercent decimal(18,4)
        , @LowestSystemIdlePercent decimal(18,4)
        , @PeakRunnableTasks int
        , @AvgRunnableTasks decimal(18,4)
        , @HighRunnableSampleCount int
        , @ServerSampleCount int

        , @HostName nvarchar(1024)
        , @ProgramName nvarchar(1024)
        , @LoginName nvarchar(1024)
        , @ObjectName nvarchar(1024)
        , @CPUms decimal(19,3)
        , @DurationMs decimal(19,3)
        , @LogicalReads bigint
        , @PhysicalReads bigint
        , @Writes bigint
        , @TotalRows bigint
        , @SubmittedCommand nvarchar(max);

    SELECT
          @DatabaseName=TargetDatabase
        , @CaptureStatus=CaptureStatus
        , @IncidentStartUTC=StartTimeUTC
        , @IncidentEndUTC=EndTimeUTC
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SELECT TOP (1)
          @CPUSchedulerEvidenceID=CPUSchedulerEvidenceID
        , @PrimaryExecutionEvidenceID=PrimaryExecutionEvidenceID
        , @PrimarySessionID=PrimarySessionID
        , @Confidence=Confidence
        , @RootCauseRole=RootCauseRole
        , @PeakSqlCpuPercent=PeakSqlCpuPercent
        , @AvgSqlCpuPercent=AvgSqlCpuPercent
        , @PeakOtherCpuPercent=PeakOtherCpuPercent
        , @AvgOtherCpuPercent=AvgOtherCpuPercent
        , @LowestSystemIdlePercent=LowestSystemIdlePercent
        , @PeakRunnableTasks=PeakRunnableTasks
        , @AvgRunnableTasks=AvgRunnableTasks
        , @HighRunnableSampleCount=HighRunnableSampleCount
        , @ServerSampleCount=ServerSampleCount
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseRole='PRIMARY'
    ORDER BY
          CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , CPUSchedulerEvidenceID DESC;

    IF @CPUSchedulerEvidenceID IS NULL
    BEGIN
        THROW 56411,N'No PRIMARY CPU scheduler evidence exists for this capture.',1;
    END;

    SELECT
          @HostName=HostName
        , @ProgramName=ProgramName
        , @LoginName=LoginName
        , @ObjectName=ObjectName
        , @CPUms=CPUms
        , @DurationMs=DurationMs
        , @LogicalReads=LogicalReads
        , @PhysicalReads=PhysicalReads
        , @Writes=Writes
        , @TotalRows=TotalRows
        , @SubmittedCommand=SubmittedCommand
    FROM dbo.RCA_ExecutionEvidence
    WHERE ExecutionEvidenceID=@PrimaryExecutionEvidenceID;

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
        N'CPU / scheduler pressure | Confidence: ' + COALESCE(CONVERT(nvarchar(20),@Confidence),N'UNKNOWN')
    );

    INSERT @Rows VALUES
    (
        4,
        N'WHAT HAPPENED?',
        N'The RCA engine identified CPU / scheduler pressure as the PRIMARY cause for '
        + COALESCE(@DatabaseName,N'the database')
        + N'. Peak runnable tasks reached '
        + COALESCE(CONVERT(nvarchar(20),@PeakRunnableTasks),N'unknown')
        + N', average runnable tasks were '
        + COALESCE(CONVERT(nvarchar(40),@AvgRunnableTasks),N'unknown')
        + N', and high-runnable pressure was observed across '
        + COALESCE(CONVERT(nvarchar(20),@HighRunnableSampleCount),N'unknown')
        + N' sample(s) out of '
        + COALESCE(CONVERT(nvarchar(20),@ServerSampleCount),N'unknown')
        + N'.'
    );

    INSERT @Rows VALUES
    (
        5,
        N'WHO OR WHAT CAUSED IT?',
        N'The primary correlated execution was Evidence ID '
        + COALESCE(CONVERT(nvarchar(30),@PrimaryExecutionEvidenceID),N'unknown')
        + N' on session '
        + COALESCE(CONVERT(nvarchar(20),@PrimarySessionID),N'unknown')
        + N'. Host: ' + COALESCE(@HostName,N'unknown')
        + N'. Program: ' + COALESCE(@ProgramName,N'unknown')
        + N'. Login: ' + COALESCE(@LoginName,N'unknown')
        + N'.'
        + CASE
            WHEN @ObjectName IS NOT NULL
                THEN N' Object: ' + @ObjectName + N'.'
            ELSE N''
          END
        + CASE
            WHEN @SubmittedCommand IS NOT NULL
                THEN N' Captured SQL: '
                     + LEFT(REPLACE(REPLACE(@SubmittedCommand,CHAR(13),N' '),CHAR(10),N' '),2500)
            ELSE N''
          END
    );

    INSERT @Rows VALUES
    (
        6,
        N'WHY DO WE BELIEVE THIS?',
        N'The conclusion comes from persisted RCA CPU scheduler evidence, not from CPU percentage alone. '
        + N'RCA_CPUSchedulerEvidence ID '
        + CONVERT(nvarchar(30),@CPUSchedulerEvidenceID)
        + N' was classified as '
        + COALESCE(CONVERT(nvarchar(20),@RootCauseRole),N'UNKNOWN')
        + N' with '
        + COALESCE(CONVERT(nvarchar(20),@Confidence),N'UNKNOWN')
        + N' confidence. Peak SQL CPU was '
        + COALESCE(CONVERT(nvarchar(40),@PeakSqlCpuPercent),N'unknown')
        + N'%, average SQL CPU was '
        + COALESCE(CONVERT(nvarchar(40),@AvgSqlCpuPercent),N'unknown')
        + N'%, lowest system idle was '
        + COALESCE(CONVERT(nvarchar(40),@LowestSystemIdlePercent),N'unknown')
        + N'%, peak runnable tasks were '
        + COALESCE(CONVERT(nvarchar(20),@PeakRunnableTasks),N'unknown')
        + N', and average runnable tasks were '
        + COALESCE(CONVERT(nvarchar(40),@AvgRunnableTasks),N'unknown')
        + N'.'
    );

    INSERT @Rows VALUES
    (
        7,
        N'WHAT WAS THE IMPACT?',
        N'The primary correlated execution consumed '
        + COALESCE(CONVERT(nvarchar(40),@CPUms),N'unknown')
        + N' ms of CPU over '
        + COALESCE(CONVERT(nvarchar(40),@DurationMs),N'unknown')
        + N' ms elapsed time'
        + CASE
            WHEN @LogicalReads IS NOT NULL
                THEN N', with ' + CONVERT(nvarchar(30),@LogicalReads) + N' logical reads'
            ELSE N''
          END
        + CASE
            WHEN @PhysicalReads IS NOT NULL
                THEN N', ' + CONVERT(nvarchar(30),@PhysicalReads) + N' physical reads'
            ELSE N''
          END
        + CASE
            WHEN @Writes IS NOT NULL
                THEN N', and ' + CONVERT(nvarchar(30),@Writes) + N' writes'
            ELSE N''
          END
        + N'.'
    );

    INSERT @Rows VALUES
    (
        8,
        N'WHAT SHOULD I DO?',
        N'Investigate the primary CPU-consuming workload first. Review the captured SQL, execution pattern, '
        + N'concurrency, row volume, logical reads, plan shape, and whether the application launched many similar '
        + N'CPU-heavy requests at the same time. Reduce work at the query/application level before considering '
        + N'instance-wide CPU configuration changes.'
    );

    INSERT @Rows VALUES
    (
        9,
        N'WHAT SHOULD I NOT CHANGE YET?',
        N'Do not change MAXDOP, cost threshold for parallelism, server memory, affinity, or other instance-wide '
        + N'settings from this capture alone. First validate whether the identified workload and concurrency pattern '
        + N'are expected and whether the query can perform less CPU work.'
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
  2. MULTI-DOMAIN CANONICAL ROUTER

  Routing order:
      1. PRIMARY HIGH/MEDIUM blocking evidence -> existing transaction-aware path
      2. PRIMARY HIGH/MEDIUM CPU evidence      -> CPU narrator
      3. otherwise                             -> existing transaction-aware path

  Why preserve the old path as fallback?
      It already proved uncertainty preservation for negative controls such as
      Capture 38.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_DBAAnswer
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @CaptureRunID IS NULL
        THROW 56420,N'@CaptureRunID is required.',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 56421,N'CaptureRunID does not exist.',1;

    DECLARE
          @HasBlockingPrimary bit=0
        , @HasCPUPrimary bit=0;

    /*
      Blocking evidence in this RCA design already represents accepted causal
      blocking observations used successfully by the proven Capture 42 path.
    */
    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence IN ('HIGH','MEDIUM')
    )
        SET @HasBlockingPrimary=1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CPUSchedulerEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence IN ('HIGH','MEDIUM')
    )
        SET @HasCPUPrimary=1;

    /*
      Keep blocking first only because that path was already production-accepted
      and transaction-enriched. Cross-domain arbitration remains owned by the
      evidence/ranking layer; this router does not manufacture causes.
    */
    IF @HasBlockingPrimary=1
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_TransactionAware
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    IF @HasCPUPrimary=1
    BEGIN
        EXEC dbo.usp_RCA_DBAAnswer_CPU
             @CaptureRunID=@CaptureRunID;
        RETURN;
    END;

    /*
      Preserve the existing uncertainty behavior for unsupported captures.
    */
    EXEC dbo.usp_RCA_DBAAnswer_TransactionAware
         @CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
  3. KEEP FRIENDLY ALIASES ON THE CANONICAL ROUTER
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlow
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer
         @CaptureRunID=@CaptureRunID;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainDatabaseSlowness
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_DBAAnswer
         @CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
  4. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection='1 - SCRIPT 64 DEPLOYMENT'
    , CPUNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalRouter=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , WhyIsDatabaseSlowAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExplainDatabaseSlownessAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainDatabaseSlowness',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PresentationLayerOnly='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  5. ROUTING DISCOVERY
==============================================================================*/
SELECT
      ValidationSection='2 - ROUTING MATRIX'
    , CaptureRunID=c.CaptureRunID
    , BlockingPrimary=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.RCA_BlockingEvidence b
            WHERE b.CaptureRunID=c.CaptureRunID
              AND b.RootCauseRole='PRIMARY'
              AND b.Confidence IN ('HIGH','MEDIUM')
        ) THEN 'YES' ELSE 'NO' END
    , CPUPrimary=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.RCA_CPUSchedulerEvidence cpu
            WHERE cpu.CaptureRunID=c.CaptureRunID
              AND cpu.RootCauseRole='PRIMARY'
              AND cpu.Confidence IN ('HIGH','MEDIUM')
        ) THEN 'YES' ELSE 'NO' END
    , ExpectedNarrator=
        CASE
          WHEN EXISTS
          (
              SELECT 1
              FROM dbo.RCA_BlockingEvidence b
              WHERE b.CaptureRunID=c.CaptureRunID
                AND b.RootCauseRole='PRIMARY'
                AND b.Confidence IN ('HIGH','MEDIUM')
          )
          THEN 'BLOCKING / TRANSACTION'

          WHEN EXISTS
          (
              SELECT 1
              FROM dbo.RCA_CPUSchedulerEvidence cpu
              WHERE cpu.CaptureRunID=c.CaptureRunID
                AND cpu.RootCauseRole='PRIMARY'
                AND cpu.Confidence IN ('HIGH','MEDIUM')
          )
          THEN 'CPU / SCHEDULER'

          ELSE 'UNCERTAINTY / FALLBACK'
        END
FROM dbo.RCA_CaptureRun c
WHERE c.CaptureRunID IN (38,42,44)
ORDER BY c.CaptureRunID;
GO


/*==============================================================================
  6. CAPTURE 42 REGRESSION - BLOCKING MUST REMAIN CORRECT
==============================================================================*/
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=42)
BEGIN
    SELECT
          ValidationSection='3 - CAPTURE 42 BLOCKING REGRESSION'
        , CaptureRunID=42
        , ExpectedResult='ROOT CAUSE IDENTIFIED - BLOCKING / WAIT-CHAIN';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
END;
GO


/*==============================================================================
  7. CAPTURE 44 CPU POSITIVE CONTROL
==============================================================================*/
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=44)
BEGIN
    SELECT
          ValidationSection='4 - CAPTURE 44 CPU ANSWER'
        , CaptureRunID=44
        , ExpectedResult='ROOT CAUSE IDENTIFIED - CPU / SCHEDULER';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
END;
GO


/*==============================================================================
  8. CAPTURE 38 NEGATIVE CONTROL
==============================================================================*/
IF EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=38)
BEGIN
    SELECT
          ValidationSection='5 - CAPTURE 38 NEGATIVE CONTROL'
        , CaptureRunID=38
        , ExpectedResult='ROOT CAUSE NOT CONFIRMED - UNCERTAINTY PRESERVED';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;
END;
GO


/*==============================================================================
  9. ACCEPTANCE
==============================================================================*/
DECLARE
      @C42BlockingPrimary int=0
    , @C44CPUPrimary int=0
    , @C44CPUHigh int=0
    , @C38BlockingPrimary int=0
    , @C38CPUPrimary int=0;

SELECT @C42BlockingPrimary=COUNT(*)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=42
  AND RootCauseRole='PRIMARY'
  AND Confidence IN ('HIGH','MEDIUM');

SELECT
      @C44CPUPrimary=
          ISNULL(SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END),0)
    , @C44CPUHigh=
          ISNULL(SUM(CASE WHEN RootCauseRole='PRIMARY' AND Confidence='HIGH' THEN 1 ELSE 0 END),0)
FROM dbo.RCA_CPUSchedulerEvidence
WHERE CaptureRunID=44;

SELECT @C38BlockingPrimary=COUNT(*)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=38
  AND RootCauseRole='PRIMARY'
  AND Confidence IN ('HIGH','MEDIUM');

SELECT @C38CPUPrimary=COUNT(*)
FROM dbo.RCA_CPUSchedulerEvidence
WHERE CaptureRunID=38
  AND RootCauseRole='PRIMARY'
  AND Confidence IN ('HIGH','MEDIUM');

SELECT
      ValidationSection='6 - SCRIPT 64 ACCEPTANCE'
    , Capture42BlockingPrimary=
        CASE WHEN @C42BlockingPrimary>0 THEN 'PASS' ELSE 'FAIL' END
    , Capture44CPUPrimary=
        CASE WHEN @C44CPUPrimary>0 THEN 'PASS' ELSE 'FAIL' END
    , Capture44CPUHighConfidence=
        CASE WHEN @C44CPUHigh>0 THEN 'PASS' ELSE 'REVIEW' END
    , Capture38NoBlockingPrimary=
        CASE WHEN @C38BlockingPrimary=0 THEN 'PASS' ELSE 'REVIEW' END
    , Capture38NoCPUPrimary=
        CASE WHEN @C38CPUPrimary=0 THEN 'PASS' ELSE 'REVIEW' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUNarrator=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PresentationLayerOnly='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO'
    , OverallResult=
        CASE
          WHEN @C42BlockingPrimary>0
           AND @C44CPUPrimary>0
           AND @C38BlockingPrimary=0
           AND @C38CPUPrimary=0
          THEN 'PASS - CANONICAL DBA ANSWER NOW ROUTES BLOCKING AND CPU EVIDENCE'
          ELSE 'REVIEW - ROUTER DEPLOYED; REVIEW CONTROL EVIDENCE'
        END
    , NextStep=
        'If the three control narratives are accepted, freeze blocking + CPU presentation paths and move to the next root-cause domain without changing detector thresholds.';
GO


/*==============================================================================
  10. SAFETY
==============================================================================*/
SELECT
      ValidationSection='7 - SCRIPT 64 SAFETY'
    , PresentationRouterAdded='YES'
    , CPUNarratorAdded='YES'
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
