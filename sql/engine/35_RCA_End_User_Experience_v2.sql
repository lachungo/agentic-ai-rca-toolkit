USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  35_RCA_End_User_Experience_v2.sql

  PURPOSE
  -------
  Replace the complete DBA-facing RCA workflow as ONE deployment:
      Start -> Status -> Stop/Analyze -> Report -> Query/Plan drilldown

  IMPORTANT
  ---------
  * This script does NOT change validated detector thresholds or root-cause rules.
  * It fixes the end-user orchestration gap exposed by CaptureRunID 36:
        Stop now imports XE evidence and runs the existing RCA analysis pipeline.
  * It surfaces ACTUAL showplan XML from dbo.RCA_PlanEvidence when present.
  * Cached plan XML from sys.dm_exec_query_plan(plan_handle) remains clearly
    labeled as cached-plan evidence and is never called an actual execution plan.
  * Status distinguishes TARGET DATABASE workload from SERVER-WIDE context.
  * Empty evidence is returned as an explicit human-readable status row.
  * Report order is:
      1 WHY
      2 WHO/WHAT
      3 QUERY/PARAMETERS
      4 EXECUTION PLAN
      5 WHY BELIEVE
      6 SERVER HEALTH
      7 WHAT SHOULD I DO
      8 INCIDENT CONTEXT
==============================================================================*/

-------------------------------------------------------------------------------
-- 0. PREREQUISITES
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
 OR OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_StartCapture',N'P') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_StopCapture',N'P') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_ImportXE',N'P') IS NULL
 OR OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NULL
BEGIN
    THROW 52300,N'RCA v2 prerequisites are missing. Core capture/import/analyze objects must exist first.',1;
END;
GO

-------------------------------------------------------------------------------
-- 1. INCIDENT CONTEXT
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_IncidentContext
    (
        CaptureRunID bigint NOT NULL
            CONSTRAINT PK_RCA_IncidentContext PRIMARY KEY,
        RequestedDatabaseName sysname NULL,
        IncidentDescription nvarchar(2000) NULL,
        RequestedBy nvarchar(256) NULL,
        StartedFromHost nvarchar(256) NULL,
        StartedFromProgram nvarchar(512) NULL,
        CreatedTimeUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_IncidentContext_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );
END;
GO

-------------------------------------------------------------------------------
-- 2. CACHED PLAN EVIDENCE (secondary/fallback plan source)
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.RCA_ExecutionPlanEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_ExecutionPlanEvidence
    (
        ExecutionPlanEvidenceID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_ExecutionPlanEvidence PRIMARY KEY,
        CaptureRunID bigint NOT NULL,
        ExecutionEvidenceID bigint NOT NULL,
        PlanHandle varbinary(64) NULL,
        QueryHash varbinary(8) NULL,
        QueryPlanHash varbinary(8) NULL,
        PlanSource varchar(40) NOT NULL,
        QueryPlanXML xml NULL,
        PlanCapturedUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_ExecutionPlanEvidence_Captured
            DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_RCA_ExecutionPlanEvidence
            UNIQUE(CaptureRunID,ExecutionEvidenceID)
    );

    CREATE INDEX IX_RCA_ExecutionPlanEvidence_Run
        ON dbo.RCA_ExecutionPlanEvidence(CaptureRunID,ExecutionEvidenceID);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_CaptureAvailablePlans
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 52310,N'Invalid CaptureRunID.',1;

    /* Refresh only missing fallback rows. Actual plans live in RCA_PlanEvidence. */
    INSERT dbo.RCA_ExecutionPlanEvidence
    (
        CaptureRunID,ExecutionEvidenceID,PlanHandle,QueryHash,QueryPlanHash,
        PlanSource,QueryPlanXML
    )
    SELECT
        e.CaptureRunID,e.ExecutionEvidenceID,e.PlanHandle,e.QueryHash,e.QueryPlanHash,
        CASE WHEN qp.query_plan IS NULL
             THEN 'NOT_AVAILABLE'
             ELSE 'CACHED_PLAN_HANDLE'
        END,
        TRY_CONVERT(xml,qp.query_plan)
    FROM dbo.RCA_ExecutionEvidence e
    OUTER APPLY sys.dm_exec_query_plan(e.PlanHandle) qp
    WHERE e.CaptureRunID=@CaptureRunID
      AND e.PlanHandle IS NOT NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.RCA_ExecutionPlanEvidence p
          WHERE p.CaptureRunID=e.CaptureRunID
            AND p.ExecutionEvidenceID=e.ExecutionEvidenceID
      );

    SELECT
        CaptureRunID=@CaptureRunID,
        ExecutionRows=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence
             WHERE CaptureRunID=@CaptureRunID),
        PlanHandleRows=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence
             WHERE CaptureRunID=@CaptureRunID AND PlanHandle IS NOT NULL),
        ActualShowplanRows=
            CASE WHEN OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL THEN 0
                 ELSE (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence
                       WHERE CaptureRunID=@CaptureRunID
                         AND ActualExecutionPlanXML IS NOT NULL)
            END,
        CachedPlansResolved=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionPlanEvidence
             WHERE CaptureRunID=@CaptureRunID AND QueryPlanXML IS NOT NULL);
END;
GO

-------------------------------------------------------------------------------
-- 3. START
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_Start
    @DatabaseName sysname=NULL,
    @IncidentDescription nvarchar(2000)=NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @DatabaseName IS NOT NULL AND DB_ID(@DatabaseName) IS NULL
        THROW 52320,N'Requested database does not exist.',1;

    DECLARE @CaptureRunID bigint,
            @Reason nvarchar(1000);

    SET @Reason=LEFT
    (
        CONCAT
        (
            N'End-user RCA',
            CASE WHEN @DatabaseName IS NULL
                 THEN N''
                 ELSE CONCAT(N' | DB=',@DatabaseName) END,
            CASE WHEN NULLIF(LTRIM(RTRIM(@IncidentDescription)),N'') IS NULL
                 THEN N''
                 ELSE CONCAT(N' | ',@IncidentDescription) END
        ),
        1000
    );

    EXEC dbo.usp_RCA_StartCapture
         @CaptureReason=@Reason,
         @CaptureRunID=@CaptureRunID OUTPUT;

    INSERT dbo.RCA_IncidentContext
    (
        CaptureRunID,RequestedDatabaseName,IncidentDescription,
        RequestedBy,StartedFromHost,StartedFromProgram
    )
    VALUES
    (
        @CaptureRunID,@DatabaseName,@IncidentDescription,
        ORIGINAL_LOGIN(),HOST_NAME(),PROGRAM_NAME()
    );

    SELECT
        ReportSection='RCA STARTED',
        CaptureRunID=@CaptureRunID,
        DatabaseName=COALESCE(@DatabaseName,N'ALL DATABASES'),
        IncidentDescription=COALESCE(@IncidentDescription,N'Not supplied'),
        Status='CAPTURING',
        CaptureMode='XE runtime capture + RCA server snapshot framework',
        NextStep=CONCAT(N'EXEC DBA.dbo.usp_RCA_Status @CaptureRunID=',@CaptureRunID,N';');
END;
GO

-------------------------------------------------------------------------------
-- 4. STATUS
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_Status
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 52330,N'Invalid CaptureRunID.',1;

    DECLARE @DB sysname;
    SELECT @DB=RequestedDatabaseName
    FROM dbo.RCA_IncidentContext
    WHERE CaptureRunID=@CaptureRunID;

    /* Add a current live snapshot to the run whenever the DBA checks status. */
    IF EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID AND CaptureStatus='RUNNING'
    )
    AND OBJECT_ID(N'dbo.usp_RCA_CaptureLiveSnapshot',N'P') IS NOT NULL
    BEGIN
        EXEC dbo.usp_RCA_CaptureLiveSnapshot @CaptureRunID=@CaptureRunID;
    END;

    SELECT
        ReportSection='1 - INCIDENT STATUS',
        r.CaptureRunID,
        DatabaseName=COALESCE(c.RequestedDatabaseName,N'ALL DATABASES'),
        c.IncidentDescription,
        r.StartTimeUTC,
        r.EndTimeUTC,
        r.CaptureStatus,
        ElapsedSeconds=DATEDIFF(second,r.StartTimeUTC,
                               COALESCE(r.EndTimeUTC,SYSUTCDATETIME())),
        NextStep=
            CASE WHEN r.CaptureStatus='RUNNING'
                 THEN CONCAT(N'When user impact ends: EXEC DBA.dbo.usp_RCA_Stop @CaptureRunID=',r.CaptureRunID,N';')
                 ELSE CONCAT(N'EXEC DBA.dbo.usp_RCA_Report @CaptureRunID=',r.CaptureRunID,N';')
            END
    FROM dbo.RCA_CaptureRun r
    LEFT JOIN dbo.RCA_IncidentContext c
      ON c.CaptureRunID=r.CaptureRunID
    WHERE r.CaptureRunID=@CaptureRunID;

    /* Target-scoped workload. Capture 36 exposed that server-wide counts were
       misleading when the detail grid was filtered to the requested database. */
    SELECT
        ReportSection='2 - TARGET DATABASE WORKLOAD',
        DatabaseScope=COALESCE(@DB,N'ALL DATABASES'),
        ActiveRequests=COUNT(*),
        BlockedRequests=SUM(CASE WHEN ISNULL(r.blocking_session_id,0)<>0 THEN 1 ELSE 0 END),
        LongestRequestSeconds=MAX(CONVERT(decimal(19,2),r.total_elapsed_time/1000.0)),
        TotalCPUms=SUM(CONVERT(bigint,r.cpu_time)),
        TotalLogicalReads=SUM(CONVERT(bigint,r.logical_reads)),
        TotalWrites=SUM(CONVERT(bigint,r.writes))
    FROM sys.dm_exec_requests r
    WHERE r.session_id<>@@SPID
      AND (@DB IS NULL OR DB_NAME(r.database_id)=@DB);

    SELECT TOP(10)
        ReportSection='3 - TOP ACTIVE REQUESTS',
        r.session_id,
        DatabaseName=DB_NAME(r.database_id),
        r.status,r.command,r.wait_type,
        WaitSeconds=CONVERT(decimal(19,2),r.wait_time/1000.0),
        r.blocking_session_id,
        CPUms=r.cpu_time,
        DurationMs=r.total_elapsed_time,
        LogicalReads=r.logical_reads,
        PhysicalReads=r.reads,
        Writes=r.writes,
        s.host_name,s.program_name,s.login_name,
        QueryHash=CONVERT(varchar(18),qs.query_hash,1),
        QueryPlanHash=CONVERT(varchar(18),qs.query_plan_hash,1),
        PlanHandle=CONVERT(varchar(130),r.plan_handle,1),
        RunningStatement=
            SUBSTRING
            (
                t.text,
                (r.statement_start_offset/2)+1,
                (
                    (CASE r.statement_end_offset
                         WHEN -1 THEN DATALENGTH(t.text)
                         ELSE r.statement_end_offset END
                     -r.statement_start_offset)/2
                )+1
            ),
        CachedPlanXML=qp.query_plan,
        PlanNote=
            CASE WHEN qp.query_plan IS NULL
                 THEN 'No cached plan currently resolvable.'
                 ELSE 'LIVE cached plan evidence only; not an actual execution plan.'
            END
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s
      ON s.session_id=r.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
    OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) qp
    OUTER APPLY
    (
        SELECT TOP(1)
            query_hash,query_plan_hash
        FROM sys.dm_exec_query_stats q
        WHERE q.plan_handle=r.plan_handle
        ORDER BY q.last_execution_time DESC
    ) qs
    WHERE r.session_id<>@@SPID
      AND (@DB IS NULL OR DB_NAME(r.database_id)=@DB)
    ORDER BY r.cpu_time DESC,r.logical_reads DESC,r.total_elapsed_time DESC;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.dm_exec_requests r
        WHERE r.session_id<>@@SPID
          AND (@DB IS NULL OR DB_NAME(r.database_id)=@DB)
    )
    BEGIN
        SELECT
            ReportSection='3 - TOP ACTIVE REQUESTS',
            EvidenceStatus='NO ACTIVE TARGET-DATABASE REQUESTS AT THIS STATUS CHECK',
            Meaning='The server can have other active requests while the requested database has none. This is not evidence of a SQL root cause.';
    END;

    SELECT
        ReportSection='4 - SERVER-WIDE CONTEXT',
        ActiveRequests=COUNT(*),
        BlockedRequests=SUM(CASE WHEN ISNULL(blocking_session_id,0)<>0 THEN 1 ELSE 0 END),
        TotalCPUms=SUM(CONVERT(bigint,cpu_time)),
        TotalLogicalReads=SUM(CONVERT(bigint,logical_reads)),
        TotalWrites=SUM(CONVERT(bigint,writes))
    FROM sys.dm_exec_requests
    WHERE session_id<>@@SPID;
END;
GO

-------------------------------------------------------------------------------
-- 5. STOP + COMPLETE ANALYSIS
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_Stop
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 52340,N'Invalid CaptureRunID.',1;

    /* Stop core capture first. */
    IF EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID AND CaptureStatus='RUNNING'
    )
        EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@CaptureRunID;

    /*
      Critical v2 correction:
      v1 stopped capture and immediately attempted plan hydration.
      It did not import the XE file or run the parser/analyzer, which explains
      CaptureRunID 36 returning ExecutionRows=0.
    */
    EXEC dbo.usp_RCA_ImportXE
         @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_AnalyzeCaptureRun
         @CaptureRunID=@CaptureRunID,
         @Reparse=1;

    /* Run already-installed independent domains if present.
       No thresholds/rules are modified here. */
    IF OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildBlockingEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildCPUSchedulerEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildCPUSchedulerEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildIOPressureEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildIOPressureEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildTempDBPressureEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildTempDBPressureEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildMemoryPressureEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildMemoryPressureEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildTransactionLogEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildTransactionLogEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildConnectivityEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildConnectivityEvidence @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

    SELECT
        ReportSection='RCA STOPPED + ANALYZED',
        CaptureRunID=@CaptureRunID,
        CaptureStatus=
            (SELECT CaptureStatus FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID),
        ExecutionRows=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID),
        ActualShowplanRows=
            CASE WHEN OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL THEN 0
                 ELSE (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence
                       WHERE CaptureRunID=@CaptureRunID
                         AND ActualExecutionPlanXML IS NOT NULL)
            END,
        CachedPlansResolved=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionPlanEvidence
             WHERE CaptureRunID=@CaptureRunID AND QueryPlanXML IS NOT NULL),
        NextStep=CONCAT(N'EXEC DBA.dbo.usp_RCA_Report @CaptureRunID=',@CaptureRunID,N';');
END;
GO

-------------------------------------------------------------------------------
-- 6. QUERY / PARAMETERS / PLAN DRILLDOWN
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_QueryPlan
    @CaptureRunID bigint,
    @ExecutionEvidenceID bigint=NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 52350,N'Invalid CaptureRunID.',1;

    EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND (@ExecutionEvidenceID IS NULL OR ExecutionEvidenceID=@ExecutionEvidenceID)
    )
    BEGIN
        SELECT
            ReportSection='QUERY / PARAMETERS / EXECUTION PLAN',
            EvidenceStatus='NO EXECUTION EVIDENCE CAPTURED',
            Meaning='No completed execution evidence was parsed for this incident. Do not infer query attribution or a query plan.';
        RETURN;
    END;

    ;WITH x AS
    (
        SELECT e.*,
               rn=ROW_NUMBER() OVER
                  (ORDER BY ISNULL(e.CPUms,0) DESC,
                            ISNULL(e.LogicalReads,0) DESC,
                            ISNULL(e.DurationMs,0) DESC)
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
          AND (@ExecutionEvidenceID IS NULL
               OR e.ExecutionEvidenceID=@ExecutionEvidenceID)
    )
    SELECT
        ReportSection='QUERY / PARAMETERS / EXECUTION PLAN',
        e.ExecutionEvidenceID,e.EventTimeUTC,e.DatabaseName,e.SessionID,
        ProcedureOrObject=e.ObjectName,
        QueryText=e.SubmittedCommand,
        CapturedParameters=e.ParameterText,
        e.ParameterEvidenceStatus,
        e.HostName,e.ProgramName,e.LoginName,
        e.CPUms,e.DurationMs,e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows,
        QueryHash=CASE WHEN e.QueryHash IS NULL THEN NULL
                       ELSE CONVERT(varchar(18),e.QueryHash,1) END,
        QueryPlanHash=CASE WHEN e.QueryPlanHash IS NULL THEN NULL
                           ELSE CONVERT(varchar(18),e.QueryPlanHash,1) END,
        PlanHandle=CASE WHEN e.PlanHandle IS NULL THEN NULL
                        ELSE CONVERT(varchar(130),e.PlanHandle,1) END,
        PlanAvailability=
            CASE
                WHEN ap.ActualExecutionPlanXML IS NOT NULL
                    THEN 'ACTUAL SHOWPLAN CAPTURED - CLICK XML IN SSMS'
                WHEN cp.QueryPlanXML IS NOT NULL
                    THEN 'CACHED PLAN AVAILABLE - CLICK XML IN SSMS'
                WHEN e.PlanHandle IS NOT NULL
                    THEN 'PLAN HANDLE CAPTURED; XML NO LONGER RESOLVABLE'
                ELSE 'PLAN NOT CAPTURED'
            END,
        PlanSource=
            CASE
                WHEN ap.ActualExecutionPlanXML IS NOT NULL THEN 'ACTUAL_SHOWPLAN_XE'
                WHEN cp.QueryPlanXML IS NOT NULL THEN cp.PlanSource
                ELSE 'NOT_AVAILABLE'
            END,
        ActualExecutionPlanXML=ap.ActualExecutionPlanXML,
        CachedPlanXML=cp.QueryPlanXML,
        PlanInterpretation=
            CASE
                WHEN ap.ActualExecutionPlanXML IS NOT NULL
                    THEN 'Actual execution plan captured by the RCA XE pipeline for this execution.'
                WHEN cp.QueryPlanXML IS NOT NULL
                    THEN 'Cached plan XML resolved from a captured plan handle. This is not an actual execution plan.'
                ELSE 'No plan XML is available. Do not claim plan-level findings.'
            END
    FROM x e
    OUTER APPLY
    (
        SELECT TOP(1) p.ActualExecutionPlanXML
        FROM dbo.RCA_PlanEvidence p
        WHERE p.CaptureRunID=e.CaptureRunID
          AND p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID
          AND p.ActualExecutionPlanXML IS NOT NULL
        ORDER BY p.PlanEvidenceID DESC
    ) ap
    LEFT JOIN dbo.RCA_ExecutionPlanEvidence cp
      ON cp.CaptureRunID=e.CaptureRunID
     AND cp.ExecutionEvidenceID=e.ExecutionEvidenceID
    WHERE @ExecutionEvidenceID IS NOT NULL OR e.rn<=10
    ORDER BY e.rn;
END;
GO

-------------------------------------------------------------------------------
-- 7. POLISHED END-USER REPORT
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RCA_Report
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 52360,N'Invalid CaptureRunID.',1;

    DECLARE
        @Cause varchar(80),
        @Display nvarchar(200),
        @Confidence varchar(20),
        @Evidence nvarchar(max),
        @Action nvarchar(4000),
        @ExecID bigint;

    SELECT TOP(1)
        @Cause=CauseCategory,
        @Display=CauseDisplayName,
        @Confidence=Confidence,
        @Evidence=PrimaryEvidence,
        @Action=RecommendedAction,
        @ExecID=ImpactedExecutionEvidenceID
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseRole='PRIMARY'
      AND Confidence IN('HIGH','MEDIUM')
    ORDER BY RoleRank,ConfidenceRank,ImpactRank,EvidenceStrengthRank;

    ---------------------------------------------------------------------------
    -- 1. WHY
    ---------------------------------------------------------------------------
    SELECT
        ReportSection='1 - WHY WAS IT SLOW?',
        Answer=CASE WHEN @Cause IS NULL
                    THEN 'NO ROOT CAUSE CONFIRMED'
                    ELSE 'ROOT CAUSE IDENTIFIED' END,
        AssessmentState=
            CASE WHEN EXISTS
                 (SELECT 1 FROM dbo.RCA_CaptureRun
                  WHERE CaptureRunID=@CaptureRunID AND CaptureStatus='RUNNING')
                 THEN 'PRELIMINARY' ELSE 'FINAL' END,
        PrimaryCause=COALESCE(@Display,N'No supported primary cause'),
        Confidence=COALESCE(@Confidence,'N/A'),
        Summary=
            CASE WHEN @Cause IS NULL
                 THEN 'Captured SQL Server evidence did not support a PRIMARY root cause at MEDIUM/HIGH confidence. No corrective SQL change is justified from this capture alone.'
                 ELSE CONCAT(N'The RCA engine identified ',@Display,
                             N' as the primary supported cause.')
            END;

    ---------------------------------------------------------------------------
    -- 2. WHO / WHAT
    ---------------------------------------------------------------------------
    IF EXISTS(SELECT 1 FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        SELECT TOP(10)
            ReportSection='2 - WHO / WHAT CAUSED IT?',
            AttributionStatus=
                CASE WHEN e.ExecutionEvidenceID=@ExecID
                     THEN 'PRIMARY ATTRIBUTED EXECUTION'
                     ELSE 'CAPTURED WORKLOAD EVIDENCE' END,
            e.ExecutionEvidenceID,e.EventTimeUTC,e.DatabaseName,e.SessionID,
            ProcedureOrObject=e.ObjectName,
            e.HostName,e.ProgramName,e.LoginName,
            e.CPUms,e.DurationMs,e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows,
            QueryText=e.SubmittedCommand
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
        ORDER BY CASE WHEN e.ExecutionEvidenceID=@ExecID THEN 0 ELSE 1 END,
                 ISNULL(e.CPUms,0) DESC,
                 ISNULL(e.LogicalReads,0) DESC,
                 ISNULL(e.DurationMs,0) DESC;
    END
    ELSE
    BEGIN
        SELECT
            ReportSection='2 - WHO / WHAT CAUSED IT?',
            AttributionStatus='NO EXECUTION ATTRIBUTION AVAILABLE',
            Meaning='No completed execution evidence was captured/parsed for this incident. The RCA will not invent a query, user, host, or application.';
    END;

    ---------------------------------------------------------------------------
    -- 3. QUERY + PARAMETERS
    ---------------------------------------------------------------------------
    IF EXISTS(SELECT 1 FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        SELECT TOP(5)
            ReportSection='3 - QUERY + PARAMETERS',
            e.ExecutionEvidenceID,e.DatabaseName,e.SessionID,
            ProcedureOrObject=e.ObjectName,
            QueryText=e.SubmittedCommand,
            CapturedParameters=e.ParameterText,
            ParameterEvidenceStatus=
                COALESCE(e.ParameterEvidenceStatus,
                         CASE WHEN NULLIF(LTRIM(RTRIM(e.ParameterText)),N'') IS NULL
                              THEN 'NOT CAPTURED'
                              ELSE 'CAPTURED' END),
            e.HostName,e.ProgramName,e.LoginName,
            QueryHash=CASE WHEN e.QueryHash IS NULL THEN NULL
                           ELSE CONVERT(varchar(18),e.QueryHash,1) END,
            QueryPlanHash=CASE WHEN e.QueryPlanHash IS NULL THEN NULL
                               ELSE CONVERT(varchar(18),e.QueryPlanHash,1) END,
            PlanHandle=CASE WHEN e.PlanHandle IS NULL THEN NULL
                            ELSE CONVERT(varchar(130),e.PlanHandle,1) END
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
        ORDER BY CASE WHEN e.ExecutionEvidenceID=@ExecID THEN 0 ELSE 1 END,
                 ISNULL(e.CPUms,0) DESC,
                 ISNULL(e.LogicalReads,0) DESC;
    END
    ELSE
    BEGIN
        SELECT
            ReportSection='3 - QUERY + PARAMETERS',
            EvidenceStatus='NOT CAPTURED',
            Meaning='No execution evidence exists for this incident, therefore no query/procedure or runtime parameters can be attributed.';
    END;

    ---------------------------------------------------------------------------
    -- 4. EXECUTION PLAN
    ---------------------------------------------------------------------------
    EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

    IF EXISTS(SELECT 1 FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        ;WITH e AS
        (
            SELECT x.*,
                   rn=ROW_NUMBER() OVER
                     (ORDER BY CASE WHEN x.ExecutionEvidenceID=@ExecID THEN 0 ELSE 1 END,
                               ISNULL(x.CPUms,0) DESC,
                               ISNULL(x.LogicalReads,0) DESC)
            FROM dbo.RCA_ExecutionEvidence x
            WHERE x.CaptureRunID=@CaptureRunID
        )
        SELECT TOP(5)
            ReportSection='4 - EXECUTION PLAN',
            e.ExecutionEvidenceID,e.DatabaseName,e.SessionID,
            ProcedureOrObject=e.ObjectName,
            e.CPUms,e.DurationMs,e.LogicalReads,
            PlanAvailability=
                CASE
                    WHEN ap.ActualExecutionPlanXML IS NOT NULL
                        THEN 'ACTUAL SHOWPLAN CAPTURED - CLICK XML IN SSMS'
                    WHEN cp.QueryPlanXML IS NOT NULL
                        THEN 'CACHED PLAN AVAILABLE - CLICK XML IN SSMS'
                    WHEN e.PlanHandle IS NOT NULL
                        THEN 'PLAN HANDLE CAPTURED; XML NO LONGER RESOLVABLE'
                    ELSE 'PLAN NOT CAPTURED'
                END,
            PlanSource=
                CASE
                    WHEN ap.ActualExecutionPlanXML IS NOT NULL THEN 'ACTUAL_SHOWPLAN_XE'
                    WHEN cp.QueryPlanXML IS NOT NULL THEN cp.PlanSource
                    ELSE 'NOT_AVAILABLE'
                END,
            ActualExecutionPlanXML=ap.ActualExecutionPlanXML,
            CachedPlanXML=cp.QueryPlanXML,
            ImportantNote=
                CASE
                    WHEN ap.ActualExecutionPlanXML IS NOT NULL
                        THEN 'This is actual-showplan XML captured by the RCA XE pipeline.'
                    WHEN cp.QueryPlanXML IS NOT NULL
                        THEN 'This is cached plan XML resolved from the captured plan handle; do not call it an actual execution plan.'
                    ELSE 'No plan XML is available. Do not make plan-level claims from this row.'
                END
        FROM e
        OUTER APPLY
        (
            SELECT TOP(1) p.ActualExecutionPlanXML
            FROM dbo.RCA_PlanEvidence p
            WHERE p.CaptureRunID=e.CaptureRunID
              AND p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID
              AND p.ActualExecutionPlanXML IS NOT NULL
            ORDER BY p.PlanEvidenceID DESC
        ) ap
        LEFT JOIN dbo.RCA_ExecutionPlanEvidence cp
          ON cp.CaptureRunID=e.CaptureRunID
         AND cp.ExecutionEvidenceID=e.ExecutionEvidenceID
        ORDER BY e.rn;
    END
    ELSE
    BEGIN
        SELECT
            ReportSection='4 - EXECUTION PLAN',
            PlanAvailability='NOT AVAILABLE',
            PlanSource='NO EXECUTION EVIDENCE',
            ImportantNote='No execution evidence was captured/parsed, so no plan can be responsibly attributed to this incident.';
    END;

    ---------------------------------------------------------------------------
    -- 5. WHY BELIEVE
    ---------------------------------------------------------------------------
    SELECT
        ReportSection='5 - WHY DO WE BELIEVE THIS?',
        Confidence=COALESCE(@Confidence,'N/A'),
        Evidence=COALESCE(@Evidence,
            N'No PRIMARY MEDIUM/HIGH-confidence evidence was established.'),
        EvidenceIntegrity=
            CASE WHEN @Cause IS NULL
                 THEN 'The utility intentionally did not manufacture a root cause.'
                 ELSE 'Conclusion comes from the validated RCA final-cause ranking.'
            END;

    ---------------------------------------------------------------------------
    -- 6. SERVER HEALTH DURING INCIDENT
    -- Will-facing health evidence includes Buffer Cache Hit Ratio + PLE.
    ---------------------------------------------------------------------------
    IF EXISTS(SELECT 1 FROM dbo.RCA_ServerSnapshot WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        SELECT
            ReportSection='6 - SERVER HEALTH DURING INCIDENT',
            ServerSamples=COUNT(*),
            FirstSampleUTC=MIN(CaptureTimeUTC),
            LastSampleUTC=MAX(CaptureTimeUTC),
            PeakSqlCpuPercent=MAX(SqlCpuPercent),
            AvgSqlCpuPercent=CONVERT(decimal(9,2),AVG(SqlCpuPercent)),
            PeakOtherCpuPercent=MAX(OtherCpuPercent),
            LowestSystemIdlePercent=MIN(SystemIdlePercent),
            PeakRunnableTasks=MAX(RunnableTasks),
            LowestBufferCacheHitRatio=MIN(BufferCacheHitRatio),
            AvgBufferCacheHitRatio=CONVERT(decimal(19,6),AVG(BufferCacheHitRatio)),
            LowestPLESeconds=MIN(PageLifeExpectancySeconds),
            LowestAvailablePhysicalMemoryMB=MIN(AvailablePhysicalMemoryMB),
            PeakMemoryGrantsPending=MAX(MemoryGrantsPending),
            PeakMemoryGrantsOutstanding=MAX(MemoryGrantsOutstanding),
            MinTotalServerMemoryMB=MIN(TotalServerMemoryMB),
            MaxTargetServerMemoryMB=MAX(TargetServerMemoryMB),
            ServerMaxDOP=MAX(ServerMaxDOP),
            CostThresholdForParallelism=MAX(CostThresholdForParallelism)
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID=@CaptureRunID;
    END
    ELSE
    BEGIN
        SELECT
            ReportSection='6 - SERVER HEALTH DURING INCIDENT',
            EvidenceStatus='NO SERVER SNAPSHOTS',
            Meaning='No server snapshot evidence is available for this capture. CPU, memory, Buffer Cache Hit Ratio, PLE, grants and runnable-task conclusions should not be inferred.';
    END;

    ---------------------------------------------------------------------------
    -- 7. ACTION
    ---------------------------------------------------------------------------
    SELECT
        ReportSection='7 - WHAT SHOULD I DO?',
        RecommendedAction=
            COALESCE
            (
                @Action,
                N'No PRIMARY MEDIUM/HIGH-confidence cause was established. Do not make a SQL Server corrective change from this capture alone. Correlate application/network evidence or repeat the RCA during active user impact.'
            ),
        SafetyNote=
            CASE @Cause
                WHEN 'BLOCKING_WAIT_CHAIN'
                    THEN 'Do not automatically kill the head blocker; confirm transaction owner, business impact and rollback risk.'
                WHEN 'CLIENT_CONNECTION_NETWORK_PRESSURE'
                    THEN 'Do not assume ASYNC_NETWORK_IO proves a bad physical network; confirm client consumption, result-set size, pooling/retries and network path.'
                WHEN 'INSTANCE_MEMORY_PRESSURE'
                    THEN 'Do not change max server memory or add RAM solely from Buffer Cache Hit Ratio. Corroborate grants, PLE, available OS memory and workload demand.'
                ELSE 'Apply changes only after confirming the attributed workload, evidence and business impact.'
            END;

    ---------------------------------------------------------------------------
    -- 8. INCIDENT CONTEXT
    ---------------------------------------------------------------------------
    SELECT
        ReportSection='8 - INCIDENT CONTEXT',
        r.CaptureRunID,
        RequestedDatabaseName=COALESCE(c.RequestedDatabaseName,N'ALL DATABASES'),
        c.IncidentDescription,
        c.RequestedBy,c.StartedFromHost,c.StartedFromProgram,
        r.StartTimeUTC,r.EndTimeUTC,r.CaptureStatus,
        CaptureDurationSeconds=
            DATEDIFF(second,r.StartTimeUTC,COALESCE(r.EndTimeUTC,SYSUTCDATETIME())),
        ExecutionEvidenceRows=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence e
             WHERE e.CaptureRunID=r.CaptureRunID),
        ActualShowplanRows=
            CASE WHEN OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL THEN 0
                 ELSE (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence p
                       WHERE p.CaptureRunID=r.CaptureRunID
                         AND p.ActualExecutionPlanXML IS NOT NULL)
            END
    FROM dbo.RCA_CaptureRun r
    LEFT JOIN dbo.RCA_IncidentContext c
      ON c.CaptureRunID=r.CaptureRunID
    WHERE r.CaptureRunID=@CaptureRunID;
END;
GO

-------------------------------------------------------------------------------
-- 8. INCIDENT LIST
-------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_RCA_IncidentList
AS
WITH x AS
(
    SELECT
        r.CaptureRunID,r.CauseDisplayName,r.Confidence,
        rn=ROW_NUMBER() OVER
        (
            PARTITION BY r.CaptureRunID
            ORDER BY r.RoleRank,r.ConfidenceRank,r.ImpactRank,r.EvidenceStrengthRank
        )
    FROM dbo.vw_RCA_FinalCauseRanking r
    WHERE r.RootCauseRole='PRIMARY'
      AND r.Confidence IN('HIGH','MEDIUM')
)
SELECT
    cr.CaptureRunID,
    DatabaseName=COALESCE(ic.RequestedDatabaseName,N'ALL DATABASES'),
    ic.IncidentDescription,
    cr.StartTimeUTC,cr.EndTimeUTC,cr.CaptureStatus,
    PrimaryCause=COALESCE(x.CauseDisplayName,N'Not confirmed'),
    Confidence=COALESCE(x.Confidence,'N/A'),
    ExecutionEvidenceRows=
        (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence e
         WHERE e.CaptureRunID=cr.CaptureRunID),
    ic.RequestedBy,ic.StartedFromHost
FROM dbo.RCA_CaptureRun cr
LEFT JOIN dbo.RCA_IncidentContext ic
  ON ic.CaptureRunID=cr.CaptureRunID
LEFT JOIN x
  ON x.CaptureRunID=cr.CaptureRunID AND x.rn=1;
GO

-------------------------------------------------------------------------------
-- 9. DEPLOYMENT VALIDATION
-------------------------------------------------------------------------------
SELECT
    IncidentContext=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    ExecutionPlanEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionPlanEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    XEImport=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ImportXE',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    AnalyzePipeline=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    ActualShowplanSource=
        CASE WHEN OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    PlanHydration=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_CaptureAvailablePlans',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    EndUserStart=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Start',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    EndUserStatus=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Status',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    EndUserStop=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    QueryPlanDrilldown=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_QueryPlan',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    EndUserReport=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Report',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
    IncidentList=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_IncidentList',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO

/*==============================================================================
  FIRST V2 USER TEST
  ------------------
  1. Start:
       EXEC dbo.usp_RCA_Start
            @DatabaseName=N'RCA',
            @IncidentDescription=N'Users reporting severe application slowness';

  2. During active impact:
       EXEC dbo.usp_RCA_Status @CaptureRunID=<id>;

  3. Run/reproduce ONE previously validated RCA workload while capture is active.

  4. Status again:
       EXEC dbo.usp_RCA_Status @CaptureRunID=<id>;

  5. Stop. v2 now performs Stop -> Import XE -> Analyze -> installed domain
     builders -> plan hydration:
       EXEC dbo.usp_RCA_Stop @CaptureRunID=<id>;

  6. Final human report:
       EXEC dbo.usp_RCA_Report @CaptureRunID=<id>;

  7. Plan drilldown:
       EXEC dbo.usp_RCA_QueryPlan @CaptureRunID=<id>;

  ACCEPTANCE
  ----------
  A DBA should be able to answer, without opening RCA evidence tables:
    * Why was it slow?
    * Who/what caused it?
    * Which query/procedure?
    * Which parameters were captured?
    * What were CPU/read/write/row impacts?
    * Is the plan ACTUAL showplan or cached-plan evidence?
    * What did server health show, including Buffer Cache Hit Ratio and PLE?
    * What evidence proves the conclusion?
    * What should I do next?

  CaptureRunID 36 lesson incorporated:
    v1 stopped capture without importing/parsing the XE evidence, leaving
    ExecutionRows=0. v2 completes that evidence pipeline automatically.
==============================================================================*/
