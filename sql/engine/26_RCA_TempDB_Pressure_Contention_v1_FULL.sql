USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    26_RCA_TempDB_Pressure_Contention_v1.sql

    PURPOSE
    -------
    Add TempDB pressure / contention as a dedicated RCA root-cause domain
    without changing any existing detector logic.

    NEW ROOT-CAUSE CATEGORY
    -----------------------
        TEMPDB_PRESSURE_CONTENTION

    WHAT THIS DOMAIN DETECTS
    ------------------------
    1. Sustained TempDB space pressure
    2. Sustained internal-object pressure
    3. Sustained version-store pressure
    4. TempDB PAGELATCH contention
    5. TempDB file I/O latency pressure (correlated from existing I/O evidence)

    IMPORTANT CAUSAL RULE
    ---------------------
    TempDB activity is not automatically a root cause.

    Example:
        bad cardinality estimate
            -> bad memory grant
            -> spill
            -> TempDB activity

    In that case:
        MEMORY_GRANT_SPILL            = PRIMARY
        TEMPDB_PRESSURE_CONTENTION    = CONTRIBUTING

    This script:
      - creates the TempDB sampler and evidence objects
      - integrates the new domain into vw_RCA_FinalCauseCandidates
      - updates dbo.usp_RCA_WhyWasItSlow so humans get a useful answer
      - includes deployment validation

    It does NOT:
      - change existing thresholds for other domains
      - change existing XE sessions
      - modify existing evidence tables
      - modify existing root-cause ranking logic
==============================================================================*/


/*==============================================================================
    1. RAW TEMPDB SNAPSHOT
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_TempDBSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_TempDBSnapshot
    (
          TempDBSnapshotID              bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_TempDBSnapshot PRIMARY KEY

        , CaptureRunID                  bigint NOT NULL
        , CaptureTimeUTC                datetime2(3) NOT NULL

        , TotalSizeMB                   decimal(19,2) NULL
        , UnallocatedMB                 decimal(19,2) NULL
        , UsedMB                        decimal(19,2) NULL
        , UsedPercent                   decimal(9,4) NULL

        , UserObjectMB                  decimal(19,2) NULL
        , InternalObjectMB              decimal(19,2) NULL
        , VersionStoreMB                decimal(19,2) NULL
        , MixedExtentMB                 decimal(19,2) NULL

        , TempDBLatchWaiterCount        int NOT NULL
        , TempDBPFSWaiterCount          int NOT NULL
        , TempDBGAMWaiterCount          int NOT NULL
        , TempDBSGAMWaiterCount         int NOT NULL

        , CreatedTimeUTC                datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_TempDBSnapshot_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_TempDBSnapshot_RunTime
        ON dbo.RCA_TempDBSnapshot
        (
            CaptureRunID,
            CaptureTimeUTC
        );
END;
GO


/*==============================================================================
    2. TEMPDB SAMPLER
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_RunTempDBSampler
      @CaptureRunID bigint
    , @DurationMinutes int = 3
    , @SampleSeconds int = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationMinutes < 1
        THROW 51400, N'@DurationMinutes must be >= 1.', 1;

    IF @SampleSeconds < 1 OR @SampleSeconds > 86399
        THROW 51401, N'@SampleSeconds must be between 1 and 86399.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
    )
        THROW 51402, N'Invalid CaptureRunID.', 1;

    DELETE FROM dbo.RCA_TempDBSnapshot
    WHERE CaptureRunID = @CaptureRunID;

    DECLARE
          @StartTimeUTC datetime2(3) = SYSUTCDATETIME()
        , @StopAt datetime2(3)
        , @Delay varchar(8)
        , @Samples int = 0;

    SET @StopAt =
        DATEADD(MINUTE, @DurationMinutes, @StartTimeUTC);

    SET @Delay =
        RIGHT('00' + CONVERT(varchar(2), @SampleSeconds / 3600), 2)
        + ':' +
        RIGHT('00' + CONVERT(varchar(2), (@SampleSeconds % 3600) / 60), 2)
        + ':' +
        RIGHT('00' + CONVERT(varchar(2), @SampleSeconds % 60), 2);

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        DECLARE
              @TotalPages bigint = 0
            , @UnallocatedPages bigint = 0
            , @UserObjectPages bigint = 0
            , @InternalObjectPages bigint = 0
            , @VersionStorePages bigint = 0
            , @MixedExtentPages bigint = 0
            , @LatchWaiters int = 0
            , @PFSWaiters int = 0
            , @GAMWaiters int = 0
            , @SGAMWaiters int = 0;

        SELECT
              @TotalPages =
                    SUM(CONVERT(bigint, allocated_extent_page_count)
                      + CONVERT(bigint, unallocated_extent_page_count))
            , @UnallocatedPages =
                    SUM(CONVERT(bigint, unallocated_extent_page_count))
            , @UserObjectPages =
                    SUM(CONVERT(bigint, user_object_reserved_page_count))
            , @InternalObjectPages =
                    SUM(CONVERT(bigint, internal_object_reserved_page_count))
            , @VersionStorePages =
                    SUM(CONVERT(bigint, version_store_reserved_page_count))
            , @MixedExtentPages =
                    SUM(CONVERT(bigint, mixed_extent_page_count))
        FROM tempdb.sys.dm_db_file_space_usage;

        SELECT
              @LatchWaiters =
                    SUM
                    (
                        CASE
                            WHEN wait_type LIKE N'PAGELATCH_%'
                             AND resource_description LIKE N'2:%'
                                THEN 1
                            ELSE 0
                        END
                    )
            , @PFSWaiters =
                    SUM
                    (
                        CASE
                            WHEN wait_type LIKE N'PAGELATCH_%'
                             AND resource_description = N'2:1:1'
                                THEN 1
                            ELSE 0
                        END
                    )
            , @GAMWaiters =
                    SUM
                    (
                        CASE
                            WHEN wait_type LIKE N'PAGELATCH_%'
                             AND resource_description = N'2:1:2'
                                THEN 1
                            ELSE 0
                        END
                    )
            , @SGAMWaiters =
                    SUM
                    (
                        CASE
                            WHEN wait_type LIKE N'PAGELATCH_%'
                             AND resource_description = N'2:1:3'
                                THEN 1
                            ELSE 0
                        END
                    )
        FROM sys.dm_os_waiting_tasks;

        SET @LatchWaiters = ISNULL(@LatchWaiters,0);
        SET @PFSWaiters   = ISNULL(@PFSWaiters,0);
        SET @GAMWaiters   = ISNULL(@GAMWaiters,0);
        SET @SGAMWaiters  = ISNULL(@SGAMWaiters,0);

        INSERT dbo.RCA_TempDBSnapshot
        (
              CaptureRunID
            , CaptureTimeUTC
            , TotalSizeMB
            , UnallocatedMB
            , UsedMB
            , UsedPercent
            , UserObjectMB
            , InternalObjectMB
            , VersionStoreMB
            , MixedExtentMB
            , TempDBLatchWaiterCount
            , TempDBPFSWaiterCount
            , TempDBGAMWaiterCount
            , TempDBSGAMWaiterCount
        )
        SELECT
              @CaptureRunID
            , SYSUTCDATETIME()
            , CONVERT(decimal(19,2), @TotalPages / 128.0)
            , CONVERT(decimal(19,2), @UnallocatedPages / 128.0)
            , CONVERT(decimal(19,2), (@TotalPages - @UnallocatedPages) / 128.0)
            , CONVERT
              (
                  decimal(9,4),
                  CASE
                      WHEN @TotalPages > 0
                      THEN ((@TotalPages - @UnallocatedPages) * 100.0) / @TotalPages
                  END
              )
            , CONVERT(decimal(19,2), @UserObjectPages / 128.0)
            , CONVERT(decimal(19,2), @InternalObjectPages / 128.0)
            , CONVERT(decimal(19,2), @VersionStorePages / 128.0)
            , CONVERT(decimal(19,2), @MixedExtentPages / 128.0)
            , @LatchWaiters
            , @PFSWaiters
            , @GAMWaiters
            , @SGAMWaiters;

        SET @Samples += 1;

        WAITFOR DELAY @Delay;
    END;

    SELECT
          CaptureRunID = @CaptureRunID
        , TempDBSamplesCaptured = @Samples
        , SampleSeconds = @SampleSeconds
        , DurationMinutes = @DurationMinutes
        , DelayUsed = @Delay;
END;
GO


/*==============================================================================
    3. TEMPDB EVIDENCE TABLE
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_TempDBEvidence', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_TempDBEvidence
    (
          TempDBEvidenceID              bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_TempDBEvidence PRIMARY KEY
        , CaptureRunID                  bigint NOT NULL
        , PressureSubtype               varchar(80) NOT NULL
        , SampleCount                   int NOT NULL
        , ObservationSeconds            decimal(19,2) NULL
        , PeakUsedPercent               decimal(9,4) NULL
        , AvgUsedPercent                decimal(9,4) NULL
        , HighSpaceSampleCount          int NOT NULL
        , PeakInternalObjectMB          decimal(19,2) NULL
        , AvgInternalObjectMB           decimal(19,2) NULL
        , HighInternalSampleCount       int NOT NULL
        , PeakVersionStoreMB            decimal(19,2) NULL
        , AvgVersionStoreMB             decimal(19,2) NULL
        , HighVersionStoreSampleCount   int NOT NULL
        , PeakLatchWaiters              int NOT NULL
        , AvgLatchWaiters               decimal(19,2) NULL
        , LatchPressureSampleCount      int NOT NULL
        , PeakPFSWaiters                int NOT NULL
        , PeakGAMWaiters                int NOT NULL
        , PeakSGAMWaiters               int NOT NULL
        , PeakTempDBReadLatencyMs       decimal(19,4) NULL
        , PeakTempDBWriteLatencyMs      decimal(19,4) NULL
        , TempDBIOLatencyPressure       bit NOT NULL
        , UpstreamCauseCategory         varchar(80) NULL
        , RootCauseRole                 varchar(20) NOT NULL
        , Confidence                    varchar(20) NOT NULL
        , EvidenceSummary               nvarchar(max) NOT NULL
        , RecommendedAction             nvarchar(max) NOT NULL
        , CreatedTimeUTC                datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_TempDBEvidence_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_TempDBEvidence_Run
        ON dbo.RCA_TempDBEvidence
        (
            CaptureRunID,
            RootCauseRole,
            Confidence
        );
END;
GO


/*==============================================================================
    4. TEMPDB EVIDENCE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_TempDBEvidence
AS
SELECT *
FROM dbo.RCA_TempDBEvidence;
GO


/*==============================================================================
    5. TEMPDB DETECTOR
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildTempDBEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM dbo.RCA_TempDBEvidence
    WHERE CaptureRunID = @CaptureRunID;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_TempDBSnapshot
        WHERE CaptureRunID = @CaptureRunID
    )
    BEGIN
        SELECT
              CaptureRunID = @CaptureRunID
            , TempDBCases = 0
            , PrimaryCases = 0
            , HighConfidence = 0
            , MediumConfidence = 0
            , Message = 'No TempDB snapshot evidence exists for this capture.';
        RETURN;
    END;

    DECLARE
          @UpstreamCauseCategory varchar(80) = NULL
        , @SampleCount int
        , @ObservationSeconds decimal(19,2)
        , @PeakUsedPercent decimal(9,4)
        , @AvgUsedPercent decimal(9,4)
        , @HighSpaceSampleCount int
        , @PeakInternalObjectMB decimal(19,2)
        , @AvgInternalObjectMB decimal(19,2)
        , @HighInternalSampleCount int
        , @PeakVersionStoreMB decimal(19,2)
        , @AvgVersionStoreMB decimal(19,2)
        , @HighVersionStoreSampleCount int
        , @PeakLatchWaiters int
        , @AvgLatchWaiters decimal(19,2)
        , @LatchPressureSampleCount int
        , @PeakPFSWaiters int
        , @PeakGAMWaiters int
        , @PeakSGAMWaiters int
        , @PeakTempDBReadLatencyMs decimal(19,4)
        , @PeakTempDBWriteLatencyMs decimal(19,4)
        , @TempDBIOLatencyPressure bit = 0
        , @PressureSubtype varchar(80)
        , @RootCauseRole varchar(20)
        , @Confidence varchar(20)
        , @EvidenceSummary nvarchar(max)
        , @RecommendedAction nvarchar(max);

    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_ParameterSensitivePlanEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND Confidence = 'HIGH'
    )
        SET @UpstreamCauseCategory = 'PARAMETER_SENSITIVE_PLAN_REUSE';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_StatisticsCardinalityEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND Confidence = 'HIGH'
    )
        SET @UpstreamCauseCategory = 'STATISTICS_CARDINALITY_REGRESSION';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_MemorySpillEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND RootCauseRole = 'PRIMARY'
          AND Confidence IN ('HIGH','MEDIUM')
    )
        SET @UpstreamCauseCategory = 'MEMORY_GRANT_SPILL';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND RootCauseRole = 'PRIMARY'
          AND Confidence = 'HIGH'
    )
        SET @UpstreamCauseCategory = 'BLOCKING_WAIT_CHAIN';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CPUSchedulerEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND RootCauseRole = 'PRIMARY'
          AND Confidence = 'HIGH'
    )
        SET @UpstreamCauseCategory = 'CPU_SCHEDULER_PRESSURE';

    SELECT
          @SampleCount = COUNT(*)
        , @ObservationSeconds =
            CONVERT(decimal(19,2),
                DATEDIFF_BIG(millisecond,MIN(CaptureTimeUTC),MAX(CaptureTimeUTC))/1000.0)
        , @PeakUsedPercent = MAX(UsedPercent)
        , @AvgUsedPercent = AVG(UsedPercent)
        , @HighSpaceSampleCount =
            SUM(CASE WHEN UsedPercent >= 90 THEN 1 ELSE 0 END)
        , @PeakInternalObjectMB = MAX(InternalObjectMB)
        , @AvgInternalObjectMB = AVG(InternalObjectMB)
        , @HighInternalSampleCount =
            SUM(CASE WHEN InternalObjectMB >= 1024 THEN 1 ELSE 0 END)
        , @PeakVersionStoreMB = MAX(VersionStoreMB)
        , @AvgVersionStoreMB = AVG(VersionStoreMB)
        , @HighVersionStoreSampleCount =
            SUM(CASE WHEN VersionStoreMB >= 1024 THEN 1 ELSE 0 END)
        , @PeakLatchWaiters = MAX(TempDBLatchWaiterCount)
        , @AvgLatchWaiters =
            AVG(CONVERT(decimal(19,2),TempDBLatchWaiterCount))
        , @LatchPressureSampleCount =
            SUM(CASE WHEN TempDBLatchWaiterCount >= 2 THEN 1 ELSE 0 END)
        , @PeakPFSWaiters = MAX(TempDBPFSWaiterCount)
        , @PeakGAMWaiters = MAX(TempDBGAMWaiterCount)
        , @PeakSGAMWaiters = MAX(TempDBSGAMWaiterCount)
    FROM dbo.RCA_TempDBSnapshot
    WHERE CaptureRunID = @CaptureRunID;

    SELECT
          @PeakTempDBReadLatencyMs = MAX(AvgReadLatencyMs)
        , @PeakTempDBWriteLatencyMs = MAX(AvgWriteLatencyMs)
        , @TempDBIOLatencyPressure =
            CONVERT(bit,
                MAX(CASE
                        WHEN ReadLatencyPressure = 1
                          OR WriteLatencyPressure = 1
                            THEN 1
                        ELSE 0
                    END))
    FROM dbo.RCA_IOStorageEvidence
    WHERE CaptureRunID = @CaptureRunID
      AND DatabaseName = 'tempdb';

    SET @TempDBIOLatencyPressure =
        ISNULL(@TempDBIOLatencyPressure,0);

    SET @PressureSubtype =
        CASE
            WHEN @LatchPressureSampleCount >= 3
                THEN 'TEMPDB_LATCH_CONTENTION'
            WHEN @HighSpaceSampleCount >= 3
                THEN 'TEMPDB_SPACE_PRESSURE'
            WHEN @HighVersionStoreSampleCount >= 3
                THEN 'TEMPDB_VERSION_STORE_PRESSURE'
            WHEN @HighInternalSampleCount >= 3
                THEN 'TEMPDB_INTERNAL_OBJECT_PRESSURE'
            WHEN @TempDBIOLatencyPressure = 1
                THEN 'TEMPDB_IO_LATENCY'
            ELSE 'TEMPDB_ACTIVITY_ONLY'
        END;

    SET @RootCauseRole =
        CASE
            WHEN @PressureSubtype = 'TEMPDB_ACTIVITY_ONLY'
                THEN 'CONTRIBUTING'
            WHEN @UpstreamCauseCategory IS NOT NULL
                THEN 'CONTRIBUTING'
            ELSE 'PRIMARY'
        END;

    SET @Confidence =
        CASE
            WHEN @PressureSubtype = 'TEMPDB_ACTIVITY_ONLY'
                THEN 'LOW'
            WHEN @PressureSubtype = 'TEMPDB_LATCH_CONTENTION'
             AND @LatchPressureSampleCount >= 5
                THEN 'HIGH'
            WHEN @PressureSubtype = 'TEMPDB_SPACE_PRESSURE'
             AND @HighSpaceSampleCount >= 5
                THEN 'HIGH'
            WHEN @PressureSubtype = 'TEMPDB_VERSION_STORE_PRESSURE'
             AND @HighVersionStoreSampleCount >= 5
                THEN 'HIGH'
            WHEN @PressureSubtype = 'TEMPDB_INTERNAL_OBJECT_PRESSURE'
             AND @HighInternalSampleCount >= 5
                THEN 'HIGH'
            WHEN @PressureSubtype = 'TEMPDB_IO_LATENCY'
             AND
             (
                 ISNULL(@PeakTempDBReadLatencyMs,0) >= 40
                 OR ISNULL(@PeakTempDBWriteLatencyMs,0) >= 40
             )
                THEN 'HIGH'
            ELSE 'MEDIUM'
        END;

    SET @EvidenceSummary =
        CONCAT
        (
            'TempDB subtype=',@PressureSubtype,
            '; samples=',@SampleCount,
            '; observation=',COALESCE(CONVERT(varchar(30),@ObservationSeconds),'NULL'),' sec',
            '; peak used=',COALESCE(CONVERT(varchar(30),@PeakUsedPercent),'NULL'),'%',
            '; avg used=',COALESCE(CONVERT(varchar(30),@AvgUsedPercent),'NULL'),'%',
            '; high-space samples=',@HighSpaceSampleCount,
            '; peak internal objects=',COALESCE(CONVERT(varchar(30),@PeakInternalObjectMB),'NULL'),' MB',
            '; high-internal samples=',@HighInternalSampleCount,
            '; peak version store=',COALESCE(CONVERT(varchar(30),@PeakVersionStoreMB),'NULL'),' MB',
            '; high-version samples=',@HighVersionStoreSampleCount,
            '; peak latch waiters=',@PeakLatchWaiters,
            '; latch-pressure samples=',@LatchPressureSampleCount,
            '; PFS/GAM/SGAM peak waiters=',@PeakPFSWaiters,'/',@PeakGAMWaiters,'/',@PeakSGAMWaiters,
            '; tempdb peak read latency=',COALESCE(CONVERT(varchar(30),@PeakTempDBReadLatencyMs),'NULL'),' ms',
            '; tempdb peak write latency=',COALESCE(CONVERT(varchar(30),@PeakTempDBWriteLatencyMs),'NULL'),' ms',
            CASE
                WHEN @UpstreamCauseCategory IS NOT NULL
                    THEN CONCAT('; stronger upstream cause=',@UpstreamCauseCategory)
                ELSE ''
            END,
            '.'
        );

    SET @RecommendedAction =
        CASE @PressureSubtype
            WHEN 'TEMPDB_LATCH_CONTENTION'
            THEN
                'Investigate sessions repeatedly waiting on TempDB PAGELATCH resources. Review temporary-object concurrency and confirm whether PFS/GAM/SGAM allocation pages are involved before changing TempDB file configuration.'
            WHEN 'TEMPDB_SPACE_PRESSURE'
            THEN
                'Identify the sessions consuming TempDB space, determine whether user objects, internal worktables, spills, or version store are responsible, and avoid growing TempDB blindly until the dominant consumer is understood.'
            WHEN 'TEMPDB_VERSION_STORE_PRESSURE'
            THEN
                'Investigate long-running snapshot/RCSI transactions and version-store consumers. Identify transactions preventing version cleanup before increasing TempDB capacity.'
            WHEN 'TEMPDB_INTERNAL_OBJECT_PRESSURE'
            THEN
                'Correlate TempDB internal-object growth with sorts, hashes, spools, worktables, and spill evidence. Correct the upstream query/estimate/memory problem when one is established.'
            WHEN 'TEMPDB_IO_LATENCY'
            THEN
                'Investigate TempDB file latency and storage placement together with the workload generating TempDB I/O. Confirm host/storage contention before changing SQL Server configuration.'
            ELSE
                'TempDB activity was observed but did not meet the threshold required to declare TempDB a root cause. Do not make a TempDB configuration change solely from this evidence.'
        END;

    INSERT dbo.RCA_TempDBEvidence
    (
          CaptureRunID
        , PressureSubtype
        , SampleCount
        , ObservationSeconds
        , PeakUsedPercent
        , AvgUsedPercent
        , HighSpaceSampleCount
        , PeakInternalObjectMB
        , AvgInternalObjectMB
        , HighInternalSampleCount
        , PeakVersionStoreMB
        , AvgVersionStoreMB
        , HighVersionStoreSampleCount
        , PeakLatchWaiters
        , AvgLatchWaiters
        , LatchPressureSampleCount
        , PeakPFSWaiters
        , PeakGAMWaiters
        , PeakSGAMWaiters
        , PeakTempDBReadLatencyMs
        , PeakTempDBWriteLatencyMs
        , TempDBIOLatencyPressure
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
        , @PeakUsedPercent
        , @AvgUsedPercent
        , @HighSpaceSampleCount
        , @PeakInternalObjectMB
        , @AvgInternalObjectMB
        , @HighInternalSampleCount
        , @PeakVersionStoreMB
        , @AvgVersionStoreMB
        , @HighVersionStoreSampleCount
        , @PeakLatchWaiters
        , @AvgLatchWaiters
        , @LatchPressureSampleCount
        , @PeakPFSWaiters
        , @PeakGAMWaiters
        , @PeakSGAMWaiters
        , @PeakTempDBReadLatencyMs
        , @PeakTempDBWriteLatencyMs
        , @TempDBIOLatencyPressure
        , @UpstreamCauseCategory
        , @RootCauseRole
        , @Confidence
        , @EvidenceSummary
        , @RecommendedAction
    );

    SELECT
          CaptureRunID = @CaptureRunID
        , TempDBCases = COUNT(*)
        , PrimaryCases =
            SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , HighConfidence =
            SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence =
            SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_TempDBEvidence
    WHERE CaptureRunID = @CaptureRunID;
END;
GO


/*==============================================================================
    6. FINAL CAUSE CANDIDATE INTEGRATION

    Complete replacement preserving all validated domains and appending TempDB.
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseCandidates
AS

SELECT
      p.CaptureRunID
    , CauseCategory = CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    , CauseDisplayName = CONVERT(nvarchar(200),N'Parameter-sensitive plan reuse')
    , RootCauseRole = CONVERT(varchar(20),'PRIMARY')
    , Confidence = p.Confidence
    , CorrelationKey = CONVERT(nvarchar(200),CONCAT(N'EXEC:',p.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID = p.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID = CONVERT(int,NULL)
    , ImpactedRequestCount = CONVERT(int,1)
    , BlockingDepth = CONVERT(int,NULL)
    , MaxObservedWaitMs = CONVERT(bigint,NULL)
    , DurationRatio = p.DurationRatio
    , CPURatio = p.CPURatio
    , LogicalReadRatio = p.LogicalReadRatio
    , EvidenceCount = p.SharedStatementPlanCount
    , PrimaryEvidence = p.EvidenceSummary
    , RecommendedAction =
        CONVERT
        (
            nvarchar(4000),
            N'Validate the distinct parameter distributions with measured plan alternatives and re-test the identical runtime parameter values.'
        )
FROM dbo.RCA_ParameterSensitivePlanEvidence AS p

UNION ALL

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
    , s.CardinalityMismatchCount + s.StatisticsRiskCount + s.LargeScanCount
    , s.EvidenceSummary
    , CONVERT
      (
          nvarchar(4000),
          N'Review the statistics used by the affected operators, validate estimate-versus-actual row counts, and re-test after the least invasive corrective change.'
      )
FROM dbo.RCA_StatisticsCardinalityEvidence AS s

UNION ALL

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
    , c.HighSqlCpuSampleCount + c.HighRunnableSampleCount
    , c.EvidenceSummary
    , CONVERT(nvarchar(4000),c.RecommendedAction)
FROM dbo.RCA_CPUSchedulerEvidence AS c

UNION ALL

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

SELECT
      t.CaptureRunID
    , CONVERT(varchar(80),'TEMPDB_PRESSURE_CONTENTION')
    , CONVERT(nvarchar(200),N'TempDB pressure / contention')
    , t.RootCauseRole
    , t.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'TEMPDB:',t.PressureSubtype))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,
        CASE WHEN t.PeakLatchWaiters > 0 THEN t.PeakLatchWaiters ELSE 1 END)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , t.SampleCount
    , t.EvidenceSummary
    , CONVERT(nvarchar(4000),t.RecommendedAction)
FROM dbo.RCA_TempDBEvidence AS t
WHERE t.PressureSubtype <> 'TEMPDB_ACTIVITY_ONLY';
GO


/*==============================================================================
    7. HUMAN-FACING OUTPUT INTEGRATION
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

    SET @AssessmentState =
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
            , Answer =
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
            , Summary =
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'No SQL Server root cause has reached the required evidence threshold yet. Evidence collection is still in progress, so this assessment may change as additional evidence is captured.'
                    ELSE 'The captured SQL Server evidence does not support a specific root cause strongly enough to explain the reported slowdown.'
                END;

        SELECT
              ReportSection='2 - WHAT DID SQL SERVER SHOW?'
            , Finding =
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'No PRIMARY root cause has reached HIGH or MEDIUM confidence yet.'
                    ELSE 'No PRIMARY root cause reached HIGH or MEDIUM confidence.'
                END
            , Meaning =
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'Evidence collection is still active. Do not make a SQL Server corrective change or declare SQL Server healthy solely from this interim assessment.'
                    ELSE 'Do not make a SQL Server corrective change merely because the application was reported as slow.'
                END;

        IF EXISTS (SELECT 1 FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID)
        BEGIN
            SELECT
                  ReportSection='3 - WHAT DID WE RULE OUT?'
                , Hypothesis='I/O latency / storage pressure'
                , Assessment =
                    CASE
                        WHEN EXISTS
                        (
                            SELECT 1
                            FROM dbo.RCA_IOStorageEvidence
                            WHERE CaptureRunID=@CaptureRunID
                              AND (ReadLatencyPressure=1 OR WriteLatencyPressure=1)
                        )
                            THEN 'EVIDENCE EXISTS BUT DID NOT BECOME PRIMARY'
                        ELSE 'NOT SUPPORTED'
                    END
                , MaxReadLatencyMs=
                    (SELECT MAX(AvgReadLatencyMs) FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID)
                , MaxWriteLatencyMs=
                    (SELECT MAX(AvgWriteLatencyMs) FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID)
                , TotalReadMB=
                    (SELECT SUM(DeltaReadMB) FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID)
                , TotalWriteMB=
                    (SELECT SUM(DeltaWriteMB) FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID);
        END;

        IF EXISTS (SELECT 1 FROM dbo.RCA_TempDBEvidence WHERE CaptureRunID=@CaptureRunID)
        BEGIN
            SELECT
                  ReportSection='3 - WHAT DID WE RULE OUT?'
                , Hypothesis='TempDB pressure / contention'
                , Assessment =
                    CASE
                        WHEN EXISTS
                        (
                            SELECT 1
                            FROM dbo.RCA_TempDBEvidence
                            WHERE CaptureRunID=@CaptureRunID
                              AND PressureSubtype<>'TEMPDB_ACTIVITY_ONLY'
                        )
                            THEN 'EVIDENCE EXISTS BUT DID NOT BECOME PRIMARY'
                        ELSE 'NOT SUPPORTED'
                    END
                , PressureSubtype=
                    (SELECT TOP (1) PressureSubtype
                     FROM dbo.RCA_TempDBEvidence
                     WHERE CaptureRunID=@CaptureRunID
                     ORDER BY TempDBEvidenceID DESC)
                , PeakUsedPercent=
                    (SELECT MAX(PeakUsedPercent) FROM dbo.RCA_TempDBEvidence WHERE CaptureRunID=@CaptureRunID)
                , PeakLatchWaiters=
                    (SELECT MAX(PeakLatchWaiters) FROM dbo.RCA_TempDBEvidence WHERE CaptureRunID=@CaptureRunID);
        END;

        SELECT
              ReportSection='4 - WHAT SHOULD I DO?'
            , Step1 =
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'Allow the active evidence capture to continue.'
                    ELSE 'Confirm that the user-reported slowdown occurred inside this capture window.'
                END
            , Step2 =
                'Do not change SQL Server configuration, indexes, storage, memory, TempDB, or sessions without supporting evidence.'
            , Step3 =
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'Continue correlating the reported slowdown with the active capture window while additional evidence is collected.'
                    ELSE 'If SQL Server evidence remains normal, investigate the application tier, API/web services, network latency, external dependencies, or client-side response time.'
                END
            , Step4 =
                CASE
                    WHEN @AssessmentState='PRELIMINARY'
                        THEN 'When capture completes, rerun the RCA analysis and use the FINAL assessment for incident conclusions.'
                    ELSE 'If the slowdown recurs, capture the incident while it is actively occurring and rerun the RCA analysis.'
                END;
        RETURN;
    END;

    SET @AttributionType =
        CASE
            WHEN @CauseCategory='BLOCKING_WAIT_CHAIN' THEN 'BLOCKING CHAIN'
            WHEN @CauseCategory='IO_STORAGE_PRESSURE' THEN 'DATABASE FILE'
            WHEN @CauseCategory='CPU_SCHEDULER_PRESSURE' THEN 'CPU / SCHEDULER'
            WHEN @CauseCategory='TEMPDB_PRESSURE_CONTENTION' THEN 'TEMPDB'
            WHEN @ImpactedExecutionEvidenceID IS NOT NULL THEN 'SQL EXECUTION'
            ELSE 'SYSTEM LEVEL'
        END;

    SET @HumanAnswer =
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
            WHEN 'MEMORY_GRANT_SPILL'
                THEN 'The slowdown was caused by a query memory grant / spill problem. The affected query could not complete its memory-intensive work entirely in memory.'
            WHEN 'PARAMETER_SENSITIVE_PLAN_REUSE'
                THEN 'The slowdown was caused by parameter-sensitive plan reuse. SQL Server reused an execution plan that was inappropriate for the runtime parameter values.'
            WHEN 'STATISTICS_CARDINALITY_REGRESSION'
                THEN 'The slowdown was caused by a statistics / cardinality estimation problem that led SQL Server to choose an inefficient execution strategy.'
            ELSE CONCAT('The RCA engine identified ',COALESCE(@CauseDisplayName,@CauseCategory),' as the primary cause of the slowdown.')
        END;

    IF @AssessmentState='PRELIMINARY'
        SET @HumanAnswer =
            CONCAT('PRELIMINARY ASSESSMENT: ',@HumanAnswer,
                   ' Evidence collection is still in progress. This conclusion may change as additional evidence is captured.');

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
                ELSE 'Validate the recommended action against the technical evidence before making a production change.'
            END;

    IF EXISTS (SELECT 1 FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        SELECT
              ReportSection='5 - OTHER HYPOTHESES EVALUATED'
            , Hypothesis='I/O latency / storage pressure'
            , Assessment=
                CASE
                    WHEN EXISTS
                    (
                        SELECT 1
                        FROM dbo.RCA_IOStorageEvidence
                        WHERE CaptureRunID=@CaptureRunID
                          AND (ReadLatencyPressure=1 OR WriteLatencyPressure=1)
                    )
                        THEN 'SUPPORTED'
                    ELSE 'NOT SUPPORTED'
                END
            , MaxReadLatencyMs=
                (SELECT MAX(AvgReadLatencyMs) FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID)
            , MaxWriteLatencyMs=
                (SELECT MAX(AvgWriteLatencyMs) FROM dbo.RCA_IOStorageEvidence WHERE CaptureRunID=@CaptureRunID);
    END;

    IF EXISTS (SELECT 1 FROM dbo.RCA_TempDBEvidence WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        SELECT
              ReportSection='5 - OTHER HYPOTHESES EVALUATED'
            , Hypothesis='TempDB pressure / contention'
            , Assessment=
                CASE
                    WHEN EXISTS
                    (
                        SELECT 1
                        FROM dbo.RCA_TempDBEvidence
                        WHERE CaptureRunID=@CaptureRunID
                          AND PressureSubtype<>'TEMPDB_ACTIVITY_ONLY'
                    )
                        THEN 'SUPPORTED'
                    ELSE 'NOT SUPPORTED'
                END
            , PressureSubtype=
                (SELECT TOP (1) PressureSubtype
                 FROM dbo.RCA_TempDBEvidence
                 WHERE CaptureRunID=@CaptureRunID
                 ORDER BY TempDBEvidenceID DESC)
            , PeakUsedPercent=
                (SELECT MAX(PeakUsedPercent) FROM dbo.RCA_TempDBEvidence WHERE CaptureRunID=@CaptureRunID)
            , PeakLatchWaiters=
                (SELECT MAX(PeakLatchWaiters) FROM dbo.RCA_TempDBEvidence WHERE CaptureRunID=@CaptureRunID);
    END;
END;
GO


/*==============================================================================
    8. DEPLOYMENT VALIDATION
==============================================================================*/

SELECT
      TempDBSnapshotTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_TempDBSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBSampler =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunTempDBSampler',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_TempDBEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBEvidenceView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_TempDBEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , TempDBDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildTempDBEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseIntegration =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HumanOutputIntegration =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
    9. EXISTING-DOMAIN REGRESSION MATRIX
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
        CASE WHEN CauseCategory=ExpectedCause THEN 'PASS' ELSE 'REVIEW' END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO
