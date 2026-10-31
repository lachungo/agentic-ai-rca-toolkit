USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  46_RCA_Why_Is_Database_Slow_v1.sql

  PURPOSE
  -------
  Create the simple, human-readable RCA experience:

      "Why is DB1 slow?"

  This is a PRESENTATION LAYER ONLY.

  It does NOT:
      - change XE capture
      - rebuild evidence
      - change detector thresholds
      - change root-cause ranking
      - promote a cause
      - start a new capture

  It consumes the existing RCA evidence and final cause-ranking layer.

  DEFAULT UX
  ----------
      EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow
           @CaptureRunID = 39;

  OPTIONAL TECHNICAL DETAIL
  -------------------------
      EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow
           @CaptureRunID = 39,
           @IncludeTechnicalDetail = 1;

==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlow
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------------------------------
    -- 1. Validate the capture.
    ---------------------------------------------------------------------------
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
    )
    BEGIN
        DECLARE @MissingCapture nvarchar(2048) =
            CONCAT(N'CaptureRunID ', @CaptureRunID, N' does not exist.');

        THROW 54600, @MissingCapture, 1;
    END;

    ---------------------------------------------------------------------------
    -- 2. Incident context.
    ---------------------------------------------------------------------------
    DECLARE
          @DatabaseName sysname
        , @CaptureReason nvarchar(4000)
        , @StartTimeUTC datetime2
        , @EndTimeUTC datetime2
        , @CaptureStatus varchar(100)
        , @IncidentDescription nvarchar(4000)
        , @RequestedBy nvarchar(512)
        , @StartedFromHost nvarchar(512)
        , @StartedFromProgram nvarchar(1024);

    SELECT
          @DatabaseName = cr.TargetDatabase
        , @CaptureReason = cr.CaptureReason
        , @StartTimeUTC = cr.StartTimeUTC
        , @EndTimeUTC = cr.EndTimeUTC
        , @CaptureStatus = cr.CaptureStatus
    FROM dbo.RCA_CaptureRun AS cr
    WHERE cr.CaptureRunID = @CaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NOT NULL
    BEGIN
        SELECT TOP (1)
              @DatabaseName =
                  COALESCE(NULLIF(ic.RequestedDatabaseName,N''), @DatabaseName)
            , @IncidentDescription = ic.IncidentDescription
            , @RequestedBy = ic.RequestedBy
            , @StartedFromHost = ic.StartedFromHost
            , @StartedFromProgram = ic.StartedFromProgram
        FROM dbo.RCA_IncidentContext AS ic
        WHERE ic.CaptureRunID = @CaptureRunID;
    END;

    SET @DatabaseName = COALESCE(NULLIF(@DatabaseName,N''),N'Database');

    ---------------------------------------------------------------------------
    -- 3. Final supported cause.
    --
    -- IMPORTANT:
    -- We do not manufacture a cause here.  Only an existing PRIMARY
    -- MEDIUM/HIGH-confidence cause from vw_RCA_FinalCauseRanking can become
    -- the answer.
    ---------------------------------------------------------------------------
    DECLARE
          @CauseCategory varchar(100)
        , @CauseDisplayName nvarchar(512)
        , @RootCauseRole varchar(30)
        , @Confidence varchar(20)
        , @CorrelationKey nvarchar(512)
        , @ImpactedRequestCount int
        , @EvidenceCount int
        , @PrimaryEvidence nvarchar(4000)
        , @CauseRecommendedAction nvarchar(4000);

    IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL
    BEGIN
        SELECT TOP (1)
              @CauseCategory = f.CauseCategory
            , @CauseDisplayName = f.CauseDisplayName
            , @RootCauseRole = f.RootCauseRole
            , @Confidence = f.Confidence
            , @CorrelationKey = f.CorrelationKey
            , @ImpactedRequestCount = f.ImpactedRequestCount
            , @EvidenceCount = f.EvidenceCount
            , @PrimaryEvidence = f.PrimaryEvidence
            , @CauseRecommendedAction = f.RecommendedAction
        FROM dbo.vw_RCA_FinalCauseRanking AS f
        WHERE f.CaptureRunID = @CaptureRunID
          AND f.RootCauseRole = 'PRIMARY'
          AND f.Confidence IN ('HIGH','MEDIUM')
        ORDER BY
              CASE f.Confidence WHEN 'HIGH' THEN 1 ELSE 2 END
            , f.EvidenceCount DESC
            , f.ImpactedRequestCount DESC;
    END;

    DECLARE @RootCauseConfirmed bit =
        CASE WHEN @CauseCategory IS NOT NULL THEN 1 ELSE 0 END;

    ---------------------------------------------------------------------------
    -- 4. Highest-impact observed execution.
    ---------------------------------------------------------------------------
    DECLARE
          @ExecutionEvidenceID bigint
        , @ExecutionTimeUTC datetime2
        , @SessionID int
        , @ObjectName nvarchar(1024)
        , @HostName nvarchar(512)
        , @ProgramName nvarchar(1024)
        , @LoginName nvarchar(512)
        , @CPUms decimal(19,3)
        , @DurationMs decimal(19,3)
        , @LogicalReads bigint
        , @PhysicalReads bigint
        , @Writes bigint
        , @TotalRows bigint;

    IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
    BEGIN
        SELECT TOP (1)
              @ExecutionEvidenceID = e.ExecutionEvidenceID
            , @ExecutionTimeUTC = e.EventTimeUTC
            , @SessionID = e.SessionID
            , @ObjectName = e.ObjectName
            , @HostName = e.HostName
            , @ProgramName = e.ProgramName
            , @LoginName = e.LoginName
            , @CPUms = e.CPUms
            , @DurationMs = e.DurationMs
            , @LogicalReads = e.LogicalReads
            , @PhysicalReads = e.PhysicalReads
            , @Writes = e.Writes
            , @TotalRows = e.TotalRows
        FROM dbo.RCA_ExecutionEvidence AS e
        WHERE e.CaptureRunID = @CaptureRunID
        ORDER BY
              ISNULL(e.CPUms,0) DESC
            , ISNULL(e.DurationMs,0) DESC
            , ISNULL(e.LogicalReads,0) DESC
            , e.ExecutionEvidenceID;
    END;

    ---------------------------------------------------------------------------
    -- 5. Blocking detail for a supported blocking root cause.
    ---------------------------------------------------------------------------
    DECLARE
          @VictimSessionID int
        , @ImmediateBlockerSessionID int
        , @HeadBlockerSessionID int
        , @WaitType nvarchar(512)
        , @MaxWaitDurationMs bigint
        , @BlockingDepth int
        , @BlockingSampleCount int
        , @VictimHostName nvarchar(512)
        , @VictimProgramName nvarchar(1024)
        , @VictimLoginName nvarchar(512);

    IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL
    BEGIN
        SELECT TOP (1)
              @VictimSessionID = b.VictimSessionID
            , @ImmediateBlockerSessionID = b.ImmediateBlockerSessionID
            , @HeadBlockerSessionID = b.HeadBlockerSessionID
            , @WaitType = b.WaitType
            , @MaxWaitDurationMs = b.WaitDurationMs
            , @BlockingDepth = b.BlockingDepth
            , @BlockingSampleCount = b.SampleCount
            , @VictimHostName = b.VictimHostName
            , @VictimProgramName = b.VictimProgramName
            , @VictimLoginName = b.VictimLoginName
        FROM dbo.RCA_BlockingEvidence AS b
        WHERE b.CaptureRunID = @CaptureRunID
        ORDER BY
              CASE WHEN b.RootCauseRole = 'PRIMARY' THEN 1 ELSE 2 END
            , CASE b.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , b.WaitDurationMs DESC
            , b.BlockingEvidenceID;
    END;

    ---------------------------------------------------------------------------
    -- 6. Server-health context.
    ---------------------------------------------------------------------------
    DECLARE
          @ServerSamples int = 0
        , @PeakSqlCpu decimal(19,6)
        , @AvgSqlCpu decimal(19,6)
        , @PeakOtherCpu decimal(19,6)
        , @LowestSystemIdle decimal(19,6)
        , @PeakRunnableTasks int
        , @LowestBufferCacheHitRatio decimal(19,6)
        , @AvgBufferCacheHitRatio decimal(19,6)
        , @LowestPLE bigint;

    IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NOT NULL
    BEGIN
        SELECT
              @ServerSamples = COUNT(*)
            , @PeakSqlCpu = MAX(SqlCpuPercent)
            , @AvgSqlCpu = AVG(CONVERT(decimal(19,6),SqlCpuPercent))
            , @PeakOtherCpu = MAX(OtherCpuPercent)
            , @LowestSystemIdle = MIN(SystemIdlePercent)
            , @PeakRunnableTasks = MAX(RunnableTasks)
            , @LowestBufferCacheHitRatio = MIN(BufferCacheHitRatio)
            , @AvgBufferCacheHitRatio =
                AVG(CONVERT(decimal(19,6),BufferCacheHitRatio))
            , @LowestPLE = MIN(PageLifeExpectancySeconds)
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID = @CaptureRunID;
    END;

    ---------------------------------------------------------------------------
    -- 7. Plan findings summary.
    ---------------------------------------------------------------------------
    DECLARE
          @HighPlanFindings int = 0
        , @MediumPlanFindings int = 0
        , @LowPlanFindings int = 0
        , @LargeScanFindings int = 0
        , @ImplicitConversionFindings int = 0
        , @CardinalityMismatchFindings int = 0
        , @StatisticsRiskFindings int = 0;

    IF OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NOT NULL
    BEGIN
        SELECT
              @HighPlanFindings =
                  SUM(CASE WHEN Severity = 'HIGH' THEN 1 ELSE 0 END)
            , @MediumPlanFindings =
                  SUM(CASE WHEN Severity = 'MEDIUM' THEN 1 ELSE 0 END)
            , @LowPlanFindings =
                  SUM(CASE WHEN Severity = 'LOW' THEN 1 ELSE 0 END)
            , @LargeScanFindings =
                  SUM(CASE WHEN FindingType = 'LARGE_SCAN' THEN 1 ELSE 0 END)
            , @ImplicitConversionFindings =
                  SUM(CASE WHEN FindingType = 'IMPLICIT_CONVERSION' THEN 1 ELSE 0 END)
            , @CardinalityMismatchFindings =
                  SUM(CASE WHEN FindingType = 'CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
            , @StatisticsRiskFindings =
                  SUM(CASE WHEN FindingType = 'STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID = @CaptureRunID;
    END;

    SET @HighPlanFindings = ISNULL(@HighPlanFindings,0);
    SET @MediumPlanFindings = ISNULL(@MediumPlanFindings,0);
    SET @LowPlanFindings = ISNULL(@LowPlanFindings,0);
    SET @LargeScanFindings = ISNULL(@LargeScanFindings,0);
    SET @ImplicitConversionFindings = ISNULL(@ImplicitConversionFindings,0);
    SET @CardinalityMismatchFindings = ISNULL(@CardinalityMismatchFindings,0);
    SET @StatisticsRiskFindings = ISNULL(@StatisticsRiskFindings,0);

    ---------------------------------------------------------------------------
    -- 8. Translate evidence into plain English.
    ---------------------------------------------------------------------------
    DECLARE
          @Question nvarchar(512)
        , @Answer varchar(50)
        , @RootCause nvarchar(512)
        , @WhatHappened nvarchar(max)
        , @WhyWeBelieveIt nvarchar(max)
        , @WhoOrWhatCausedIt nvarchar(max)
        , @Impact nvarchar(max)
        , @WhatShouldIDo nvarchar(max)
        , @DoNotChangeYet nvarchar(max)
        , @TechnicalEvidence nvarchar(max);

    SET @Question = CONCAT(N'Why is ',@DatabaseName,N' slow?');

    IF @RootCauseConfirmed = 1
    BEGIN
        SET @Answer = 'ROOT CAUSE IDENTIFIED';
        SET @RootCause = COALESCE(@CauseDisplayName,@CauseCategory);

        IF @CauseCategory = 'BLOCKING_WAIT_CHAIN'
        BEGIN
            SET @WhatHappened =
                CONCAT(
                    @DatabaseName,
                    N' experienced blocking during the incident window. ',
                    CASE
                      WHEN @VictimSessionID IS NOT NULL
                       AND @HeadBlockerSessionID IS NOT NULL
                      THEN CONCAT(
                            N'Session ',@VictimSessionID,
                            N' was blocked by session ',@HeadBlockerSessionID,N'. '
                           )
                      ELSE N'A blocking chain was repeatedly observed. '
                    END,
                    CASE
                      WHEN @WaitType IS NOT NULL
                      THEN CONCAT(N'The blocked request was waiting on ',@WaitType,N'. ')
                      ELSE N''
                    END,
                    CASE
                      WHEN @BlockingSampleCount IS NOT NULL
                      THEN CONCAT(
                            N'The condition was observed across ',
                            @BlockingSampleCount,N' samples. '
                           )
                      ELSE N''
                    END,
                    CASE
                      WHEN @MaxWaitDurationMs IS NOT NULL
                      THEN CONCAT(
                            N'The maximum observed wait was ',
                            CONVERT(decimal(19,1),@MaxWaitDurationMs / 1000.0),
                            N' seconds.'
                           )
                      ELSE N''
                    END
                );

            SET @WhyWeBelieveIt =
                CONCAT(
                    N'The RCA engine classified blocking / wait-chain contention ',
                    N'as the PRIMARY cause with ',@Confidence,N' confidence. ',
                    CASE
                      WHEN @EvidenceCount IS NOT NULL
                      THEN CONCAT(
                            N'The conclusion is supported by ',
                            @EvidenceCount,N' persisted evidence observation(s). '
                           )
                      ELSE N''
                    END,
                    CASE
                      WHEN @HeadBlockerSessionID IS NOT NULL
                      THEN CONCAT(
                            N'Session ',@HeadBlockerSessionID,
                            N' was identified as the head blocker'
                           )
                      ELSE N'The blocking chain contained an identifiable blocker'
                    END,
                    CASE
                      WHEN @BlockingDepth IS NOT NULL
                      THEN CONCAT(
                            N', with a maximum blocking depth of ',
                            @BlockingDepth
                           )
                      ELSE N''
                    END,
                    N'. The conclusion comes from persisted causal evidence, ',
                    N'not simply from observing an expensive query.'
                );

            SET @WhoOrWhatCausedIt =
                CONCAT(
                    N'Head blocker: session ',
                    COALESCE(CONVERT(varchar(20),@HeadBlockerSessionID),'unknown'),
                    N'. Immediate blocker: session ',
                    COALESCE(CONVERT(varchar(20),@ImmediateBlockerSessionID),'unknown'),
                    N'. Victim: session ',
                    COALESCE(CONVERT(varchar(20),@VictimSessionID),'unknown'),
                    N'.',
                    CASE WHEN @VictimHostName IS NOT NULL
                         THEN CONCAT(N' Victim host: ',@VictimHostName,N'.')
                         ELSE N'' END,
                    CASE WHEN @VictimProgramName IS NOT NULL
                         THEN CONCAT(N' Program: ',@VictimProgramName,N'.')
                         ELSE N'' END,
                    CASE WHEN @VictimLoginName IS NOT NULL
                         THEN CONCAT(N' Login: ',@VictimLoginName,N'.')
                         ELSE N'' END
                );

            SET @Impact =
                CONCAT(
                    CASE
                      WHEN @ImpactedRequestCount IS NOT NULL
                      THEN CONCAT(
                            @ImpactedRequestCount,
                            N' distinct request(s) were associated with the supported blocking cause. '
                           )
                      ELSE N''
                    END,
                    CASE
                      WHEN @MaxWaitDurationMs IS NOT NULL
                      THEN CONCAT(
                            N'Maximum observed blocking wait: ',
                            CONVERT(decimal(19,1),@MaxWaitDurationMs / 1000.0),
                            N' seconds. '
                           )
                      ELSE N''
                    END,
                    CASE
                      WHEN @BlockingSampleCount IS NOT NULL
                      THEN CONCAT(
                            N'Blocking persisted across ',
                            @BlockingSampleCount,N' samples.'
                           )
                      ELSE N''
                    END
                );

            SET @WhatShouldIDo =
                CONCAT(
                    N'Investigate head blocker session ',
                    COALESCE(CONVERT(varchar(20),@HeadBlockerSessionID),'identified by the RCA evidence'),
                    N'. Determine which transaction retained the required locks, ',
                    N'who or what submitted it, how long the transaction remained open, ',
                    N'and whether it can commit sooner or perform less work inside the transaction. ',
                    N'Review the blocker SQL and application transaction pattern before changing ',
                    N'database or server configuration.'
                );
        END
        ELSE
        BEGIN
            SET @WhatHappened =
                CONCAT(
                    N'During the incident window, the RCA engine found sufficient ',
                    N'correlated evidence to identify ',
                    COALESCE(@CauseDisplayName,@CauseCategory),
                    N' as the primary cause of the reported slowdown.'
                );

            SET @WhyWeBelieveIt =
                CONCAT(
                    N'The final cause-ranking layer classified this condition as PRIMARY ',
                    N'with ',@Confidence,N' confidence. ',
                    COALESCE(@PrimaryEvidence,N'')
                );

            SET @WhoOrWhatCausedIt =
                COALESCE(
                    @PrimaryEvidence,
                    N'The responsible component is identified by the correlated RCA evidence.'
                );

            SET @Impact =
                CONCAT(
                    COALESCE(CONVERT(varchar(20),@ImpactedRequestCount),'0'),
                    N' impacted request(s); ',
                    COALESCE(CONVERT(varchar(20),@EvidenceCount),'0'),
                    N' supporting evidence item(s).'
                );

            SET @WhatShouldIDo =
                COALESCE(
                    @CauseRecommendedAction,
                    N'Investigate the supported primary cause and correct the responsible workload or resource condition.'
                );
        END;
    END
    ELSE
    BEGIN
        SET @Answer = 'ROOT CAUSE NOT CONFIRMED';
        SET @RootCause = N'No supported primary cause';

        SET @WhatHappened =
            CONCAT(
                N'SQL Server activity was captured during the reported slowdown for ',
                @DatabaseName,N'. ',
                CASE
                  WHEN @ExecutionEvidenceID IS NOT NULL
                  THEN CONCAT(
                        N'The highest-impact observed execution was Evidence ID ',
                        @ExecutionEvidenceID,
                        CASE WHEN @SessionID IS NOT NULL
                             THEN CONCAT(N' on session ',@SessionID)
                             ELSE N'' END,
                        N'. '
                       )
                  ELSE N''
                END,
                N'However, the available evidence does not establish that the ',
                N'observed workload caused the reported database slowdown.'
            );

        SET @WhyWeBelieveIt =
            CONCAT(
                N'No PRIMARY MEDIUM/HIGH-confidence root cause exists in the final ',
                N'cause ranking for this capture. ',
                CASE WHEN @LargeScanFindings > 0
                     THEN CONCAT(
                          N'The plans contained ',@LargeScanFindings,
                          N' large-scan finding(s), but a scan is an observation rather than proof of causation. '
                          )
                     ELSE N'' END,
                CASE WHEN @ImplicitConversionFindings > 0
                     THEN CONCAT(
                          N'There were ',@ImplicitConversionFindings,
                          N' operator-local implicit-conversion finding(s), but they were not independently established as the incident cause. '
                          )
                     ELSE N'' END,
                CASE WHEN @StatisticsRiskFindings > 0
                     THEN CONCAT(
                          N'There were ',@StatisticsRiskFindings,
                          N' statistics-risk observation(s), but the evidence did not justify promoting statistics as the root cause. '
                          )
                     ELSE N'' END,
                N'The RCA engine therefore preserved uncertainty rather than manufacturing attribution.'
            );

        SET @WhoOrWhatCausedIt =
            CONCAT(
                N'Not confirmed.',
                CASE WHEN @HostName IS NOT NULL
                     THEN CONCAT(N' Observed workload originated from host ',@HostName,N'.')
                     ELSE N'' END,
                CASE WHEN @ProgramName IS NOT NULL
                     THEN CONCAT(N' Program: ',@ProgramName,N'.')
                     ELSE N'' END,
                CASE WHEN @LoginName IS NOT NULL
                     THEN CONCAT(N' Login: ',@LoginName,N'.')
                     ELSE N'' END
            );

        SET @Impact =
            CONCAT(
                CASE WHEN @CPUms IS NOT NULL
                     THEN CONCAT(N'Highest observed execution CPU: ',@CPUms,N' ms. ')
                     ELSE N'' END,
                CASE WHEN @DurationMs IS NOT NULL
                     THEN CONCAT(N'Duration: ',@DurationMs,N' ms. ')
                     ELSE N'' END,
                CASE WHEN @LogicalReads IS NOT NULL
                     THEN CONCAT(N'Logical reads: ',@LogicalReads,N'. ')
                     ELSE N'' END,
                N'These measurements describe observed workload; they do not by themselves prove incident causation.'
            );

        SET @WhatShouldIDo =
            CONCAT(
                N'Correlate the reported user or application action with the captured SQL request, ',
                N'host, login, session, parameter values, and exact execution time. ',
                N'Confirm whether the business request genuinely required the observed workload ',
                N'before considering query, indexing, or configuration changes.'
            );
    END;

    SET @DoNotChangeYet =
        CONCAT(
            N'Do not make server-wide SQL configuration changes from this capture alone. ',
            N'Do not change MAXDOP, server memory, cost threshold, or similar instance settings ',
            N'without independent evidence. Do not update statistics or add indexes merely because ',
            N'a plan observation exists; first validate that it contributed to the incident.'
        );

    SET @TechnicalEvidence =
        CONCAT(
            N'Capture ',@CaptureRunID,
            N'; database ',@DatabaseName,
            N'; status ',COALESCE(@CaptureStatus,'unknown'),
            N'; window ',
            COALESCE(CONVERT(varchar(33),@StartTimeUTC,126),'unknown'),
            N' to ',
            COALESCE(CONVERT(varchar(33),@EndTimeUTC,126),'unknown'),
            N'; server samples ',@ServerSamples,
            N'; high/medium/low plan findings ',
            @HighPlanFindings,N'/',@MediumPlanFindings,N'/',@LowPlanFindings,
            N'; large scans ',@LargeScanFindings,
            N'; implicit conversions ',@ImplicitConversionFindings,
            N'; cardinality mismatches ',@CardinalityMismatchFindings,
            N'; statistics risks ',@StatisticsRiskFindings,
            N'.'
        );

    ---------------------------------------------------------------------------
    -- 9. THE PRODUCT: one human-readable answer.
    ---------------------------------------------------------------------------
    SELECT
          Question = @Question
        , Answer = @Answer
        , RootCause = @RootCause
        , Confidence =
            CASE
              WHEN @RootCauseConfirmed = 1 THEN @Confidence
              ELSE 'N/A'
            END
        , WhatHappened = @WhatHappened
        , WhyWeBelieveIt = @WhyWeBelieveIt
        , WhoOrWhatCausedIt = @WhoOrWhatCausedIt
        , Impact = @Impact
        , WhatShouldIDo = @WhatShouldIDo
        , DoNotChangeYet = @DoNotChangeYet
        , CaptureRunID = @CaptureRunID
        , DatabaseName = @DatabaseName
        , IncidentStartUTC = @StartTimeUTC
        , IncidentEndUTC = @EndTimeUTC;

    ---------------------------------------------------------------------------
    -- 10. Optional DBA drill-down.
    --
    -- Default stays one result set. Technical mode deliberately exposes the
    -- supporting facts after the human answer.
    ---------------------------------------------------------------------------
    IF @IncludeTechnicalDetail = 1
    BEGIN
        SELECT
              TechnicalSection = 'INCIDENT CONTEXT'
            , CaptureRunID = @CaptureRunID
            , DatabaseName = @DatabaseName
            , CaptureReason = @CaptureReason
            , IncidentDescription = @IncidentDescription
            , RequestedBy = @RequestedBy
            , StartedFromHost = @StartedFromHost
            , StartedFromProgram = @StartedFromProgram
            , CaptureStatus = @CaptureStatus
            , StartTimeUTC = @StartTimeUTC
            , EndTimeUTC = @EndTimeUTC;

        SELECT
              TechnicalSection = 'ROOT CAUSE EVIDENCE'
            , CauseCategory = @CauseCategory
            , CauseDisplayName = @CauseDisplayName
            , RootCauseRole = @RootCauseRole
            , Confidence = @Confidence
            , CorrelationKey = @CorrelationKey
            , ImpactedRequestCount = @ImpactedRequestCount
            , EvidenceCount = @EvidenceCount
            , PrimaryEvidence = @PrimaryEvidence
            , RecommendedAction = @CauseRecommendedAction;

        SELECT
              TechnicalSection = 'HIGHEST IMPACT OBSERVED EXECUTION'
            , ExecutionEvidenceID = @ExecutionEvidenceID
            , EventTimeUTC = @ExecutionTimeUTC
            , SessionID = @SessionID
            , ObjectName = @ObjectName
            , HostName = @HostName
            , ProgramName = @ProgramName
            , LoginName = @LoginName
            , CPUms = @CPUms
            , DurationMs = @DurationMs
            , LogicalReads = @LogicalReads
            , PhysicalReads = @PhysicalReads
            , Writes = @Writes
            , TotalRows = @TotalRows;

        SELECT
              TechnicalSection = 'BLOCKING'
            , VictimSessionID = @VictimSessionID
            , ImmediateBlockerSessionID = @ImmediateBlockerSessionID
            , HeadBlockerSessionID = @HeadBlockerSessionID
            , WaitType = @WaitType
            , MaxWaitDurationMs = @MaxWaitDurationMs
            , BlockingDepth = @BlockingDepth
            , SampleCount = @BlockingSampleCount
            , VictimHostName = @VictimHostName
            , VictimProgramName = @VictimProgramName
            , VictimLoginName = @VictimLoginName;

        SELECT
              TechnicalSection = 'SERVER HEALTH'
            , ServerSamples = @ServerSamples
            , PeakSqlCpuPercent = @PeakSqlCpu
            , AvgSqlCpuPercent = @AvgSqlCpu
            , PeakOtherCpuPercent = @PeakOtherCpu
            , LowestSystemIdlePercent = @LowestSystemIdle
            , PeakRunnableTasks = @PeakRunnableTasks
            , LowestBufferCacheHitRatio = @LowestBufferCacheHitRatio
            , AvgBufferCacheHitRatio = @AvgBufferCacheHitRatio
            , LowestPLESeconds = @LowestPLE;

        SELECT
              TechnicalSection = 'PLAN FINDINGS'
            , HighFindings = @HighPlanFindings
            , MediumFindings = @MediumPlanFindings
            , LowFindings = @LowPlanFindings
            , LargeScanFindings = @LargeScanFindings
            , ImplicitConversionFindings = @ImplicitConversionFindings
            , CardinalityMismatchFindings = @CardinalityMismatchFindings
            , StatisticsRiskFindings = @StatisticsRiskFindings
            , EvidenceSummary = @TechnicalEvidence;
    END;
END;
GO


/*==============================================================================
  FRIENDLY ALIAS

  This lets us evolve the internal procedure name later without changing the
  DBA-facing command.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExplainSlowness
      @CaptureRunID bigint
    , @IncludeTechnicalDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_WhyIsDatabaseSlow
         @CaptureRunID = @CaptureRunID,
         @IncludeTechnicalDetail = @IncludeTechnicalDetail;
END;
GO


/*==============================================================================
  DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '1 - SCRIPT 46 DEPLOYMENT'
    , WhyIsDatabaseSlow =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainSlowness',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PresentationLayerOnly = 'YES'
    , SourceEvidenceModified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , NewCaptureStarted = 'NO';
GO


/*==============================================================================
  VALIDATE THE TWO EXISTING EXPERIENCES

  Capture 38 = uncertainty / negative-control case
  Capture 39 = blocking / positive root-cause case

  Each execution returns ONE result set.
==============================================================================*/

EXEC dbo.usp_RCA_WhyIsDatabaseSlow
     @CaptureRunID = 38,
     @IncludeTechnicalDetail = 0;
GO

EXEC dbo.usp_RCA_WhyIsDatabaseSlow
     @CaptureRunID = 39,
     @IncludeTechnicalDetail = 0;
GO


/*==============================================================================
  NORMAL DBA USAGE
  ----------------

  EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow
       @CaptureRunID = <CaptureRunID>;

  or:

  EXEC DBA.dbo.usp_RCA_ExplainSlowness
       @CaptureRunID = <CaptureRunID>;

  For DBA drill-down:

  EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow
       @CaptureRunID = <CaptureRunID>,
       @IncludeTechnicalDetail = 1;

==============================================================================*/
