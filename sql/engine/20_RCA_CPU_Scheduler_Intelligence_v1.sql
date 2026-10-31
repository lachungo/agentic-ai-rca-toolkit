USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
20_RCA_CPU_Scheduler_Intelligence_v1.sql

PURPOSE
-------
Add a dedicated CPU / scheduler-pressure detector to the existing RCA engine.

NO COLLECTOR CHANGES.
NO XE CHANGES.
NO SAMPLER CHANGES.

EXISTING INPUTS
---------------
dbo.RCA_ServerSnapshot
    SqlCpuPercent
    OtherCpuPercent
    SystemIdlePercent
    RunnableTasks
    MemoryGrantsPending
    ...

dbo.RCA_LiveRequestSnapshot
    SessionID
    CPUms
    ElapsedMs
    LogicalReads
    WaitType
    BlockingSessionID
    HostName
    ProgramName
    LoginName
    RunningStatement
    ...

dbo.RCA_ExecutionEvidence
    CPUms
    DurationMs
    LogicalReads
    HostName
    ProgramName
    LoginName
    SubmittedCommand
    ParameterText
    ...

GOAL
----
Distinguish:

1. SQL CPU saturation
2. Scheduler queue pressure
3. One/few runaway requests dominating captured CPU
4. Parallel-work amplification as a contributing factor
5. High host CPU where SQL Server is NOT the dominant consumer

The detector creates one causal case per capture run, not one case per sample.
==============================================================================*/


/*==============================================================================
1. EVIDENCE TABLE
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_CPUSchedulerEvidence
    (
          CPUSchedulerEvidenceID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_CPUSchedulerEvidence PRIMARY KEY
        , CaptureRunID bigint NOT NULL
        , PrimaryExecutionEvidenceID bigint NULL
        , PrimarySessionID int NULL

        , PeakSqlCpuPercent decimal(9,2) NULL
        , AvgSqlCpuPercent decimal(9,2) NULL
        , PeakOtherCpuPercent decimal(9,2) NULL
        , AvgOtherCpuPercent decimal(9,2) NULL
        , LowestSystemIdlePercent decimal(9,2) NULL

        , PeakRunnableTasks int NULL
        , AvgRunnableTasks decimal(19,2) NULL
        , HighRunnableSampleCount int NOT NULL

        , ServerSampleCount int NOT NULL
        , HighSqlCpuSampleCount int NOT NULL
        , SqlCpuDominantSampleCount int NOT NULL

        , CapturedExecutionCount int NOT NULL
        , TopExecutionCPUms decimal(19,3) NULL
        , TotalCapturedCPUms decimal(19,3) NULL
        , TopExecutionCPUSharePercent decimal(19,4) NULL
        , TopExecutionDurationMs decimal(19,3) NULL
        , TopExecutionLogicalReads bigint NULL

        , PrimaryHostName nvarchar(512) NULL
        , PrimaryProgramName nvarchar(512) NULL
        , PrimaryLoginName nvarchar(512) NULL
        , PrimaryStatement nvarchar(max) NULL

        , SchedulerPressure bit NOT NULL
        , SqlCpuSaturation bit NOT NULL
        , RunawayQueryDominance bit NOT NULL
        , NonSqlCpuDominance bit NOT NULL

        , UpstreamCauseCategory varchar(80) NULL
        , RootCauseRole varchar(20) NOT NULL
        , Confidence varchar(20) NOT NULL
        , EvidenceSummary nvarchar(max) NOT NULL
        , RecommendedAction nvarchar(max) NOT NULL
        , CreatedTimeUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_CPUSchedulerEvidence_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_CPUSchedulerEvidence_Run
        ON dbo.RCA_CPUSchedulerEvidence
        (
            CaptureRunID,
            RootCauseRole,
            Confidence
        );
END;
GO


/*==============================================================================
2. EVIDENCE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_CPUSchedulerEvidence
AS
SELECT
      e.CPUSchedulerEvidenceID
    , e.CaptureRunID
    , e.PrimaryExecutionEvidenceID
    , e.PrimarySessionID
    , e.PeakSqlCpuPercent
    , e.AvgSqlCpuPercent
    , e.PeakOtherCpuPercent
    , e.AvgOtherCpuPercent
    , e.LowestSystemIdlePercent
    , e.PeakRunnableTasks
    , e.AvgRunnableTasks
    , e.HighRunnableSampleCount
    , e.ServerSampleCount
    , e.HighSqlCpuSampleCount
    , e.SqlCpuDominantSampleCount
    , e.CapturedExecutionCount
    , e.TopExecutionCPUms
    , e.TotalCapturedCPUms
    , e.TopExecutionCPUSharePercent
    , e.TopExecutionDurationMs
    , e.TopExecutionLogicalReads
    , e.PrimaryHostName
    , e.PrimaryProgramName
    , e.PrimaryLoginName
    , e.PrimaryStatement
    , e.SchedulerPressure
    , e.SqlCpuSaturation
    , e.RunawayQueryDominance
    , e.NonSqlCpuDominance
    , e.UpstreamCauseCategory
    , e.RootCauseRole
    , e.Confidence
    , e.EvidenceSummary
    , e.RecommendedAction
    , e.CreatedTimeUTC
FROM dbo.RCA_CPUSchedulerEvidence AS e;
GO


/*==============================================================================
3. DETECTOR
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildCPUSchedulerEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;

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
        , @SqlDominantSamples int;

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


    DECLARE
          @ExecutionCount int
        , @TopExecutionEvidenceID bigint
        , @TopSessionID int
        , @TopCPUms decimal(19,3)
        , @TotalCPUms decimal(19,3)
        , @CPUShare decimal(19,4)
        , @TopDurationMs decimal(19,3)
        , @TopLogicalReads bigint
        , @TopHost nvarchar(512)
        , @TopProgram nvarchar(512)
        , @TopLogin nvarchar(512)
        , @TopStatement nvarchar(max);

    SELECT
        @ExecutionCount=COUNT(*),
        @TotalCPUms=SUM(ISNULL(CPUms,0))
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

    SET @CPUShare =
        CASE
            WHEN ISNULL(@TotalCPUms,0)>0
            THEN CONVERT(decimal(19,4),(@TopCPUms/@TotalCPUms)*100.0)
            ELSE NULL
        END;


    DECLARE
          @SqlCpuSaturation bit =
            CASE
                WHEN ISNULL(@PeakSqlCpu,0)>=90
                  OR
                     (
                        ISNULL(@HighSqlCpuSamples,0)>=3
                        AND ISNULL(@AvgSqlCpu,0)>=70
                     )
                THEN 1 ELSE 0
            END

        , @SchedulerPressure bit =
            CASE
                WHEN ISNULL(@PeakRunnable,0)>=8
                  OR ISNULL(@HighRunnableSamples,0)>=3
                THEN 1 ELSE 0
            END

        , @RunawayDominance bit =
            CASE
                WHEN ISNULL(@CPUShare,0)>=40
                 AND ISNULL(@TopCPUms,0)>=5000
                THEN 1 ELSE 0
            END

        , @NonSqlDominance bit =
            CASE
                WHEN ISNULL(@PeakOtherCpu,0)>=80
                 AND ISNULL(@PeakOtherCpu,0)>ISNULL(@PeakSqlCpu,0)
                THEN 1 ELSE 0
            END;


    /*--------------------------------------------------------------------------
      Dedicated upstream causes already proven by other detectors.
      CPU pressure should be CONTRIBUTING when one of these strongly explains
      why the expensive query behaved badly.
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
            WHEN @SqlCpuSaturation=1
             AND (@SchedulerPressure=1 OR @RunawayDominance=1)
                THEN 'PRIMARY'
            ELSE 'CONTRIBUTING'
        END;

    SET @Confidence =
        CASE
            WHEN @SqlCpuSaturation=1
             AND @SchedulerPressure=1
             AND @RunawayDominance=1
                THEN 'HIGH'
            WHEN @SqlCpuSaturation=1
             AND (@SchedulerPressure=1 OR @RunawayDominance=1)
                THEN 'HIGH'
            WHEN @SqlCpuSaturation=1
              OR @SchedulerPressure=1
                THEN 'MEDIUM'
            ELSE 'LOW'
        END;


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
                  N'; high-runnable samples=',ISNULL(@HighRunnableSamples,0),
                  N'. Top captured execution=',COALESCE(CONVERT(varchar(30),@TopExecutionEvidenceID),'NULL'),
                  N' consumed ',COALESCE(CONVERT(varchar(30),@TopCPUms),'NULL'),
                  N' ms CPU, representing ',
                  COALESCE(CONVERT(varchar(30),@CPUShare),'NULL'),
                  N'% of captured execution CPU. SQL CPU saturation=',
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
                    THEN N'Correlate SQL Server timing with host-level processes because non-SQL CPU was the stronger CPU consumer.'
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
4. FINAL-OUTPUT INTEGRATION
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseCandidates
AS

SELECT
      p.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Parameter-sensitive plan reuse')
    , RootCauseRole              = CONVERT(varchar(20),'PRIMARY')
    , Confidence                 = p.Confidence
    , CorrelationKey             = CONVERT(nvarchar(200),CONCAT(N'EXEC:',p.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= p.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = p.DurationRatio
    , CPURatio                   = p.CPURatio
    , LogicalReadRatio           = p.LogicalReadRatio
    , EvidenceCount              = p.SharedStatementPlanCount
    , PrimaryEvidence            = p.EvidenceSummary
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        N'Validate the distinct parameter distributions with measured plan alternatives and re-test the identical runtime parameter values.')
FROM dbo.RCA_ParameterSensitivePlanEvidence AS p

UNION ALL

SELECT
      s.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'STATISTICS_CARDINALITY_REGRESSION')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Statistics / cardinality regression')
    , RootCauseRole              = CONVERT(varchar(20),'PRIMARY')
    , Confidence                 = s.Confidence
    , CorrelationKey             = CONVERT(nvarchar(200),CONCAT(N'EXEC:',s.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= s.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = s.DurationRatio
    , CPURatio                   = s.CPURatio
    , LogicalReadRatio           = s.LogicalReadRatio
    , EvidenceCount              =
        s.CardinalityMismatchCount + s.StatisticsRiskCount + s.LargeScanCount
    , PrimaryEvidence            = s.EvidenceSummary
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        N'Review the statistics used by the affected operators, validate estimate-versus-actual row counts, and re-test after the least invasive corrective change.')
FROM dbo.RCA_StatisticsCardinalityEvidence AS s

UNION ALL

SELECT
      m.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'MEMORY_GRANT_SPILL')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Memory grant / spill')
    , RootCauseRole              = m.RootCauseRole
    , Confidence                 = m.Confidence
    , CorrelationKey             = CONVERT(nvarchar(200),CONCAT(N'EXEC:',m.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= m.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = m.DurationRatio
    , CPURatio                   = m.CPURatio
    , LogicalReadRatio           = m.LogicalReadRatio
    , EvidenceCount              = m.SpillOperatorCount
    , PrimaryEvidence            = m.EvidenceSummary
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        N'Review requested, granted, and used query memory together with spill operators; correct upstream estimate problems first when they are stronger causal evidence.')
FROM dbo.RCA_MemorySpillEvidence AS m

UNION ALL

SELECT
      b.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'BLOCKING_WAIT_CHAIN')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Blocking / wait-chain contention')
    , RootCauseRole              =
        CASE
            WHEN SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>0
            THEN CONVERT(varchar(20),'PRIMARY')
            ELSE CONVERT(varchar(20),'CONTRIBUTING')
        END
    , Confidence                 =
        CASE
            WHEN SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)>0
            THEN CONVERT(varchar(20),'HIGH')
            WHEN SUM(CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END)>0
            THEN CONVERT(varchar(20),'MEDIUM')
            ELSE CONVERT(varchar(20),'LOW')
        END
    , CorrelationKey             =
        CONVERT(nvarchar(200),CONCAT(N'HEAD_BLOCKER:',b.HeadBlockerSessionID))
    , ImpactedExecutionEvidenceID= CONVERT(bigint,NULL)
    , HeadBlockerSessionID       = b.HeadBlockerSessionID
    , ImpactedRequestCount       = COUNT(DISTINCT b.VictimSessionID)
    , BlockingDepth              = MAX(b.BlockingDepth)
    , MaxObservedWaitMs          = MAX(b.WaitDurationMs)
    , DurationRatio              = CONVERT(decimal(19,4),NULL)
    , CPURatio                   = CONVERT(decimal(19,4),NULL)
    , LogicalReadRatio           = CONVERT(decimal(19,4),NULL)
    , EvidenceCount              = SUM(b.SampleCount)
    , PrimaryEvidence            =
        CONVERT(nvarchar(max),
        CONCAT
        (
            N'Head blocker session ',b.HeadBlockerSessionID,
            N' affected ',COUNT(DISTINCT b.VictimSessionID),
            N' distinct request(s). Maximum blocking depth=',MAX(b.BlockingDepth),
            N'; maximum observed wait=',MAX(b.WaitDurationMs),
            N' ms; total sampler observations=',SUM(b.SampleCount),N'.'
        ))
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        CONCAT
        (
            N'Investigate head blocker session ',b.HeadBlockerSessionID,
            N', identify the transaction retaining the required locks, and map the blocker host/application/login back to the owning workload.'
        ))
FROM dbo.RCA_BlockingEvidence AS b
GROUP BY
      b.CaptureRunID
    , b.HeadBlockerSessionID

UNION ALL

SELECT
      c.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'CPU_SCHEDULER_PRESSURE')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'CPU / scheduler pressure')
    , c.RootCauseRole
    , c.Confidence
    , CorrelationKey             =
        CONVERT(nvarchar(200),CONCAT(N'EXEC:',c.PrimaryExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= c.PrimaryExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = CONVERT(decimal(19,4),NULL)
    , CPURatio                   = CONVERT(decimal(19,4),NULL)
    , LogicalReadRatio           = CONVERT(decimal(19,4),NULL)
    , EvidenceCount              =
        c.HighSqlCpuSampleCount + c.HighRunnableSampleCount
    , PrimaryEvidence            = c.EvidenceSummary
    , RecommendedAction          = CONVERT(nvarchar(4000),c.RecommendedAction)
FROM dbo.RCA_CPUSchedulerEvidence AS c;
GO


/*==============================================================================
5. INSTALLATION / REGRESSION VALIDATION
==============================================================================*/

SELECT
      CPUSchedulerEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerEvidenceView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CPUSchedulerEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildCPUSchedulerEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseIntegration =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO
