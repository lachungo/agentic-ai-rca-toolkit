USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
23_RCA_CPU_Scheduler_Intelligence_v1_1.sql

PURPOSE
-------
Refine the CPU / scheduler-pressure intelligence using proven Run 16 evidence.

RUN 16 PROVED
-------------
- Peak SQL CPU              = 37%
- Average SQL CPU           = 35.17%
- Peak runnable tasks       = 7
- Average runnable tasks    = 5.83
- High-runnable samples     = 22 of 23
- Memory grants pending     = 0

The workload therefore demonstrated sustained scheduler queue pressure even
though whole-instance SQL CPU never reached the existing saturation threshold.

PATCH GOALS
-----------
1. Allow persistent scheduler queue pressure to become PRIMARY / HIGH without
   falsely relabeling it as CPU saturation.
2. Attribute the pressure to live requests when completed execution evidence
   is unavailable.
3. Preserve existing detector evidence and ranking architecture.
4. Improve final human-readable output for CPU / scheduler incidents.
5. Regression-test previously validated RCA families.

NO COLLECTOR CHANGES.
NO XE CHANGES.
NO SAMPLER CHANGES.
NO TABLE REBUILD.
==============================================================================*/


/*==============================================================================
1. PATCH CPU / SCHEDULER EVIDENCE BUILDER
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildCPUSchedulerEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;

    /*--------------------------------------------------------------------------
      SERVER-LEVEL SIGNAL
    --------------------------------------------------------------------------*/
    DECLARE
          @ServerSampleCount int
        , @PeakSqlCpu decimal(9,2)
        , @AvgSqlCpu decimal(9,2)
        , @PeakOtherCpu decimal(9,2)
        , @AvgOtherCpu decimal(9,2)
        , @LowestIdle decimal(9,2)
        , @PeakRunnable int
        , @AvgRunnable decimal(19,2)
        , @HighRunnableSamples int
        , @HighSqlCpuSamples int
        , @SqlDominantSamples int
        , @PersistentRunnablePercent decimal(19,4);

    SELECT
          @ServerSampleCount = COUNT(*)
        , @PeakSqlCpu =
            MAX(CONVERT(decimal(9,2),SqlCpuPercent))
        , @AvgSqlCpu =
            AVG(CONVERT(decimal(9,2),SqlCpuPercent))
        , @PeakOtherCpu =
            MAX(CONVERT(decimal(9,2),OtherCpuPercent))
        , @AvgOtherCpu =
            AVG(CONVERT(decimal(9,2),OtherCpuPercent))
        , @LowestIdle =
            MIN(CONVERT(decimal(9,2),SystemIdlePercent))
        , @PeakRunnable =
            MAX(RunnableTasks)
        , @AvgRunnable =
            AVG(CONVERT(decimal(19,2),RunnableTasks))
        , @HighRunnableSamples =
            SUM(CASE WHEN ISNULL(RunnableTasks,0)>=4 THEN 1 ELSE 0 END)
        , @HighSqlCpuSamples =
            SUM(CASE WHEN ISNULL(SqlCpuPercent,0)>=80 THEN 1 ELSE 0 END)
        , @SqlDominantSamples =
            SUM
            (
                CASE
                    WHEN ISNULL(SqlCpuPercent,0)>=70
                     AND ISNULL(SqlCpuPercent,0)>ISNULL(OtherCpuPercent,0)
                    THEN 1 ELSE 0
                END
            )
    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID=@CaptureRunID;

    SET @PersistentRunnablePercent =
        CASE
            WHEN ISNULL(@ServerSampleCount,0)>0
            THEN CONVERT
                 (
                     decimal(19,4),
                     (CONVERT(decimal(19,4),ISNULL(@HighRunnableSamples,0))
                      / @ServerSampleCount) * 100.0
                 )
            ELSE 0
        END;


    /*--------------------------------------------------------------------------
      WORKLOAD ATTRIBUTION - FIRST CHOICE: COMPLETED EXECUTION EVIDENCE
    --------------------------------------------------------------------------*/
    DECLARE
          @ExecutionCount int = 0
        , @TopExecutionEvidenceID bigint = NULL
        , @TopSessionID int = NULL
        , @TopCPUms decimal(19,3) = NULL
        , @TotalCPUms decimal(19,3) = NULL
        , @CPUShare decimal(19,4) = NULL
        , @TopDurationMs decimal(19,3) = NULL
        , @TopLogicalReads bigint = NULL
        , @TopHost nvarchar(512) = NULL
        , @TopProgram nvarchar(512) = NULL
        , @TopLogin nvarchar(512) = NULL
        , @TopStatement nvarchar(max) = NULL
        , @AttributionSource varchar(40) = NULL;

    SELECT
          @ExecutionCount=COUNT(*)
        , @TotalCPUms=SUM(ISNULL(CPUms,0))
    FROM dbo.RCA_ExecutionEvidence
    WHERE CaptureRunID=@CaptureRunID
      AND ISNULL(CPUms,0)>0;

    SELECT TOP (1)
          @TopExecutionEvidenceID = ExecutionEvidenceID
        , @TopSessionID = SessionID
        , @TopCPUms = CPUms
        , @TopDurationMs = DurationMs
        , @TopLogicalReads = LogicalReads
        , @TopHost = HostName
        , @TopProgram = ProgramName
        , @TopLogin = LoginName
        , @TopStatement =
            COALESCE(NULLIF(SubmittedCommand,N''),NULLIF(ParameterText,N''))
    FROM dbo.RCA_ExecutionEvidence
    WHERE CaptureRunID=@CaptureRunID
      AND ISNULL(CPUms,0)>0
    ORDER BY
          CPUms DESC
        , DurationMs DESC
        , LogicalReads DESC;

    IF ISNULL(@ExecutionCount,0)>0
        SET @AttributionSource='EXECUTION_EVIDENCE';


    /*--------------------------------------------------------------------------
      WORKLOAD ATTRIBUTION FALLBACK:
      RCA_LiveRequestSnapshot stores cumulative request CPU at each observation.
      To avoid double-counting repeated samples, reduce to MAX(CPUms) per
      session, then rank sessions from those maxima.
    --------------------------------------------------------------------------*/
    IF ISNULL(@ExecutionCount,0)=0
    BEGIN
        ;WITH PerSession AS
        (
            SELECT
                  SessionID
                , MaxCPUms = MAX(ISNULL(CPUms,0))
                , MaxElapsedMs = MAX(ISNULL(ElapsedMs,0))
                , MaxLogicalReads = MAX(ISNULL(LogicalReads,0))
            FROM dbo.RCA_LiveRequestSnapshot
            WHERE CaptureRunID=@CaptureRunID
              AND ISNULL(CPUms,0)>0
            GROUP BY SessionID
        )
        SELECT
              @ExecutionCount = COUNT(*)
            , @TotalCPUms = SUM(CONVERT(decimal(19,3),MaxCPUms))
        FROM PerSession;

        ;WITH PerSession AS
        (
            SELECT
                  SessionID
                , MaxCPUms = MAX(ISNULL(CPUms,0))
                , MaxElapsedMs = MAX(ISNULL(ElapsedMs,0))
                , MaxLogicalReads = MAX(ISNULL(LogicalReads,0))
            FROM dbo.RCA_LiveRequestSnapshot
            WHERE CaptureRunID=@CaptureRunID
              AND ISNULL(CPUms,0)>0
            GROUP BY SessionID
        ),
        TopSession AS
        (
            SELECT TOP (1)
                  SessionID
                , MaxCPUms
                , MaxElapsedMs
                , MaxLogicalReads
            FROM PerSession
            ORDER BY
                  MaxCPUms DESC
                , MaxElapsedMs DESC
                , MaxLogicalReads DESC
        )
        SELECT
              @TopSessionID = t.SessionID
            , @TopCPUms = CONVERT(decimal(19,3),t.MaxCPUms)
            , @TopDurationMs = CONVERT(decimal(19,3),t.MaxElapsedMs)
            , @TopLogicalReads = t.MaxLogicalReads
        FROM TopSession AS t;

        SELECT TOP (1)
              @TopHost = s.HostName
            , @TopProgram = s.ProgramName
            , @TopLogin = s.LoginName
            , @TopStatement = s.RunningStatement
        FROM dbo.RCA_LiveRequestSnapshot AS s
        WHERE s.CaptureRunID=@CaptureRunID
          AND s.SessionID=@TopSessionID
        ORDER BY
              ISNULL(s.CPUms,0) DESC
            , s.CaptureTimeUTC DESC;

        IF ISNULL(@ExecutionCount,0)>0
            SET @AttributionSource='LIVE_REQUEST_SNAPSHOT';
    END;

    SET @CPUShare =
        CASE
            WHEN ISNULL(@TotalCPUms,0)>0
            THEN CONVERT(decimal(19,4),(@TopCPUms/@TotalCPUms)*100.0)
            ELSE NULL
        END;


    /*--------------------------------------------------------------------------
      CLASSIFICATION SIGNALS
    --------------------------------------------------------------------------*/
    DECLARE
          @SqlCpuSaturation bit
        , @SchedulerPressure bit
        , @PersistentSchedulerPressure bit
        , @RunawayDominance bit
        , @NonSqlDominance bit;

    SET @SqlCpuSaturation =
        CASE
            WHEN ISNULL(@PeakSqlCpu,0)>=90
              OR
                 (
                    ISNULL(@HighSqlCpuSamples,0)>=3
                    AND ISNULL(@AvgSqlCpu,0)>=70
                 )
            THEN 1 ELSE 0
        END;

    SET @SchedulerPressure =
        CASE
            WHEN ISNULL(@PeakRunnable,0)>=8
              OR ISNULL(@HighRunnableSamples,0)>=3
            THEN 1 ELSE 0
        END;

    /*--------------------------------------------------------------------------
      New v1.1 signal.

      Persistent scheduler pressure requires:
      - enough observations to avoid one-sample noise,
      - runnable >= 4 in at least half the captured server samples,
      - average runnable queue >= 2.

      Run 16:
      22 / 23 high-runnable samples = 95.65%
      AvgRunnableTasks = 5.83
    --------------------------------------------------------------------------*/
    SET @PersistentSchedulerPressure =
        CASE
            WHEN ISNULL(@ServerSampleCount,0)>=5
             AND ISNULL(@HighRunnableSamples,0)>=3
             AND ISNULL(@PersistentRunnablePercent,0)>=50.0
             AND ISNULL(@AvgRunnable,0)>=2.0
            THEN 1 ELSE 0
        END;

    SET @RunawayDominance =
        CASE
            WHEN ISNULL(@CPUShare,0)>=40
             AND ISNULL(@TopCPUms,0)>=5000
            THEN 1 ELSE 0
        END;

    SET @NonSqlDominance =
        CASE
            WHEN ISNULL(@PeakOtherCpu,0)>=80
             AND ISNULL(@PeakOtherCpu,0)>ISNULL(@PeakSqlCpu,0)
            THEN 1 ELSE 0
        END;


    /*--------------------------------------------------------------------------
      STRONGER DEDICATED UPSTREAM CAUSES
    --------------------------------------------------------------------------*/
    DECLARE @UpstreamCauseCategory varchar(80)=NULL;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_ParameterSensitivePlanEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='PARAMETER_SENSITIVE_PLAN_REUSE';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_StatisticsCardinalityEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='STATISTICS_CARDINALITY_REGRESSION';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_MemorySpillEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='MEMORY_GRANT_SPILL';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='BLOCKING_WAIT_CHAIN';


    DECLARE
          @Role varchar(20)
        , @Confidence varchar(20);

    SET @Role =
        CASE
            WHEN @NonSqlDominance=1
                THEN 'CONTRIBUTING'

            WHEN @UpstreamCauseCategory IS NOT NULL
                THEN 'CONTRIBUTING'

            WHEN @PersistentSchedulerPressure=1
                THEN 'PRIMARY'

            WHEN @SqlCpuSaturation=1
             AND (@SchedulerPressure=1 OR @RunawayDominance=1)
                THEN 'PRIMARY'

            ELSE 'CONTRIBUTING'
        END;

    SET @Confidence =
        CASE
            WHEN @PersistentSchedulerPressure=1
             AND @NonSqlDominance=0
                THEN 'HIGH'

            WHEN @SqlCpuSaturation=1
             AND (@SchedulerPressure=1 OR @RunawayDominance=1)
                THEN 'HIGH'

            WHEN @SqlCpuSaturation=1
              OR @SchedulerPressure=1
                THEN 'MEDIUM'

            ELSE 'LOW'
        END;


    /*--------------------------------------------------------------------------
      INSERT ONE CAPTURE-LEVEL CAUSAL CASE
    --------------------------------------------------------------------------*/
    IF
    (
        ISNULL(@SqlCpuSaturation,0)=1
        OR ISNULL(@SchedulerPressure,0)=1
        OR ISNULL(@RunawayDominance,0)=1
        OR ISNULL(@NonSqlDominance,0)=1
    )
    BEGIN
        INSERT dbo.RCA_CPUSchedulerEvidence
        (
              CaptureRunID
            , PrimaryExecutionEvidenceID
            , PrimarySessionID
            , PeakSqlCpuPercent
            , AvgSqlCpuPercent
            , PeakOtherCpuPercent
            , AvgOtherCpuPercent
            , LowestSystemIdlePercent
            , PeakRunnableTasks
            , AvgRunnableTasks
            , HighRunnableSampleCount
            , ServerSampleCount
            , HighSqlCpuSampleCount
            , SqlCpuDominantSampleCount
            , CapturedExecutionCount
            , TopExecutionCPUms
            , TotalCapturedCPUms
            , TopExecutionCPUSharePercent
            , TopExecutionDurationMs
            , TopExecutionLogicalReads
            , PrimaryHostName
            , PrimaryProgramName
            , PrimaryLoginName
            , PrimaryStatement
            , SchedulerPressure
            , SqlCpuSaturation
            , RunawayQueryDominance
            , NonSqlCpuDominance
            , UpstreamCauseCategory
            , RootCauseRole
            , Confidence
            , EvidenceSummary
            , RecommendedAction
        )
        VALUES
        (
              @CaptureRunID
            , @TopExecutionEvidenceID
            , @TopSessionID
            , @PeakSqlCpu
            , @AvgSqlCpu
            , @PeakOtherCpu
            , @AvgOtherCpu
            , @LowestIdle
            , @PeakRunnable
            , @AvgRunnable
            , ISNULL(@HighRunnableSamples,0)
            , ISNULL(@ServerSampleCount,0)
            , ISNULL(@HighSqlCpuSamples,0)
            , ISNULL(@SqlDominantSamples,0)
            , ISNULL(@ExecutionCount,0)
            , @TopCPUms
            , @TotalCPUms
            , @CPUShare
            , @TopDurationMs
            , @TopLogicalReads
            , @TopHost
            , @TopProgram
            , @TopLogin
            , @TopStatement
            , @SchedulerPressure
            , @SqlCpuSaturation
            , @RunawayDominance
            , @NonSqlDominance
            , @UpstreamCauseCategory
            , @Role
            , @Confidence
            , CONCAT
              (
                  N'Peak SQL CPU=',COALESCE(CONVERT(varchar(30),@PeakSqlCpu),'NULL'),
                  N'%; average SQL CPU=',COALESCE(CONVERT(varchar(30),@AvgSqlCpu),'NULL'),
                  N'%; peak other CPU=',COALESCE(CONVERT(varchar(30),@PeakOtherCpu),'NULL'),
                  N'%; lowest system idle=',COALESCE(CONVERT(varchar(30),@LowestIdle),'NULL'),
                  N'%. Peak runnable tasks=',COALESCE(CONVERT(varchar(30),@PeakRunnable),'NULL'),
                  N'; average runnable tasks=',COALESCE(CONVERT(varchar(30),@AvgRunnable),'NULL'),
                  N'; high-runnable samples=',ISNULL(@HighRunnableSamples,0),
                  N' of ',ISNULL(@ServerSampleCount,0),
                  N' (',COALESCE(CONVERT(varchar(30),@PersistentRunnablePercent),'NULL'),N'%). ',
                  N'Persistent scheduler pressure=',
                  CASE WHEN @PersistentSchedulerPressure=1 THEN 'YES' ELSE 'NO' END,
                  N'. Top workload attribution source=',
                  COALESCE(@AttributionSource,'NONE'),
                  N'; primary session=',
                  COALESCE(CONVERT(varchar(20),@TopSessionID),'NULL'),
                  N'; top CPU=',
                  COALESCE(CONVERT(varchar(30),@TopCPUms),'NULL'),
                  N' ms; top CPU share=',
                  COALESCE(CONVERT(varchar(30),@CPUShare),'NULL'),
                  N'%. SQL CPU saturation=',
                  CASE WHEN @SqlCpuSaturation=1 THEN 'YES' ELSE 'NO' END,
                  N'; scheduler pressure=',
                  CASE WHEN @SchedulerPressure=1 THEN 'YES' ELSE 'NO' END,
                  N'; runaway-query dominance=',
                  CASE WHEN @RunawayDominance=1 THEN 'YES' ELSE 'NO' END,
                  N'; non-SQL CPU dominance=',
                  CASE WHEN @NonSqlDominance=1 THEN 'YES' ELSE 'NO' END,
                  N'.'
              )
            , CASE
                WHEN @NonSqlDominance=1
                    THEN N'Correlate SQL timing with host-level processes because non-SQL CPU was the stronger CPU consumer.'

                WHEN @PersistentSchedulerPressure=1
                    THEN N'Investigate the sessions repeatedly consuming scheduler time during the pressure window. Review the top attributed request first, then examine workload concurrency, parallelism, affinity/NUMA balance, and query efficiency before changing server-wide CPU settings.'

                WHEN @RunawayDominance=1
                    THEN N'Review the top CPU-consuming execution first: validate plan shape, row estimates, logical reads, parameter values, parallelism, and application ownership; then re-test after the least invasive corrective change.'

                WHEN @SchedulerPressure=1
                    THEN N'Review runnable-task pressure by scheduler together with the top CPU consumers and parallel query activity; reduce the dominant workload source rather than treating scheduler queueing as an isolated symptom.'

                ELSE
                    N'Correlate server CPU samples with the highest CPU-consuming executions and confirm whether SQL Server remained the dominant host CPU consumer.'
              END
        );
    END;

    SELECT
          CaptureRunID=@CaptureRunID
        , CPUSchedulerCases=COUNT(*)
        , PrimaryCases=
            SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , HighConfidence=
            SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=
            SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
2. PATCH FINAL INCIDENT OUTPUT FOR CPU / SCHEDULER INCIDENTS
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowFinalIncidentOutput
      @CaptureRunID bigint
    , @IncludeTechnicalEvidence bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51180,N'Invalid CaptureRunID.',1;

    DECLARE
          @CauseCategory varchar(80)
        , @CauseDisplayName nvarchar(200)
        , @Confidence varchar(20)
        , @RootCauseRole varchar(20)
        , @PrimaryEvidence nvarchar(max)
        , @RecommendedAction nvarchar(4000)
        , @ImpactedRequestCount int
        , @HeadBlockerSessionID int
        , @BlockingDepth int
        , @MaxObservedWaitMs bigint
        , @DurationRatio decimal(19,4)
        , @CPURatio decimal(19,4)
        , @LogicalReadRatio decimal(19,4);

    SELECT TOP (1)
          @CauseCategory        = CauseCategory
        , @CauseDisplayName     = CauseDisplayName
        , @Confidence           = Confidence
        , @RootCauseRole        = RootCauseRole
        , @PrimaryEvidence      = PrimaryEvidence
        , @RecommendedAction    = RecommendedAction
        , @ImpactedRequestCount = ImpactedRequestCount
        , @HeadBlockerSessionID = HeadBlockerSessionID
        , @BlockingDepth        = BlockingDepth
        , @MaxObservedWaitMs    = MaxObservedWaitMs
        , @DurationRatio        = DurationRatio
        , @CPURatio             = CPURatio
        , @LogicalReadRatio     = LogicalReadRatio
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          RoleRank
        , ConfidenceRank
        , ImpactRank
        , EvidenceStrengthRank
        , CASE CauseCategory
              WHEN 'PARAMETER_SENSITIVE_PLAN_REUSE'     THEN 1
              WHEN 'STATISTICS_CARDINALITY_REGRESSION'  THEN 2
              WHEN 'MEMORY_GRANT_SPILL'                 THEN 3
              WHEN 'BLOCKING_WAIT_CHAIN'                THEN 4
              WHEN 'CPU_SCHEDULER_PRESSURE'             THEN 5
              ELSE 9
          END;

    DECLARE
          @TargetDatabase sysname
        , @CaptureReason nvarchar(1000)
        , @StartTimeUTC datetime2
        , @EndTimeUTC datetime2;

    SELECT
          @TargetDatabase = TargetDatabase
        , @CaptureReason   = CaptureReason
        , @StartTimeUTC    = StartTimeUTC
        , @EndTimeUTC      = EndTimeUTC
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    DECLARE
          @ExecutiveSummary nvarchar(max)
        , @CompetingCauseSummary nvarchar(max);

    SET @ExecutiveSummary =
        CASE
            WHEN @CauseCategory='BLOCKING_WAIT_CHAIN'
            THEN CONCAT
            (
                N'Application work was delayed by a blocking chain rooted at SQL session ',
                COALESCE(CONVERT(varchar(20),@HeadBlockerSessionID),'UNKNOWN'),
                N'. The resolved head blocker affected ',
                COALESCE(CONVERT(varchar(20),@ImpactedRequestCount),'0'),
                N' distinct request(s), reached a maximum blocking depth of ',
                COALESCE(CONVERT(varchar(20),@BlockingDepth),'UNKNOWN'),
                N', and the longest captured wait was approximately ',
                COALESCE(CONVERT(varchar(30),CONVERT(decimal(19,1),@MaxObservedWaitMs/1000.0)),'UNKNOWN'),
                N' seconds. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='PARAMETER_SENSITIVE_PLAN_REUSE'
            THEN CONCAT
            (
                N'Application work regressed because a reused execution plan was not well suited to the captured runtime parameter distribution. ',
                N'Captured duration ratio=',COALESCE(CONVERT(varchar(30),@DurationRatio),'UNKNOWN'),
                N'x; CPU ratio=',COALESCE(CONVERT(varchar(30),@CPURatio),'UNKNOWN'),
                N'x; logical-read ratio=',COALESCE(CONVERT(varchar(30),@LogicalReadRatio),'UNKNOWN'),
                N'x. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='STATISTICS_CARDINALITY_REGRESSION'
            THEN CONCAT
            (
                N'Application work regressed because estimate quality and statistics/cardinality evidence materially diverged from the observed runtime workload. ',
                N'Captured duration ratio=',COALESCE(CONVERT(varchar(30),@DurationRatio),'UNKNOWN'),
                N'x; CPU ratio=',COALESCE(CONVERT(varchar(30),@CPURatio),'UNKNOWN'),
                N'x; logical-read ratio=',COALESCE(CONVERT(varchar(30),@LogicalReadRatio),'UNKNOWN'),
                N'x. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='MEMORY_GRANT_SPILL'
            THEN CONCAT
            (
                N'Application work experienced material memory-grant/spill behavior. ',
                N'Captured duration ratio=',COALESCE(CONVERT(varchar(30),@DurationRatio),'UNKNOWN'),
                N'x. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='CPU_SCHEDULER_PRESSURE'
            THEN
            (
                SELECT TOP (1)
                    CONCAT
                    (
                        N'Application work experienced sustained SQL scheduler queue pressure. ',
                        N'Runnable tasks averaged ',
                        CONVERT(varchar(30),c.AvgRunnableTasks),
                        N' and peaked at ',
                        CONVERT(varchar(30),c.PeakRunnableTasks),
                        N'; ',
                        CONVERT(varchar(30),c.HighRunnableSampleCount),
                        N' of ',
                        CONVERT(varchar(30),c.ServerSampleCount),
                        N' server samples met the high-runnable threshold. ',
                        N'SQL CPU averaged ',
                        CONVERT(varchar(30),c.AvgSqlCpuPercent),
                        N'% and peaked at ',
                        CONVERT(varchar(30),c.PeakSqlCpuPercent),
                        N'%, so SQL CPU saturation=',
                        CASE WHEN c.SqlCpuSaturation=1 THEN N'YES' ELSE N'NO' END,
                        N'. Confidence=',c.Confidence,N'.'
                    )
                FROM dbo.RCA_CPUSchedulerEvidence AS c
                WHERE c.CaptureRunID=@CaptureRunID
                ORDER BY c.CPUSchedulerEvidenceID DESC
            )

            ELSE
                N'The RCA engine did not establish a dedicated high-confidence primary cause for this capture. Review ranked contributing evidence and technical details.'
        END;

    SELECT
        @CompetingCauseSummary =
        STUFF
        (
            (
                SELECT
                    N'; ' +
                    CONCAT
                    (
                        c.CauseDisplayName,
                        N' [',
                        c.RootCauseRole,
                        N'/',
                        c.Confidence,
                        N']'
                    )
                FROM dbo.vw_RCA_FinalCauseRanking AS c
                WHERE c.CaptureRunID=@CaptureRunID
                  AND c.CauseCategory<>@CauseCategory
                ORDER BY
                      c.RoleRank
                    , c.ConfidenceRank
                    , c.ImpactRank
                    , c.EvidenceStrengthRank
                FOR XML PATH(''),TYPE
            ).value('.','nvarchar(max)')
        ,1,2,N'');

    IF NULLIF(@CompetingCauseSummary,N'') IS NULL
        SET @CompetingCauseSummary =
            N'No stronger competing dedicated detector was established for this capture.';

    /* RESULT 1 */
    SELECT
          ReportSection         = '1 - EXECUTIVE INCIDENT SUMMARY'
        , CaptureRunID          = @CaptureRunID
        , TargetDatabase        = @TargetDatabase
        , CaptureReason         = @CaptureReason
        , StartTimeUTC          = @StartTimeUTC
        , EndTimeUTC            = @EndTimeUTC
        , PrimaryCauseCategory  = @CauseCategory
        , PrimaryCause          = @CauseDisplayName
        , RootCauseRole         = @RootCauseRole
        , Confidence            = @Confidence
        , ImpactedRequestCount  = @ImpactedRequestCount
        , HeadBlockerSessionID  = @HeadBlockerSessionID
        , MaxBlockingDepth      = @BlockingDepth
        , MaxObservedWaitMs     = @MaxObservedWaitMs
        , ExecutiveSummary      = @ExecutiveSummary
        , WhyWeBelieveIt        = @PrimaryEvidence
        , CompetingCauses       = @CompetingCauseSummary
        , RecommendedNextAction = @RecommendedAction;

    /* RESULT 2 */
    SELECT
          ReportSection='2 - RANKED CAUSES'
        , CauseRank =
            ROW_NUMBER() OVER
            (
                ORDER BY
                      RoleRank
                    , ConfidenceRank
                    , ImpactRank
                    , EvidenceStrengthRank
            )
        , CauseCategory
        , CauseDisplayName
        , RootCauseRole
        , Confidence
        , ImpactedExecutionEvidenceID
        , HeadBlockerSessionID
        , ImpactedRequestCount
        , BlockingDepth
        , MaxObservedWaitMs
        , DurationRatio
        , CPURatio
        , LogicalReadRatio
        , EvidenceCount
        , PrimaryEvidence
        , RecommendedAction
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          RoleRank
        , ConfidenceRank
        , ImpactRank
        , EvidenceStrengthRank;

    /* RESULT 3 */
    IF @CauseCategory='BLOCKING_WAIT_CHAIN'
    BEGIN
        SELECT
              ReportSection='3 - IMPACTED REQUESTS / BLOCKING CHAIN'
            , r.HeadBlockerSessionID
            , r.SessionID
            , r.RequestRole
            , r.ImmediateBlockerSessionID
            , r.BlockingDepth
            , r.WaitType
            , WaitSeconds =
                CONVERT(decimal(19,2),r.WaitDurationMs/1000.0)
            , r.SampleCount
            , r.FirstObservedUTC
            , r.LastObservedUTC
            , r.DatabaseName
            , r.HostName
            , r.ProgramName
            , r.LoginName
            , r.StatementText
            , r.RootCauseRole
            , r.Confidence
        FROM dbo.vw_RCA_FinalBlockingRequestRole AS r
        WHERE r.CaptureRunID=@CaptureRunID
        ORDER BY
              r.HeadBlockerSessionID
            , r.BlockingDepth
            , r.SessionID;
    END
    ELSE IF @CauseCategory='CPU_SCHEDULER_PRESSURE'
    BEGIN
        SELECT
              ReportSection='3 - CPU / SCHEDULER WORKLOAD ATTRIBUTION'
            , c.PrimarySessionID
            , c.PrimaryExecutionEvidenceID
            , c.PrimaryHostName
            , c.PrimaryProgramName
            , c.PrimaryLoginName
            , c.PrimaryStatement
            , c.TopExecutionCPUms
            , c.TotalCapturedCPUms
            , c.TopExecutionCPUSharePercent
            , c.TopExecutionDurationMs
            , c.TopExecutionLogicalReads
            , c.PeakSqlCpuPercent
            , c.AvgSqlCpuPercent
            , c.PeakOtherCpuPercent
            , c.AvgOtherCpuPercent
            , c.LowestSystemIdlePercent
            , c.PeakRunnableTasks
            , c.AvgRunnableTasks
            , c.HighRunnableSampleCount
            , c.ServerSampleCount
            , c.SchedulerPressure
            , c.SqlCpuSaturation
            , c.RunawayQueryDominance
            , c.NonSqlCpuDominance
            , c.RootCauseRole
            , c.Confidence
        FROM dbo.RCA_CPUSchedulerEvidence AS c
        WHERE c.CaptureRunID=@CaptureRunID
        ORDER BY c.CPUSchedulerEvidenceID DESC;
    END
    ELSE
    BEGIN
        SELECT TOP (10)
              ReportSection='3 - MOST IMPACTED EXECUTIONS'
            , e.ExecutionEvidenceID
            , e.EventTimeUTC
            , e.DatabaseName
            , e.SessionID
            , e.ObjectName
            , e.HostName
            , e.ProgramName
            , e.LoginName
            , DurationSeconds =
                CONVERT(decimal(19,2),e.DurationMs/1000.0)
            , CPUSeconds =
                CONVERT(decimal(19,2),e.CPUms/1000.0)
            , e.LogicalReads
            , e.PhysicalReads
            , e.Writes
            , e.TotalRows
            , e.ParameterText
            , e.SubmittedCommand
        FROM dbo.RCA_ExecutionEvidence AS e
        WHERE e.CaptureRunID=@CaptureRunID
        ORDER BY
              ISNULL(e.DurationMs,0) DESC
            , ISNULL(e.CPUms,0) DESC
            , ISNULL(e.LogicalReads,0) DESC;
    END

    /* RESULT 4 */
    SELECT
          ReportSection='4 - BLOCKING BLAST RADIUS'
        , *
    FROM dbo.vw_RCA_FinalBlockingBlastRadius
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          DistinctVictims DESC
        , MaxObservedWaitMs DESC;

    /* RESULT 5 */
    SELECT
          ReportSection='5 - BLOCKING REQUEST DETAIL'
        , b.BlockingEvidenceID
        , b.VictimSessionID
        , VictimRole =
            CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_BlockingEvidence AS child
                    WHERE child.CaptureRunID=b.CaptureRunID
                      AND child.HeadBlockerSessionID=b.HeadBlockerSessionID
                      AND child.ImmediateBlockerSessionID=b.VictimSessionID
                )
                THEN 'INTERMEDIATE BLOCKER / VICTIM'
                ELSE 'VICTIM'
            END
        , b.VictimExecutionEvidenceID
        , b.ImmediateBlockerSessionID
        , b.HeadBlockerSessionID
        , b.BlockingDepth
        , b.WaitType
        , b.WaitDurationMs
        , b.FirstObservedUTC
        , b.LastObservedUTC
        , b.SampleCount
        , b.VictimDatabaseName
        , b.VictimHostName
        , b.VictimProgramName
        , b.VictimLoginName
        , b.VictimStatement
        , b.HeadBlockerHostName
        , b.HeadBlockerProgramName
        , b.HeadBlockerLoginName
        , b.HeadBlockerStatement
        , b.RootCauseRole
        , b.Confidence
        , b.EvidenceSummary
    FROM dbo.RCA_BlockingEvidence AS b
    WHERE b.CaptureRunID=@CaptureRunID
    ORDER BY
          b.HeadBlockerSessionID
        , b.BlockingDepth
        , b.VictimSessionID;

    IF @IncludeTechnicalEvidence=1
    BEGIN
        SELECT
              ReportSection='6A - PARAMETER-SENSITIVE PLAN EVIDENCE'
            , *
        FROM dbo.RCA_ParameterSensitivePlanEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        SELECT
              ReportSection='6B - STATISTICS / CARDINALITY EVIDENCE'
            , *
        FROM dbo.RCA_StatisticsCardinalityEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        SELECT
              ReportSection='6C - MEMORY GRANT / SPILL EVIDENCE'
            , *
        FROM dbo.RCA_MemorySpillEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        SELECT
              ReportSection='6D - CPU / SCHEDULER EVIDENCE'
            , *
        FROM dbo.RCA_CPUSchedulerEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CPUSchedulerEvidenceID;

        SELECT
              ReportSection='6E - PLAN FINDINGS'
            , *
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY
              CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , ExecutionEvidenceID
            , PlanFindingID;

        SELECT
              ReportSection='6F - SERVER STATE'
            , *
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CaptureTimeUTC;
    END;
END;
GO


/*==============================================================================
3. INSTALL VALIDATION
==============================================================================*/

SELECT
      CPUDetectorV11 =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_BuildCPUSchedulerEvidence',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END
    , FinalOutputCPUIntegration =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_ShowFinalIncidentOutput',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END;
GO


/*==============================================================================
4. REBUILD RUN 16 USING THE NEW LOGIC
==============================================================================*/

EXEC dbo.usp_RCA_BuildCPUSchedulerEvidence
     @CaptureRunID=16;
GO

SELECT
      CPUSchedulerEvidenceID
    , CaptureRunID
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , PeakSqlCpuPercent
    , AvgSqlCpuPercent
    , PeakOtherCpuPercent
    , AvgOtherCpuPercent
    , LowestSystemIdlePercent
    , PeakRunnableTasks
    , AvgRunnableTasks
    , HighRunnableSampleCount
    , ServerSampleCount
    , CapturedExecutionCount
    , TopExecutionCPUms
    , TotalCapturedCPUms
    , TopExecutionCPUSharePercent
    , PrimaryHostName
    , PrimaryProgramName
    , PrimaryLoginName
    , PrimaryStatement
    , SchedulerPressure
    , SqlCpuSaturation
    , RunawayQueryDominance
    , NonSqlCpuDominance
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
FROM dbo.RCA_CPUSchedulerEvidence
WHERE CaptureRunID=16;
GO


/*==============================================================================
5. RUN 16 ACCEPTANCE TEST
==============================================================================*/

SELECT
      Run16_CPU_Scheduler =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_CPUSchedulerEvidence
                WHERE CaptureRunID=16
                  AND SchedulerPressure=1
                  AND RootCauseRole='PRIMARY'
                  AND Confidence='HIGH'
                  AND HighRunnableSampleCount>=3
                  AND ServerSampleCount>=5
                  AND AvgRunnableTasks>=2
                  AND NonSqlCpuDominance=0
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END
    , WorkloadAttribution =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_CPUSchedulerEvidence
                WHERE CaptureRunID=16
                  AND PrimarySessionID IS NOT NULL
                  AND PrimaryStatement IS NOT NULL
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END
    , CorrectlyNotCalledCPUSaturation =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM dbo.RCA_CPUSchedulerEvidence
                WHERE CaptureRunID=16
                  AND SqlCpuSaturation=0
            )
            THEN 'PASS'
            ELSE 'REVIEW'
        END;
GO


/*==============================================================================
6. FINAL CAUSE REGRESSION MATRIX
==============================================================================*/

;WITH TestRuns AS
(
    SELECT CaptureRunID=CONVERT(bigint,3),
           ExpectedCause=CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 16, 'CPU_SCHEDULER_PRESSURE'
),
Ranked AS
(
    SELECT
          t.CaptureRunID
        , t.ExpectedCause
        , c.CauseCategory
        , c.CauseDisplayName
        , c.RootCauseRole
        , c.Confidence
        , rn =
            ROW_NUMBER() OVER
            (
                PARTITION BY t.CaptureRunID
                ORDER BY
                      c.RoleRank
                    , c.ConfidenceRank
                    , c.ImpactRank
                    , c.EvidenceStrengthRank
            )
    FROM TestRuns AS t
    JOIN dbo.RCA_CaptureRun AS r
      ON r.CaptureRunID=t.CaptureRunID
    LEFT JOIN dbo.vw_RCA_FinalCauseRanking AS c
      ON c.CaptureRunID=t.CaptureRunID
)
SELECT
      CaptureRunID
    , ExpectedCause
    , DetectedTopCause=CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , ValidationResult=
        CASE
            WHEN CauseCategory=ExpectedCause THEN 'PASS'
            ELSE 'REVIEW'
        END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO


/*==============================================================================
7. FINAL RUN 16 REPORT
==============================================================================*/

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=16,
     @IncludeTechnicalEvidence=0;
GO
