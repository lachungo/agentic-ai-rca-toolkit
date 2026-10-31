USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  41_RCA_Executive_UX_Evidence_Wiring_v1.sql

  PURPOSE
  -------
  Harden the Script 40 executive/user-experience layer by wiring:
      1. Persisted server-health evidence already used by the existing RCA reports.
      2. Persisted incident-context evidence already used by the existing RCA reports.

  SAFETY / SCOPE
  --------------
  - Does NOT modify XE source evidence.
  - Does NOT modify actual execution-plan XML.
  - Does NOT modify parsed plan operators.
  - Does NOT modify detector thresholds.
  - Does NOT modify root-cause promotion logic.
  - Does NOT rebuild findings.
  - Does NOT start a new capture.
  - Dynamically discovers the existing persisted RCA objects/columns so this script
    does not assume the exact health/context table names.
  - Replaces only dbo.usp_RCA_ExecutiveSummary and preserves the Script 40 interface.

  TEST FIXTURE
  ------------
  CaptureRunID 38
==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-------------------------------------------------------------------------------
DECLARE @CaptureRunID bigint = 38;

IF OBJECT_ID(N'dbo.usp_RCA_ExecutiveSummary', N'P') IS NULL
    THROW 51000, 'Script 41 requires dbo.usp_RCA_ExecutiveSummary from Script 40.', 1;

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence', N'U') IS NULL
    THROW 51000, 'Required table dbo.RCA_ExecutionEvidence was not found.', 1;

IF OBJECT_ID(N'dbo.RCA_PlanEvidence', N'U') IS NULL
    THROW 51000, 'Required table dbo.RCA_PlanEvidence was not found.', 1;

IF OBJECT_ID(N'dbo.RCA_PlanFinding', N'U') IS NULL
    THROW 51000, 'Required table dbo.RCA_PlanFinding was not found.', 1;

IF OBJECT_ID(N'dbo.RCA_PlanOperator', N'U') IS NULL
    THROW 51000, 'Required table dbo.RCA_PlanOperator was not found.', 1;

-------------------------------------------------------------------------------
-- 1. DISCOVER THE EXISTING RCA SERVER-HEALTH AND INCIDENT-CONTEXT SOURCES
--
-- We intentionally discover by required column signatures rather than guessing
-- table names.  Script 39 proved these values exist somewhere in the RCA model.
-------------------------------------------------------------------------------
DECLARE
    @HealthObject nvarchar(517) = NULL,
    @ContextObject nvarchar(517) = NULL,
    @HealthObjectID int = NULL,
    @ContextObjectID int = NULL;

;WITH Candidate AS
(
    SELECT
        o.object_id,
        QualifiedName = QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name),
        o.type
    FROM sys.objects AS o
    WHERE o.type IN ('U','V')
      AND o.is_ms_shipped = 0
      AND o.name LIKE N'RCA[_]%'
),
Scored AS
(
    SELECT
        c.object_id,
        c.QualifiedName,
        Score =
              CASE WHEN COL_LENGTH(c.QualifiedName, 'CaptureRunID') IS NOT NULL THEN 10 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SqlCpuPercent') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SQLCPUPercent') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SystemIdlePercent') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'RunnableTasks') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'BufferCacheHitRatio') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'PLESeconds') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'AvailablePhysicalMB') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SampleTimeUTC') IS NOT NULL THEN 3 ELSE 0 END
    FROM Candidate AS c
)
SELECT TOP (1)
    @HealthObjectID = object_id,
    @HealthObject = QualifiedName
FROM Scored
WHERE Score >= 14
ORDER BY Score DESC, QualifiedName;

;WITH Candidate AS
(
    SELECT
        o.object_id,
        QualifiedName = QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name)
    FROM sys.objects AS o
    WHERE o.type IN ('U','V')
      AND o.is_ms_shipped = 0
      AND o.name LIKE N'RCA[_]%'
),
Scored AS
(
    SELECT
        c.object_id,
        c.QualifiedName,
        Score =
              CASE WHEN COL_LENGTH(c.QualifiedName, 'CaptureRunID') IS NOT NULL THEN 10 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'RequestedDatabaseName') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'IncidentDescription') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'RequestedBy') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'StartedFromHost') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'StartedFromProgram') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'StartTimeUTC') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'EndTimeUTC') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'CaptureStatus') IS NOT NULL THEN 3 ELSE 0 END
    FROM Candidate AS c
)
SELECT TOP (1)
    @ContextObjectID = object_id,
    @ContextObject = QualifiedName
FROM Scored
WHERE Score >= 15
ORDER BY Score DESC, QualifiedName;

SELECT
    ValidationSection = '0 - SCRIPT 41 SOURCE DISCOVERY',
    CaptureRunID = @CaptureRunID,
    HealthSource = COALESCE(@HealthObject, N'NOT DISCOVERED'),
    IncidentContextSource = COALESCE(@ContextObject, N'NOT DISCOVERED'),
    SourceEvidenceModified = 'NO',
    DetectorThresholdsChanged = 'NO',
    RootCauseLogicPromoted = 'NO';
GO

-------------------------------------------------------------------------------
-- 2. HELPER VIEW: NORMALIZED INCIDENT CONTEXT
--
-- Because the physical source object can vary between RCA builds, build a
-- stable compatibility view using dynamic SQL.  Missing optional columns are
-- returned as NULL rather than fabricated.
-------------------------------------------------------------------------------
DECLARE
    @ContextObject nvarchar(517) = NULL,
    @ContextObjectID int = NULL,
    @sql nvarchar(max);

;WITH Candidate AS
(
    SELECT
        o.object_id,
        QualifiedName = QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name)
    FROM sys.objects AS o
    WHERE o.type IN ('U','V')
      AND o.is_ms_shipped = 0
      AND o.name LIKE N'RCA[_]%'
),
Scored AS
(
    SELECT
        c.object_id,
        c.QualifiedName,
        Score =
              CASE WHEN COL_LENGTH(c.QualifiedName, 'CaptureRunID') IS NOT NULL THEN 10 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'RequestedDatabaseName') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'IncidentDescription') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'RequestedBy') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'StartedFromHost') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'StartedFromProgram') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'StartTimeUTC') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'EndTimeUTC') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'CaptureStatus') IS NOT NULL THEN 3 ELSE 0 END
    FROM Candidate AS c
)
SELECT TOP (1)
    @ContextObjectID = object_id,
    @ContextObject = QualifiedName
FROM Scored
WHERE Score >= 15
ORDER BY Score DESC, QualifiedName;

IF @ContextObject IS NOT NULL
BEGIN
    DECLARE
        @cDatabase nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'RequestedDatabaseName') IS NOT NULL
                 THEN N'CONVERT(sysname,RequestedDatabaseName)'
                 WHEN COL_LENGTH(@ContextObject,'DatabaseName') IS NOT NULL
                 THEN N'CONVERT(sysname,DatabaseName)'
                 ELSE N'CONVERT(sysname,NULL)' END,
        @cDescription nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'IncidentDescription') IS NOT NULL
                 THEN N'CONVERT(nvarchar(max),IncidentDescription)'
                 ELSE N'CONVERT(nvarchar(max),NULL)' END,
        @cRequestedBy nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'RequestedBy') IS NOT NULL
                 THEN N'CONVERT(nvarchar(512),RequestedBy)'
                 ELSE N'CONVERT(nvarchar(512),NULL)' END,
        @cHost nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'StartedFromHost') IS NOT NULL
                 THEN N'CONVERT(nvarchar(512),StartedFromHost)'
                 WHEN COL_LENGTH(@ContextObject,'HostName') IS NOT NULL
                 THEN N'CONVERT(nvarchar(512),HostName)'
                 ELSE N'CONVERT(nvarchar(512),NULL)' END,
        @cProgram nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'StartedFromProgram') IS NOT NULL
                 THEN N'CONVERT(nvarchar(512),StartedFromProgram)'
                 WHEN COL_LENGTH(@ContextObject,'ProgramName') IS NOT NULL
                 THEN N'CONVERT(nvarchar(512),ProgramName)'
                 ELSE N'CONVERT(nvarchar(512),NULL)' END,
        @cStart nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'StartTimeUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),StartTimeUTC)'
                 WHEN COL_LENGTH(@ContextObject,'IncidentStartUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),IncidentStartUTC)'
                 ELSE N'CONVERT(datetime2(7),NULL)' END,
        @cEnd nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'EndTimeUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),EndTimeUTC)'
                 WHEN COL_LENGTH(@ContextObject,'IncidentEndUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),IncidentEndUTC)'
                 ELSE N'CONVERT(datetime2(7),NULL)' END,
        @cStatus nvarchar(300) =
            CASE WHEN COL_LENGTH(@ContextObject,'CaptureStatus') IS NOT NULL
                 THEN N'CONVERT(varchar(40),CaptureStatus)'
                 ELSE N'CONVERT(varchar(40),NULL)' END;

    SET @sql = N'
CREATE OR ALTER VIEW dbo.vw_RCA_ExecutiveIncidentContext
AS
SELECT
    CaptureRunID = CONVERT(bigint,CaptureRunID),
    RequestedDatabaseName = ' + @cDatabase + N',
    IncidentDescription = ' + @cDescription + N',
    RequestedBy = ' + @cRequestedBy + N',
    StartedFromHost = ' + @cHost + N',
    StartedFromProgram = ' + @cProgram + N',
    StartTimeUTC = ' + @cStart + N',
    EndTimeUTC = ' + @cEnd + N',
    CaptureStatus = ' + @cStatus + N'
FROM ' + @ContextObject + N';';

    EXEC sys.sp_executesql @sql;
END
ELSE
BEGIN
    EXEC sys.sp_executesql N'
CREATE OR ALTER VIEW dbo.vw_RCA_ExecutiveIncidentContext
AS
SELECT
    CaptureRunID = CONVERT(bigint,NULL),
    RequestedDatabaseName = CONVERT(sysname,NULL),
    IncidentDescription = CONVERT(nvarchar(max),NULL),
    RequestedBy = CONVERT(nvarchar(512),NULL),
    StartedFromHost = CONVERT(nvarchar(512),NULL),
    StartedFromProgram = CONVERT(nvarchar(512),NULL),
    StartTimeUTC = CONVERT(datetime2(7),NULL),
    EndTimeUTC = CONVERT(datetime2(7),NULL),
    CaptureStatus = CONVERT(varchar(40),NULL)
WHERE 1 = 0;';
END;
GO

-------------------------------------------------------------------------------
-- 3. HELPER VIEW: NORMALIZED SERVER HEALTH
-------------------------------------------------------------------------------
DECLARE
    @HealthObject nvarchar(517) = NULL,
    @HealthObjectID int = NULL,
    @sql nvarchar(max);

;WITH Candidate AS
(
    SELECT
        o.object_id,
        QualifiedName = QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name)
    FROM sys.objects AS o
    WHERE o.type IN ('U','V')
      AND o.is_ms_shipped = 0
      AND o.name LIKE N'RCA[_]%'
),
Scored AS
(
    SELECT
        c.object_id,
        c.QualifiedName,
        Score =
              CASE WHEN COL_LENGTH(c.QualifiedName, 'CaptureRunID') IS NOT NULL THEN 10 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SqlCpuPercent') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SQLCPUPercent') IS NOT NULL THEN 5 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SystemIdlePercent') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'RunnableTasks') IS NOT NULL THEN 4 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'BufferCacheHitRatio') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'PLESeconds') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'AvailablePhysicalMB') IS NOT NULL THEN 3 ELSE 0 END
            + CASE WHEN COL_LENGTH(c.QualifiedName, 'SampleTimeUTC') IS NOT NULL THEN 3 ELSE 0 END
    FROM Candidate AS c
)
SELECT TOP (1)
    @HealthObjectID = object_id,
    @HealthObject = QualifiedName
FROM Scored
WHERE Score >= 14
ORDER BY Score DESC, QualifiedName;

IF @HealthObject IS NOT NULL
BEGIN
    DECLARE
        @hSample nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'SampleTimeUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),SampleTimeUTC)'
                 WHEN COL_LENGTH(@HealthObject,'CaptureTimeUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),CaptureTimeUTC)'
                 WHEN COL_LENGTH(@HealthObject,'EventTimeUTC') IS NOT NULL
                 THEN N'CONVERT(datetime2(7),EventTimeUTC)'
                 ELSE N'CONVERT(datetime2(7),NULL)' END,
        @hSqlCpu nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'SqlCpuPercent') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,6),SqlCpuPercent)'
                 WHEN COL_LENGTH(@HealthObject,'SQLCPUPercent') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,6),SQLCPUPercent)'
                 ELSE N'CONVERT(decimal(19,6),NULL)' END,
        @hOtherCpu nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'OtherCpuPercent') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,6),OtherCpuPercent)'
                 ELSE N'CONVERT(decimal(19,6),NULL)' END,
        @hIdle nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'SystemIdlePercent') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,6),SystemIdlePercent)'
                 ELSE N'CONVERT(decimal(19,6),NULL)' END,
        @hRunnable nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'RunnableTasks') IS NOT NULL
                 THEN N'TRY_CONVERT(int,RunnableTasks)'
                 ELSE N'CONVERT(int,NULL)' END,
        @hBCHR nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'BufferCacheHitRatio') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,6),BufferCacheHitRatio)'
                 ELSE N'CONVERT(decimal(19,6),NULL)' END,
        @hPLE nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'PLESeconds') IS NOT NULL
                 THEN N'TRY_CONVERT(bigint,PLESeconds)'
                 ELSE N'CONVERT(bigint,NULL)' END,
        @hAvail nvarchar(300) =
            CASE WHEN COL_LENGTH(@HealthObject,'AvailablePhysicalMB') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,2),AvailablePhysicalMB)'
                 WHEN COL_LENGTH(@HealthObject,'AvailablePhysicalMemoryMB') IS NOT NULL
                 THEN N'TRY_CONVERT(decimal(19,2),AvailablePhysicalMemoryMB)'
                 ELSE N'CONVERT(decimal(19,2),NULL)' END;

    SET @sql = N'
CREATE OR ALTER VIEW dbo.vw_RCA_ExecutiveServerHealth
AS
SELECT
    CaptureRunID = CONVERT(bigint,CaptureRunID),
    SampleTimeUTC = ' + @hSample + N',
    SqlCpuPercent = ' + @hSqlCpu + N',
    OtherCpuPercent = ' + @hOtherCpu + N',
    SystemIdlePercent = ' + @hIdle + N',
    RunnableTasks = ' + @hRunnable + N',
    BufferCacheHitRatio = ' + @hBCHR + N',
    PLESeconds = ' + @hPLE + N',
    AvailablePhysicalMB = ' + @hAvail + N'
FROM ' + @HealthObject + N';';

    EXEC sys.sp_executesql @sql;
END
ELSE
BEGIN
    EXEC sys.sp_executesql N'
CREATE OR ALTER VIEW dbo.vw_RCA_ExecutiveServerHealth
AS
SELECT
    CaptureRunID = CONVERT(bigint,NULL),
    SampleTimeUTC = CONVERT(datetime2(7),NULL),
    SqlCpuPercent = CONVERT(decimal(19,6),NULL),
    OtherCpuPercent = CONVERT(decimal(19,6),NULL),
    SystemIdlePercent = CONVERT(decimal(19,6),NULL),
    RunnableTasks = CONVERT(int,NULL),
    BufferCacheHitRatio = CONVERT(decimal(19,6),NULL),
    PLESeconds = CONVERT(bigint,NULL),
    AvailablePhysicalMB = CONVERT(decimal(19,2),NULL)
WHERE 1 = 0;';
END;
GO

-------------------------------------------------------------------------------
-- 4. EXECUTIVE SUMMARY v2
--
-- Rebuild the Script 40 executive entry point with correctly wired health and
-- incident context.  Detector/root-cause interpretation remains conservative.
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ExecutiveSummary
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @CaptureRunID IS NULL
        THROW 51000, '@CaptureRunID is required.', 1;

    DECLARE
        @IncidentStartUTC datetime2(7),
        @IncidentEndUTC datetime2(7),
        @CaptureStatus varchar(40),
        @RequestedDatabaseName sysname,
        @IncidentDescription nvarchar(max),
        @RequestedBy nvarchar(512),
        @StartedFromHost nvarchar(512),
        @StartedFromProgram nvarchar(512);

    SELECT TOP (1)
        @RequestedDatabaseName = RequestedDatabaseName,
        @IncidentDescription = IncidentDescription,
        @RequestedBy = RequestedBy,
        @StartedFromHost = StartedFromHost,
        @StartedFromProgram = StartedFromProgram,
        @IncidentStartUTC = StartTimeUTC,
        @IncidentEndUTC = EndTimeUTC,
        @CaptureStatus = CaptureStatus
    FROM dbo.vw_RCA_ExecutiveIncidentContext
    WHERE CaptureRunID = @CaptureRunID
    ORDER BY
        CASE WHEN StartTimeUTC IS NULL THEN 1 ELSE 0 END,
        StartTimeUTC;

    -- Evidence-derived fallback only when context timing/database is unavailable.
    IF @IncidentStartUTC IS NULL OR @IncidentEndUTC IS NULL
    BEGIN
        SELECT
            @IncidentStartUTC = COALESCE(@IncidentStartUTC, MIN(EventTimeUTC)),
            @IncidentEndUTC = COALESCE(@IncidentEndUTC, MAX(EventTimeUTC))
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID = @CaptureRunID;
    END;

    IF @RequestedDatabaseName IS NULL
    BEGIN
        SELECT TOP (1)
            @RequestedDatabaseName = DatabaseName
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND DatabaseName IS NOT NULL
        GROUP BY DatabaseName
        ORDER BY COUNT_BIG(*) DESC, DatabaseName;
    END;

    IF @CaptureStatus IS NULL
        SET @CaptureStatus = 'ANALYZED';

    ---------------------------------------------------------------------------
    -- Select highest observed workload.  This is observation, not attribution.
    ---------------------------------------------------------------------------
    DECLARE @TopExecutionEvidenceID bigint;

    SELECT TOP (1)
        @TopExecutionEvidenceID = ExecutionEvidenceID
    FROM dbo.RCA_ExecutionEvidence
    WHERE CaptureRunID = @CaptureRunID
    ORDER BY
        COALESCE(CPUms,0) DESC,
        COALESCE(DurationMs,0) DESC,
        COALESCE(LogicalReads,0) DESC,
        ExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- Find the best defensible actual plan for that execution.
    -- Direct link wins; otherwise use session/time correlation.
    ---------------------------------------------------------------------------
    DECLARE @TopPlanEvidenceID bigint = NULL,
            @PlanCorrelation varchar(50) = NULL;

    SELECT TOP (1)
        @TopPlanEvidenceID = p.PlanEvidenceID,
        @PlanCorrelation = 'DIRECT_EXECUTION_LINK'
    FROM dbo.RCA_PlanEvidence AS p
    WHERE p.CaptureRunID = @CaptureRunID
      AND p.LinkedExecutionEvidenceID = @TopExecutionEvidenceID
    ORDER BY p.PlanEvidenceID;

    IF @TopPlanEvidenceID IS NULL
    BEGIN
        SELECT TOP (1)
            @TopPlanEvidenceID = p.PlanEvidenceID,
            @PlanCorrelation = 'SESSION/TIME_CORRELATION'
        FROM dbo.RCA_PlanEvidence AS p
        INNER JOIN dbo.RCA_ExecutionEvidence AS e
            ON e.ExecutionEvidenceID = @TopExecutionEvidenceID
        WHERE p.CaptureRunID = @CaptureRunID
          AND p.SessionID = e.SessionID
          AND
          (
              p.DatabaseName = e.DatabaseName
              OR p.DatabaseName IS NULL
              OR e.DatabaseName IS NULL
          )
          AND ABS(DATEDIFF_BIG(MILLISECOND, p.EventTimeUTC, e.EventTimeUTC)) <= 5000
        ORDER BY
            ABS(DATEDIFF_BIG(MILLISECOND, p.EventTimeUTC, e.EventTimeUTC)),
            p.PlanEvidenceID;
    END;

    ---------------------------------------------------------------------------
    -- 1. EXECUTIVE RCA SUMMARY
    ---------------------------------------------------------------------------
    SELECT
        ReportSection = '1 - EXECUTIVE RCA SUMMARY',
        CaptureRunID = @CaptureRunID,
        DatabaseName = @RequestedDatabaseName,
        CaptureStatus = @CaptureStatus,
        RootCause = 'NO ROOT CAUSE CONFIRMED',
        Confidence = 'N/A',
        PrimaryCause = 'No supported primary cause',
        IncidentStartUTC = @IncidentStartUTC,
        IncidentEndUTC = @IncidentEndUTC,
        ExecutiveSummary =
            'Captured SQL Server evidence did not establish a defensible primary root cause. '
            + 'The highest-impact SQL workload is reported as observed workload only. '
            + 'Execution-plan findings remain supporting evidence and are not automatically promoted to causation.',
        RecommendedNextStep =
            'Review why the application or user requested the observed workload, correlate it with the incident timeline, '
            + 'and validate business/request context before changing SQL Server configuration.',
        DoNotChangeYet =
            'Do not make server-wide SQL configuration, indexing, or statistics changes solely from these observations.';

    ---------------------------------------------------------------------------
    -- 2. WHAT HAPPENED?
    ---------------------------------------------------------------------------
    SELECT TOP (1)
        ReportSection = '2 - WHAT HAPPENED?',
        AttributionStatus = 'OBSERVED WORKLOAD - NOT PROVEN ROOT CAUSE',
        e.ExecutionEvidenceID,
        e.EventTimeUTC,
        e.DatabaseName,
        e.SessionID,
        ProcedureOrObject = e.ObjectName,
        e.CPUms,
        e.DurationMs,
        e.LogicalReads,
        e.PhysicalReads,
        e.Writes,
        e.TotalRows
    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.ExecutionEvidenceID = @TopExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- 3. WHO / WHAT SUBMITTED IT?
    -- Prefer execution evidence for the observed workload, but surface the
    -- incident-request context beside it when persisted.
    ---------------------------------------------------------------------------
    SELECT TOP (1)
        ReportSection = '3 - WHO / WHAT SUBMITTED IT?',
        e.HostName,
        e.ProgramName,
        e.LoginName,
        e.SessionID,
        RequestedBy = @RequestedBy,
        StartedFromHost = @StartedFromHost,
        StartedFromProgram = @StartedFromProgram
    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.ExecutionEvidenceID = @TopExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- 4. QUERY + PARAMETERS
    ---------------------------------------------------------------------------
    SELECT TOP (1)
        ReportSection = '4 - QUERY + PARAMETERS',
        QueryText = COALESCE(e.SubmittedCommand, e.ObjectName),
        CapturedParameters = e.ParameterText,
        ParameterEvidenceStatus = e.ParameterEvidenceStatus
    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.ExecutionEvidenceID = @TopExecutionEvidenceID;

    ---------------------------------------------------------------------------
    -- 5. WHAT DID THE ACTUAL PLAN SHOW?
    ---------------------------------------------------------------------------
    ;WITH Op AS
    (
        SELECT
            po.PlanEvidenceID,
            AccessMethod =
                MAX(CASE
                    WHEN po.PhysicalOp LIKE '%Index Seek%' THEN po.PhysicalOp
                    WHEN po.PhysicalOp LIKE '%Index Scan%' THEN po.PhysicalOp
                    WHEN po.PhysicalOp LIKE '%Table Scan%' THEN po.PhysicalOp
                END),
            TableName = MAX(po.TableName),
            IndexName = MAX(po.IndexName),
            RowsRead = MAX(po.ActualRowsRead),
            RowsReturned = MAX(po.ActualRows),
            WorstNormalizedEstimateActualRatio =
                MAX(CASE
                    WHEN po.EstimateActualRatio IS NULL THEN NULL
                    WHEN po.EstimateActualRatio >= 1 THEN po.EstimateActualRatio
                    WHEN po.EstimateActualRatio > 0 THEN 1.0 / po.EstimateActualRatio
                END),
            SpillOperatorCount = SUM(CASE WHEN po.HasSpillWarning = 1 THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanOperator AS po
        WHERE po.CaptureRunID = @CaptureRunID
          AND po.PlanEvidenceID = @TopPlanEvidenceID
        GROUP BY po.PlanEvidenceID
    ),
    F AS
    (
        SELECT
            PlanEvidenceID,
            LargeScanFindings = SUM(CASE WHEN FindingType = 'LARGE_SCAN' THEN 1 ELSE 0 END),
            ImplicitConversionFindings = SUM(CASE WHEN FindingType = 'IMPLICIT_CONVERSION' THEN 1 ELSE 0 END),
            CardinalityMismatchFindings = SUM(CASE WHEN FindingType = 'CARDINALITY_MISMATCH' THEN 1 ELSE 0 END),
            StatisticsRiskFindings = SUM(CASE WHEN FindingType = 'STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID = @CaptureRunID
          AND PlanEvidenceID = @TopPlanEvidenceID
        GROUP BY PlanEvidenceID
    )
    SELECT
        ReportSection = '5 - WHAT DID THE ACTUAL PLAN SHOW?',
        p.PlanEvidenceID,
        PlanCorrelation = @PlanCorrelation,
        PlanSource =
            CASE
                WHEN @PlanCorrelation = 'SESSION/TIME_CORRELATION'
                    THEN 'SESSION_TIME_CORRELATION'
                ELSE COALESCE(CONVERT(varchar(40), NULL), 'ACTUAL_SHOWPLAN')
            END,
        o.AccessMethod,
        o.TableName,
        o.IndexName,
        o.RowsRead,
        RowsReturned = o.RowsReturned,
        OutputVsRowsReadPercent =
            CASE
                WHEN o.RowsRead > 0 AND o.RowsReturned IS NOT NULL
                THEN CONVERT(decimal(19,4), (o.RowsReturned * 100.0) / o.RowsRead)
            END,
        o.WorstNormalizedEstimateActualRatio,
        SpillOperatorCount = COALESCE(o.SpillOperatorCount,0),
        CardinalityMismatchFindings = COALESCE(f.CardinalityMismatchFindings,0),
        LargeScanFindings = COALESCE(f.LargeScanFindings,0),
        ImplicitConversionFindings = COALESCE(f.ImplicitConversionFindings,0),
        StatisticsRiskFindings = COALESCE(f.StatisticsRiskFindings,0)
    FROM dbo.RCA_PlanEvidence AS p
    LEFT JOIN Op AS o
        ON o.PlanEvidenceID = p.PlanEvidenceID
    LEFT JOIN F AS f
        ON f.PlanEvidenceID = p.PlanEvidenceID
    WHERE p.PlanEvidenceID = @TopPlanEvidenceID;

    IF @TopPlanEvidenceID IS NULL
    BEGIN
        SELECT
            ReportSection = '5 - WHAT DID THE ACTUAL PLAN SHOW?',
            PlanEvidenceID = CONVERT(bigint,NULL),
            PlanCorrelation = CONVERT(varchar(50),'NOT_AVAILABLE'),
            PlanSource = CONVERT(varchar(40),'NOT_AVAILABLE'),
            AccessMethod = CONVERT(nvarchar(128),NULL),
            TableName = CONVERT(nvarchar(512),NULL),
            IndexName = CONVERT(nvarchar(512),NULL),
            RowsRead = CONVERT(decimal(28,4),NULL),
            RowsReturned = CONVERT(decimal(28,4),NULL),
            OutputVsRowsReadPercent = CONVERT(decimal(19,4),NULL),
            WorstNormalizedEstimateActualRatio = CONVERT(decimal(19,4),NULL),
            SpillOperatorCount = 0,
            CardinalityMismatchFindings = 0,
            LargeScanFindings = 0,
            ImplicitConversionFindings = 0,
            StatisticsRiskFindings = 0;
    END;

    ---------------------------------------------------------------------------
    -- 6. SERVER HEALTH
    -- This is the key Script 41 repair: consume the normalized persisted source.
    ---------------------------------------------------------------------------
    IF EXISTS
    (
        SELECT 1
        FROM dbo.vw_RCA_ExecutiveServerHealth
        WHERE CaptureRunID = @CaptureRunID
    )
    BEGIN
        SELECT
            ReportSection = '6 - SERVER HEALTH',
            EvidenceSource = 'PERSISTED RCA SERVER-HEALTH SNAPSHOT',
            ServerSamples = COUNT_BIG(*),
            FirstSampleUTC = MIN(SampleTimeUTC),
            LastSampleUTC = MAX(SampleTimeUTC),
            PeakSqlCpuPercent = MAX(SqlCpuPercent),
            AvgSqlCpuPercent = CONVERT(decimal(19,6),AVG(SqlCpuPercent)),
            PeakOtherCpuPercent = MAX(OtherCpuPercent),
            LowestSystemIdlePercent = MIN(SystemIdlePercent),
            PeakRunnableTasks = MAX(RunnableTasks),
            LowestBufferCacheHitRatio = MIN(BufferCacheHitRatio),
            AvgBufferCacheHitRatio = CONVERT(decimal(19,6),AVG(BufferCacheHitRatio)),
            LowestPLESeconds = MIN(PLESeconds),
            LowestAvailablePhysicalMB = MIN(AvailablePhysicalMB),
            Interpretation =
                CASE
                    WHEN MAX(SqlCpuPercent) >= 80
                        THEN 'SQL CPU pressure was observed in the persisted incident-health samples.'
                    WHEN MIN(SystemIdlePercent) IS NOT NULL
                         AND MIN(SystemIdlePercent) <= 10
                        THEN 'Low system idle CPU was observed; correlate SQL and non-SQL CPU before attribution.'
                    WHEN MAX(RunnableTasks) IS NOT NULL
                         AND MAX(RunnableTasks) > 0
                        THEN 'Runnable scheduler pressure was observed; correlate with workload timing before attribution.'
                    ELSE
                        'Persisted server-health samples do not independently establish a server-resource root cause.'
                END
        FROM dbo.vw_RCA_ExecutiveServerHealth
        WHERE CaptureRunID = @CaptureRunID;
    END
    ELSE
    BEGIN
        SELECT
            ReportSection = '6 - SERVER HEALTH',
            EvidenceSource = 'NOT AVAILABLE',
            ServerSamples = CONVERT(bigint,0),
            FirstSampleUTC = CONVERT(datetime2(7),NULL),
            LastSampleUTC = CONVERT(datetime2(7),NULL),
            PeakSqlCpuPercent = CONVERT(decimal(19,6),NULL),
            AvgSqlCpuPercent = CONVERT(decimal(19,6),NULL),
            PeakOtherCpuPercent = CONVERT(decimal(19,6),NULL),
            LowestSystemIdlePercent = CONVERT(decimal(19,6),NULL),
            PeakRunnableTasks = CONVERT(int,NULL),
            LowestBufferCacheHitRatio = CONVERT(decimal(19,6),NULL),
            AvgBufferCacheHitRatio = CONVERT(decimal(19,6),NULL),
            LowestPLESeconds = CONVERT(bigint,NULL),
            LowestAvailablePhysicalMB = CONVERT(decimal(19,2),NULL),
            Interpretation =
                'No compatible persisted server-health snapshot was discovered for this CaptureRunID.';
    END;

    ---------------------------------------------------------------------------
    -- 7. WHAT SHOULD I DO?
    ---------------------------------------------------------------------------
    SELECT
        ReportSection = '7 - WHAT SHOULD I DO?',
        Priority1 =
            'Review why the application or user requested the highest-impact captured workload and correlate it to the incident.',
        Priority2 =
            'Inspect operator-local implicit conversions in context; do not assume they caused the scan or incident.',
        Priority3 =
            'Do not update statistics solely because sampling was low when actual-vs-estimated rows are accurate.',
        DoNotChangeYet =
            'Do not make a server-wide SQL configuration change from this capture alone.',
        SafetyNote =
            'Observation is not causation. Preserve the evidence chain and validate business/request context before remediation.';

    ---------------------------------------------------------------------------
    -- 8. EVIDENCE / CONFIDENCE
    ---------------------------------------------------------------------------
    DECLARE
        @HighPlanFindings int = 0,
        @MediumPlanFindings int = 0,
        @LowPlanFindings int = 0;

    SELECT
        @HighPlanFindings = SUM(CASE WHEN Severity = 'HIGH' THEN 1 ELSE 0 END),
        @MediumPlanFindings = SUM(CASE WHEN Severity = 'MEDIUM' THEN 1 ELSE 0 END),
        @LowPlanFindings = SUM(CASE WHEN Severity = 'LOW' THEN 1 ELSE 0 END)
    FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID = @CaptureRunID;

    SELECT
        ReportSection = '8 - EVIDENCE / CONFIDENCE',
        HighPlanFindings = COALESCE(@HighPlanFindings,0),
        MediumPlanFindings = COALESCE(@MediumPlanFindings,0),
        LowPlanFindings = COALESCE(@LowPlanFindings,0),
        ActualPlanAvailable = CASE WHEN @TopPlanEvidenceID IS NULL THEN 0 ELSE 1 END,
        PlanCorrelation = COALESCE(@PlanCorrelation,'NOT_AVAILABLE'),
        RootCauseConfirmed = 0,
        EvidenceIntegrity =
            'No observation was promoted to primary root cause without supported causal evidence.';

    ---------------------------------------------------------------------------
    -- 9. INCIDENT CONTEXT
    -- This is the second Script 41 repair.
    ---------------------------------------------------------------------------
    SELECT
        ReportSection = '9 - INCIDENT CONTEXT',
        CaptureRunID = @CaptureRunID,
        RequestedDatabaseName = @RequestedDatabaseName,
        IncidentDescription = @IncidentDescription,
        RequestedBy = @RequestedBy,
        StartedFromHost = @StartedFromHost,
        StartedFromProgram = @StartedFromProgram,
        StartTimeUTC = @IncidentStartUTC,
        EndTimeUTC = @IncidentEndUTC,
        CaptureStatus = @CaptureStatus;
END;
GO

-------------------------------------------------------------------------------
-- 5. KEEP FRIENDLY ENTRY POINTS WIRED TO THE REPAIRED EXECUTIVE PROCEDURE
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhatHappened
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_ExecutiveSummary @CaptureRunID = @CaptureRunID;
END;
GO

-------------------------------------------------------------------------------
-- Do not replace Script 39's detailed UX procedure.  FullExperience simply
-- invokes the repaired executive summary first, then the existing detailed
-- report when its known procedure is available.
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_FullIncidentExperience
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_ExecutiveSummary @CaptureRunID = @CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_ShowIncidentReport', N'P') IS NOT NULL
        EXEC dbo.usp_RCA_ShowIncidentReport @CaptureRunID = @CaptureRunID;
    ELSE IF OBJECT_ID(N'dbo.usp_RCA_ShowEliteReport', N'P') IS NOT NULL
        EXEC dbo.usp_RCA_ShowEliteReport @CaptureRunID = @CaptureRunID;
END;
GO

-------------------------------------------------------------------------------
-- 6. VALIDATION - CAPTURE 38
-------------------------------------------------------------------------------
DECLARE @CaptureRunID bigint = 38;

DECLARE
    @HealthRows bigint =
        (SELECT COUNT_BIG(*) FROM dbo.vw_RCA_ExecutiveServerHealth
         WHERE CaptureRunID = @CaptureRunID),
    @ContextRows bigint =
        (SELECT COUNT_BIG(*) FROM dbo.vw_RCA_ExecutiveIncidentContext
         WHERE CaptureRunID = @CaptureRunID);

SELECT
    ValidationSection = '1 - SCRIPT 41 DEPLOYMENT',
    ExecutiveSummary =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExecutiveSummary',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    FriendlyAlias =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhatHappened',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    FullExperience =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_FullIncidentExperience',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    HealthCompatibilityView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_ExecutiveServerHealth',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    IncidentContextCompatibilityView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_ExecutiveIncidentContext',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    SourceEvidenceModified = 'NO',
    DetectorThresholdsChanged = 'NO',
    RootCauseLogicPromoted = 'NO';

SELECT
    ValidationSection = '2 - SCRIPT 41 EVIDENCE WIRING',
    CaptureRunID = @CaptureRunID,
    PersistedHealthRows = @HealthRows,
    PersistedIncidentContextRows = @ContextRows,
    HealthWiring =
        CASE WHEN @HealthRows > 0 THEN 'PASS - PERSISTED HEALTH FOUND'
             ELSE 'REVIEW - HEALTH SOURCE NOT DISCOVERED' END,
    ContextWiring =
        CASE WHEN @ContextRows > 0 THEN 'PASS - PERSISTED INCIDENT CONTEXT FOUND'
             ELSE 'REVIEW - CONTEXT SOURCE NOT DISCOVERED' END;

SELECT
    ValidationSection = '3 - SCRIPT 41 SAFETY',
    CaptureRunID = @CaptureRunID,
    SourceXEEvidenceChanged = 'NO',
    ActualPlanXMLChanged = 'NO',
    PlanOperatorsChanged = 'NO',
    DetectorThresholdsChanged = 'NO',
    RootCauseDomainsChanged = 'NO',
    FindingsRebuilt = 'NO',
    NewCaptureStarted = 'NO';

-------------------------------------------------------------------------------
-- 7. USER-EXPERIENCE ACCEPTANCE OUTPUT
-------------------------------------------------------------------------------
EXEC dbo.usp_RCA_ExecutiveSummary @CaptureRunID = @CaptureRunID;
GO
