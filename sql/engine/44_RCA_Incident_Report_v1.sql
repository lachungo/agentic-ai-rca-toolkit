USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  44_RCA_Incident_Report_v1.sql

  PURPOSE
  -------
  Create the final presentation layer for the RCA utility.

  PRIMARY ENTRY POINT
  -------------------
      EXEC dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 38;

  OPTIONAL TECHNICAL DRILL-DOWN
  -----------------------------
      EXEC dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 38,
           @IncludeTechnicalDetail = 1;

  DEFAULT USER EXPERIENCE
  -----------------------
  Result Set 1:
      One-row incident report answering:
          - What is the verdict?
          - What happened?
          - What did we observe?
          - What did the actual execution plan show?
          - What did server health show?
          - Why do we believe this?
          - What should we do?
          - What should we NOT change yet?

  Result Set 2:
      Human-readable report sections in presentation order.

  TECHNICAL MODE
  --------------
  When @IncludeTechnicalDetail = 1, Script 44 additionally invokes the
  validated Script 43 detailed experience.

  DESIGN PRINCIPLES
  -----------------
  1. Presentation only.
  2. No detector thresholds changed.
  3. No findings rebuilt.
  4. No source XE evidence changed.
  5. No root-cause promotion performed here.
  6. Final-cause ranking remains authoritative.
  7. Observation is not causation.
  8. Large scans, implicit conversions, and statistics observations remain
     evidence until causal support exists.
==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.usp_RCA_ExplainIncident',N'P') IS NULL
    THROW 51600,N'Script 44 requires dbo.usp_RCA_ExplainIncident from Script 43.',1;

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 51601,N'dbo.RCA_CaptureRun is missing.',1;

IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NULL
    THROW 51602,N'dbo.RCA_IncidentContext is missing.',1;

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    THROW 51603,N'dbo.RCA_ExecutionEvidence is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
    THROW 51604,N'dbo.RCA_PlanEvidence is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
    THROW 51605,N'dbo.RCA_PlanOperator is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
    THROW 51606,N'dbo.RCA_PlanFinding is missing.',1;

IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
    THROW 51607,N'dbo.RCA_ServerSnapshot is missing.',1;

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    THROW 51608,N'dbo.vw_RCA_FinalCauseRanking is missing.',1;
GO

/*==============================================================================
  1. FINAL INCIDENT REPORT
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_FinalIncidentReport
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
    )
        THROW 51610,N'Invalid CaptureRunID.',1;

    ---------------------------------------------------------------------------
    -- Incident context
    ---------------------------------------------------------------------------
    DECLARE
          @RequestedDatabaseName sysname
        , @IncidentDescription nvarchar(4000)
        , @RequestedBy nvarchar(512)
        , @StartedFromHost nvarchar(512)
        , @StartedFromProgram nvarchar(1024)
        , @StartTimeUTC datetime2(7)
        , @EndTimeUTC datetime2(7)
        , @CaptureStatus varchar(40);

    SELECT
          @StartTimeUTC = StartTimeUTC
        , @EndTimeUTC = EndTimeUTC
        , @CaptureStatus = CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = @CaptureRunID;

    SELECT TOP (1)
          @RequestedDatabaseName = RequestedDatabaseName
        , @IncidentDescription = IncidentDescription
        , @RequestedBy = RequestedBy
        , @StartedFromHost = StartedFromHost
        , @StartedFromProgram = StartedFromProgram
    FROM dbo.RCA_IncidentContext
    WHERE CaptureRunID = @CaptureRunID
    ORDER BY CreatedTimeUTC DESC;

    ---------------------------------------------------------------------------
    -- Supported primary cause, if one exists
    ---------------------------------------------------------------------------
    DECLARE
          @PrimaryCauseCategory varchar(100)
        , @PrimaryCauseDisplay nvarchar(256)
        , @PrimaryConfidence varchar(20)
        , @PrimaryEvidence nvarchar(max)
        , @PrimaryAction nvarchar(max)
        , @PrimaryExecutionEvidenceID bigint
        , @ImpactedRequestCount int
        , @EvidenceCount int;

    SELECT TOP (1)
          @PrimaryCauseCategory = CauseCategory
        , @PrimaryCauseDisplay = CauseDisplayName
        , @PrimaryConfidence = Confidence
        , @PrimaryEvidence = PrimaryEvidence
        , @PrimaryAction = RecommendedAction
        , @PrimaryExecutionEvidenceID = ImpactedExecutionEvidenceID
        , @ImpactedRequestCount = ImpactedRequestCount
        , @EvidenceCount = EvidenceCount
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID = @CaptureRunID
      AND RootCauseRole = 'PRIMARY'
      AND Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , EvidenceCount DESC
        , ImpactedRequestCount DESC;

    ---------------------------------------------------------------------------
    -- Highest-impact observed execution
    ---------------------------------------------------------------------------
    DECLARE
          @ExecutionEvidenceID bigint
        , @EventTimeUTC datetime2(7)
        , @DatabaseName sysname
        , @SessionID int
        , @ObjectName nvarchar(1024)
        , @SubmittedCommand nvarchar(max)
        , @ParameterText nvarchar(max)
        , @ParameterStatus varchar(40)
        , @HostName nvarchar(512)
        , @ProgramName nvarchar(512)
        , @LoginName nvarchar(512)
        , @CPUms decimal(19,3)
        , @DurationMs decimal(19,3)
        , @LogicalReads bigint
        , @PhysicalReads bigint
        , @Writes bigint
        , @TotalRows bigint;

    SELECT TOP (1)
          @ExecutionEvidenceID = e.ExecutionEvidenceID
        , @EventTimeUTC = e.EventTimeUTC
        , @DatabaseName = e.DatabaseName
        , @SessionID = e.SessionID
        , @ObjectName = e.ObjectName
        , @SubmittedCommand = e.SubmittedCommand
        , @ParameterText = e.ParameterText
        , @ParameterStatus = e.ParameterEvidenceStatus
        , @HostName = e.HostName
        , @ProgramName = e.ProgramName
        , @LoginName = e.LoginName
        , @CPUms = e.CPUms
        , @DurationMs = e.DurationMs
        , @LogicalReads = e.LogicalReads
        , @PhysicalReads = e.PhysicalReads
        , @Writes = e.Writes
        , @TotalRows = e.TotalRows
    FROM dbo.RCA_ExecutionEvidence e
    WHERE e.CaptureRunID = @CaptureRunID
    ORDER BY
          CASE WHEN e.ExecutionEvidenceID = @PrimaryExecutionEvidenceID THEN 0 ELSE 1 END
        , ISNULL(e.CPUms,0) DESC
        , ISNULL(e.DurationMs,0) DESC
        , ISNULL(e.LogicalReads,0) DESC
        , e.ExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- Best defensible actual execution plan
    ---------------------------------------------------------------------------
    DECLARE
          @PlanEvidenceID bigint
        , @PlanCorrelation varchar(60)
        , @PlanSource varchar(80)
        , @ActualExecutionPlanXML xml;

    SELECT TOP (1)
          @PlanEvidenceID = p.PlanEvidenceID
        , @ActualExecutionPlanXML = p.ActualExecutionPlanXML
        , @PlanCorrelation =
            CASE
              WHEN p.LinkedExecutionEvidenceID = @ExecutionEvidenceID
                THEN 'DIRECT EXECUTION LINK'
              ELSE 'SESSION/TIME CORRELATION'
            END
        , @PlanSource =
            CASE
              WHEN p.LinkedExecutionEvidenceID = @ExecutionEvidenceID
                THEN 'ACTUAL_SHOWPLAN_XE_DIRECT_LINK'
              ELSE 'ACTUAL_SHOWPLAN_XE_STRICT_CORRELATION'
            END
    FROM dbo.RCA_PlanEvidence p
    WHERE p.CaptureRunID = @CaptureRunID
      AND p.ActualExecutionPlanXML IS NOT NULL
      AND
      (
          p.LinkedExecutionEvidenceID = @ExecutionEvidenceID
          OR
          (
              p.LinkedExecutionEvidenceID IS NULL
              AND p.SessionID = @SessionID
              AND ISNULL(p.DatabaseName,N'') = ISNULL(@DatabaseName,N'')
              AND NULLIF(LTRIM(RTRIM(p.SQLText)),N'')
                  = NULLIF(LTRIM(RTRIM(@SubmittedCommand)),N'')
              AND ABS(DATEDIFF_BIG(millisecond,p.EventTimeUTC,@EventTimeUTC)) <= 100
          )
      )
    ORDER BY
          CASE WHEN p.LinkedExecutionEvidenceID = @ExecutionEvidenceID THEN 0 ELSE 1 END
        , ABS(DATEDIFF_BIG(millisecond,p.EventTimeUTC,@EventTimeUTC))
        , p.PlanEvidenceID DESC;

    ---------------------------------------------------------------------------
    -- Plan summary
    ---------------------------------------------------------------------------
    DECLARE
          @AccessMethod nvarchar(256)
        , @PlanTableName nvarchar(512)
        , @PlanIndexName nvarchar(512)
        , @RowsRead decimal(28,4)
        , @RowsReturned decimal(28,4)
        , @OutputVsRowsReadPercent decimal(19,4)
        , @WorstNormalizedEstimateActualRatio decimal(19,4)
        , @SpillOperatorCount int = 0
        , @RunLargeScans int = 0
        , @RunImplicitConversions int = 0
        , @RunCardinalityMismatch int = 0
        , @RunStatisticsRisk int = 0;

    IF @PlanEvidenceID IS NOT NULL
    BEGIN
        SELECT TOP (1)
              @AccessMethod = PhysicalOp
            , @PlanTableName = TableName
            , @PlanIndexName = IndexName
            , @RowsRead = CONVERT(decimal(28,4),ActualRowsRead)
            , @RowsReturned = CONVERT(decimal(28,4),ActualRows)
        FROM dbo.RCA_PlanOperator
        WHERE CaptureRunID = @CaptureRunID
          AND PlanEvidenceID = @PlanEvidenceID
          AND (PhysicalOp LIKE '%Scan%' OR PhysicalOp LIKE '%Seek%')
          AND COALESCE(ActualRowsRead,ActualRows) IS NOT NULL
        ORDER BY COALESCE(ActualRowsRead,ActualRows) DESC, NodeID;

        SET @OutputVsRowsReadPercent =
            CASE
              WHEN @RowsRead > 0 AND @RowsReturned IS NOT NULL
              THEN CONVERT(decimal(19,4),@RowsReturned * 100.0 / @RowsRead)
            END;

        SELECT
              @WorstNormalizedEstimateActualRatio =
                MAX
                (
                    CASE
                      WHEN EstimateActualRatio IS NULL OR EstimateActualRatio = 0 THEN NULL
                      WHEN EstimateActualRatio >= 1
                        THEN CONVERT(decimal(19,4),EstimateActualRatio)
                      ELSE CONVERT(decimal(19,4),1.0 / EstimateActualRatio)
                    END
                )
            , @SpillOperatorCount =
                SUM(CASE WHEN HasSpillWarning = 1 THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanOperator
        WHERE CaptureRunID = @CaptureRunID
          AND PlanEvidenceID = @PlanEvidenceID;
    END;

    SELECT
          @RunLargeScans = SUM(CASE WHEN FindingType = 'LARGE_SCAN' THEN 1 ELSE 0 END)
        , @RunImplicitConversions = SUM(CASE WHEN FindingType = 'IMPLICIT_CONVERSION' THEN 1 ELSE 0 END)
        , @RunCardinalityMismatch = SUM(CASE WHEN FindingType = 'CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
        , @RunStatisticsRisk = SUM(CASE WHEN FindingType = 'STATISTICS_RISK' THEN 1 ELSE 0 END)
    FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID = @CaptureRunID;

    SET @SpillOperatorCount = ISNULL(@SpillOperatorCount,0);
    SET @RunLargeScans = ISNULL(@RunLargeScans,0);
    SET @RunImplicitConversions = ISNULL(@RunImplicitConversions,0);
    SET @RunCardinalityMismatch = ISNULL(@RunCardinalityMismatch,0);
    SET @RunStatisticsRisk = ISNULL(@RunStatisticsRisk,0);

    ---------------------------------------------------------------------------
    -- Server health
    ---------------------------------------------------------------------------
    DECLARE
          @ServerSamples bigint = 0
        , @PeakSqlCpuPercent decimal(19,6)
        , @AvgSqlCpuPercent decimal(19,6)
        , @PeakOtherCpuPercent decimal(19,6)
        , @LowestSystemIdlePercent decimal(19,6)
        , @PeakRunnableTasks int
        , @LowestBufferCacheHitRatio decimal(19,6)
        , @LowestPLESeconds bigint
        , @LowestAvailablePhysicalMemoryMB decimal(19,2)
        , @PeakMemoryGrantsPending int
        , @PeakMemoryGrantsOutstanding int;

    SELECT
          @ServerSamples = COUNT_BIG(*)
        , @PeakSqlCpuPercent = MAX(SqlCpuPercent)
        , @AvgSqlCpuPercent = CONVERT(decimal(19,6),AVG(SqlCpuPercent))
        , @PeakOtherCpuPercent = MAX(OtherCpuPercent)
        , @LowestSystemIdlePercent = MIN(SystemIdlePercent)
        , @PeakRunnableTasks = MAX(RunnableTasks)
        , @LowestBufferCacheHitRatio = MIN(BufferCacheHitRatio)
        , @LowestPLESeconds = MIN(PageLifeExpectancySeconds)
        , @LowestAvailablePhysicalMemoryMB = MIN(AvailablePhysicalMemoryMB)
        , @PeakMemoryGrantsPending = MAX(MemoryGrantsPending)
        , @PeakMemoryGrantsOutstanding = MAX(MemoryGrantsOutstanding)
    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID = @CaptureRunID;

    ---------------------------------------------------------------------------
    -- Presentation language
    ---------------------------------------------------------------------------
    DECLARE
          @Verdict varchar(50)
        , @ExecutiveSummary nvarchar(max)
        , @ObservedWorkload nvarchar(max)
        , @PlanSummary nvarchar(max)
        , @ServerHealthSummary nvarchar(max)
        , @WhyWeBelieveThis nvarchar(max)
        , @RecommendedAction nvarchar(max)
        , @DoNotChangeYet nvarchar(max)
        , @FinalReport nvarchar(max);

    SET @Verdict =
        CASE
          WHEN @PrimaryCauseCategory IS NULL
            THEN 'NO ROOT CAUSE CONFIRMED'
          ELSE 'ROOT CAUSE IDENTIFIED'
        END;

    SET @ObservedWorkload =
        CASE
          WHEN @ExecutionEvidenceID IS NULL
            THEN 'No ranked execution evidence was available for the captured incident.'
          ELSE CONCAT(
               'The highest-impact observed execution was Evidence ID ',
               @ExecutionEvidenceID,
               ' on session ',
               COALESCE(CONVERT(varchar(20),@SessionID),'UNKNOWN'),
               '. It used ',
               COALESCE(CONVERT(varchar(40),@CPUms),'UNKNOWN'),
               ' ms CPU, ran for ',
               COALESCE(CONVERT(varchar(40),@DurationMs),'UNKNOWN'),
               ' ms, and performed ',
               COALESCE(CONVERT(varchar(40),@LogicalReads),'UNKNOWN'),
               ' logical reads. The request originated from host ',
               COALESCE(@HostName,N'UNKNOWN'),
               ' using ',
               COALESCE(@ProgramName,N'UNKNOWN'),
               ' under login ',
               COALESCE(@LoginName,N'UNKNOWN'),
               '.')
        END;

    SET @PlanSummary =
        CASE
          WHEN @PlanEvidenceID IS NULL
            THEN 'No defensibly correlated actual execution plan was available for the selected workload.'
          ELSE CONCAT(
               'An actual execution plan was captured and correlated by ',
               LOWER(@PlanCorrelation),
               '. The highest-row-read access method was ',
               COALESCE(@AccessMethod,N'UNKNOWN'),
               CASE WHEN @PlanTableName IS NOT NULL
                    THEN CONCAT(' against ',@PlanTableName)
                    ELSE '' END,
               CASE WHEN @PlanIndexName IS NOT NULL
                    THEN CONCAT(' using ',@PlanIndexName)
                    ELSE '' END,
               '. ',
               CASE WHEN @RowsRead IS NOT NULL
                    THEN CONCAT(
                         'The operator read approximately ',
                         CONVERT(varchar(40),CONVERT(decimal(28,0),@RowsRead)),
                         ' rows and returned approximately ',
                         CONVERT(varchar(40),CONVERT(decimal(28,0),@RowsReturned)),
                         ' rows (',
                         CONVERT(varchar(40),@OutputVsRowsReadPercent),
                         '% of rows read). ')
                    ELSE '' END,
               CASE WHEN @OutputVsRowsReadPercent >= 90
                    THEN 'Because most rows read were also returned, the scan alone does not demonstrate inefficient row elimination or prove root cause. '
                    ELSE '' END,
               CASE WHEN @WorstNormalizedEstimateActualRatio IS NOT NULL
                    THEN CONCAT(
                         'Worst normalized estimate-to-actual ratio was ',
                         CONVERT(varchar(40),@WorstNormalizedEstimateActualRatio),
                         '. ')
                    ELSE '' END,
               CASE WHEN @RunCardinalityMismatch = 0
                    THEN 'No supported cardinality-mismatch finding was established for the capture. '
                    ELSE CONCAT(@RunCardinalityMismatch,' cardinality-mismatch finding(s) were present. ') END,
               CASE WHEN @RunStatisticsRisk = 0
                    THEN 'Statistics were not established as a harmful cause by the hardened detector. '
                    ELSE CONCAT(@RunStatisticsRisk,' statistics-risk finding(s) were present. ') END,
               CASE WHEN @RunImplicitConversions > 0
                    THEN CONCAT(
                         @RunImplicitConversions,
                         ' implicit-conversion observation(s) were retained as plan evidence and were not automatically promoted to causation. ')
                    ELSE '' END,
               CASE WHEN @SpillOperatorCount = 0
                    THEN 'No spill warning was observed.'
                    ELSE CONCAT(@SpillOperatorCount,' spill-related operator(s) were observed.') END)
        END;

    SET @ServerHealthSummary =
        CASE
          WHEN @ServerSamples = 0
            THEN 'No persisted server-health samples were available for this capture.'
          ELSE CONCAT(
               'The incident contains ',
               @ServerSamples,
               ' persisted server-health sample(s). Peak SQL CPU was ',
               COALESCE(CONVERT(varchar(40),@PeakSqlCpuPercent),'UNKNOWN'),
               '%, average SQL CPU was ',
               COALESCE(CONVERT(varchar(40),@AvgSqlCpuPercent),'UNKNOWN'),
               '%, peak other CPU was ',
               COALESCE(CONVERT(varchar(40),@PeakOtherCpuPercent),'UNKNOWN'),
               '%, lowest system idle was ',
               COALESCE(CONVERT(varchar(40),@LowestSystemIdlePercent),'UNKNOWN'),
               '%, peak runnable tasks were ',
               COALESCE(CONVERT(varchar(40),@PeakRunnableTasks),'UNKNOWN'),
               ', lowest Buffer Cache Hit Ratio was ',
               COALESCE(CONVERT(varchar(40),@LowestBufferCacheHitRatio),'UNKNOWN'),
               '%, lowest PLE was ',
               COALESCE(CONVERT(varchar(40),@LowestPLESeconds),'UNKNOWN'),
               ' seconds, and lowest available physical memory was ',
               COALESCE(CONVERT(varchar(40),@LowestAvailablePhysicalMemoryMB),'UNKNOWN'),
               ' MB. Peak pending memory grants were ',
               COALESCE(CONVERT(varchar(40),@PeakMemoryGrantsPending),'UNKNOWN'),
               '.')
        END;

    SET @WhyWeBelieveThis =
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
            THEN CONCAT(
                 'Final-cause ranking contains a PRIMARY ',
                 @PrimaryConfidence,
                 '-confidence result supported by ',
                 COALESCE(CONVERT(varchar(20),@EvidenceCount),'UNKNOWN'),
                 ' evidence item(s). Primary evidence: ',
                 COALESCE(@PrimaryEvidence,N'Not supplied'),
                 '.')
          ELSE CONCAT(
               'Final-cause ranking contains no PRIMARY MEDIUM/HIGH-confidence cause. ',
               'The utility therefore reports the observed workload and execution-plan evidence without manufacturing causal attribution. ',
               CASE WHEN @ServerSamples > 0
                         AND ISNULL(@PeakSqlCpuPercent,0) < 80
                         AND ISNULL(@PeakRunnableTasks,0) = 0
                         AND ISNULL(@PeakMemoryGrantsPending,0) = 0
                    THEN 'The persisted server-health samples also do not independently establish CPU, scheduler, or memory-grant pressure. '
                    ELSE '' END,
               'Observation is not causation.')
        END;

    SET @RecommendedAction =
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
            THEN COALESCE(
                 @PrimaryAction,
                 N'Review the supported primary cause, affected workload, business impact, and rollback path before remediation.')
          ELSE CONCAT(
               'Correlate the reported user or application action with the captured SQL batch, parameter values, host, login, session, and exact execution time. ',
               CASE WHEN @RunLargeScans > 0
                    THEN 'Confirm whether the business request genuinely required the observed data volume before considering indexing changes. '
                    ELSE '' END,
               CASE WHEN @RunImplicitConversions > 0
                    THEN 'Review implicit conversions only where they affect predicates, joins, seeks, cardinality, or measurable cost. '
                    ELSE '' END,
               CASE WHEN @RunStatisticsRisk = 0
                    THEN 'Do not update statistics solely because sampling was low when runtime estimates are accurate. '
                    ELSE '' END,
               'If user impact recurs while SQL Server evidence remains healthy, correlate application, network, service, and HA evidence from the same incident window.')
        END;

    SET @DoNotChangeYet =
        CASE
          WHEN @PrimaryCauseCategory IS NULL
            THEN 'Do not add an index, update statistics, change MAXDOP, change server memory, force a plan, kill sessions, or make another server-wide SQL configuration change solely from this capture.'
          ELSE 'Do not apply remediation until the attributed workload, business impact, change scope, and rollback path are confirmed.'
        END;

    SET @ExecutiveSummary =
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
            THEN CONCAT(
                 'The RCA engine identified ',
                 @PrimaryCauseDisplay,
                 ' as the supported primary cause with ',
                 @PrimaryConfidence,
                 ' confidence.')
          ELSE CONCAT(
               'No defensible SQL Server root cause was confirmed from this capture. ',
               'The highest-impact workload was observed and measured, but the evidence does not support promoting that workload, its scan, its implicit-conversion observations, statistics sampling, or server-wide resource pressure to primary cause.')
        END;

    SET @FinalReport =
        CONCAT(
            'RCA VERDICT',CHAR(13),CHAR(10),
            @Verdict,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'EXECUTIVE SUMMARY',CHAR(13),CHAR(10),
            @ExecutiveSummary,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHAT WE OBSERVED',CHAR(13),CHAR(10),
            @ObservedWorkload,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHAT THE ACTUAL EXECUTION PLAN SHOWED',CHAR(13),CHAR(10),
            @PlanSummary,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'SERVER HEALTH DURING THE INCIDENT',CHAR(13),CHAR(10),
            @ServerHealthSummary,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHY WE BELIEVE THIS',CHAR(13),CHAR(10),
            @WhyWeBelieveThis,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHAT SHOULD WE DO NEXT',CHAR(13),CHAR(10),
            @RecommendedAction,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'DO NOT CHANGE YET',CHAR(13),CHAR(10),
            @DoNotChangeYet);

    /*==========================================================================
      RESULT SET 1 - FINAL INCIDENT REPORT
    ==========================================================================*/
    SELECT
          ReportSection = '1 - FINAL INCIDENT REPORT'
        , CaptureRunID = @CaptureRunID
        , DatabaseName = COALESCE(@RequestedDatabaseName,@DatabaseName)
        , IncidentDescription = @IncidentDescription
        , IncidentStartUTC = @StartTimeUTC
        , IncidentEndUTC = @EndTimeUTC
        , CaptureStatus = @CaptureStatus
        , Verdict = @Verdict
        , Confidence = COALESCE(@PrimaryConfidence,'N/A')
        , PrimaryCause = COALESCE(@PrimaryCauseDisplay,N'No supported primary cause')
        , ExecutiveSummary = @ExecutiveSummary
        , WhatWeObserved = @ObservedWorkload
        , WhatThePlanShowed = @PlanSummary
        , ServerHealth = @ServerHealthSummary
        , WhyWeBelieveThis = @WhyWeBelieveThis
        , RecommendedNextStep = @RecommendedAction
        , DoNotChangeYet = @DoNotChangeYet
        , FullNarrative = @FinalReport;

    /*==========================================================================
      RESULT SET 2 - PRESENTATION SECTIONS
    ==========================================================================*/
    SELECT
          SectionOrder = 1
        , ReportSection = 'RCA VERDICT'
        , Narrative = CONVERT(nvarchar(max),@Verdict)

    UNION ALL

    SELECT
          2
        , 'EXECUTIVE SUMMARY'
        , @ExecutiveSummary

    UNION ALL

    SELECT
          3
        , 'WHAT WE OBSERVED'
        , @ObservedWorkload

    UNION ALL

    SELECT
          4
        , 'WHAT THE ACTUAL EXECUTION PLAN SHOWED'
        , @PlanSummary

    UNION ALL

    SELECT
          5
        , 'SERVER HEALTH DURING THE INCIDENT'
        , @ServerHealthSummary

    UNION ALL

    SELECT
          6
        , 'WHY WE BELIEVE THIS'
        , @WhyWeBelieveThis

    UNION ALL

    SELECT
          7
        , 'WHAT SHOULD WE DO NEXT'
        , @RecommendedAction

    UNION ALL

    SELECT
          8
        , 'DO NOT CHANGE YET'
        , @DoNotChangeYet
    ORDER BY SectionOrder;

    /*==========================================================================
      OPTIONAL TECHNICAL DRILL-DOWN
    ==========================================================================*/
    IF @IncludeTechnicalDetail = 1
    BEGIN
        EXEC dbo.usp_RCA_ExplainIncident
             @CaptureRunID = @CaptureRunID,
             @IncludeTechnicalDetail = 1;
    END;
END;
GO

/*==============================================================================
  2. FRIENDLY ALIASES
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ReportIncident
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_FinalIncidentReport
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_FinalReport
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_FinalIncidentReport
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO

/*==============================================================================
  3. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '1 - SCRIPT 44 DEPLOYMENT'
    , FinalIncidentReport =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_FinalIncidentReport',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReportIncidentAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ReportIncident',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalReportAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_FinalReport',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , Script43Dependency =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainIncident',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , SourceEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicPromoted = 'NO'
    , NewCaptureStarted = 'NO';
GO

/*==============================================================================
  4. CAPTURE 38 ACCEPTANCE TEST
==============================================================================*/
EXEC dbo.usp_RCA_FinalIncidentReport
     @CaptureRunID = 38,
     @IncludeTechnicalDetail = 0;
GO

/*==============================================================================
  5. SAFETY VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '2 - SCRIPT 44 SAFETY'
    , CaptureRunID = 38
    , PresentationLayerAdded = 'YES'
    , SourceXEEvidenceChanged = 'NO'
    , ActualPlanXMLChanged = 'NO'
    , PlanOperatorsChanged = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicPromoted = 'NO'
    , NewCaptureStarted = 'NO'
    , DefaultResultSetCount = '2'
    , NextStep = 'Review the final presentation output. If accepted, use Capture 39 as the first fresh end-to-end validation incident.';
GO

/*==============================================================================
  NORMAL USE
  ----------

  Final incident report:
      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 38;

  Friendly alias:
      EXEC DBA.dbo.usp_RCA_ReportIncident
           @CaptureRunID = 38;

  Final report + full technical drill-down:
      EXEC DBA.dbo.usp_RCA_FinalIncidentReport
           @CaptureRunID = 38,
           @IncludeTechnicalDetail = 1;
==============================================================================*/
