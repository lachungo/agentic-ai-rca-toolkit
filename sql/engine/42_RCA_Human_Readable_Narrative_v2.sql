USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  42_RCA_Human_Readable_Narrative_v2.sql

  PURPOSE
  -------
  Create the human-readable RCA narrative layer using the VERIFIED RCA schema
  and the same evidence model already proven by Scripts 39-41.

  PRIMARY ENTRY POINT
  -------------------
      EXEC dbo.usp_RCA_HumanReadableNarrative @CaptureRunID = 38;

  DESIGN PRINCIPLES
  -----------------
  1. Observation is not causation.
  2. Root cause is only stated when vw_RCA_FinalCauseRanking contains a
     PRIMARY cause at MEDIUM or HIGH confidence.
  3. A large scan is described factually; it is not automatically blamed.
  4. Low statistics sampling is not called harmful without supported evidence.
  5. LOW implicit-conversion findings remain observations, not root cause.
  6. Actual execution-plan XML is preserved and exposed for SSMS drill-down.
  7. Script 42 is presentation only. It does not alter evidence or detectors.

  VERIFIED SOURCE OBJECTS
  -----------------------
      dbo.RCA_CaptureRun
      dbo.RCA_IncidentContext
      dbo.RCA_ExecutionEvidence
      dbo.RCA_PlanEvidence
      dbo.RCA_PlanOperator
      dbo.RCA_PlanFinding
      dbo.RCA_ServerSnapshot
      dbo.vw_RCA_FinalCauseRanking

  TEST FIXTURE
  ------------
      CaptureRunID 38
==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 51400,N'dbo.RCA_CaptureRun is missing.',1;

IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NULL
    THROW 51401,N'dbo.RCA_IncidentContext is missing.',1;

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    THROW 51402,N'dbo.RCA_ExecutionEvidence is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
    THROW 51403,N'dbo.RCA_PlanEvidence is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
    THROW 51404,N'dbo.RCA_PlanOperator is missing.',1;

IF OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
    THROW 51405,N'dbo.RCA_PlanFinding is missing.',1;

IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
    THROW 51406,N'dbo.RCA_ServerSnapshot is missing.',1;

IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    THROW 51407,N'dbo.vw_RCA_FinalCauseRanking is missing.',1;
GO

/*==============================================================================
  1. HUMAN-READABLE NARRATIVE PROCEDURE
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_HumanReadableNarrative
    @CaptureRunID bigint
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
        THROW 51410,N'Invalid CaptureRunID.',1;

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
    FROM dbo.RCA_IncidentContext
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY CreatedTimeUTC DESC;

    ---------------------------------------------------------------------------
    -- Supported primary root cause, if one exists
    ---------------------------------------------------------------------------
    DECLARE
          @PrimaryCauseCategory varchar(100)
        , @PrimaryCauseDisplay nvarchar(256)
        , @PrimaryConfidence varchar(20)
        , @PrimaryEvidence nvarchar(max)
        , @PrimaryAction nvarchar(max)
        , @PrimaryExecutionEvidenceID bigint
        , @ImpactedRequestCount int;

    SELECT TOP (1)
          @PrimaryCauseCategory=CauseCategory
        , @PrimaryCauseDisplay=CauseDisplayName
        , @PrimaryConfidence=Confidence
        , @PrimaryEvidence=PrimaryEvidence
        , @PrimaryAction=RecommendedAction
        , @PrimaryExecutionEvidenceID=ImpactedExecutionEvidenceID
        , @ImpactedRequestCount=ImpactedRequestCount
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseRole='PRIMARY'
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
        , @TotalRows bigint
        , @QueryHash varbinary(8)
        , @QueryPlanHash varbinary(8);

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
        , @QueryHash=e.QueryHash
        , @QueryPlanHash=e.QueryPlanHash
    FROM dbo.RCA_ExecutionEvidence e
    WHERE e.CaptureRunID=@CaptureRunID
    ORDER BY
          CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID THEN 0 ELSE 1 END
        , ISNULL(e.CPUms,0) DESC
        , ISNULL(e.DurationMs,0) DESC
        , ISNULL(e.LogicalReads,0) DESC
        , e.ExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- Best defensible actual-plan correlation
    ---------------------------------------------------------------------------
    DECLARE
          @PlanEvidenceID bigint
        , @PlanCorrelation varchar(60)
        , @PlanSource varchar(80)
        , @ActualExecutionPlanXML xml
        , @PlanEventTimeUTC datetime2(7);

    SELECT TOP (1)
          @PlanEvidenceID=p.PlanEvidenceID
        , @PlanEventTimeUTC=p.EventTimeUTC
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
    -- Actual-plan interpretation
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
        , @LargeScanFindings int=0
        , @ImplicitConversionFindings int=0
        , @CardinalityMismatchFindings int=0
        , @StatisticsRiskFindings int=0;

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
        ORDER BY
              COALESCE(ActualRowsRead,ActualRows) DESC
            , NodeID;

        SET @OutputVsRowsReadPercent=
            CASE
              WHEN @RowsRead>0 AND @RowsReturned IS NOT NULL
              THEN CONVERT(decimal(19,4),@RowsReturned*100.0/NULLIF(@RowsRead,0))
            END;

        SELECT
              @WorstNormalizedEstimateActualRatio=
                MAX
                (
                    CASE
                      WHEN EstimateActualRatio IS NULL OR EstimateActualRatio=0 THEN NULL
                      WHEN EstimateActualRatio>=1 THEN CONVERT(decimal(19,4),EstimateActualRatio)
                      ELSE CONVERT(decimal(19,4),1.0/EstimateActualRatio)
                    END
                )
            , @SpillOperatorCount=
                SUM(CASE WHEN HasSpillWarning=1 THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanOperator
        WHERE CaptureRunID=@CaptureRunID
          AND PlanEvidenceID=@PlanEvidenceID;

        SELECT
              @LargeScanFindings=SUM(CASE WHEN FindingType='LARGE_SCAN' THEN 1 ELSE 0 END)
            , @ImplicitConversionFindings=SUM(CASE WHEN FindingType='IMPLICIT_CONVERSION' THEN 1 ELSE 0 END)
            , @CardinalityMismatchFindings=SUM(CASE WHEN FindingType='CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
            , @StatisticsRiskFindings=SUM(CASE WHEN FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
          AND PlanEvidenceID=@PlanEvidenceID;
    END;

    SET @SpillOperatorCount=ISNULL(@SpillOperatorCount,0);
    SET @LargeScanFindings=ISNULL(@LargeScanFindings,0);
    SET @ImplicitConversionFindings=ISNULL(@ImplicitConversionFindings,0);
    SET @CardinalityMismatchFindings=ISNULL(@CardinalityMismatchFindings,0);
    SET @StatisticsRiskFindings=ISNULL(@StatisticsRiskFindings,0);

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
    -- Server-health evidence
    ---------------------------------------------------------------------------
    DECLARE
          @ServerSamples bigint=0
        , @FirstSampleUTC datetime2(7)
        , @LastSampleUTC datetime2(7)
        , @PeakSqlCpuPercent decimal(19,6)
        , @AvgSqlCpuPercent decimal(19,6)
        , @PeakOtherCpuPercent decimal(19,6)
        , @LowestSystemIdlePercent decimal(19,6)
        , @PeakRunnableTasks int
        , @LowestBufferCacheHitRatio decimal(19,6)
        , @AvgBufferCacheHitRatio decimal(19,6)
        , @LowestPLESeconds bigint
        , @LowestAvailablePhysicalMemoryMB decimal(19,2)
        , @PeakMemoryGrantsPending int
        , @PeakMemoryGrantsOutstanding int;

    SELECT
          @ServerSamples=COUNT_BIG(*)
        , @FirstSampleUTC=MIN(CaptureTimeUTC)
        , @LastSampleUTC=MAX(CaptureTimeUTC)
        , @PeakSqlCpuPercent=MAX(SqlCpuPercent)
        , @AvgSqlCpuPercent=CONVERT(decimal(19,6),AVG(SqlCpuPercent))
        , @PeakOtherCpuPercent=MAX(OtherCpuPercent)
        , @LowestSystemIdlePercent=MIN(SystemIdlePercent)
        , @PeakRunnableTasks=MAX(RunnableTasks)
        , @LowestBufferCacheHitRatio=MIN(BufferCacheHitRatio)
        , @AvgBufferCacheHitRatio=CONVERT(decimal(19,6),AVG(BufferCacheHitRatio))
        , @LowestPLESeconds=MIN(PageLifeExpectancySeconds)
        , @LowestAvailablePhysicalMemoryMB=MIN(AvailablePhysicalMemoryMB)
        , @PeakMemoryGrantsPending=MAX(MemoryGrantsPending)
        , @PeakMemoryGrantsOutstanding=MAX(MemoryGrantsOutstanding)
    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID=@CaptureRunID;

    ---------------------------------------------------------------------------
    -- Build narrative components
    ---------------------------------------------------------------------------
    DECLARE
          @Assessment varchar(40)
        , @WhatHappened nvarchar(max)
        , @WhoWhatSubmitted nvarchar(max)
        , @QueryNarrative nvarchar(max)
        , @PlanNarrative nvarchar(max)
        , @ServerNarrative nvarchar(max)
        , @EvidenceNarrative nvarchar(max)
        , @ConclusionNarrative nvarchar(max)
        , @CannotConclude nvarchar(max)
        , @RecommendedNextStep nvarchar(max)
        , @DoNotChangeYet nvarchar(max)
        , @ExecutiveNarrative nvarchar(max);

    SET @Assessment=
        CASE WHEN @PrimaryCauseCategory IS NULL
             THEN 'NO ROOT CAUSE CONFIRMED'
             ELSE 'ROOT CAUSE IDENTIFIED' END;

    SET @WhatHappened=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN CONCAT(
               'During Capture Run ',@CaptureRunID,
               ', the RCA engine identified ',@PrimaryCauseDisplay,
               ' as the supported primary cause with ',@PrimaryConfidence,
               ' confidence. ',
               COALESCE(@PrimaryEvidence,N''))
          ELSE CONCAT(
               'During Capture Run ',@CaptureRunID,
               CASE WHEN COALESCE(@RequestedDatabaseName,@DatabaseName) IS NOT NULL
                    THEN CONCAT(' for database ',COALESCE(@RequestedDatabaseName,@DatabaseName))
                    ELSE '' END,
               ', SQL Server evidence was captured for the reported incident window. ',
               'No PRIMARY root cause reached MEDIUM or HIGH confidence. ',
               CASE WHEN @ExecutionEvidenceID IS NOT NULL
                    THEN CONCAT(
                         'The highest-impact observed execution consumed ',
                         CONVERT(varchar(40),@CPUms),' ms CPU, ran for ',
                         CONVERT(varchar(40),@DurationMs),' ms, and performed ',
                         CONVERT(varchar(40),@LogicalReads),' logical reads. ')
                    ELSE 'No ranked execution evidence was available. ' END,
               'This workload is reported as observed activity, not automatically as the cause of the incident.')
        END;

    SET @WhoWhatSubmitted=
        CONCAT(
            CASE WHEN @HostName IS NOT NULL
                 THEN CONCAT('The observed workload originated from host ',@HostName,'. ')
                 ELSE '' END,
            CASE WHEN @ProgramName IS NOT NULL
                 THEN CONCAT('Client application: ',@ProgramName,'. ')
                 ELSE '' END,
            CASE WHEN @LoginName IS NOT NULL
                 THEN CONCAT('Login: ',@LoginName,'. ')
                 ELSE '' END,
            CASE WHEN @SessionID IS NOT NULL
                 THEN CONCAT('Session: ',@SessionID,'. ')
                 ELSE '' END,
            CASE WHEN @RequestedBy IS NOT NULL
                 THEN CONCAT('The RCA capture was requested by ',@RequestedBy,'. ')
                 ELSE '' END,
            CASE WHEN @StartedFromHost IS NOT NULL
                 THEN CONCAT('The investigation was started from ',@StartedFromHost,
                      CASE WHEN @StartedFromProgram IS NOT NULL
                           THEN CONCAT(' using ',@StartedFromProgram)
                           ELSE '' END,'.')
                 ELSE '' END);

    SET @QueryNarrative=
        CONCAT(
            CASE WHEN @ObjectName IS NOT NULL
                 THEN CONCAT('Captured object/procedure: ',@ObjectName,'. ')
                 ELSE '' END,
            CASE WHEN NULLIF(LTRIM(RTRIM(@SubmittedCommand)),N'') IS NOT NULL
                 THEN 'The submitted SQL batch was captured and is available in the detailed result set. '
                 ELSE 'Submitted SQL text was not available for the selected execution. ' END,
            CASE WHEN NULLIF(LTRIM(RTRIM(@ParameterText)),N'') IS NOT NULL
                 THEN CONCAT('Parameter evidence status: ',COALESCE(@ParameterStatus,'CAPTURED'),'. ')
                 ELSE CONCAT('Parameter evidence status: ',COALESCE(@ParameterStatus,'NOT CAPTURED'),'. ') END,
            'Observed execution metrics: ',
            COALESCE(CONVERT(varchar(40),@CPUms),'0'),' ms CPU, ',
            COALESCE(CONVERT(varchar(40),@DurationMs),'0'),' ms duration, ',
            COALESCE(CONVERT(varchar(40),@LogicalReads),'0'),' logical reads, ',
            COALESCE(CONVERT(varchar(40),@PhysicalReads),'0'),' physical reads, ',
            COALESCE(CONVERT(varchar(40),@Writes),'0'),' writes, and ',
            COALESCE(CONVERT(varchar(40),@TotalRows),'0'),' reported rows.');

    SET @PlanNarrative=
        CASE
          WHEN @PlanEvidenceID IS NULL
          THEN 'No defensibly correlated actual execution plan was available for the selected workload. No plan-level causal claim should be made.'
          ELSE CONCAT(
               'An actual execution plan was correlated using ',LOWER(@PlanCorrelation),'. ',
               CASE WHEN @AccessMethod IS NOT NULL
                    THEN CONCAT('The highest-row-read access operator was ',@AccessMethod,
                         CASE WHEN @PlanTableName IS NOT NULL THEN CONCAT(' against ',@PlanTableName) ELSE '' END,
                         CASE WHEN @PlanIndexName IS NOT NULL THEN CONCAT(' using ',@PlanIndexName) ELSE '' END,'. ')
                    ELSE '' END,
               CASE WHEN @RowsRead IS NOT NULL
                    THEN CONCAT('It read approximately ',CONVERT(varchar(40),CONVERT(decimal(28,0),@RowsRead)),' rows')
                    ELSE '' END,
               CASE WHEN @RowsReturned IS NOT NULL
                    THEN CONCAT(' and returned approximately ',CONVERT(varchar(40),CONVERT(decimal(28,0),@RowsReturned)),' rows')
                    ELSE '' END,
               CASE WHEN @OutputVsRowsReadPercent IS NOT NULL
                    THEN CONCAT(' (',CONVERT(varchar(40),@OutputVsRowsReadPercent),'% of rows read). ')
                    ELSE '. ' END,
               CASE
                 WHEN @OutputVsRowsReadPercent>=90
                 THEN 'Because most rows read were also returned, the large scan alone does not demonstrate inefficient row elimination or prove root cause. '
                 WHEN @LargeScanFindings>0
                 THEN 'The scan is an important observation, but requires predicate/selectivity and business-context review before being treated as causal. '
                 ELSE '' END,
               CASE WHEN @WorstNormalizedEstimateActualRatio IS NOT NULL
                    THEN CONCAT('Worst normalized estimate-to-actual ratio was ',
                         CONVERT(varchar(40),@WorstNormalizedEstimateActualRatio),'. ')
                    ELSE '' END,
               CASE WHEN @CardinalityMismatchFindings=0
                    THEN 'No supported cardinality-mismatch finding was present for the correlated plan. '
                    ELSE CONCAT(@CardinalityMismatchFindings,' cardinality-mismatch finding(s) were present. ') END,
               CASE WHEN @StatisticsRiskFindings=0
                    THEN 'Statistics were not supported as a harmful cause by the hardened detector. '
                    ELSE CONCAT(@StatisticsRiskFindings,' supported statistics-risk finding(s) were present. ') END,
               CASE WHEN @ImplicitConversionFindings>0
                    THEN CONCAT(@ImplicitConversionFindings,
                         ' operator-local implicit-conversion observation(s) were present; these observations are not automatically causal. ')
                    ELSE 'No operator-local implicit-conversion finding was present. ' END,
               CASE WHEN @SpillOperatorCount=0
                    THEN 'No spill warning was observed.'
                    ELSE CONCAT(@SpillOperatorCount,' spill-related operator(s) were observed.') END)
        END;

    SET @ServerNarrative=
        CASE
          WHEN @ServerSamples=0
          THEN 'No persisted server-health samples were available for this capture.'
          ELSE CONCAT(
               'The RCA repository contains ',@ServerSamples,' server-health sample(s) from ',
               CONVERT(varchar(33),@FirstSampleUTC,126),' through ',
               CONVERT(varchar(33),@LastSampleUTC,126),'. ',
               'Peak SQL CPU was ',COALESCE(CONVERT(varchar(40),@PeakSqlCpuPercent),'UNKNOWN'),
               '%, average SQL CPU was ',COALESCE(CONVERT(varchar(40),@AvgSqlCpuPercent),'UNKNOWN'),
               '%, peak other CPU was ',COALESCE(CONVERT(varchar(40),@PeakOtherCpuPercent),'UNKNOWN'),
               '%, and lowest system idle was ',COALESCE(CONVERT(varchar(40),@LowestSystemIdlePercent),'UNKNOWN'),'%. ',
               'Peak runnable tasks were ',COALESCE(CONVERT(varchar(40),@PeakRunnableTasks),'UNKNOWN'),'. ',
               'Lowest Buffer Cache Hit Ratio was ',COALESCE(CONVERT(varchar(40),@LowestBufferCacheHitRatio),'UNKNOWN'),
               '%, lowest PLE was ',COALESCE(CONVERT(varchar(40),@LowestPLESeconds),'UNKNOWN'),
               ' seconds, and lowest available physical memory was ',
               COALESCE(CONVERT(varchar(40),@LowestAvailablePhysicalMemoryMB),'UNKNOWN'),' MB. ',
               'Peak pending memory grants were ',COALESCE(CONVERT(varchar(40),@PeakMemoryGrantsPending),'UNKNOWN'),
               ' and peak outstanding memory grants were ',COALESCE(CONVERT(varchar(40),@PeakMemoryGrantsOutstanding),'UNKNOWN'),'. ',
               CASE
                 WHEN ISNULL(@PeakSqlCpuPercent,0)<80
                  AND ISNULL(@PeakRunnableTasks,0)=0
                  AND ISNULL(@PeakMemoryGrantsPending,0)=0
                 THEN 'These persisted samples do not independently establish CPU, scheduler, or memory-grant pressure as the incident root cause.'
                 ELSE 'One or more server-health pressure indicators were observed and should be correlated to workload timing before attribution.'
               END)
        END;

    SET @EvidenceNarrative=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN CONCAT(
               'The final-cause ranking contains a PRIMARY ',@PrimaryConfidence,
               '-confidence cause. Impacted request count: ',
               COALESCE(CONVERT(varchar(20),@ImpactedRequestCount),'UNKNOWN'),
               '. Primary evidence: ',COALESCE(@PrimaryEvidence,N'Not supplied'),'.')
          ELSE CONCAT(
               'No PRIMARY MEDIUM/HIGH-confidence cause was established. ',
               'Run-wide plan findings include ',@RunLargeScans,' large scan(s), ',
               @RunImplicitConversions,' implicit-conversion observation(s), ',
               @RunCardinalityMismatch,' cardinality-mismatch finding(s), and ',
               @RunStatisticsRisk,' statistics-risk finding(s). ',
               'The narrative therefore preserves observed evidence without manufacturing causation.')
        END;

    SET @ConclusionNarrative=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN CONCAT(
               'The supported RCA conclusion is ',@PrimaryCauseDisplay,
               ' with ',@PrimaryConfidence,' confidence. ',
               'Remediation should still be validated against the attributed workload and business impact.')
          ELSE CONCAT(
               'No defensible SQL Server root cause was confirmed from this capture. ',
               CASE WHEN @RunLargeScans>0
                    THEN 'Large scans were observed, but scan size alone does not prove causation. '
                    ELSE '' END,
               CASE WHEN @RunCardinalityMismatch=0
                    THEN 'The hardened plan evidence did not establish cardinality mismatch as a cause. '
                    ELSE '' END,
               CASE WHEN @RunStatisticsRisk=0
                    THEN 'The hardened plan evidence did not establish statistics quality as a cause. '
                    ELSE '' END,
               CASE WHEN @ServerSamples>0 AND ISNULL(@PeakSqlCpuPercent,0)<80
                    AND ISNULL(@PeakRunnableTasks,0)=0
                    THEN 'The persisted health samples also do not show obvious CPU/scheduler saturation. '
                    ELSE '' END,
               'The investigation should therefore continue at the workload/business/application correlation layer.')
        END;

    SET @CannotConclude=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN 'Do not assume every correlated workload or plan finding contributed equally. Only the supported primary/contributing evidence should drive remediation.'
          ELSE CONCAT(
               'The evidence does not justify claiming that the highest-resource query caused the user-reported slowdown merely because it was the largest captured SQL workload. ',
               'It does not justify adding an index simply because a scan was observed, updating statistics solely because of sampling percentage, changing MAXDOP, adding memory, killing sessions, or making another server-wide SQL configuration change without corroborating evidence.')
        END;

    SET @RecommendedNextStep=
        CASE
          WHEN @PrimaryCauseCategory IS NOT NULL
          THEN COALESCE(@PrimaryAction,
               N'Review the attributed primary cause, affected workload, and business impact before remediation.')
          ELSE CONCAT(
               'Correlate the reported user action or application request with the captured SQL batch, parameter values, host, login, session, and exact execution time. ',
               CASE WHEN @RunLargeScans>0
                    THEN 'Determine whether the requested business operation genuinely requires the observed data volume before considering indexing changes. '
                    ELSE '' END,
               CASE WHEN @RunImplicitConversions>0
                    THEN 'Review operator-local implicit conversions only where they affect predicates, joins, seeks, cardinality, or measurable cost. '
                    ELSE '' END,
               CASE WHEN @RunStatisticsRisk=0
                    THEN 'Do not update statistics solely because sampling was low when runtime estimates are accurate. '
                    ELSE '' END,
               'If the user impact recurs while SQL Server evidence remains healthy, correlate application/network/service evidence from the same incident window.')
        END;

    SET @DoNotChangeYet=
        CASE
          WHEN @PrimaryCauseCategory IS NULL
          THEN 'Do not make a server-wide SQL configuration change, force a plan, create an index, update statistics, add RAM, change MAXDOP, or kill sessions solely from this capture.'
          ELSE 'Do not apply remediation until the attributed workload, business impact, change scope, and rollback path are confirmed.'
        END;

    SET @ExecutiveNarrative=
        CONCAT(
            'INCIDENT SUMMARY',CHAR(13),CHAR(10),
            @WhatHappened,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHO / WHAT SUBMITTED IT',CHAR(13),CHAR(10),
            @WhoWhatSubmitted,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'QUERY / WORKLOAD',CHAR(13),CHAR(10),
            @QueryNarrative,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'ACTUAL EXECUTION PLAN',CHAR(13),CHAR(10),
            @PlanNarrative,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'SERVER HEALTH',CHAR(13),CHAR(10),
            @ServerNarrative,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHY WE BELIEVE THIS',CHAR(13),CHAR(10),
            @EvidenceNarrative,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'CONCLUSION',CHAR(13),CHAR(10),
            @ConclusionNarrative,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'WHAT WE CANNOT CONCLUDE',CHAR(13),CHAR(10),
            @CannotConclude,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'RECOMMENDED NEXT STEP',CHAR(13),CHAR(10),
            @RecommendedNextStep,CHAR(13),CHAR(10),CHAR(13),CHAR(10),

            'DO NOT CHANGE YET',CHAR(13),CHAR(10),
            @DoNotChangeYet);

    /*==========================================================================
      RESULT SET 1 - HUMAN-READABLE RCA
    ==========================================================================*/
    SELECT
          ReportSection='1 - HUMAN-READABLE RCA'
        , CaptureRunID=@CaptureRunID
        , DatabaseName=COALESCE(@RequestedDatabaseName,@DatabaseName)
        , Assessment=@Assessment
        , Confidence=COALESCE(@PrimaryConfidence,'N/A')
        , PrimaryCause=COALESCE(@PrimaryCauseDisplay,N'No supported primary cause')
        , IncidentDescription=@IncidentDescription
        , StartTimeUTC=@StartTimeUTC
        , EndTimeUTC=@EndTimeUTC
        , CaptureStatus=@CaptureStatus
        , ExecutiveNarrative=@ExecutiveNarrative;

    /*==========================================================================
      RESULT SET 2 - ROOT CAUSE ASSESSMENT
    ==========================================================================*/
    SELECT
          ReportSection='2 - ROOT CAUSE ASSESSMENT'
        , Assessment=@Assessment
        , PrimaryCause=COALESCE(@PrimaryCauseDisplay,N'No supported primary cause')
        , Confidence=COALESCE(@PrimaryConfidence,'N/A')
        , ImpactedRequestCount=@ImpactedRequestCount
        , Evidence=@EvidenceNarrative
        , Conclusion=@ConclusionNarrative;

    /*==========================================================================
      RESULT SET 3 - WHAT HAPPENED?
    ==========================================================================*/
    SELECT
          ReportSection='3 - WHAT HAPPENED?'
        , Narrative=@WhatHappened;

    /*==========================================================================
      RESULT SET 4 - WHO / WHAT SUBMITTED IT?
    ==========================================================================*/
    SELECT
          ReportSection='4 - WHO / WHAT SUBMITTED IT?'
        , Narrative=@WhoWhatSubmitted
        , HostName=@HostName
        , ProgramName=@ProgramName
        , LoginName=@LoginName
        , SessionID=@SessionID
        , RequestedBy=@RequestedBy
        , StartedFromHost=@StartedFromHost
        , StartedFromProgram=@StartedFromProgram;

    /*==========================================================================
      RESULT SET 5 - QUERY + PARAMETERS
    ==========================================================================*/
    SELECT
          ReportSection='5 - QUERY + PARAMETERS'
        , ExecutionEvidenceID=@ExecutionEvidenceID
        , EventTimeUTC=@EventTimeUTC
        , DatabaseName=@DatabaseName
        , ProcedureOrObject=@ObjectName
        , QueryText=@SubmittedCommand
        , CapturedParameters=@ParameterText
        , ParameterEvidenceStatus=@ParameterStatus
        , CPUms=@CPUms
        , DurationMs=@DurationMs
        , LogicalReads=@LogicalReads
        , PhysicalReads=@PhysicalReads
        , Writes=@Writes
        , TotalRows=@TotalRows
        , Narrative=@QueryNarrative;

    /*==========================================================================
      RESULT SET 6 - ACTUAL EXECUTION PLAN + HUMAN INTERPRETATION
    ==========================================================================*/
    SELECT
          ReportSection='6 - ACTUAL EXECUTION PLAN'
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
        , LargeScanFindings=@LargeScanFindings
        , ImplicitConversionFindings=@ImplicitConversionFindings
        , CardinalityMismatchFindings=@CardinalityMismatchFindings
        , StatisticsRiskFindings=@StatisticsRiskFindings
        , Narrative=@PlanNarrative
        , ActualExecutionPlanXML=@ActualExecutionPlanXML;

    /*==========================================================================
      RESULT SET 7 - SERVER HEALTH
    ==========================================================================*/
    SELECT
          ReportSection='7 - SERVER HEALTH'
        , ServerSamples=@ServerSamples
        , FirstSampleUTC=@FirstSampleUTC
        , LastSampleUTC=@LastSampleUTC
        , PeakSqlCpuPercent=@PeakSqlCpuPercent
        , AvgSqlCpuPercent=@AvgSqlCpuPercent
        , PeakOtherCpuPercent=@PeakOtherCpuPercent
        , LowestSystemIdlePercent=@LowestSystemIdlePercent
        , PeakRunnableTasks=@PeakRunnableTasks
        , LowestBufferCacheHitRatio=@LowestBufferCacheHitRatio
        , AvgBufferCacheHitRatio=@AvgBufferCacheHitRatio
        , LowestPLESeconds=@LowestPLESeconds
        , LowestAvailablePhysicalMemoryMB=@LowestAvailablePhysicalMemoryMB
        , PeakMemoryGrantsPending=@PeakMemoryGrantsPending
        , PeakMemoryGrantsOutstanding=@PeakMemoryGrantsOutstanding
        , Narrative=@ServerNarrative;

    /*==========================================================================
      RESULT SET 8 - WHAT CAN WE CONCLUDE?
    ==========================================================================*/
    SELECT
          ReportSection='8 - WHAT CAN WE CONCLUDE?'
        , Narrative=@ConclusionNarrative;

    /*==========================================================================
      RESULT SET 9 - WHAT CAN WE NOT CONCLUDE?
    ==========================================================================*/
    SELECT
          ReportSection='9 - WHAT CAN WE NOT CONCLUDE?'
        , Narrative=@CannotConclude;

    /*==========================================================================
      RESULT SET 10 - WHAT SHOULD WE DO NEXT?
    ==========================================================================*/
    SELECT
          ReportSection='10 - WHAT SHOULD WE DO NEXT?'
        , RecommendedNextStep=@RecommendedNextStep
        , DoNotChangeYet=@DoNotChangeYet;

    /*==========================================================================
      RESULT SET 11 - EVIDENCE / CONFIDENCE SNAPSHOT
    ==========================================================================*/
    SELECT
          ReportSection='11 - EVIDENCE / CONFIDENCE'
        , HighPlanFindings=@HighPlanFindings
        , MediumPlanFindings=@MediumPlanFindings
        , LowPlanFindings=@LowPlanFindings
        , LargeScanFindings=@RunLargeScans
        , ImplicitConversionFindings=@RunImplicitConversions
        , CardinalityMismatchFindings=@RunCardinalityMismatch
        , StatisticsRiskFindings=@RunStatisticsRisk
        , ActualPlanAvailable=CONVERT(bit,CASE WHEN @PlanEvidenceID IS NULL THEN 0 ELSE 1 END)
        , RootCauseConfirmed=CONVERT(bit,CASE WHEN @PrimaryCauseCategory IS NULL THEN 0 ELSE 1 END)
        , EvidenceIntegrity=
            CASE WHEN @PrimaryCauseCategory IS NULL
                 THEN 'No observation was promoted to primary root cause without supported MEDIUM/HIGH-confidence causal evidence.'
                 ELSE 'The narrative reflects the existing supported PRIMARY cause from final-cause ranking.' END;

    /*==========================================================================
      RESULT SET 12 - INCIDENT CONTEXT
    ==========================================================================*/
    SELECT
          ReportSection='12 - INCIDENT CONTEXT'
        , CaptureRunID=@CaptureRunID
        , RequestedDatabaseName=@RequestedDatabaseName
        , IncidentDescription=@IncidentDescription
        , RequestedBy=@RequestedBy
        , StartedFromHost=@StartedFromHost
        , StartedFromProgram=@StartedFromProgram
        , StartTimeUTC=@StartTimeUTC
        , EndTimeUTC=@EndTimeUTC
        , CaptureStatus=@CaptureStatus;

    /*==========================================================================
      RESULT SET 13 - SAFETY
    ==========================================================================*/
    SELECT
          ReportSection='13 - EVIDENCE SAFETY'
        , SourceXEEvidenceChanged='NO'
        , ActualPlanXMLChanged='NO'
        , PlanOperatorsChanged='NO'
        , FindingsRebuilt='NO'
        , DetectorThresholdsChanged='NO'
        , RootCauseDomainsChanged='NO'
        , RootCauseLogicPromoted='NO'
        , NewCaptureStarted='NO'
        , Interpretation='Script 42 v2 is a presentation/narrative layer only.';
END;
GO

/*==============================================================================
  2. FRIENDLY ALIAS
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_TellMeWhatHappened
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_HumanReadableNarrative
         @CaptureRunID=@CaptureRunID;
END;
GO

/*==============================================================================
  3. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection='1 - SCRIPT 42 v2 DEPLOYMENT'
    , HumanReadableNarrative=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_HumanReadableNarrative',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_TellMeWhatHappened',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , SourceEvidenceModified='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicPromoted='NO';
GO

/*==============================================================================
  4. CAPTURE 38 ACCEPTANCE TEST
==============================================================================*/
EXEC dbo.usp_RCA_HumanReadableNarrative
     @CaptureRunID=38;
GO

/*==============================================================================
  5. FINAL SAFETY CHECK
==============================================================================*/
SELECT
      ValidationSection='14 - SCRIPT 42 v2 SAFETY'
    , CaptureRunID=38
    , NarrativeLayerAdded=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_HumanReadableNarrative',N'P') IS NOT NULL
             THEN 'YES' ELSE 'NO' END
    , SourceXEEvidenceChanged='NO'
    , ActualPlanXMLChanged='NO'
    , PlanOperatorsChanged='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicPromoted='NO'
    , NewCaptureStarted='NO'
    , NextStep='Review the Capture 38 narrative. If accepted, integrate it into the full RCA user experience.';
GO

/*==============================================================================
  NORMAL USE
  ----------

  Human-readable narrative:
      EXEC DBA.dbo.usp_RCA_HumanReadableNarrative @CaptureRunID = 38;

  Friendly command:
      EXEC DBA.dbo.usp_RCA_TellMeWhatHappened @CaptureRunID = 38;
==============================================================================*/
