USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    28_RCA_Memory_BufferPool_Pressure_v1.sql

    PURPOSE
    -------
    Add SQL Server instance memory / buffer-pool pressure as a dedicated
    root-cause domain.

    NEW ROOT-CAUSE CATEGORY
    -----------------------
        INSTANCE_MEMORY_PRESSURE

    WHY THIS DOMAIN EXISTS
    ----------------------
    The existing MEMORY_GRANT_SPILL domain is query-level evidence.

    This new domain answers a different question:

        "Was the SQL Server instance itself under sustained memory pressure?"

    EXISTING INPUT
    --------------
        dbo.RCA_ServerSnapshot

    REQUIRED SERVER-SNAPSHOT SIGNALS
    --------------------------------
        BufferCacheHitRatio
        PageLifeExpectancySeconds
        TotalServerMemoryMB
        TargetServerMemoryMB
        AvailablePhysicalMemoryMB
        MemoryGrantsPending

    IMPORTANT
    ---------
    Buffer Cache Hit Ratio is captured and reported because it is operationally
    useful, but it is NEVER sufficient by itself to declare memory pressure.

    The detector requires corroborating evidence such as:
        - sustained pending memory grants
        - sustained low available physical memory
        - persistent SQL target-memory deficit
        - severe buffer-pool churn / PLE collapse

    SUBTYPES
    --------
        MEMORY_GRANT_QUEUE_PRESSURE
        OS_MEMORY_PRESSURE
        BUFFER_POOL_CHURN
        MEMORY_PRESSURE_MIXED
        MEMORY_HEALTHY

    CAUSAL RULE
    -----------
    A stronger query-level cause can make instance memory pressure CONTRIBUTING
    rather than PRIMARY.

    Example:
        bad estimate
          -> oversized/undersized grant
          -> spill
          -> memory pressure symptoms

        MEMORY_GRANT_SPILL       = PRIMARY
        INSTANCE_MEMORY_PRESSURE = CONTRIBUTING

    THIS SCRIPT
    -----------
      1. validates the existing server-snapshot contract
      2. creates memory-pressure evidence storage
      3. creates the detector
      4. integrates the new cause into final ranking candidates
      5. integrates it into dbo.usp_RCA_WhyWasItSlow
      6. regression-tests all validated root-cause domains

    NO EXISTING SAMPLER CHANGES.
    NO XE CHANGES.
==============================================================================*/


/*==============================================================================
    1. PRE-FLIGHT - EXISTING SERVER SNAPSHOT CONTRACT
==============================================================================*/

SELECT
      ServerSnapshotTable =
        CASE
            WHEN OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , BufferCacheHitRatio =
        CASE
            WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'BufferCacheHitRatio') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , PageLifeExpectancySeconds =
        CASE
            WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'PageLifeExpectancySeconds') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , TotalServerMemoryMB =
        CASE
            WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TotalServerMemoryMB') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , TargetServerMemoryMB =
        CASE
            WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TargetServerMemoryMB') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , AvailablePhysicalMemoryMB =
        CASE
            WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'AvailablePhysicalMemoryMB') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , MemoryGrantsPending =
        CASE
            WHEN COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'MemoryGrantsPending') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END;
GO

IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'BufferCacheHitRatio') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'PageLifeExpectancySeconds') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TotalServerMemoryMB') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'TargetServerMemoryMB') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'AvailablePhysicalMemoryMB') IS NULL
 OR COL_LENGTH(N'dbo.RCA_ServerSnapshot',N'MemoryGrantsPending') IS NULL
BEGIN
    THROW 51600,
          N'Memory-pressure deployment stopped: dbo.RCA_ServerSnapshot does not expose the required memory-health columns.',
          1;
END;
GO


/*==============================================================================
    2. MEMORY PRESSURE EVIDENCE TABLE
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_MemoryPressureEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_MemoryPressureEvidence
    (
          MemoryPressureEvidenceID          bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_MemoryPressureEvidence PRIMARY KEY

        , CaptureRunID                      bigint NOT NULL
        , PressureSubtype                   varchar(80) NOT NULL

        , SampleCount                       int NOT NULL
        , ObservationSeconds                decimal(19,2) NULL

        , PeakMemoryGrantsPending           int NOT NULL
        , GrantPressureSampleCount          int NOT NULL

        , MinAvailablePhysicalMemoryMB      decimal(19,2) NULL
        , AvgAvailablePhysicalMemoryMB      decimal(19,2) NULL
        , LowAvailableMemorySampleCount     int NOT NULL
        , SevereLowMemorySampleCount        int NOT NULL

        , MinBufferCacheHitRatio            decimal(19,4) NULL
        , AvgBufferCacheHitRatio            decimal(19,4) NULL
        , LowBufferCacheSampleCount         int NOT NULL

        , MinPLESeconds                     bigint NULL
        , AvgPLESeconds                     decimal(19,2) NULL
        , MaxPLESeconds                     bigint NULL
        , PLECollapsePercent                decimal(19,4) NULL
        , PLECollapsePressure               bit NOT NULL

        , MinTotalServerMemoryMB            decimal(19,2) NULL
        , AvgTotalServerMemoryMB            decimal(19,2) NULL
        , MaxTargetServerMemoryMB           decimal(19,2) NULL
        , MaxTargetMemoryDeficitMB          decimal(19,2) NULL
        , TargetDeficitSampleCount          int NOT NULL

        , GrantQueuePressure                bit NOT NULL
        , OSMemoryPressure                  bit NOT NULL
        , BufferPoolChurn                   bit NOT NULL

        , UpstreamCauseCategory             varchar(80) NULL

        , RootCauseRole                     varchar(20) NOT NULL
        , Confidence                        varchar(20) NOT NULL

        , EvidenceSummary                   nvarchar(max) NOT NULL
        , RecommendedAction                 nvarchar(max) NOT NULL

        , CreatedTimeUTC                    datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_MemoryPressureEvidence_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_MemoryPressureEvidence_Run
        ON dbo.RCA_MemoryPressureEvidence
        (
            CaptureRunID,
            RootCauseRole,
            Confidence
        );
END;
GO


/*==============================================================================
    3. MEMORY PRESSURE EVIDENCE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_MemoryPressureEvidence
AS
SELECT *
FROM dbo.RCA_MemoryPressureEvidence;
GO


/*==============================================================================
    4. MEMORY / BUFFER-POOL DETECTOR

    CONSERVATIVE SIGNALS
    --------------------
    Grant queue:
        MemoryGrantsPending > 0 for >= 3 samples

    Low physical memory:
        AvailablePhysicalMemoryMB <= 2048 for >= 3 samples

    Severe physical-memory pressure:
        AvailablePhysicalMemoryMB <= 1024 for >= 3 samples

    Target deficit:
        TargetServerMemoryMB - TotalServerMemoryMB >= 1024 MB
        for >= 3 samples

    Buffer cache:
        BufferCacheHitRatio < 95 for >= 3 samples
        SUPPORTING ONLY - never sufficient by itself.

    PLE collapse:
        Maximum PLE >= 600 seconds
        minimum PLE <= 50% of maximum
        decline >= 600 seconds

    PRIMARY classification requires a sustained strong signal.
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildMemoryPressureEvidence
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
        THROW 51601,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_MemoryPressureEvidence
    WHERE CaptureRunID=@CaptureRunID;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID=@CaptureRunID
    )
    BEGIN
        SELECT
              CaptureRunID=@CaptureRunID
            , MemoryPressureCases=0
            , PrimaryCases=0
            , HighConfidence=0
            , MediumConfidence=0
            , Message='No RCA_ServerSnapshot evidence exists for this capture.';
        RETURN;
    END;

    DECLARE
          @SampleCount int
        , @ObservationSeconds decimal(19,2)

        , @PeakMemoryGrantsPending int
        , @GrantPressureSampleCount int

        , @MinAvailablePhysicalMemoryMB decimal(19,2)
        , @AvgAvailablePhysicalMemoryMB decimal(19,2)
        , @LowAvailableMemorySampleCount int
        , @SevereLowMemorySampleCount int

        , @MinBufferCacheHitRatio decimal(19,4)
        , @AvgBufferCacheHitRatio decimal(19,4)
        , @LowBufferCacheSampleCount int

        , @MinPLESeconds bigint
        , @AvgPLESeconds decimal(19,2)
        , @MaxPLESeconds bigint
        , @PLECollapsePercent decimal(19,4)
        , @PLECollapsePressure bit=0

        , @MinTotalServerMemoryMB decimal(19,2)
        , @AvgTotalServerMemoryMB decimal(19,2)
        , @MaxTargetServerMemoryMB decimal(19,2)
        , @MaxTargetMemoryDeficitMB decimal(19,2)
        , @TargetDeficitSampleCount int

        , @GrantQueuePressure bit=0
        , @OSMemoryPressure bit=0
        , @BufferPoolChurn bit=0

        , @PressureSubtype varchar(80)
        , @UpstreamCauseCategory varchar(80)=NULL
        , @RootCauseRole varchar(20)
        , @Confidence varchar(20)

        , @EvidenceSummary nvarchar(max)
        , @RecommendedAction nvarchar(max);

    SELECT
          @SampleCount=COUNT(*)

        , @ObservationSeconds=
            CONVERT
            (
                decimal(19,2),
                DATEDIFF_BIG
                (
                    millisecond,
                    MIN(CaptureTimeUTC),
                    MAX(CaptureTimeUTC)
                ) / 1000.0
            )

        , @PeakMemoryGrantsPending=
            MAX(ISNULL(MemoryGrantsPending,0))

        , @GrantPressureSampleCount=
            SUM
            (
                CASE
                    WHEN ISNULL(MemoryGrantsPending,0) > 0
                        THEN 1
                    ELSE 0
                END
            )

        , @MinAvailablePhysicalMemoryMB=
            MIN(CONVERT(decimal(19,2),AvailablePhysicalMemoryMB))

        , @AvgAvailablePhysicalMemoryMB=
            AVG(CONVERT(decimal(19,2),AvailablePhysicalMemoryMB))

        , @LowAvailableMemorySampleCount=
            SUM
            (
                CASE
                    WHEN AvailablePhysicalMemoryMB <= 2048
                        THEN 1
                    ELSE 0
                END
            )

        , @SevereLowMemorySampleCount=
            SUM
            (
                CASE
                    WHEN AvailablePhysicalMemoryMB <= 1024
                        THEN 1
                    ELSE 0
                END
            )

        , @MinBufferCacheHitRatio=
            MIN(CONVERT(decimal(19,4),BufferCacheHitRatio))

        , @AvgBufferCacheHitRatio=
            AVG(CONVERT(decimal(19,4),BufferCacheHitRatio))

        , @LowBufferCacheSampleCount=
            SUM
            (
                CASE
                    WHEN BufferCacheHitRatio < 95
                        THEN 1
                    ELSE 0
                END
            )

        , @MinPLESeconds=
            MIN(CONVERT(bigint,PageLifeExpectancySeconds))

        , @AvgPLESeconds=
            AVG(CONVERT(decimal(19,2),PageLifeExpectancySeconds))

        , @MaxPLESeconds=
            MAX(CONVERT(bigint,PageLifeExpectancySeconds))

        , @MinTotalServerMemoryMB=
            MIN(CONVERT(decimal(19,2),TotalServerMemoryMB))

        , @AvgTotalServerMemoryMB=
            AVG(CONVERT(decimal(19,2),TotalServerMemoryMB))

        , @MaxTargetServerMemoryMB=
            MAX(CONVERT(decimal(19,2),TargetServerMemoryMB))

        , @MaxTargetMemoryDeficitMB=
            MAX
            (
                CONVERT
                (
                    decimal(19,2),
                    CASE
                        WHEN TargetServerMemoryMB > TotalServerMemoryMB
                            THEN TargetServerMemoryMB - TotalServerMemoryMB
                        ELSE 0
                    END
                )
            )

        , @TargetDeficitSampleCount=
            SUM
            (
                CASE
                    WHEN TargetServerMemoryMB - TotalServerMemoryMB >= 1024
                        THEN 1
                    ELSE 0
                END
            )

    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID=@CaptureRunID;

    SET @PLECollapsePercent=
        CONVERT
        (
            decimal(19,4),
            CASE
                WHEN ISNULL(@MaxPLESeconds,0) > 0
                THEN
                    ((@MaxPLESeconds - @MinPLESeconds) * 100.0)
                    / @MaxPLESeconds
            END
        );

    SET @PLECollapsePressure=
        CASE
            WHEN ISNULL(@MaxPLESeconds,0) >= 600
             AND ISNULL(@MinPLESeconds,0) <= (@MaxPLESeconds * 0.50)
             AND (@MaxPLESeconds - @MinPLESeconds) >= 600
                THEN 1
            ELSE 0
        END;

    SET @GrantQueuePressure=
        CASE
            WHEN @GrantPressureSampleCount >= 3
                THEN 1
            ELSE 0
        END;

    SET @OSMemoryPressure=
        CASE
            WHEN @SevereLowMemorySampleCount >= 3
                THEN 1

            WHEN @LowAvailableMemorySampleCount >= 3
             AND @TargetDeficitSampleCount >= 3
                THEN 1

            ELSE 0
        END;

    SET @BufferPoolChurn=
        CASE
            WHEN @PLECollapsePressure=1
             AND
             (
                 @LowBufferCacheSampleCount >= 3
                 OR @TargetDeficitSampleCount >= 3
                 OR @GrantPressureSampleCount >= 3
             )
                THEN 1
            ELSE 0
        END;

    /*--------------------------------------------------------------------------
      Stronger upstream causes.
    --------------------------------------------------------------------------*/

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
          AND Confidence IN ('HIGH','MEDIUM')
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

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CPUSchedulerEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='CPU_SCHEDULER_PRESSURE';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_TempDBEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
          AND PressureSubtype<>'TEMPDB_ACTIVITY_ONLY'
    )
        SET @UpstreamCauseCategory='TEMPDB_PRESSURE_CONTENTION';

    /*--------------------------------------------------------------------------
      Subtype.
    --------------------------------------------------------------------------*/

    SET @PressureSubtype=
        CASE
            WHEN @GrantQueuePressure=1
             AND @OSMemoryPressure=1
                THEN 'MEMORY_PRESSURE_MIXED'

            WHEN @GrantQueuePressure=1
                THEN 'MEMORY_GRANT_QUEUE_PRESSURE'

            WHEN @OSMemoryPressure=1
                THEN 'OS_MEMORY_PRESSURE'

            WHEN @BufferPoolChurn=1
                THEN 'BUFFER_POOL_CHURN'

            ELSE 'MEMORY_HEALTHY'
        END;

    SET @RootCauseRole=
        CASE
            WHEN @PressureSubtype='MEMORY_HEALTHY'
                THEN 'CONTRIBUTING'

            WHEN @UpstreamCauseCategory IS NOT NULL
                THEN 'CONTRIBUTING'

            ELSE 'PRIMARY'
        END;

    SET @Confidence=
        CASE
            WHEN @PressureSubtype='MEMORY_HEALTHY'
                THEN 'LOW'

            WHEN @GrantQueuePressure=1
             AND @GrantPressureSampleCount >= 5
             AND
             (
                 @OSMemoryPressure=1
                 OR @BufferPoolChurn=1
             )
                THEN 'HIGH'

            WHEN @OSMemoryPressure=1
             AND @SevereLowMemorySampleCount >= 5
                THEN 'HIGH'

            WHEN @BufferPoolChurn=1
             AND @PLECollapsePercent >= 75
                THEN 'HIGH'

            ELSE 'MEDIUM'
        END;

    SET @EvidenceSummary=
        CONCAT
        (
            'Memory subtype=',@PressureSubtype,
            '; samples=',@SampleCount,
            '; observation=',COALESCE(CONVERT(varchar(30),@ObservationSeconds),'NULL'),' sec',

            '; peak memory grants pending=',@PeakMemoryGrantsPending,
            '; grant-pressure samples=',@GrantPressureSampleCount,

            '; minimum available physical memory=',
            COALESCE(CONVERT(varchar(30),@MinAvailablePhysicalMemoryMB),'NULL'),' MB',
            '; average available physical memory=',
            COALESCE(CONVERT(varchar(30),@AvgAvailablePhysicalMemoryMB),'NULL'),' MB',
            '; low-memory samples=',@LowAvailableMemorySampleCount,
            '; severe-low-memory samples=',@SevereLowMemorySampleCount,

            '; minimum Buffer Cache Hit Ratio=',
            COALESCE(CONVERT(varchar(30),@MinBufferCacheHitRatio),'NULL'),'%',
            '; average Buffer Cache Hit Ratio=',
            COALESCE(CONVERT(varchar(30),@AvgBufferCacheHitRatio),'NULL'),'%',
            '; low-buffer-cache samples=',@LowBufferCacheSampleCount,

            '; minimum PLE=',COALESCE(CONVERT(varchar(30),@MinPLESeconds),'NULL'),' sec',
            '; average PLE=',COALESCE(CONVERT(varchar(30),@AvgPLESeconds),'NULL'),' sec',
            '; maximum PLE=',COALESCE(CONVERT(varchar(30),@MaxPLESeconds),'NULL'),' sec',
            '; PLE collapse=',COALESCE(CONVERT(varchar(30),@PLECollapsePercent),'NULL'),'%',
            '; PLE-collapse pressure=',CASE WHEN @PLECollapsePressure=1 THEN 'YES' ELSE 'NO' END,

            '; average total server memory=',
            COALESCE(CONVERT(varchar(30),@AvgTotalServerMemoryMB),'NULL'),' MB',
            '; maximum target server memory=',
            COALESCE(CONVERT(varchar(30),@MaxTargetServerMemoryMB),'NULL'),' MB',
            '; maximum target deficit=',
            COALESCE(CONVERT(varchar(30),@MaxTargetMemoryDeficitMB),'NULL'),' MB',
            '; target-deficit samples=',@TargetDeficitSampleCount,

            CASE
                WHEN @UpstreamCauseCategory IS NOT NULL
                    THEN CONCAT('; stronger upstream cause=',@UpstreamCauseCategory)
                ELSE ''
            END,
            '.'
        );

    SET @RecommendedAction=
        CASE @PressureSubtype

            WHEN 'MEMORY_PRESSURE_MIXED'
            THEN
                'Investigate sustained pending memory grants together with host memory availability and SQL Server target-versus-total memory. Identify the workloads requesting large grants before changing max server memory or adding RAM.'

            WHEN 'MEMORY_GRANT_QUEUE_PRESSURE'
            THEN
                'Identify queries waiting for execution memory and the workloads holding large grants. Review grant sizing, concurrency, cardinality estimates, and query plans before changing max server memory.'

            WHEN 'OS_MEMORY_PRESSURE'
            THEN
                'Investigate host-level physical-memory pressure and SQL Server memory configuration. Confirm whether another process is consuming memory, whether max server memory leaves sufficient OS headroom, and whether SQL Server is persistently below target.'

            WHEN 'BUFFER_POOL_CHURN'
            THEN
                'Investigate the workload causing rapid buffer-pool turnover. Correlate the PLE collapse and Buffer Cache Hit Ratio degradation with physical reads, large scans, index access patterns, and concurrent memory-intensive queries.'

            ELSE
                'Memory-health signals were evaluated and did not provide strong enough corroborating evidence to declare instance memory pressure. Do not change max server memory or add RAM solely from this capture.'
        END;

    INSERT dbo.RCA_MemoryPressureEvidence
    (
          CaptureRunID
        , PressureSubtype
        , SampleCount
        , ObservationSeconds
        , PeakMemoryGrantsPending
        , GrantPressureSampleCount
        , MinAvailablePhysicalMemoryMB
        , AvgAvailablePhysicalMemoryMB
        , LowAvailableMemorySampleCount
        , SevereLowMemorySampleCount
        , MinBufferCacheHitRatio
        , AvgBufferCacheHitRatio
        , LowBufferCacheSampleCount
        , MinPLESeconds
        , AvgPLESeconds
        , MaxPLESeconds
        , PLECollapsePercent
        , PLECollapsePressure
        , MinTotalServerMemoryMB
        , AvgTotalServerMemoryMB
        , MaxTargetServerMemoryMB
        , MaxTargetMemoryDeficitMB
        , TargetDeficitSampleCount
        , GrantQueuePressure
        , OSMemoryPressure
        , BufferPoolChurn
        , UpstreamCauseCategory
        , RootCauseRole
        , Confidence
        , EvidenceSummary
        , RecommendedAction
    )
    VALUES
    (
          @CaptureRunID
        , @PressureSubtype
        , @SampleCount
        , @ObservationSeconds
        , @PeakMemoryGrantsPending
        , @GrantPressureSampleCount
        , @MinAvailablePhysicalMemoryMB
        , @AvgAvailablePhysicalMemoryMB
        , @LowAvailableMemorySampleCount
        , @SevereLowMemorySampleCount
        , @MinBufferCacheHitRatio
        , @AvgBufferCacheHitRatio
        , @LowBufferCacheSampleCount
        , @MinPLESeconds
        , @AvgPLESeconds
        , @MaxPLESeconds
        , @PLECollapsePercent
        , @PLECollapsePressure
        , @MinTotalServerMemoryMB
        , @AvgTotalServerMemoryMB
        , @MaxTargetServerMemoryMB
        , @MaxTargetMemoryDeficitMB
        , @TargetDeficitSampleCount
        , @GrantQueuePressure
        , @OSMemoryPressure
        , @BufferPoolChurn
        , @UpstreamCauseCategory
        , @RootCauseRole
        , @Confidence
        , @EvidenceSummary
        , @RecommendedAction
    );

    SELECT
          CaptureRunID=@CaptureRunID
        , MemoryPressureCases=COUNT(*)
        , PrimaryCases=
            SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , HighConfidence=
            SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=
            SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_MemoryPressureEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
    5. FINAL CAUSE CANDIDATE INTEGRATION

    Complete replacement preserving all validated domains.
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseCandidates
AS

/* A. PARAMETER-SENSITIVE PLAN REUSE */
SELECT
      p.CaptureRunID
    , CauseCategory=CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    , CauseDisplayName=CONVERT(nvarchar(200),N'Parameter-sensitive plan reuse')
    , RootCauseRole=CONVERT(varchar(20),'PRIMARY')
    , Confidence=p.Confidence
    , CorrelationKey=CONVERT(nvarchar(200),CONCAT(N'EXEC:',p.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID=p.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID=CONVERT(int,NULL)
    , ImpactedRequestCount=CONVERT(int,1)
    , BlockingDepth=CONVERT(int,NULL)
    , MaxObservedWaitMs=CONVERT(bigint,NULL)
    , DurationRatio=p.DurationRatio
    , CPURatio=p.CPURatio
    , LogicalReadRatio=p.LogicalReadRatio
    , EvidenceCount=p.SharedStatementPlanCount
    , PrimaryEvidence=p.EvidenceSummary
    , RecommendedAction=
        CONVERT
        (
            nvarchar(4000),
            N'Validate the distinct parameter distributions with measured plan alternatives and re-test the identical runtime parameter values.'
        )
FROM dbo.RCA_ParameterSensitivePlanEvidence AS p

UNION ALL

/* B. STATISTICS / CARDINALITY */
SELECT
      s.CaptureRunID
    , CONVERT(varchar(80),'STATISTICS_CARDINALITY_REGRESSION')
    , CONVERT(nvarchar(200),N'Statistics / cardinality regression')
    , CONVERT(varchar(20),'PRIMARY')
    , s.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'EXEC:',s.ImpactedExecutionEvidenceID))
    , s.ImpactedExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , s.DurationRatio
    , s.CPURatio
    , s.LogicalReadRatio
    , s.CardinalityMismatchCount+s.StatisticsRiskCount+s.LargeScanCount
    , s.EvidenceSummary
    , CONVERT
      (
          nvarchar(4000),
          N'Review the statistics used by the affected operators, validate estimate-versus-actual row counts, and re-test after the least invasive corrective change.'
      )
FROM dbo.RCA_StatisticsCardinalityEvidence AS s

UNION ALL

/* C. MEMORY GRANT / SPILL */
SELECT
      m.CaptureRunID
    , CONVERT(varchar(80),'MEMORY_GRANT_SPILL')
    , CONVERT(nvarchar(200),N'Memory grant / spill')
    , m.RootCauseRole
    , m.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'EXEC:',m.ImpactedExecutionEvidenceID))
    , m.ImpactedExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , m.DurationRatio
    , m.CPURatio
    , m.LogicalReadRatio
    , m.SpillOperatorCount
    , m.EvidenceSummary
    , CONVERT
      (
          nvarchar(4000),
          N'Review requested, granted, and used query memory together with spill operators; correct upstream estimate problems first when they are stronger causal evidence.'
      )
FROM dbo.RCA_MemorySpillEvidence AS m

UNION ALL

/* D. BLOCKING */
SELECT
      b.CaptureRunID
    , CONVERT(varchar(80),'BLOCKING_WAIT_CHAIN')
    , CONVERT(nvarchar(200),N'Blocking / wait-chain contention')
    , CASE
          WHEN SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>0
              THEN CONVERT(varchar(20),'PRIMARY')
          ELSE CONVERT(varchar(20),'CONTRIBUTING')
      END
    , CASE
          WHEN SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)>0
              THEN CONVERT(varchar(20),'HIGH')
          WHEN SUM(CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END)>0
              THEN CONVERT(varchar(20),'MEDIUM')
          ELSE CONVERT(varchar(20),'LOW')
      END
    , CONVERT(nvarchar(200),CONCAT(N'HEAD_BLOCKER:',b.HeadBlockerSessionID))
    , CONVERT(bigint,NULL)
    , b.HeadBlockerSessionID
    , COUNT(DISTINCT b.VictimSessionID)
    , MAX(b.BlockingDepth)
    , MAX(b.WaitDurationMs)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , SUM(b.SampleCount)
    , CONVERT
      (
          nvarchar(max),
          CONCAT
          (
              N'Head blocker session ',b.HeadBlockerSessionID,
              N' affected ',COUNT(DISTINCT b.VictimSessionID),
              N' distinct request(s). Maximum blocking depth=',MAX(b.BlockingDepth),
              N'; maximum observed wait=',MAX(b.WaitDurationMs),
              N' ms; total sampler observations=',SUM(b.SampleCount),N'.'
          )
      )
    , CONVERT
      (
          nvarchar(4000),
          CONCAT
          (
              N'Investigate head blocker session ',b.HeadBlockerSessionID,
              N', identify the transaction retaining the required locks, and map the blocker host/application/login back to the owning workload.'
          )
      )
FROM dbo.RCA_BlockingEvidence AS b
GROUP BY b.CaptureRunID,b.HeadBlockerSessionID

UNION ALL

/* E. CPU / SCHEDULER */
SELECT
      c.CaptureRunID
    , CONVERT(varchar(80),'CPU_SCHEDULER_PRESSURE')
    , CONVERT(nvarchar(200),N'CPU / scheduler pressure')
    , c.RootCauseRole
    , c.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'EXEC:',c.PrimaryExecutionEvidenceID))
    , c.PrimaryExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , c.HighSqlCpuSampleCount+c.HighRunnableSampleCount
    , c.EvidenceSummary
    , CONVERT(nvarchar(4000),c.RecommendedAction)
FROM dbo.RCA_CPUSchedulerEvidence AS c

UNION ALL

/* F. I/O / STORAGE */
SELECT
      i.CaptureRunID
    , CONVERT(varchar(80),'IO_STORAGE_PRESSURE')
    , CONVERT(nvarchar(200),N'I/O latency / storage pressure')
    , i.RootCauseRole
    , i.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'FILE:',i.DatabaseID,N':',i.FileID))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , i.SampleCount
    , i.EvidenceSummary
    , CONVERT(nvarchar(4000),i.RecommendedAction)
FROM dbo.RCA_IOStorageEvidence AS i
WHERE i.ReadLatencyPressure=1
   OR i.WriteLatencyPressure=1

UNION ALL

/* G. TEMPDB */
SELECT
      t.CaptureRunID
    , CONVERT(varchar(80),'TEMPDB_PRESSURE_CONTENTION')
    , CONVERT(nvarchar(200),N'TempDB pressure / contention')
    , t.RootCauseRole
    , t.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'TEMPDB:',t.PressureSubtype))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,CASE WHEN t.PeakLatchWaiters>0 THEN t.PeakLatchWaiters ELSE 1 END)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , t.SampleCount
    , t.EvidenceSummary
    , CONVERT(nvarchar(4000),t.RecommendedAction)
FROM dbo.RCA_TempDBEvidence AS t
WHERE t.PressureSubtype<>'TEMPDB_ACTIVITY_ONLY'

UNION ALL

/* H. INSTANCE MEMORY / BUFFER POOL */
SELECT
      mp.CaptureRunID
    , CONVERT(varchar(80),'INSTANCE_MEMORY_PRESSURE')
    , CONVERT(nvarchar(200),N'SQL Server memory / buffer pool pressure')
    , mp.RootCauseRole
    , mp.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'MEMORY:',mp.PressureSubtype))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , mp.SampleCount
    , mp.EvidenceSummary
    , CONVERT(nvarchar(4000),mp.RecommendedAction)
FROM dbo.RCA_MemoryPressureEvidence AS mp
WHERE mp.PressureSubtype<>'MEMORY_HEALTHY';
GO


/*==============================================================================
    6. HUMAN-FACING OUTPUT INTEGRATION

    Complete replacement.
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyWasItSlow
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
        THROW 51300,N'Invalid CaptureRunID.',1;

    DECLARE
          @StartTimeUTC datetime2(3)
        , @EndTimeUTC datetime2(3)
        , @CaptureStatus varchar(30)
        , @CauseCategory varchar(80)
        , @CauseDisplayName nvarchar(4000)
        , @Confidence varchar(20)
        , @ImpactedExecutionEvidenceID bigint
        , @HeadBlockerSessionID int
        , @ImpactedRequestCount int
        , @EvidenceCount int
        , @PrimaryEvidence nvarchar(max)
        , @RecommendedAction nvarchar(max)
        , @AttributionType varchar(40)
        , @HumanAnswer nvarchar(max)
        , @AssessmentState varchar(20);

    SELECT
          @StartTimeUTC=StartTimeUTC
        , @EndTimeUTC=EndTimeUTC
        , @CaptureStatus=CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SET @AssessmentState=
        CASE
            WHEN @CaptureStatus IN ('RUNNING','RUN9C_STARTED')
                THEN 'PRELIMINARY'
            ELSE 'FINAL'
        END;

    SELECT TOP (1)
          @CauseCategory=r.CauseCategory
        , @CauseDisplayName=r.CauseDisplayName
        , @Confidence=r.Confidence
        , @ImpactedExecutionEvidenceID=r.ImpactedExecutionEvidenceID
        , @HeadBlockerSessionID=r.HeadBlockerSessionID
        , @ImpactedRequestCount=r.ImpactedRequestCount
        , @EvidenceCount=r.EvidenceCount
        , @PrimaryEvidence=r.PrimaryEvidence
        , @RecommendedAction=r.RecommendedAction
    FROM dbo.vw_RCA_FinalCauseRanking AS r
    WHERE r.CaptureRunID=@CaptureRunID
      AND r.RootCauseRole='PRIMARY'
      AND r.Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE r.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , r.EvidenceCount DESC;

    IF @CauseCategory IS NULL
    BEGIN
        SELECT
              ReportSection='1 - WHY WAS IT SLOW?'
            , Answer=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'NO ROOT CAUSE CONFIRMED YET'
                    ELSE 'NO ROOT CAUSE CONFIRMED'
                END
            , AssessmentState=@AssessmentState
            , Confidence='N/A'
            , CaptureStatus=@CaptureStatus
            , IncidentStartUTC=@StartTimeUTC
            , IncidentEndUTC=@EndTimeUTC
            , Summary=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'No SQL Server root cause has reached the required evidence threshold yet. Evidence collection is still in progress, so this assessment may change as additional evidence is captured.'
                    ELSE 'The captured SQL Server evidence does not support a specific root cause strongly enough to explain the reported slowdown.'
                END;

        SELECT
              ReportSection='2 - WHAT DID SQL SERVER SHOW?'
            , Finding=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'No PRIMARY root cause has reached HIGH or MEDIUM confidence yet.'
                    ELSE 'No PRIMARY root cause reached HIGH or MEDIUM confidence.'
                END
            , Meaning=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'Evidence collection is still active. Do not make a SQL Server corrective change or declare SQL Server healthy solely from this interim assessment.'
                    ELSE 'Do not make a SQL Server corrective change merely because the application was reported as slow.'
                END;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.RCA_MemoryPressureEvidence
            WHERE CaptureRunID=@CaptureRunID
        )
        BEGIN
            SELECT
                  ReportSection='3 - WHAT DID WE RULE OUT?'
                , Hypothesis='SQL Server memory / buffer pool pressure'
                , Assessment=
                    CASE
                        WHEN EXISTS
                        (
                            SELECT 1
                            FROM dbo.RCA_MemoryPressureEvidence
                            WHERE CaptureRunID=@CaptureRunID
                              AND PressureSubtype<>'MEMORY_HEALTHY'
                        )
                            THEN 'EVIDENCE EXISTS BUT DID NOT BECOME PRIMARY'
                        ELSE 'NOT SUPPORTED'
                    END
                , PressureSubtype=
                    (
                        SELECT TOP (1) PressureSubtype
                        FROM dbo.RCA_MemoryPressureEvidence
                        WHERE CaptureRunID=@CaptureRunID
                        ORDER BY MemoryPressureEvidenceID DESC
                    )
                , PeakMemoryGrantsPending=
                    (
                        SELECT MAX(PeakMemoryGrantsPending)
                        FROM dbo.RCA_MemoryPressureEvidence
                        WHERE CaptureRunID=@CaptureRunID
                    )
                , MinAvailablePhysicalMemoryMB=
                    (
                        SELECT MIN(MinAvailablePhysicalMemoryMB)
                        FROM dbo.RCA_MemoryPressureEvidence
                        WHERE CaptureRunID=@CaptureRunID
                    )
                , MinBufferCacheHitRatio=
                    (
                        SELECT MIN(MinBufferCacheHitRatio)
                        FROM dbo.RCA_MemoryPressureEvidence
                        WHERE CaptureRunID=@CaptureRunID
                    )
                , MinPLESeconds=
                    (
                        SELECT MIN(MinPLESeconds)
                        FROM dbo.RCA_MemoryPressureEvidence
                        WHERE CaptureRunID=@CaptureRunID
                    );
        END;

        SELECT
              ReportSection='4 - WHAT SHOULD I DO?'
            , Step1=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'Allow the active evidence capture to continue.'
                    ELSE 'Confirm that the user-reported slowdown occurred inside this capture window.'
                END
            , Step2='Do not change SQL Server configuration, indexes, storage, memory, TempDB, or sessions without supporting evidence.'
            , Step3=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'Continue correlating the reported slowdown with the active capture window while additional evidence is collected.'
                    ELSE 'If SQL Server evidence remains normal, investigate the application tier, API/web services, network latency, external dependencies, or client-side response time.'
                END
            , Step4=
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'When capture completes, rerun the RCA analysis and use the FINAL assessment for incident conclusions.'
                    ELSE 'If the slowdown recurs, capture the incident while it is actively occurring and rerun the RCA analysis.'
                END;
        RETURN;
    END;

    SET @AttributionType=
        CASE
            WHEN @CauseCategory='BLOCKING_WAIT_CHAIN' THEN 'BLOCKING CHAIN'
            WHEN @CauseCategory='IO_STORAGE_PRESSURE' THEN 'DATABASE FILE'
            WHEN @CauseCategory='CPU_SCHEDULER_PRESSURE' THEN 'CPU / SCHEDULER'
            WHEN @CauseCategory='TEMPDB_PRESSURE_CONTENTION' THEN 'TEMPDB'
            WHEN @CauseCategory='INSTANCE_MEMORY_PRESSURE' THEN 'SQL SERVER MEMORY'
            WHEN @ImpactedExecutionEvidenceID IS NOT NULL THEN 'SQL EXECUTION'
            ELSE 'SYSTEM LEVEL'
        END;

    SET @HumanAnswer=
        CASE @CauseCategory
            WHEN 'BLOCKING_WAIT_CHAIN'
                THEN CONCAT('The slowdown was caused by blocking. SQL session ',
                            COALESCE(CONVERT(varchar(20),@HeadBlockerSessionID),'?'),
                            ' was identified as the head blocker and prevented other work from progressing normally.')
            WHEN 'IO_STORAGE_PRESSURE'
                THEN 'The slowdown was caused by elevated database-file I/O latency. Storage response time was high enough to support I/O/storage pressure as the primary cause.'
            WHEN 'CPU_SCHEDULER_PRESSURE'
                THEN 'The slowdown was caused by CPU / scheduler pressure. SQL Server had runnable work waiting for CPU resources.'
            WHEN 'TEMPDB_PRESSURE_CONTENTION'
                THEN 'The slowdown was caused by TempDB pressure or contention. TempDB showed sustained evidence strong enough to support it as a primary cause.'
            WHEN 'INSTANCE_MEMORY_PRESSURE'
                THEN 'The slowdown was caused by sustained SQL Server memory / buffer-pool pressure. Multiple memory-health signals corroborated the condition rather than relying on Buffer Cache Hit Ratio alone.'
            WHEN 'MEMORY_GRANT_SPILL'
                THEN 'The slowdown was caused by a query memory grant / spill problem. The affected query could not complete its memory-intensive work entirely in memory.'
            WHEN 'PARAMETER_SENSITIVE_PLAN_REUSE'
                THEN 'The slowdown was caused by parameter-sensitive plan reuse. SQL Server reused an execution plan that was inappropriate for the runtime parameter values.'
            WHEN 'STATISTICS_CARDINALITY_REGRESSION'
                THEN 'The slowdown was caused by a statistics / cardinality estimation problem that led SQL Server to choose an inefficient execution strategy.'
            ELSE CONCAT('The RCA engine identified ',COALESCE(@CauseDisplayName,@CauseCategory),' as the primary cause of the slowdown.')
        END;

    IF @AssessmentState='PRELIMINARY'
        SET @HumanAnswer=
            CONCAT
            (
                'PRELIMINARY ASSESSMENT: ',
                @HumanAnswer,
                ' Evidence collection is still in progress. This conclusion may change as additional evidence is captured.'
            );

    SELECT
          ReportSection='1 - WHY WAS IT SLOW?'
        , Answer=
            CASE
                WHEN @AssessmentState='PRELIMINARY'
                    THEN 'PRELIMINARY ROOT CAUSE IDENTIFIED'
                ELSE 'ROOT CAUSE IDENTIFIED'
            END
        , AssessmentState=@AssessmentState
        , PrimaryCause=@CauseDisplayName
        , Confidence=@Confidence
        , ImpactedRequestCount=@ImpactedRequestCount
        , AttributionType=@AttributionType
        , CaptureStatus=@CaptureStatus
        , IncidentStartUTC=@StartTimeUTC
        , IncidentEndUTC=@EndTimeUTC
        , Summary=@HumanAnswer;

    IF @CauseCategory='BLOCKING_WAIT_CHAIN'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='BLOCKING'
            , b.HeadBlockerSessionID
            , b.VictimSessionID
            , b.ImmediateBlockerSessionID
            , b.BlockingDepth
            , b.WaitType
            , WaitSeconds=CONVERT(decimal(19,2),b.WaitDurationMs/1000.0)
            , b.SampleCount
            , b.FirstObservedUTC
            , b.LastObservedUTC
            , DatabaseName=b.VictimDatabaseName
            , HeadBlockerHost=b.HeadBlockerHostName
            , HeadBlockerApplication=b.HeadBlockerProgramName
            , HeadBlockerLogin=b.HeadBlockerLoginName
            , HeadBlockerStatement=b.HeadBlockerStatement
            , HeadBlockerOpenTransactions=b.HeadBlockerOpenTransactionCount
            , VictimHost=b.VictimHostName
            , VictimApplication=b.VictimProgramName
            , VictimLogin=b.VictimLoginName
            , VictimStatement=b.VictimStatement
        FROM dbo.RCA_BlockingEvidence AS b
        WHERE b.CaptureRunID=@CaptureRunID
          AND b.HeadBlockerSessionID=@HeadBlockerSessionID
        ORDER BY b.BlockingDepth DESC,b.WaitDurationMs DESC,b.SampleCount DESC;
    END

    ELSE IF @CauseCategory='IO_STORAGE_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='DATABASE FILE IO LATENCY'
            , i.DatabaseName
            , i.LogicalFileName
            , i.FileTypeDesc
            , i.PhysicalName
            , i.ObservationSeconds
            , i.DeltaReads
            , i.DeltaReadMB
            , i.AvgReadLatencyMs
            , i.ReadThroughputMBps
            , i.DeltaWrites
            , i.DeltaWriteMB
            , i.AvgWriteLatencyMs
            , i.WriteThroughputMBps
            , ReadLatencyPressure=CASE WHEN i.ReadLatencyPressure=1 THEN 'YES' ELSE 'NO' END
            , WriteLatencyPressure=CASE WHEN i.WriteLatencyPressure=1 THEN 'YES' ELSE 'NO' END
        FROM dbo.RCA_IOStorageEvidence AS i
        WHERE i.CaptureRunID=@CaptureRunID
          AND i.RootCauseRole='PRIMARY'
          AND i.Confidence IN ('HIGH','MEDIUM')
        ORDER BY
              CASE i.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , i.AvgReadLatencyMs DESC
            , i.AvgWriteLatencyMs DESC;
    END

    ELSE IF @CauseCategory='CPU_SCHEDULER_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='CPU / SCHEDULER PRESSURE'
            , c.PrimarySessionID
            , c.PrimaryHostName
            , c.PrimaryProgramName
            , c.PrimaryLoginName
            , c.PrimaryStatement
            , c.PeakSqlCpuPercent
            , c.AvgSqlCpuPercent
            , c.PeakOtherCpuPercent
            , c.LowestSystemIdlePercent
            , c.PeakRunnableTasks
            , c.AvgRunnableTasks
            , c.HighRunnableSampleCount
            , c.TopExecutionCPUms
            , c.TotalCapturedCPUms
            , c.TopExecutionCPUSharePercent
        FROM dbo.RCA_CPUSchedulerEvidence AS c
        WHERE c.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE c.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , c.PeakRunnableTasks DESC;
    END

    ELSE IF @CauseCategory='TEMPDB_PRESSURE_CONTENTION'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='TEMPDB PRESSURE / CONTENTION'
            , t.PressureSubtype
            , t.SampleCount
            , t.ObservationSeconds
            , t.PeakUsedPercent
            , t.AvgUsedPercent
            , t.HighSpaceSampleCount
            , t.PeakInternalObjectMB
            , t.AvgInternalObjectMB
            , t.HighInternalSampleCount
            , t.PeakVersionStoreMB
            , t.AvgVersionStoreMB
            , t.HighVersionStoreSampleCount
            , t.PeakLatchWaiters
            , t.AvgLatchWaiters
            , t.LatchPressureSampleCount
            , t.PeakPFSWaiters
            , t.PeakGAMWaiters
            , t.PeakSGAMWaiters
            , t.PeakTempDBReadLatencyMs
            , t.PeakTempDBWriteLatencyMs
            , t.UpstreamCauseCategory
        FROM dbo.RCA_TempDBEvidence AS t
        WHERE t.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE t.RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END
            , CASE t.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
    END

    ELSE IF @CauseCategory='INSTANCE_MEMORY_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='SQL SERVER MEMORY / BUFFER POOL PRESSURE'
            , mp.PressureSubtype
            , mp.SampleCount
            , mp.ObservationSeconds
            , mp.PeakMemoryGrantsPending
            , mp.GrantPressureSampleCount
            , mp.MinAvailablePhysicalMemoryMB
            , mp.AvgAvailablePhysicalMemoryMB
            , mp.LowAvailableMemorySampleCount
            , mp.SevereLowMemorySampleCount
            , mp.MinBufferCacheHitRatio
            , mp.AvgBufferCacheHitRatio
            , mp.LowBufferCacheSampleCount
            , mp.MinPLESeconds
            , mp.AvgPLESeconds
            , mp.MaxPLESeconds
            , mp.PLECollapsePercent
            , mp.PLECollapsePressure
            , mp.AvgTotalServerMemoryMB
            , mp.MaxTargetServerMemoryMB
            , mp.MaxTargetMemoryDeficitMB
            , mp.TargetDeficitSampleCount
            , mp.GrantQueuePressure
            , mp.OSMemoryPressure
            , mp.BufferPoolChurn
            , mp.UpstreamCauseCategory
        FROM dbo.RCA_MemoryPressureEvidence AS mp
        WHERE mp.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE mp.RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END
            , CASE mp.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
    END

    ELSE IF @ImpactedExecutionEvidenceID IS NOT NULL
    BEGIN
        SELECT
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause=@CauseDisplayName
            , e.ExecutionEvidenceID
            , e.DatabaseName
            , e.SessionID
            , e.ObjectName
            , e.HostName
            , e.ProgramName
            , e.LoginName
            , DurationSeconds=CONVERT(decimal(19,3),e.DurationMs/1000.0)
            , CPUSeconds=CONVERT(decimal(19,3),e.CPUms/1000.0)
            , e.LogicalReads
            , e.PhysicalReads
            , e.Writes
            , e.TotalRows
            , e.ParameterEvidenceStatus
            , e.ParameterText
            , e.SubmittedCommand
        FROM dbo.RCA_ExecutionEvidence AS e
        WHERE e.ExecutionEvidenceID=@ImpactedExecutionEvidenceID;
    END

    ELSE
    BEGIN
        SELECT
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause=@CauseDisplayName
            , Attribution='SYSTEM LEVEL'
            , Explanation='The RCA evidence supports this root cause, but no more specific attribution is available from the captured evidence.';
    END;

    SELECT
          ReportSection='3 - WHY DO WE BELIEVE THIS?'
        , Confidence=@Confidence
        , EvidenceCount=@EvidenceCount
        , Evidence=@PrimaryEvidence;

    SELECT
          ReportSection='4 - WHAT SHOULD I DO?'
        , RecommendedAction=@RecommendedAction
        , AssessmentState=@AssessmentState
        , SafetyNote=
            CASE
                WHEN @AssessmentState='PRELIMINARY'
                    THEN 'This is a preliminary assessment because evidence collection is still active. Do not make an irreversible production change solely from this interim conclusion.'
                WHEN @CauseCategory='BLOCKING_WAIT_CHAIN'
                    THEN 'Do not automatically kill the head-blocking session. Confirm the transaction owner, business impact, rollback risk, and application context first.'
                WHEN @CauseCategory='IO_STORAGE_PRESSURE'
                    THEN 'Do not change SQL Server storage configuration solely from one latency observation. Correlate the file latency with storage, host, backup, checkpoint, maintenance, and workload evidence.'
                WHEN @CauseCategory='CPU_SCHEDULER_PRESSURE'
                    THEN 'Do not treat scheduler queueing alone as the problem. Identify and reduce the workload responsible for the CPU demand.'
                WHEN @CauseCategory='MEMORY_GRANT_SPILL'
                    THEN 'Correct upstream estimate, plan, or grant problems before simply increasing SQL Server memory.'
                WHEN @CauseCategory='TEMPDB_PRESSURE_CONTENTION'
                    THEN 'Do not add TempDB files, grow TempDB, or move TempDB solely from this result. First confirm the TempDB pressure subtype and the workload producing it.'
                WHEN @CauseCategory='INSTANCE_MEMORY_PRESSURE'
                    THEN 'Do not change max server memory or add RAM solely because Buffer Cache Hit Ratio or PLE changed. Confirm the corroborating grant, OS-memory, target-memory, and workload evidence first.'
                ELSE 'Validate the recommended action against the technical evidence before making a production change.'
            END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_MemoryPressureEvidence
        WHERE CaptureRunID=@CaptureRunID
    )
    BEGIN
        SELECT
              ReportSection='5 - OTHER HYPOTHESES EVALUATED'
            , Hypothesis='SQL Server memory / buffer pool pressure'
            , Assessment=
                CASE
                    WHEN EXISTS
                    (
                        SELECT 1
                        FROM dbo.RCA_MemoryPressureEvidence
                        WHERE CaptureRunID=@CaptureRunID
                          AND PressureSubtype<>'MEMORY_HEALTHY'
                    )
                        THEN 'SUPPORTED'
                    ELSE 'NOT SUPPORTED'
                END
            , PressureSubtype=
                (
                    SELECT TOP (1) PressureSubtype
                    FROM dbo.RCA_MemoryPressureEvidence
                    WHERE CaptureRunID=@CaptureRunID
                    ORDER BY MemoryPressureEvidenceID DESC
                )
            , PeakMemoryGrantsPending=
                (
                    SELECT MAX(PeakMemoryGrantsPending)
                    FROM dbo.RCA_MemoryPressureEvidence
                    WHERE CaptureRunID=@CaptureRunID
                )
            , MinAvailablePhysicalMemoryMB=
                (
                    SELECT MIN(MinAvailablePhysicalMemoryMB)
                    FROM dbo.RCA_MemoryPressureEvidence
                    WHERE CaptureRunID=@CaptureRunID
                )
            , MinBufferCacheHitRatio=
                (
                    SELECT MIN(MinBufferCacheHitRatio)
                    FROM dbo.RCA_MemoryPressureEvidence
                    WHERE CaptureRunID=@CaptureRunID
                )
            , MinPLESeconds=
                (
                    SELECT MIN(MinPLESeconds)
                    FROM dbo.RCA_MemoryPressureEvidence
                    WHERE CaptureRunID=@CaptureRunID
                );
    END;
END;
GO


/*==============================================================================
    7. DEPLOYMENT VALIDATION
==============================================================================*/

SELECT
      MemoryPressureEvidenceTable=
        CASE
            WHEN OBJECT_ID(N'dbo.RCA_MemoryPressureEvidence',N'U') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , MemoryPressureEvidenceView=
        CASE
            WHEN OBJECT_ID(N'dbo.vw_RCA_MemoryPressureEvidence',N'V') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , MemoryPressureDetector=
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_BuildMemoryPressureEvidence',N'P') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , FinalCauseIntegration=
        CASE
            WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END

    , HumanOutputIntegration=
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
                THEN 'PASS'
            ELSE 'FAIL'
        END;
GO


/*==============================================================================
    8. EXISTING-DOMAIN REGRESSION MATRIX

    The new memory domain has not been validated yet.
    Existing validated domains must remain unchanged.
==============================================================================*/

;WITH TestRuns AS
(
    SELECT CONVERT(bigint,3) AS CaptureRunID,
           CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE') AS ExpectedCause
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 16, 'CPU_SCHEDULER_PRESSURE'
    UNION ALL SELECT 20, 'IO_STORAGE_PRESSURE'
    UNION ALL SELECT 26, 'TEMPDB_PRESSURE_CONTENTION'
),
Ranked AS
(
    SELECT
          t.CaptureRunID
        , t.ExpectedCause
        , r.CauseCategory
        , r.CauseDisplayName
        , r.RootCauseRole
        , r.Confidence
        , rn=
            ROW_NUMBER() OVER
            (
                PARTITION BY t.CaptureRunID
                ORDER BY
                      r.RoleRank
                    , r.ConfidenceRank
                    , r.ImpactRank
                    , r.EvidenceStrengthRank
            )
    FROM TestRuns AS t
    LEFT JOIN dbo.vw_RCA_FinalCauseRanking AS r
      ON r.CaptureRunID=t.CaptureRunID
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
    NEXT VALIDATION
    ---------------
    After this deployment returns all PASS:
      Run 11A - memory-health negative control
      Run 11B - live grant-pressure attempt
      Run 11C - deterministic positive memory-pressure control

    Run 11C should prove:
        INSTANCE_MEMORY_PRESSURE
        PRIMARY
        HIGH

    Human output must explicitly show:
        Buffer Cache Hit Ratio
        PLE
        Available Physical Memory
        Memory Grants Pending
        Target vs Total Server Memory

    Buffer Cache Hit Ratio remains SUPPORTING EVIDENCE, never a standalone cause.
==============================================================================*/
