USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    40_RCA_Executive_Summary_v1.sql

    PURPOSE
    -------
    Adds a concise, human-first presentation layer to the RCA utility.

    This DOES NOT replace the detailed User Experience report created in Script 39.
    It gives the DBA / architect / leadership team one first result set answering:

        - Was a root cause confirmed?
        - What workload was observed?
        - Who/what submitted it?
        - What did the actual plan show?
        - Was the scan selective or did the query actually need most rows?
        - Were cardinality, statistics, spill, CPU, scheduler, or memory problems proven?
        - What should we do next?
        - What should we NOT change yet?

    SAFETY
    ------
    * Read-only reporting layer.
    * Does not modify captured evidence.
    * Does not alter detector thresholds.
    * Does not promote LOW plan observations to root cause.
    * A large scan is not labeled causal merely because it is large.
    * Statistics sampling alone is not labeled causal.
    * Implicit conversion observations alone are not labeled causal.
    * Server-wide changes are not recommended without supporting evidence.
==============================================================================*/


/*------------------------------------------------------------------------------
    0. PRE-FLIGHT
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.usp_RCA_UserExperience', N'P') IS NULL
BEGIN
    THROW 51000,
          'Script 40 requires dbo.usp_RCA_UserExperience from Script 39.',
          1;
END;
GO

IF OBJECT_ID(N'dbo.RCA_CaptureRun', N'U') IS NULL
BEGIN
    THROW 51000, 'Required table dbo.RCA_CaptureRun was not found.', 1;
END;
GO

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence', N'U') IS NULL
BEGIN
    THROW 51000, 'Required table dbo.RCA_ExecutionEvidence was not found.', 1;
END;
GO

IF OBJECT_ID(N'dbo.RCA_PlanEvidence', N'U') IS NULL
BEGIN
    THROW 51000, 'Required table dbo.RCA_PlanEvidence was not found.', 1;
END;
GO

IF OBJECT_ID(N'dbo.RCA_PlanOperator', N'U') IS NULL
BEGIN
    THROW 51000, 'Required table dbo.RCA_PlanOperator was not found.', 1;
END;
GO

IF OBJECT_ID(N'dbo.RCA_PlanFinding', N'U') IS NULL
BEGIN
    THROW 51000, 'Required table dbo.RCA_PlanFinding was not found.', 1;
END;
GO


/*==============================================================================
    1. EXECUTIVE SUMMARY PROCEDURE
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExecutiveSummary
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
    BEGIN
        THROW 51001, 'The requested CaptureRunID does not exist.', 1;
    END;

    /*--------------------------------------------------------------------------
        Capture context.
        Dynamic metadata reads are used for optional descriptive columns so this
        presentation layer remains tolerant of minor CaptureRun schema evolution.
    --------------------------------------------------------------------------*/
    DECLARE
        @RequestedDatabase       nvarchar(256) = NULL,
        @IncidentDescription     nvarchar(max) = NULL,
        @RequestedBy             nvarchar(512) = NULL,
        @StartedFromHost         nvarchar(512) = NULL,
        @StartedFromProgram      nvarchar(512) = NULL,
        @CaptureStatus           varchar(100) = NULL,
        @StartTimeUTC            datetime2(7) = NULL,
        @EndTimeUTC              datetime2(7) = NULL;

    DECLARE @sql nvarchar(max);

    SET @sql = N'
        SELECT
            @RequestedDatabase_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','RequestedDatabaseName') IS NOT NULL
                         THEN N'CONVERT(nvarchar(256), RequestedDatabaseName)' ELSE N'NULL' END + N',
            @IncidentDescription_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','IncidentDescription') IS NOT NULL
                         THEN N'CONVERT(nvarchar(max), IncidentDescription)' ELSE N'NULL' END + N',
            @RequestedBy_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','RequestedBy') IS NOT NULL
                         THEN N'CONVERT(nvarchar(512), RequestedBy)' ELSE N'NULL' END + N',
            @StartedFromHost_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','StartedFromHost') IS NOT NULL
                         THEN N'CONVERT(nvarchar(512), StartedFromHost)' ELSE N'NULL' END + N',
            @StartedFromProgram_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','StartedFromProgram') IS NOT NULL
                         THEN N'CONVERT(nvarchar(512), StartedFromProgram)' ELSE N'NULL' END + N',
            @CaptureStatus_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','CaptureStatus') IS NOT NULL
                         THEN N'CONVERT(varchar(100), CaptureStatus)' ELSE N'NULL' END + N',
            @StartTimeUTC_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','StartTimeUTC') IS NOT NULL
                         THEN N'CONVERT(datetime2(7), StartTimeUTC)' ELSE N'NULL' END + N',
            @EndTimeUTC_OUT =
                ' + CASE WHEN COL_LENGTH('dbo.RCA_CaptureRun','EndTimeUTC') IS NOT NULL
                         THEN N'CONVERT(datetime2(7), EndTimeUTC)' ELSE N'NULL' END + N'
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID_IN;';

    EXEC sys.sp_executesql
        @sql,
        N'@CaptureRunID_IN bigint,
          @RequestedDatabase_OUT nvarchar(256) OUTPUT,
          @IncidentDescription_OUT nvarchar(max) OUTPUT,
          @RequestedBy_OUT nvarchar(512) OUTPUT,
          @StartedFromHost_OUT nvarchar(512) OUTPUT,
          @StartedFromProgram_OUT nvarchar(512) OUTPUT,
          @CaptureStatus_OUT varchar(100) OUTPUT,
          @StartTimeUTC_OUT datetime2(7) OUTPUT,
          @EndTimeUTC_OUT datetime2(7) OUTPUT',
        @CaptureRunID_IN = @CaptureRunID,
        @RequestedDatabase_OUT = @RequestedDatabase OUTPUT,
        @IncidentDescription_OUT = @IncidentDescription OUTPUT,
        @RequestedBy_OUT = @RequestedBy OUTPUT,
        @StartedFromHost_OUT = @StartedFromHost OUTPUT,
        @StartedFromProgram_OUT = @StartedFromProgram OUTPUT,
        @CaptureStatus_OUT = @CaptureStatus OUTPUT,
        @StartTimeUTC_OUT = @StartTimeUTC OUTPUT,
        @EndTimeUTC_OUT = @EndTimeUTC OUTPUT;

    /*--------------------------------------------------------------------------
        Highest-impact captured execution.
        This is OBSERVED WORKLOAD, not automatically the root cause.
    --------------------------------------------------------------------------*/
    DECLARE
        @TopExecutionEvidenceID  bigint = NULL,
        @TopEventTimeUTC         datetime2(7) = NULL,
        @TopDatabaseName         sysname = NULL,
        @TopSessionID            int = NULL,
        @TopObjectName           nvarchar(1024) = NULL,
        @TopCPUms                decimal(19,3) = NULL,
        @TopDurationMs           decimal(19,3) = NULL,
        @TopLogicalReads         bigint = NULL,
        @TopPhysicalReads        bigint = NULL,
        @TopWrites               bigint = NULL,
        @TopRows                 bigint = NULL,
        @TopHostName             nvarchar(512) = NULL,
        @TopProgramName          nvarchar(512) = NULL,
        @TopLoginName            nvarchar(512) = NULL,
        @TopQueryText            nvarchar(max) = NULL,
        @TopParameterText        nvarchar(max) = NULL,
        @TopParameterStatus      varchar(40) = NULL,
        @TopQueryHash            varbinary(8) = NULL,
        @TopQueryPlanHash        varbinary(8) = NULL;

    SELECT TOP (1)
        @TopExecutionEvidenceID = e.ExecutionEvidenceID,
        @TopEventTimeUTC        = e.EventTimeUTC,
        @TopDatabaseName        = e.DatabaseName,
        @TopSessionID           = e.SessionID,
        @TopObjectName          = e.ObjectName,
        @TopCPUms               = CONVERT(decimal(19,3), e.CPUms),
        @TopDurationMs          = CONVERT(decimal(19,3), e.DurationMs),
        @TopLogicalReads        = e.LogicalReads,
        @TopPhysicalReads       = e.PhysicalReads,
        @TopWrites              = e.Writes,
        @TopRows                = e.TotalRows,
        @TopHostName            = e.HostName,
        @TopProgramName         = e.ProgramName,
        @TopLoginName           = e.LoginName,
        @TopQueryText           = COALESCE(NULLIF(e.SubmittedCommand,N''), NULLIF(e.ObjectName,N'')),
        @TopParameterText       = e.ParameterText,
        @TopParameterStatus     = e.ParameterEvidenceStatus,
        @TopQueryHash           = e.QueryHash,
        @TopQueryPlanHash       = e.QueryPlanHash
    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.CaptureRunID = @CaptureRunID
    ORDER BY
        COALESCE(e.CPUms,0) DESC,
        COALESCE(e.DurationMs,0) DESC,
        COALESCE(e.LogicalReads,0) DESC,
        e.ExecutionEvidenceID DESC;

    /*--------------------------------------------------------------------------
        Locate the best actual plan for the top workload.

        First preference: explicitly linked actual plan.
        Second preference: query hash / plan hash correlation inside this run.
        Third preference: closest actual plan in same session/database.

        The presentation layer exposes correlation quality rather than pretending
        every captured plan is definitely the plan for the execution.
    --------------------------------------------------------------------------*/
    DECLARE
        @PlanEvidenceID          bigint = NULL,
        @PlanEventTimeUTC        datetime2(7) = NULL,
        @PlanSource              varchar(80) = NULL,
        @ActualPlanXML           xml = NULL,
        @PlanCorrelation         varchar(80) = 'NO DEFENSIBLY CORRELATED ACTUAL PLAN';

    SELECT TOP (1)
        @PlanEvidenceID   = p.PlanEvidenceID,
        @PlanEventTimeUTC = p.EventTimeUTC,
        @ActualPlanXML    = p.ActualExecutionPlanXML,
        @PlanSource       = 'LINKED_EXECUTION_EVIDENCE',
        @PlanCorrelation  = 'DIRECT EXECUTION LINK'
    FROM dbo.RCA_PlanEvidence AS p
    WHERE p.CaptureRunID = @CaptureRunID
      AND p.LinkedExecutionEvidenceID = @TopExecutionEvidenceID
    ORDER BY ABS(DATEDIFF_BIG(MICROSECOND, p.EventTimeUTC, @TopEventTimeUTC));

    IF @PlanEvidenceID IS NULL
       AND (@TopQueryHash IS NOT NULL OR @TopQueryPlanHash IS NOT NULL)
    BEGIN
        SELECT TOP (1)
            @PlanEvidenceID   = p.PlanEvidenceID,
            @PlanEventTimeUTC = p.EventTimeUTC,
            @ActualPlanXML    = p.ActualExecutionPlanXML,
            @PlanSource       = 'HASH_CORRELATION',
            @PlanCorrelation  = 'QUERY/PLAN HASH CORRELATION'
        FROM dbo.RCA_PlanEvidence AS p
        WHERE p.CaptureRunID = @CaptureRunID
          AND
          (
              (@TopQueryPlanHash IS NOT NULL AND p.QueryPlanHash = @TopQueryPlanHash)
              OR
              (@TopQueryHash IS NOT NULL AND p.QueryHash = @TopQueryHash)
          )
        ORDER BY ABS(DATEDIFF_BIG(MICROSECOND, p.EventTimeUTC, @TopEventTimeUTC));
    END;

    IF @PlanEvidenceID IS NULL
    BEGIN
        SELECT TOP (1)
            @PlanEvidenceID   = p.PlanEvidenceID,
            @PlanEventTimeUTC = p.EventTimeUTC,
            @ActualPlanXML    = p.ActualExecutionPlanXML,
            @PlanSource       = 'SESSION_TIME_CORRELATION',
            @PlanCorrelation  = 'SESSION/TIME CORRELATION'
        FROM dbo.RCA_PlanEvidence AS p
        WHERE p.CaptureRunID = @CaptureRunID
          AND p.SessionID = @TopSessionID
          AND (p.DatabaseName = @TopDatabaseName OR p.DatabaseName IS NULL OR @TopDatabaseName IS NULL)
          AND ABS(DATEDIFF_BIG(SECOND, p.EventTimeUTC, @TopEventTimeUTC)) <= 5
        ORDER BY ABS(DATEDIFF_BIG(MICROSECOND, p.EventTimeUTC, @TopEventTimeUTC));
    END;

    /*--------------------------------------------------------------------------
        Plan interpretation.
    --------------------------------------------------------------------------*/
    DECLARE
        @ScanPhysicalOp          nvarchar(120) = NULL,
        @ScanTableName           nvarchar(512) = NULL,
        @ScanIndexName           nvarchar(512) = NULL,
        @RowsRead                decimal(38,4) = NULL,
        @RowsOutput              decimal(38,4) = NULL,
        @OutputVsReadPercent     decimal(19,4) = NULL,
        @WorstEstimateRatio      decimal(19,4) = NULL,
        @SpillOperatorCount      int = 0,
        @LargeScanFindings       int = 0,
        @ImplicitFindings        int = 0,
        @CardinalityFindings     int = 0,
        @StatisticsFindings      int = 0;

    IF @PlanEvidenceID IS NOT NULL
    BEGIN
        SELECT TOP (1)
            @ScanPhysicalOp = o.PhysicalOp,
            @ScanTableName  = o.TableName,
            @ScanIndexName  = o.IndexName,
            @RowsRead       = CONVERT(decimal(38,4), o.ActualRowsRead),
            @RowsOutput     = CONVERT(decimal(38,4), o.ActualRows)
        FROM dbo.RCA_PlanOperator AS o
        WHERE o.CaptureRunID = @CaptureRunID
          AND o.PlanEvidenceID = @PlanEvidenceID
          AND o.PhysicalOp LIKE '%Scan%'
          AND o.ActualRowsRead IS NOT NULL
        ORDER BY o.ActualRowsRead DESC, o.NodeID;

        SET @OutputVsReadPercent =
            CASE
                WHEN @RowsRead > 0
                THEN CONVERT(decimal(19,4), (@RowsOutput / NULLIF(@RowsRead,0)) * 100.0)
                ELSE NULL
            END;

        SELECT
            @WorstEstimateRatio =
                MAX
                (
                    CASE
                        WHEN o.EstimateActualRatio IS NULL THEN NULL
                        WHEN o.EstimateActualRatio >= 1
                            THEN CONVERT(decimal(19,4), o.EstimateActualRatio)
                        WHEN o.EstimateActualRatio > 0
                            THEN CONVERT(decimal(19,4), 1.0 / o.EstimateActualRatio)
                        ELSE NULL
                    END
                ),
            @SpillOperatorCount =
                SUM(CASE WHEN o.HasSpillWarning = 1 THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanOperator AS o
        WHERE o.CaptureRunID = @CaptureRunID
          AND o.PlanEvidenceID = @PlanEvidenceID
          AND o.ActualRows IS NOT NULL;

        SELECT
            @LargeScanFindings =
                SUM(CASE WHEN FindingType = 'LARGE_SCAN' THEN 1 ELSE 0 END),
            @ImplicitFindings =
                SUM(CASE WHEN FindingType = 'IMPLICIT_CONVERSION' THEN 1 ELSE 0 END),
            @CardinalityFindings =
                SUM(CASE WHEN FindingType = 'CARDINALITY_MISMATCH' THEN 1 ELSE 0 END),
            @StatisticsFindings =
                SUM(CASE WHEN FindingType = 'STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID = @CaptureRunID
          AND PlanEvidenceID = @PlanEvidenceID;
    END;

    SET @LargeScanFindings   = COALESCE(@LargeScanFindings,0);
    SET @ImplicitFindings    = COALESCE(@ImplicitFindings,0);
    SET @CardinalityFindings = COALESCE(@CardinalityFindings,0);
    SET @StatisticsFindings  = COALESCE(@StatisticsFindings,0);
    SET @SpillOperatorCount  = COALESCE(@SpillOperatorCount,0);

    /*--------------------------------------------------------------------------
        Run-wide finding confidence.

        HIGH/MEDIUM findings are still observations. We do not automatically
        convert them into primary cause. The summary explicitly separates:
        "evidence observed" from "root cause confirmed".
    --------------------------------------------------------------------------*/
    DECLARE
        @HighFindingCount int = 0,
        @MediumFindingCount int = 0,
        @LowFindingCount int = 0;

    SELECT
        @HighFindingCount   = SUM(CASE WHEN Severity = 'HIGH'   THEN 1 ELSE 0 END),
        @MediumFindingCount = SUM(CASE WHEN Severity = 'MEDIUM' THEN 1 ELSE 0 END),
        @LowFindingCount    = SUM(CASE WHEN Severity = 'LOW'    THEN 1 ELSE 0 END)
    FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID = @CaptureRunID;

    SET @HighFindingCount   = COALESCE(@HighFindingCount,0);
    SET @MediumFindingCount = COALESCE(@MediumFindingCount,0);
    SET @LowFindingCount    = COALESCE(@LowFindingCount,0);

    /*--------------------------------------------------------------------------
        Server health.
        Use the same persisted evidence family when available. Because earlier
        RCA builds evolved, this block discovers common column names dynamically.
    --------------------------------------------------------------------------*/
    DECLARE
        @PeakSqlCpuPercent          decimal(19,4) = NULL,
        @AvgSqlCpuPercent           decimal(19,4) = NULL,
        @PeakOtherCpuPercent        decimal(19,4) = NULL,
        @LowestSystemIdlePercent    decimal(19,4) = NULL,
        @PeakRunnableTasks          bigint = NULL,
        @LowestBufferCacheHitRatio  decimal(19,4) = NULL,
        @AvgBufferCacheHitRatio     decimal(19,4) = NULL,
        @LowestPLESeconds           bigint = NULL,
        @LowestAvailablePhysicalMB  decimal(19,2) = NULL,
        @HealthSource               varchar(100) = 'NOT AVAILABLE';

    DECLARE @HealthTable sysname = NULL;

    IF OBJECT_ID(N'dbo.RCA_ServerHealthSnapshot', N'U') IS NOT NULL
        SET @HealthTable = N'dbo.RCA_ServerHealthSnapshot';
    ELSE IF OBJECT_ID(N'dbo.RCA_ServerHealthEvidence', N'U') IS NOT NULL
        SET @HealthTable = N'dbo.RCA_ServerHealthEvidence';
    ELSE IF OBJECT_ID(N'dbo.RCA_ServerHealthSample', N'U') IS NOT NULL
        SET @HealthTable = N'dbo.RCA_ServerHealthSample';

    IF @HealthTable IS NOT NULL
    BEGIN
        DECLARE
            @cSqlCpu sysname = NULL,
            @cOtherCpu sysname = NULL,
            @cIdle sysname = NULL,
            @cRunnable sysname = NULL,
            @cBCHR sysname = NULL,
            @cPLE sysname = NULL,
            @cAvail sysname = NULL;

        SELECT @cSqlCpu =
            CASE
                WHEN COL_LENGTH(@HealthTable,'SqlCpuPercent') IS NOT NULL THEN 'SqlCpuPercent'
                WHEN COL_LENGTH(@HealthTable,'SQLCPUPercent') IS NOT NULL THEN 'SQLCPUPercent'
                WHEN COL_LENGTH(@HealthTable,'ProcessUtilization') IS NOT NULL THEN 'ProcessUtilization'
            END;

        SELECT @cOtherCpu =
            CASE
                WHEN COL_LENGTH(@HealthTable,'OtherCpuPercent') IS NOT NULL THEN 'OtherCpuPercent'
                WHEN COL_LENGTH(@HealthTable,'OtherCPUPercent') IS NOT NULL THEN 'OtherCPUPercent'
            END;

        SELECT @cIdle =
            CASE
                WHEN COL_LENGTH(@HealthTable,'SystemIdlePercent') IS NOT NULL THEN 'SystemIdlePercent'
                WHEN COL_LENGTH(@HealthTable,'SystemIdle') IS NOT NULL THEN 'SystemIdle'
            END;

        SELECT @cRunnable =
            CASE
                WHEN COL_LENGTH(@HealthTable,'RunnableTasks') IS NOT NULL THEN 'RunnableTasks'
                WHEN COL_LENGTH(@HealthTable,'RunnableTasksCount') IS NOT NULL THEN 'RunnableTasksCount'
            END;

        SELECT @cBCHR =
            CASE
                WHEN COL_LENGTH(@HealthTable,'BufferCacheHitRatio') IS NOT NULL THEN 'BufferCacheHitRatio'
            END;

        SELECT @cPLE =
            CASE
                WHEN COL_LENGTH(@HealthTable,'PLESeconds') IS NOT NULL THEN 'PLESeconds'
                WHEN COL_LENGTH(@HealthTable,'PageLifeExpectancy') IS NOT NULL THEN 'PageLifeExpectancy'
            END;

        SELECT @cAvail =
            CASE
                WHEN COL_LENGTH(@HealthTable,'AvailablePhysicalMemoryMB') IS NOT NULL THEN 'AvailablePhysicalMemoryMB'
                WHEN COL_LENGTH(@HealthTable,'AvailableMemoryMB') IS NOT NULL THEN 'AvailableMemoryMB'
                WHEN COL_LENGTH(@HealthTable,'AvailablePhysicalMB') IS NOT NULL THEN 'AvailablePhysicalMB'
            END;

        SET @sql = N'
            SELECT
                @PeakSqlCpu_OUT = ' +
                CASE WHEN @cSqlCpu IS NULL THEN N'NULL'
                     ELSE N'MAX(CONVERT(decimal(19,4),' + QUOTENAME(@cSqlCpu) + N'))' END + N',
                @AvgSqlCpu_OUT = ' +
                CASE WHEN @cSqlCpu IS NULL THEN N'NULL'
                     ELSE N'AVG(CONVERT(decimal(19,4),' + QUOTENAME(@cSqlCpu) + N'))' END + N',
                @PeakOtherCpu_OUT = ' +
                CASE WHEN @cOtherCpu IS NULL THEN N'NULL'
                     ELSE N'MAX(CONVERT(decimal(19,4),' + QUOTENAME(@cOtherCpu) + N'))' END + N',
                @LowestIdle_OUT = ' +
                CASE WHEN @cIdle IS NULL THEN N'NULL'
                     ELSE N'MIN(CONVERT(decimal(19,4),' + QUOTENAME(@cIdle) + N'))' END + N',
                @PeakRunnable_OUT = ' +
                CASE WHEN @cRunnable IS NULL THEN N'NULL'
                     ELSE N'MAX(CONVERT(bigint,' + QUOTENAME(@cRunnable) + N'))' END + N',
                @LowestBCHR_OUT = ' +
                CASE WHEN @cBCHR IS NULL THEN N'NULL'
                     ELSE N'MIN(CONVERT(decimal(19,4),' + QUOTENAME(@cBCHR) + N'))' END + N',
                @AvgBCHR_OUT = ' +
                CASE WHEN @cBCHR IS NULL THEN N'NULL'
                     ELSE N'AVG(CONVERT(decimal(19,4),' + QUOTENAME(@cBCHR) + N'))' END + N',
                @LowestPLE_OUT = ' +
                CASE WHEN @cPLE IS NULL THEN N'NULL'
                     ELSE N'MIN(CONVERT(bigint,' + QUOTENAME(@cPLE) + N'))' END + N',
                @LowestAvail_OUT = ' +
                CASE WHEN @cAvail IS NULL THEN N'NULL'
                     ELSE N'MIN(CONVERT(decimal(19,2),' + QUOTENAME(@cAvail) + N'))' END + N'
            FROM ' + @HealthTable + N'
            WHERE CaptureRunID = @CaptureRunID_IN;';

        EXEC sys.sp_executesql
            @sql,
            N'@CaptureRunID_IN bigint,
              @PeakSqlCpu_OUT decimal(19,4) OUTPUT,
              @AvgSqlCpu_OUT decimal(19,4) OUTPUT,
              @PeakOtherCpu_OUT decimal(19,4) OUTPUT,
              @LowestIdle_OUT decimal(19,4) OUTPUT,
              @PeakRunnable_OUT bigint OUTPUT,
              @LowestBCHR_OUT decimal(19,4) OUTPUT,
              @AvgBCHR_OUT decimal(19,4) OUTPUT,
              @LowestPLE_OUT bigint OUTPUT,
              @LowestAvail_OUT decimal(19,2) OUTPUT',
            @CaptureRunID_IN = @CaptureRunID,
            @PeakSqlCpu_OUT = @PeakSqlCpuPercent OUTPUT,
            @AvgSqlCpu_OUT = @AvgSqlCpuPercent OUTPUT,
            @PeakOtherCpu_OUT = @PeakOtherCpuPercent OUTPUT,
            @LowestIdle_OUT = @LowestSystemIdlePercent OUTPUT,
            @PeakRunnable_OUT = @PeakRunnableTasks OUTPUT,
            @LowestBCHR_OUT = @LowestBufferCacheHitRatio OUTPUT,
            @AvgBCHR_OUT = @AvgBufferCacheHitRatio OUTPUT,
            @LowestPLE_OUT = @LowestPLESeconds OUTPUT,
            @LowestAvail_OUT = @LowestAvailablePhysicalMB OUTPUT;

        SET @HealthSource = @HealthTable;
    END;

    /*--------------------------------------------------------------------------
        Root-cause decision.

        Script 40 deliberately does not create a new causal detector. It reports
        the current evidence conservatively. Strong plan observations may justify
        investigation, but do not automatically prove incident attribution.
    --------------------------------------------------------------------------*/
    DECLARE
        @RootCauseStatus varchar(60) = 'NO ROOT CAUSE CONFIRMED',
        @Confidence varchar(20) = 'N/A',
        @PrimaryCause nvarchar(1000) = N'No supported primary cause',
        @ExecutiveSummary nvarchar(max),
        @PlanInterpretation nvarchar(max),
        @ServerInterpretation nvarchar(max),
        @RecommendedNextStep nvarchar(max),
        @DoNotChangeYet nvarchar(max);

    SET @PlanInterpretation =
        CASE
            WHEN @PlanEvidenceID IS NULL THEN
                N'No defensibly correlated actual execution plan was available for the highest-impact captured execution.'
            WHEN @ScanPhysicalOp IS NOT NULL
                 AND @OutputVsReadPercent >= 90.0 THEN
                CONCAT(
                    N'The actual plan used ', @ScanPhysicalOp,
                    COALESCE(N' on ' + @ScanTableName, N''),
                    COALESCE(N' using ' + @ScanIndexName, N''),
                    N'. It read approximately ',
                    CONVERT(varchar(40), CONVERT(decimal(38,0), @RowsRead)),
                    N' row(s) and returned approximately ',
                    CONVERT(varchar(40), CONVERT(decimal(38,0), @RowsOutput)),
                    N' row(s) (',
                    CONVERT(varchar(30), @OutputVsReadPercent),
                    N'% of rows read). The scan is large, but the query consumed most of the rows read; the access method alone is not sufficient evidence of root cause.'
                )
            WHEN @ScanPhysicalOp IS NOT NULL THEN
                CONCAT(
                    N'The actual plan used ', @ScanPhysicalOp,
                    COALESCE(N' on ' + @ScanTableName, N''),
                    N'. It read approximately ',
                    CONVERT(varchar(40), CONVERT(decimal(38,0), @RowsRead)),
                    N' row(s) and returned approximately ',
                    CONVERT(varchar(40), CONVERT(decimal(38,0), @RowsOutput)),
                    N'. Review predicate selectivity and indexing, but do not attribute the incident to the scan without corroborating evidence.'
                )
            ELSE
                N'An actual execution plan was captured, but no qualifying runtime scan operator was available for the executive scan summary.'
        END;

    SET @ServerInterpretation =
        CASE
            WHEN @HealthSource = 'NOT AVAILABLE' THEN
                N'No compatible persisted server-health snapshot was available to this presentation layer.'
            WHEN COALESCE(@PeakSqlCpuPercent,0) < 80
                 AND COALESCE(@PeakRunnableTasks,0) = 0 THEN
                N'The persisted server-health evidence does not show obvious CPU scheduler pressure during the captured interval.'
            ELSE
                N'Server-health evidence contains pressure indicators that should be reviewed with the detailed RCA evidence before attributing cause.'
        END;

    SET @RecommendedNextStep =
        CASE
            WHEN @PlanEvidenceID IS NOT NULL
                 AND @OutputVsReadPercent >= 90.0
                 AND @CardinalityFindings = 0
                 AND @StatisticsFindings = 0
                 AND @SpillOperatorCount = 0 THEN
                N'Review why the application or user requested this volume of data and whether the business request can be narrowed. The captured plan does not currently prove a SQL Server engine defect.'
            WHEN @PlanEvidenceID IS NULL THEN
                N'Obtain a defensibly correlated actual execution plan for the highest-impact workload before making a plan-based tuning decision.'
            ELSE
                N'Review the detailed plan findings and validate the highest-impact observation against workload behavior before changing production.'
        END;

    SET @DoNotChangeYet =
        N'Do not make a server-wide SQL configuration change, force a plan, add an index, or update statistics solely from this executive summary. Validate causal attribution first.';

    SET @ExecutiveSummary =
        CONCAT(
            N'Captured SQL Server evidence did not establish a supported primary root cause. ',
            CASE WHEN @TopExecutionEvidenceID IS NOT NULL
                 THEN CONCAT(N'The highest-impact observed execution used ',
                             COALESCE(CONVERT(varchar(30),@TopCPUms),'unknown'),
                             N' ms CPU, ran for ',
                             COALESCE(CONVERT(varchar(30),@TopDurationMs),'unknown'),
                             N' ms, and performed ',
                             COALESCE(CONVERT(varchar(30),@TopLogicalReads),'unknown'),
                             N' logical reads. ')
                 ELSE N'No captured execution was available. ' END,
            @PlanInterpretation, N' ', @ServerInterpretation
        );

    /*==========================================================================
        RESULT SET 1: THE ONE-SCREEN EXECUTIVE RCA SUMMARY
    ==========================================================================*/
    SELECT
        ReportSection             = '1 - EXECUTIVE RCA SUMMARY',
        CaptureRunID              = @CaptureRunID,
        DatabaseName              = COALESCE(@RequestedDatabase,@TopDatabaseName),
        CaptureStatus             = COALESCE(@CaptureStatus,'UNKNOWN'),
        RootCause                 = @RootCauseStatus,
        Confidence                = @Confidence,
        PrimaryCause              = @PrimaryCause,
        IncidentStartUTC          = @StartTimeUTC,
        IncidentEndUTC            = @EndTimeUTC,
        ExecutiveSummary          = @ExecutiveSummary,
        RecommendedNextStep       = @RecommendedNextStep,
        DoNotChangeYet            = @DoNotChangeYet;

    /*==========================================================================
        RESULT SET 2: WHAT HAPPENED?
    ==========================================================================*/
    SELECT
        ReportSection             = '2 - WHAT HAPPENED?',
        AttributionStatus         = 'OBSERVED WORKLOAD - NOT PROVEN ROOT CAUSE',
        ExecutionEvidenceID       = @TopExecutionEvidenceID,
        EventTimeUTC              = @TopEventTimeUTC,
        DatabaseName              = @TopDatabaseName,
        SessionID                 = @TopSessionID,
        ProcedureOrObject         = @TopObjectName,
        CPUms                     = @TopCPUms,
        DurationMs                = @TopDurationMs,
        LogicalReads              = @TopLogicalReads,
        PhysicalReads             = @TopPhysicalReads,
        Writes                    = @TopWrites,
        TotalRows                 = @TopRows;

    /*==========================================================================
        RESULT SET 3: WHO / WHAT SUBMITTED IT?
    ==========================================================================*/
    SELECT
        ReportSection             = '3 - WHO / WHAT SUBMITTED IT?',
        HostName                  = @TopHostName,
        ProgramName               = @TopProgramName,
        LoginName                 = @TopLoginName,
        SessionID                 = @TopSessionID,
        RequestedBy               = @RequestedBy,
        StartedFromHost           = @StartedFromHost,
        StartedFromProgram        = @StartedFromProgram;

    /*==========================================================================
        RESULT SET 4: QUERY + PARAMETERS
    ==========================================================================*/
    SELECT
        ReportSection             = '4 - QUERY + PARAMETERS',
        QueryText                 = @TopQueryText,
        CapturedParameters        = @TopParameterText,
        ParameterEvidenceStatus   = @TopParameterStatus;

    /*==========================================================================
        RESULT SET 5: WHAT DID THE ACTUAL PLAN SHOW?
    ==========================================================================*/
    SELECT
        ReportSection             = '5 - WHAT DID THE ACTUAL PLAN SHOW?',
        PlanEvidenceID            = @PlanEvidenceID,
        PlanCorrelation           = @PlanCorrelation,
        PlanSource                = @PlanSource,
        AccessMethod              = @ScanPhysicalOp,
        TableName                 = @ScanTableName,
        IndexName                 = @ScanIndexName,
        RowsRead                  = @RowsRead,
        RowsReturned              = @RowsOutput,
        OutputVsRowsReadPercent   = @OutputVsReadPercent,
        WorstNormalizedEstimateActualRatio = @WorstEstimateRatio,
        SpillOperatorCount        = @SpillOperatorCount,
        CardinalityMismatchFindings = @CardinalityFindings,
        StatisticsRiskFindings    = @StatisticsFindings,
        LargeScanFindings         = @LargeScanFindings,
        ImplicitConversionFindings = @ImplicitFindings,
        Interpretation            = @PlanInterpretation,
        ActualExecutionPlanXML    = @ActualPlanXML;

    /*==========================================================================
        RESULT SET 6: SERVER HEALTH
    ==========================================================================*/
    SELECT
        ReportSection             = '6 - SERVER HEALTH',
        EvidenceSource            = @HealthSource,
        PeakSqlCpuPercent         = @PeakSqlCpuPercent,
        AvgSqlCpuPercent          = @AvgSqlCpuPercent,
        PeakOtherCpuPercent       = @PeakOtherCpuPercent,
        LowestSystemIdlePercent   = @LowestSystemIdlePercent,
        PeakRunnableTasks         = @PeakRunnableTasks,
        LowestBufferCacheHitRatio = @LowestBufferCacheHitRatio,
        AvgBufferCacheHitRatio    = @AvgBufferCacheHitRatio,
        LowestPLESeconds          = @LowestPLESeconds,
        LowestAvailablePhysicalMB = @LowestAvailablePhysicalMB,
        Interpretation            = @ServerInterpretation;

    /*==========================================================================
        RESULT SET 7: WHAT SHOULD I DO?
    ==========================================================================*/
    SELECT
        ReportSection             = '7 - WHAT SHOULD I DO?',
        Priority1                 = @RecommendedNextStep,
        Priority2                 =
            CASE
                WHEN @ImplicitFindings > 0
                    THEN N'Inspect the operator-local implicit conversions in the detailed report and verify whether they affect predicates or seekability before changing data types.'
                ELSE N'No implicit-conversion follow-up is currently required from the correlated top plan.'
            END,
        Priority3                 =
            CASE
                WHEN @StatisticsFindings > 0
                    THEN N'Compare estimated versus actual rows before considering a targeted statistics update.'
                ELSE N'Do not update statistics solely because of sampling percentage when runtime estimates are accurate.'
            END,
        DoNotChangeYet            = @DoNotChangeYet,
        SafetyNote                = N'Observation is not causation. Preserve the evidence trail and validate business/application behavior before production changes.';

    /*==========================================================================
        RESULT SET 8: EVIDENCE / CONFIDENCE SNAPSHOT
    ==========================================================================*/
    SELECT
        ReportSection             = '8 - EVIDENCE / CONFIDENCE',
        HighPlanFindings          = @HighFindingCount,
        MediumPlanFindings        = @MediumFindingCount,
        LowPlanFindings           = @LowFindingCount,
        ActualPlanAvailable       = CONVERT(bit, CASE WHEN @PlanEvidenceID IS NULL THEN 0 ELSE 1 END),
        PlanCorrelation           = @PlanCorrelation,
        RootCauseConfirmed        = CONVERT(bit,0),
        EvidenceIntegrity         = N'No observation was promoted to primary root cause by this presentation layer.';

    /*==========================================================================
        RESULT SET 9: INCIDENT CONTEXT
    ==========================================================================*/
    SELECT
        ReportSection             = '9 - INCIDENT CONTEXT',
        CaptureRunID              = @CaptureRunID,
        RequestedDatabaseName     = @RequestedDatabase,
        IncidentDescription       = @IncidentDescription,
        RequestedBy               = @RequestedBy,
        StartedFromHost           = @StartedFromHost,
        StartedFromProgram        = @StartedFromProgram,
        StartTimeUTC              = @StartTimeUTC,
        EndTimeUTC                = @EndTimeUTC,
        CaptureStatus             = @CaptureStatus;
END;
GO


/*==============================================================================
    2. FRIENDLY ENTRY POINT

    This becomes the simplest command for a DBA who only wants the answer.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhatHappened
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_ExecutiveSummary
        @CaptureRunID = @CaptureRunID;
END;
GO


/*==============================================================================
    3. FULL INCIDENT EXPERIENCE

    Executive summary first, then the Script 39 detailed drill-down.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_FullIncidentExperience
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_ExecutiveSummary
        @CaptureRunID = @CaptureRunID;

    EXEC dbo.usp_RCA_UserExperience
        @CaptureRunID = @CaptureRunID;
END;
GO


/*==============================================================================
    4. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
    ValidationSection = '1 - SCRIPT 40 DEPLOYMENT',
    ExecutiveSummary =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExecutiveSummary',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    FriendlyAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhatHappened',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    FullExperience =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_FullIncidentExperience',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    SourceEvidenceModified = 'NO',
    DetectorThresholdsChanged = 'NO',
    RootCauseLogicPromoted = 'NO';
GO


/*==============================================================================
    5. CAPTURE 38 VALIDATION

    Run this fixture now.  We expect the presentation layer to preserve:
      - no confirmed root cause
      - observed high-impact workload
      - actual plan correlation where defensible
      - large scan as observation, not automatic cause
      - accurate cardinality where supported
      - no statistics causality merely from low sampling
      - no server-wide change recommendation
==============================================================================*/
EXEC dbo.usp_RCA_ExecutiveSummary
    @CaptureRunID = 38;
GO


/*==============================================================================
    NORMAL USE AFTER VALIDATION
    ---------------------------

    Short executive answer:
        EXEC DBA.dbo.usp_RCA_WhatHappened @CaptureRunID = 38;

    Executive summary + full technical drill-down:
        EXEC DBA.dbo.usp_RCA_FullIncidentExperience @CaptureRunID = 38;

    Existing Script 39 UX only:
        EXEC DBA.dbo.usp_RCA_UserExperience @CaptureRunID = 38;
==============================================================================*/
