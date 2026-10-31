USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  43_RCA_Final_User_Experience_v1.sql

  PURPOSE
  -------
  Create the final DBA-facing RCA experience on top of the validated engine,
  Script 41 executive evidence wiring, and Script 42 human-readable narrative.

  PRIMARY ENTRY POINT
  -------------------
      EXEC dbo.usp_RCA_ExplainIncident @CaptureRunID = 38;

  OPTIONAL DETAIL MODE
  --------------------
      EXEC dbo.usp_RCA_ExplainIncident
           @CaptureRunID = 38,
           @IncludeTechnicalDetail = 1;

  USER EXPERIENCE
  ---------------
  The default output is intentionally compact and organized around five
  questions:

      1. EXECUTIVE VERDICT
      2. WHAT HAPPENED?
      3. WHY DO WE BELIEVE IT?
      4. WHAT SHOULD I DO?
      5. TECHNICAL EVIDENCE SUMMARY

  With @IncludeTechnicalDetail = 1, the procedure additionally returns:
      - query + parameters
      - actual execution plan XML
      - plan operator evidence
      - plan findings
      - server-health numbers
      - incident context
      - full Script 42 narrative

  DESIGN PRINCIPLES
  -----------------
  1. Observation is not causation.
  2. Existing final-cause ranking remains authoritative.
  3. Script 43 does NOT change detector thresholds.
  4. Script 43 does NOT modify evidence.
  5. Script 43 does NOT rebuild findings.
  6. Script 43 does NOT start a capture.
  7. Script 43 does NOT promote LOW observations to root cause.
  8. Actual plan XML remains available for Bhuvan / senior DBA drill-down.
==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.usp_RCA_HumanReadableNarrative',N'P') IS NULL
    THROW 51500,N'Script 43 requires dbo.usp_RCA_HumanReadableNarrative from Script 42 v2.',1;

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 51501,N'dbo.RCA_CaptureRun is missing.',1;

IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NULL
    THROW 51502,N'dbo.RCA_IncidentContext is missing.',1;

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    THROW 51503,N'dbo.RCA_ExecutionEvidence is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
    THROW 51504,N'dbo.RCA_PlanEvidence is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
    THROW 51505,N'dbo.RCA_PlanOperator is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
    THROW 51506,N'dbo.RCA_PlanFinding is missing.',1;

IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
    THROW 51507,N'dbo.RCA_ServerSnapshot is missing.',1;

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    THROW 51508,N'dbo.vw_RCA_FinalCauseRanking is missing.',1;
GO

/*==============================================================================
  1. FINAL USER-EXPERIENCE PROCEDURE
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainIncident
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
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51510,N'Invalid CaptureRunID.',1;

    ---------------------------------------------------------------------------
    -- Incident context
    ---------------------------------------------------------------------------
    DECLARE
          @RequestedDatabaseName sysname
        , @IncidentDescription nvarchar(4000)
        , @RequestedBy nvarchar(512)
        , @StartedFromHost nvarchar(512)
        , @StartedFromProgram nvarchar(1024)
        , @CreatedTimeUTC datetime2(7)
        , @StartTimeUTC datetime2(7)
        , @EndTimeUTC datetime2(7)
        , @CaptureStatus varchar(40);

    SELECT
          @StartTimeUTC=StartTimeUTC
        , @EndTimeUTC=EndTimeUTC
        , @CaptureStatus=CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SELECT TOP (1)
          @RequestedDatabaseName=RequestedDatabaseName
        , @IncidentDescription=IncidentDescription
        , @RequestedBy=RequestedBy
        , @StartedFromHost=StartedFromHost
        , @StartedFromProgram=StartedFromProgram
        , @CreatedTimeUTC=CreatedTimeUTC
    FROM dbo.RCA_IncidentContext
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY CreatedTimeUTC DESC;

    ---------------------------------------------------------------------------
    -- Supported primary root cause
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
          @PrimaryCauseCategory=CauseCategory
        , @PrimaryCauseDisplay=CauseDisplayName
        , @PrimaryConfidence=Confidence
        , @PrimaryEvidence=PrimaryEvidence
        , @PrimaryAction=RecommendedAction
        , @PrimaryExecutionEvidenceID=ImpactedExecutionEvidenceID
        , @ImpactedRequestCount=ImpactedRequestCount
        , @EvidenceCount=EvidenceCount
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseRole='PRIMARY'
      AND Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , EvidenceCount DESC
        , ImpactedRequestCount DESC;

    ---------------------------------------------------------------------------
    -- Highest-impact observed workload
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
          @ExecutionEvidenceID=e.ExecutionEvidenceID
        , @EventTimeUTC=e.EventTimeUTC
        , @DatabaseName=e.DatabaseName
        , @SessionID=e.SessionID
        , @ObjectName=e.ObjectName
        , @SubmittedCommand=e.SubmittedCommand
        , @ParameterText=e.ParameterText
        , @ParameterStatus=e.ParameterEvidenceStatus
        , @HostName=e.HostName
        , @ProgramName=e.ProgramName
        , @LoginName=e.LoginName
        , @CPUms=e.CPUms
        , @DurationMs=e.DurationMs
        , @LogicalReads=e.LogicalReads
        , @PhysicalReads=e.PhysicalReads
        , @Writes=e.Writes
        , @TotalRows=e.TotalRows
    FROM dbo.RCA_ExecutionEvidence e
    WHERE e.CaptureRunID=@CaptureRunID
    ORDER BY
          CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID THEN 0 ELSE 1 END
        , ISNULL(e.CPUms,0) DESC
        , ISNULL(e.DurationMs,0) DESC
        , ISNULL(e.LogicalReads,0) DESC
        , e.ExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- Best actual-plan correlation
    ---------------------------------------------------------------------------
    DECLARE
          @PlanEvidenceID bigint
        , @PlanCorrelation varchar(60)
        , @PlanSource varchar(80)
        , @ActualExecutionPlanXML xml;

    SELECT TOP (1)
          @PlanEvidenceID=p.PlanEvidenceID
        , @ActualExecutionPlanXML=p.ActualExecutionPlanXML
        , @PlanCorrelation=
            CASE
              WHEN p.LinkedExecutionEvidenceID=@ExecutionEvidenceID
                THEN 'DIRECT EXECUTION LINK'
              ELSE 'SESSION/TIME CORRELATION'
            END
        , @PlanSource=
            CASE
              WHEN p.LinkedExecutionEvidenceID=@ExecutionEvidenceID
                THEN 'ACTUAL_SHOWPLAN_XE_DIRECT_LINK'
              ELSE 'ACTUAL_SHOWPLAN_XE_STRICT_CORRELATION'
            END
    FROM dbo.RCA_PlanEvidence p
    WHERE p.CaptureRunID=@CaptureRunID
      AND p.ActualExecutionPlanXML IS NOT NULL
      AND
      (
          p.LinkedExecutionEvidenceID=@ExecutionEvidenceID
          OR
          (
              p.LinkedExecutionEvidenceID IS NULL
              AND p.SessionID=@SessionID
              AND ISNULL(p.DatabaseName,N'')=ISNULL(@DatabaseName,N'')
              AND NULLIF(LTRIM(RTRIM(p.SQLText)),N'')
                  =NULLIF(LTRIM(RTRIM(@SubmittedCommand)),N'')
              AND ABS(DATEDIFF_BIG(millisecond,p.EventTimeUTC,@EventTimeUTC))<=100
          )
      )
    ORDER BY
          CASE WHEN p.LinkedExecutionEvidenceID=@ExecutionEvidenceID THEN 0 ELSE 1 END
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
        , @SpillOperatorCount int=0
        , @PlanLargeScans int=0
        , @PlanImplicitConversions int=0
        , @PlanCardinalityMismatch int=0
        , @PlanStatisticsRisk int=0;

    IF @PlanEvidenceID IS NOT NULL
    BEGIN
        SELECT TOP (1)
              @AccessMethod=PhysicalOp
            , @PlanTableName=TableName
            , @PlanIndexName=IndexName
            , @RowsRead=CONVERT(decimal(28,4),ActualRowsRead)
            , @RowsReturned=CONVERT(decimal(28,4),ActualRows)
        FROM dbo.RCA_PlanOperator
        WHERE CaptureRunID=@CaptureRunID
          AND PlanEvidenceID=@PlanEvidenceID
          AND (PhysicalOp LIKE '%Scan%' OR PhysicalOp LIKE '%Seek%')
          AND COALESCE(ActualRowsRead,ActualRows) IS NOT NULL
        ORDER BY COALESCE(ActualRowsRead,ActualRows) DESC,NodeID;

        SET @OutputVsRowsReadPercent=
            CASE WHEN @RowsRead>0 AND @RowsReturned IS NOT NULL
                 THEN CONVERT(decimal(19,4),@RowsReturned*100.0/@RowsRead) END;

        SELECT
              @WorstNormalizedEstimateActualRatio=
                MAX(CASE
                      WHEN EstimateActualRatio IS NULL OR EstimateActualRatio=0 THEN NULL
                      WHEN EstimateActualRatio>=1 THEN CONVERT(decimal(19,4),EstimateActualRatio)
                      ELSE CONVERT(decimal(19,4),1.0/EstimateActualRatio)
                    END)
            , @SpillOperatorCount=
                SUM(CASE WHEN HasSpillWarning=1 THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanOperator
        WHERE CaptureRunID=@CaptureRunID
          AND PlanEvidenceID=@PlanEvidenceID;

        SELECT
              @PlanLargeScans=SUM(CASE WHEN FindingType='LARGE_SCAN' THEN 1 ELSE 0 END)
            , @PlanImplicitConversions=SUM(CASE WHEN FindingType='IMPLICIT_CONVERSION' THEN 1 ELSE 0 END)
            , @PlanCardinalityMismatch=SUM(CASE WHEN FindingType='CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
            , @PlanStatisticsRisk=SUM(CASE WHEN FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
          AND PlanEvidenceID=@PlanEvidenceID;
    END;

    SET @SpillOperatorCount=ISNULL(@SpillOperatorCount,0);
    SET @PlanLargeScans=ISNULL(@PlanLargeScans,0);
    SET @PlanImplicitConversions=ISNULL(@PlanImplicitConversions,0);
    SET @PlanCardinalityMismatch=ISNULL(@PlanCardinalityMismatch,0);
    SET @PlanStatisticsRisk=ISNULL(@PlanStatisticsRisk,0);

    ---------------------------------------------------------------------------
    -- Run-wide finding counts
    ---------------------------------------------------------------------------
    DECLARE
          @RunLargeScans int=0
        , @RunImplicitConversions int=0
        , @RunCardinalityMismatch int=0
        , @RunStatisticsRisk int=0
        , @HighPlanFindings int=0
        , @MediumPlanFindings int=0
        , @LowPlanFindings int=0;

    SELECT
          @RunLargeScans=SUM(CASE WHEN FindingType='LARGE_SCAN' THEN 1 ELSE 0 END)
        , @RunImplicitConversions=SUM(CASE WHEN FindingType='IMPLICIT_CONVERSION' THEN 1 ELSE 0 END)
        , @RunCardinalityMismatch=SUM(CASE WHEN FindingType='CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
        , @RunStatisticsRisk=SUM(CASE WHEN FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        , @HighPlanFindings=SUM(CASE WHEN Severity='HIGH' THEN 1 ELSE 0 END)
        , @MediumPlanFindings=SUM(CASE WHEN Severity='MEDIUM' THEN 1 ELSE 0 END)
        , @LowPlanFindings=SUM(CASE WHEN Severity='LOW' THEN 1 ELSE 0 END)
    FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID;

    SET @RunLargeScans=ISNULL(@RunLargeScans,0);
    SET @RunImplicitConversions=ISNULL(@RunImplicitConversions,0);
    SET @RunCardinalityMismatch=ISNULL(@RunCardinalityMismatch,0);
    SET @RunStatisticsRisk=ISNULL(@RunStatisticsRisk,0);
    SET @HighPlanFindings=ISNULL(@HighPlanFindings,0);
    SET @MediumPlanFindings=ISNULL(@MediumPlanFindings,0);
    SET @LowPlanFindings=ISNULL(@LowPlanFindings,0);

    ---------------------------------------------------------------------------
    -- Server health
    ---------------------------------------------------------------------------
    DECLARE
          @ServerSamples bigint=0
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
          @ServerSamples=COUNT_BIG(*)
        , @PeakSqlCpuPercent=MAX(SqlCpuPercent)
        , @AvgSqlCpuPercent=CONVERT(decimal(19,6),AVG(SqlCpuPercent))
        , @PeakOtherCpuPercent=MAX(OtherCpuPercent)
        , @LowestSystemIdlePercent=MIN(SystemIdlePercent)
        , @PeakRunnableTasks=MAX(RunnableTasks)
        , @LowestBufferCacheHitRatio=MIN(BufferCacheHitRatio)
        , @LowestPLESeconds=MIN(PageLifeExpectancySeconds)
        , @LowestAvailablePhysicalMemoryMB=MIN(AvailablePhysicalMemoryMB)
        , @PeakMemoryGrantsPending=MAX(MemoryGrantsPending)
        , @PeakMemoryGrantsOutstanding=MAX(MemoryGrantsOutstanding)
    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID=@CaptureRunID;

    ---------------------------------------------------------------------------
    -- Final UX language
    ---------------------------------------------------------------------------
    DECLARE
          @Verdict varchar(50)
        , @VerdictConfidence varchar(20)
        , @WhatHappened nvarchar(max)
        , @WhyBelieveIt nvarchar(max)
        , @WhatShouldIDo nvarchar(max)
        , @DoNotChangeYet nvarchar(max)
        , @TechnicalSummary nvarchar(max);

    SET @Verdict=
        CASE WHEN @PrimaryCauseCategory IS NULL
             THEN 'NO ROOT CAUSE CONFIRMED'
             ELSE 'ROOT CAUSE IDENTIFIED' END;

    SET @VerdictConfidence=COALESCE(@PrimaryConfidence,'N/A');

    SET @WhatHappened=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN CONCAT(
               'The RCA engine identified ',@PrimaryCauseDisplay,
               ' as the supported PRIMARY cause with ',@PrimaryConfidence,
               ' confidence. ',
               COALESCE(@PrimaryEvidence,N''))
          ELSE CONCAT(
               'SQL Server evidence was captured during the reported incident, but no PRIMARY cause reached MEDIUM or HIGH confidence. ',
               CASE WHEN @ExecutionEvidenceID IS NOT NULL
                    THEN CONCAT(
                         'The highest-impact observed execution used ',
                         CONVERT(varchar(40),@CPUms),' ms CPU, ran ',
                         CONVERT(varchar(40),@DurationMs),' ms, and performed ',
                         CONVERT(varchar(40),@LogicalReads),' logical reads. ')
                    ELSE '' END,
               'The workload is therefore reported as observed activity, not proven causation.')
        END;

    SET @WhyBelieveIt=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN CONCAT(
               'Existing final-cause ranking contains a PRIMARY ',
               @PrimaryConfidence,'-confidence result supported by ',
               COALESCE(CONVERT(varchar(20),@EvidenceCount),'UNKNOWN'),
               ' evidence item(s) and ',
               COALESCE(CONVERT(varchar(20),@ImpactedRequestCount),'UNKNOWN'),
               ' impacted request(s).')
          ELSE CONCAT(
               'No PRIMARY MEDIUM/HIGH-confidence cause exists in final-cause ranking. ',
               CASE WHEN @PlanEvidenceID IS NOT NULL
                    THEN CONCAT(
                         'An actual execution plan was captured. ',
                         CASE WHEN @AccessMethod IS NOT NULL
                              THEN CONCAT('The highest-row-read access method was ',@AccessMethod,'. ')
                              ELSE '' END,
                         CASE WHEN @RowsRead IS NOT NULL
                              THEN CONCAT('Rows read: ',CONVERT(varchar(40),CONVERT(decimal(28,0),@RowsRead)),
                                   '; rows returned: ',CONVERT(varchar(40),CONVERT(decimal(28,0),@RowsReturned)),
                                   '; output/read ratio: ',CONVERT(varchar(40),@OutputVsRowsReadPercent),'%. ')
                              ELSE '' END,
                         CASE WHEN @WorstNormalizedEstimateActualRatio IS NOT NULL
                              THEN CONCAT('Worst normalized estimate/actual ratio: ',
                                   CONVERT(varchar(40),@WorstNormalizedEstimateActualRatio),'. ')
                              ELSE '' END,
                         CASE WHEN @SpillOperatorCount=0 THEN 'No spill warning was observed. ' ELSE '' END)
                    ELSE 'No defensibly correlated actual plan was available. ' END,
               CASE WHEN @ServerSamples>0
                    THEN CONCAT(
                         'Server-health evidence showed peak SQL CPU ',
                         COALESCE(CONVERT(varchar(40),@PeakSqlCpuPercent),'UNKNOWN'),
                         '%, lowest system idle ',
                         COALESCE(CONVERT(varchar(40),@LowestSystemIdlePercent),'UNKNOWN'),
                         '%, peak runnable tasks ',
                         COALESCE(CONVERT(varchar(40),@PeakRunnableTasks),'UNKNOWN'),
                         ', and peak pending memory grants ',
                         COALESCE(CONVERT(varchar(40),@PeakMemoryGrantsPending),'UNKNOWN'),'. ')
                    ELSE '' END,
               'The utility therefore preserves the observation without manufacturing a causal conclusion.')
        END;

    SET @WhatShouldIDo=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN COALESCE(
               @PrimaryAction,
               N'Review the supported primary cause, attributed workload, business impact, and rollback path before remediation.')
          ELSE CONCAT(
               'Correlate the reported user action or application request with the captured SQL batch, parameters, host, login, session, and exact execution time. ',
               CASE WHEN @RunLargeScans>0
                    THEN 'Determine whether the observed data volume was expected for the business request before considering index changes. '
                    ELSE '' END,
               CASE WHEN @RunImplicitConversions>0
                    THEN 'Review implicit conversions only where they affect predicates, joins, seeks, cardinality, or measurable cost. '
                    ELSE '' END,
               CASE WHEN @RunStatisticsRisk=0
                    THEN 'Do not update statistics solely because sampling was low when runtime estimates are accurate. '
                    ELSE '' END,
               'If user impact recurs while SQL evidence remains healthy, correlate application, network, and service evidence from the same incident window.')
        END;

    SET @DoNotChangeYet=
        CASE
          WHEN @PrimaryCauseCategory IS NULL
          THEN 'Do not make a server-wide SQL configuration change, force a plan, add an index, update statistics, add RAM, change MAXDOP, or kill sessions solely from this capture.'
          ELSE 'Do not apply remediation until the attributed workload, business impact, scope, and rollback path are confirmed.'
        END;

    SET @TechnicalSummary=
        CONCAT(
            'Observed execution: ',
            COALESCE(CONVERT(varchar(30),@ExecutionEvidenceID),'NONE'),
            '; session ',
            COALESCE(CONVERT(varchar(20),@SessionID),'UNKNOWN'),
            '; host ',
            COALESCE(@HostName,N'UNKNOWN'),
            '; program ',
            COALESCE(@ProgramName,N'UNKNOWN'),
            '; login ',
            COALESCE(@LoginName,N'UNKNOWN'),
            '. Plan evidence: ',
            COALESCE(CONVERT(varchar(30),@PlanEvidenceID),'NONE'),
            '; correlation ',
            COALESCE(@PlanCorrelation,'NOT_AVAILABLE'),
            '. Run findings: ',
            CONVERT(varchar(20),@RunLargeScans),' large scan(s), ',
            CONVERT(varchar(20),@RunImplicitConversions),' implicit conversion(s), ',
            CONVERT(varchar(20),@RunCardinalityMismatch),' cardinality mismatch(es), ',
            CONVERT(varchar(20),@RunStatisticsRisk),' statistics risk(s).');

    /*==========================================================================
      RESULT SET 1 - EXECUTIVE VERDICT
    ==========================================================================*/
    SELECT
          ReportSection='1 - EXECUTIVE VERDICT'
        , CaptureRunID=@CaptureRunID
        , DatabaseName=COALESCE(@RequestedDatabaseName,@DatabaseName)
        , IncidentDescription=@IncidentDescription
        , CaptureStatus=@CaptureStatus
        , IncidentStartUTC=@StartTimeUTC
        , IncidentEndUTC=@EndTimeUTC
        , Verdict=@Verdict
        , Confidence=@VerdictConfidence
        , PrimaryCause=COALESCE(@PrimaryCauseDisplay,N'No supported primary cause')
        , ExecutiveAnswer=@WhatHappened;

    /*==========================================================================
      RESULT SET 2 - WHAT HAPPENED?
    ==========================================================================*/
    SELECT
          ReportSection='2 - WHAT HAPPENED?'
        , Answer=@WhatHappened
        , AttributionStatus=
            CASE WHEN @PrimaryCauseCategory IS NULL
                 THEN 'OBSERVED WORKLOAD - NOT PROVEN ROOT CAUSE'
                 ELSE 'SUPPORTED PRIMARY CAUSE' END
        , ExecutionEvidenceID=@ExecutionEvidenceID
        , EventTimeUTC=@EventTimeUTC
        , DatabaseName=@DatabaseName
        , SessionID=@SessionID
        , HostName=@HostName
        , ProgramName=@ProgramName
        , LoginName=@LoginName
        , CPUms=@CPUms
        , DurationMs=@DurationMs
        , LogicalReads=@LogicalReads
        , PhysicalReads=@PhysicalReads
        , Writes=@Writes
        , TotalRows=@TotalRows;

    /*==========================================================================
      RESULT SET 3 - WHY DO WE BELIEVE IT?
    ==========================================================================*/
    SELECT
          ReportSection='3 - WHY DO WE BELIEVE IT?'
        , Answer=@WhyBelieveIt
        , RootCauseConfirmed=CONVERT(bit,CASE WHEN @PrimaryCauseCategory IS NULL THEN 0 ELSE 1 END)
        , PrimaryConfidence=COALESCE(@PrimaryConfidence,'N/A')
        , PlanEvidenceAvailable=CONVERT(bit,CASE WHEN @PlanEvidenceID IS NULL THEN 0 ELSE 1 END)
        , PlanCorrelation=COALESCE(@PlanCorrelation,'NOT_AVAILABLE')
        , LargeScanFindings=@RunLargeScans
        , ImplicitConversionFindings=@RunImplicitConversions
        , CardinalityMismatchFindings=@RunCardinalityMismatch
        , StatisticsRiskFindings=@RunStatisticsRisk
        , ServerSamples=@ServerSamples;

    /*==========================================================================
      RESULT SET 4 - WHAT SHOULD I DO?
    ==========================================================================*/
    SELECT
          ReportSection='4 - WHAT SHOULD I DO?'
        , RecommendedAction=@WhatShouldIDo
        , DoNotChangeYet=@DoNotChangeYet
        , SafetyNote='Observation is not causation. Confirm the attributed workload and business impact before production change.';

    /*==========================================================================
      RESULT SET 5 - TECHNICAL EVIDENCE SUMMARY
    ==========================================================================*/
    SELECT
          ReportSection='5 - TECHNICAL EVIDENCE SUMMARY'
        , TechnicalSummary=@TechnicalSummary
        , ExecutionEvidenceID=@ExecutionEvidenceID
        , PlanEvidenceID=@PlanEvidenceID
        , PlanSource=COALESCE(@PlanSource,'NOT_AVAILABLE')
        , AccessMethod=@AccessMethod
        , TableName=@PlanTableName
        , IndexName=@PlanIndexName
        , RowsRead=@RowsRead
        , RowsReturned=@RowsReturned
        , OutputVsRowsReadPercent=@OutputVsRowsReadPercent
        , WorstNormalizedEstimateActualRatio=@WorstNormalizedEstimateActualRatio
        , SpillOperatorCount=@SpillOperatorCount
        , PeakSqlCpuPercent=@PeakSqlCpuPercent
        , AvgSqlCpuPercent=@AvgSqlCpuPercent
        , LowestSystemIdlePercent=@LowestSystemIdlePercent
        , PeakRunnableTasks=@PeakRunnableTasks
        , LowestBufferCacheHitRatio=@LowestBufferCacheHitRatio
        , LowestPLESeconds=@LowestPLESeconds
        , LowestAvailablePhysicalMemoryMB=@LowestAvailablePhysicalMemoryMB;

    /*==========================================================================
      OPTIONAL TECHNICAL DRILL-DOWN
    ==========================================================================*/
    IF @IncludeTechnicalDetail=1
    BEGIN
        -----------------------------------------------------------------------
        -- 6 - QUERY + PARAMETERS
        -----------------------------------------------------------------------
        SELECT
              ReportSection='6 - QUERY + PARAMETERS'
            , ExecutionEvidenceID=@ExecutionEvidenceID
            , DatabaseName=@DatabaseName
            , SessionID=@SessionID
            , ProcedureOrObject=@ObjectName
            , QueryText=@SubmittedCommand
            , CapturedParameters=@ParameterText
            , ParameterEvidenceStatus=@ParameterStatus
            , HostName=@HostName
            , ProgramName=@ProgramName
            , LoginName=@LoginName;

        -----------------------------------------------------------------------
        -- 7 - ACTUAL EXECUTION PLAN
        -----------------------------------------------------------------------
        SELECT
              ReportSection='7 - ACTUAL EXECUTION PLAN'
            , PlanEvidenceID=@PlanEvidenceID
            , PlanCorrelation=COALESCE(@PlanCorrelation,'NOT_AVAILABLE')
            , PlanSource=COALESCE(@PlanSource,'NOT_AVAILABLE')
            , AccessMethod=@AccessMethod
            , TableName=@PlanTableName
            , IndexName=@PlanIndexName
            , RowsRead=@RowsRead
            , RowsReturned=@RowsReturned
            , OutputVsRowsReadPercent=@OutputVsRowsReadPercent
            , WorstNormalizedEstimateActualRatio=@WorstNormalizedEstimateActualRatio
            , SpillOperatorCount=@SpillOperatorCount
            , ActualExecutionPlanXML=@ActualExecutionPlanXML;

        -----------------------------------------------------------------------
        -- 8 - PLAN OPERATORS
        -----------------------------------------------------------------------
        SELECT
              ReportSection='8 - PLAN OPERATORS'
            , po.PlanOperatorID
            , po.PlanEvidenceID
            , po.ExecutionEvidenceID
            , po.NodeID
            , po.PhysicalOp
            , po.LogicalOp
            , po.EstimateRows
            , po.ActualRows
            , po.ActualRowsRead
            , po.ActualExecutions
            , po.EstimatedSubtreeCost
            , po.Parallel
            , po.DatabaseName
            , po.SchemaName
            , po.TableName
            , po.IndexName
            , po.IndexKind
            , po.Storage
            , po.HasSpillWarning
            , po.HasImplicitConversion
            , po.EstimateActualRatio
        FROM dbo.RCA_PlanOperator po
        WHERE po.CaptureRunID=@CaptureRunID
          AND (@PlanEvidenceID IS NULL OR po.PlanEvidenceID=@PlanEvidenceID)
        ORDER BY po.PlanEvidenceID,po.NodeID;

        -----------------------------------------------------------------------
        -- 9 - PLAN FINDINGS
        -----------------------------------------------------------------------
        SELECT
              ReportSection='9 - PLAN FINDINGS'
            , pf.PlanFindingID
            , pf.PlanEvidenceID
            , pf.ExecutionEvidenceID
            , pf.Severity
            , pf.FindingType
            , pf.FindingText
            , pf.RecommendedAction
        FROM dbo.RCA_PlanFinding pf
        WHERE pf.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE pf.Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END
            , pf.FindingType
            , pf.PlanEvidenceID
            , pf.PlanFindingID;

        -----------------------------------------------------------------------
        -- 10 - SERVER HEALTH
        -----------------------------------------------------------------------
        SELECT
              ReportSection='10 - SERVER HEALTH'
            , CaptureTimeUTC
            , SqlCpuPercent
            , OtherCpuPercent
            , SystemIdlePercent
            , BufferCacheHitRatio
            , PageLifeExpectancySeconds
            , TotalServerMemoryMB
            , TargetServerMemoryMB
            , AvailablePhysicalMemoryMB
            , MemoryGrantsPending
            , MemoryGrantsOutstanding
            , RunnableTasks
            , ServerMaxDOP
            , CostThresholdForParallelism
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CaptureTimeUTC;

        -----------------------------------------------------------------------
        -- 11 - INCIDENT CONTEXT
        -----------------------------------------------------------------------
        SELECT
              ReportSection='11 - INCIDENT CONTEXT'
            , @CaptureRunID AS CaptureRunID
            , @RequestedDatabaseName AS RequestedDatabaseName
            , @IncidentDescription AS IncidentDescription
            , @RequestedBy AS RequestedBy
            , @StartedFromHost AS StartedFromHost
            , @StartedFromProgram AS StartedFromProgram
            , @StartTimeUTC AS StartTimeUTC
            , @EndTimeUTC AS EndTimeUTC
            , @CaptureStatus AS CaptureStatus;

        -----------------------------------------------------------------------
        -- 12+ - FULL HUMAN-READABLE NARRATIVE
        -----------------------------------------------------------------------
        EXEC dbo.usp_RCA_HumanReadableNarrative
             @CaptureRunID=@CaptureRunID;
    END;
END;
GO

/*==============================================================================
  2. FRIENDLY ALIASES
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_Explain
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_ExplainIncident
         @CaptureRunID=@CaptureRunID,
         @IncludeTechnicalDetail=@IncludeTechnicalDetail;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_DrillDown
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_ExplainIncident
         @CaptureRunID=@CaptureRunID,
         @IncludeTechnicalDetail=1;
END;
GO

/*==============================================================================
  3. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection='1 - SCRIPT 43 DEPLOYMENT'
    , ExplainIncident=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainIncident',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Explain',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , DrillDownAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DrillDown',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HumanNarrativeDependency=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_HumanReadableNarrative',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , SourceEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicPromoted='NO'
    , NewCaptureStarted='NO';
GO

/*==============================================================================
  4. DEFAULT END-USER ACCEPTANCE TEST
==============================================================================*/
EXEC dbo.usp_RCA_ExplainIncident
     @CaptureRunID=38,
     @IncludeTechnicalDetail=0;
GO

/*==============================================================================
  5. SAFETY
==============================================================================*/
SELECT
      ValidationSection='2 - SCRIPT 43 SAFETY'
    , CaptureRunID=38
    , SourceXEEvidenceChanged='NO'
    , ActualPlanXMLChanged='NO'
    , PlanOperatorsChanged='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicPromoted='NO'
    , NewCaptureStarted='NO'
    , DefaultResultSetCount='5'
    , NextStep='Review the five-result-set end-user experience. If accepted, use the technical-detail mode for architect/DBA drill-down.';
GO

/*==============================================================================
  NORMAL USE
  ----------

  DBA / incident responder:
      EXEC DBA.dbo.usp_RCA_ExplainIncident
           @CaptureRunID = 38;

  Same command, shorter alias:
      EXEC DBA.dbo.usp_RCA_Explain
           @CaptureRunID = 38;

  Senior DBA / architect / Bhuvan drill-down:
      EXEC DBA.dbo.usp_RCA_ExplainIncident
           @CaptureRunID = 38,
           @IncludeTechnicalDetail = 1;

  Or:
      EXEC DBA.dbo.usp_RCA_DrillDown
           @CaptureRunID = 38;
==============================================================================*/
