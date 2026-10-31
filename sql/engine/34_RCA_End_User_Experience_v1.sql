USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
34_RCA_End_User_Experience_v1.sql

Purpose: DBA-facing Start -> Status -> Stop -> Report workflow over the validated
RCA engine. No detector thresholds or root-cause domains are changed.

Bhuvan requirements surfaced directly:
  - query/procedure
  - captured parameter text/status
  - query hash / query plan hash / plan handle
  - clickable plan XML when the captured plan handle is still resolvable

Important: sys.dm_exec_query_plan(plan_handle) is cached plan XML. This script
does NOT label it an actual execution plan unless the originating capture
explicitly captured actual-showplan XML.
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    THROW 52200,N'Required RCA core objects are missing.',1;
GO

IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.RCA_IncidentContext
 (
   CaptureRunID bigint NOT NULL PRIMARY KEY,
   RequestedDatabaseName sysname NULL,
   IncidentDescription nvarchar(2000) NULL,
   RequestedBy nvarchar(256) NULL,
   StartedFromHost nvarchar(256) NULL,
   StartedFromProgram nvarchar(512) NULL,
   CreatedTimeUTC datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
 );
END;
GO

IF OBJECT_ID(N'dbo.RCA_ExecutionPlanEvidence',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.RCA_ExecutionPlanEvidence
 (
   ExecutionPlanEvidenceID bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
   CaptureRunID bigint NOT NULL,
   ExecutionEvidenceID bigint NOT NULL,
   PlanHandle varbinary(64) NULL,
   QueryHash varbinary(8) NULL,
   QueryPlanHash varbinary(8) NULL,
   PlanSource varchar(40) NOT NULL,
   QueryPlanXML xml NULL,
   PlanCapturedUTC datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
   CONSTRAINT UQ_RCA_ExecutionPlanEvidence UNIQUE(CaptureRunID,ExecutionEvidenceID)
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
 IF NOT EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
   THROW 52210,N'Invalid CaptureRunID.',1;

 INSERT dbo.RCA_ExecutionPlanEvidence
 (CaptureRunID,ExecutionEvidenceID,PlanHandle,QueryHash,QueryPlanHash,PlanSource,QueryPlanXML)
 SELECT e.CaptureRunID,e.ExecutionEvidenceID,e.PlanHandle,e.QueryHash,e.QueryPlanHash,
        CASE WHEN qp.query_plan IS NULL THEN 'NOT_AVAILABLE' ELSE 'LIVE_PLAN_HANDLE' END,
        TRY_CONVERT(xml,qp.query_plan)
 FROM dbo.RCA_ExecutionEvidence e
 OUTER APPLY sys.dm_exec_query_plan(e.PlanHandle) qp
 WHERE e.CaptureRunID=@CaptureRunID
   AND e.PlanHandle IS NOT NULL
   AND NOT EXISTS
       (SELECT 1 FROM dbo.RCA_ExecutionPlanEvidence p
        WHERE p.CaptureRunID=e.CaptureRunID
          AND p.ExecutionEvidenceID=e.ExecutionEvidenceID);

 SELECT CaptureRunID=@CaptureRunID,
        ExecutionRows=(SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID),
        PlanHandleRows=(SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID AND PlanHandle IS NOT NULL),
        PlansResolved=(SELECT COUNT(*) FROM dbo.RCA_ExecutionPlanEvidence WHERE CaptureRunID=@CaptureRunID AND QueryPlanXML IS NOT NULL);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Start
 @DatabaseName sysname=NULL,
 @IncidentDescription nvarchar(2000)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 IF @DatabaseName IS NOT NULL AND DB_ID(@DatabaseName) IS NULL
   THROW 52220,N'Requested database does not exist.',1;

 DECLARE @CaptureRunID bigint,@Reason nvarchar(2000);
 SET @Reason=LEFT(CONCAT(N'End-user RCA',
              CASE WHEN @DatabaseName IS NULL THEN N'' ELSE CONCAT(N' | DB=',@DatabaseName) END,
              CASE WHEN NULLIF(LTRIM(RTRIM(@IncidentDescription)),N'') IS NULL THEN N'' ELSE CONCAT(N' | ',@IncidentDescription) END),2000);

 EXEC dbo.usp_RCA_StartCapture @CaptureReason=@Reason,@CaptureRunID=@CaptureRunID OUTPUT;

 INSERT dbo.RCA_IncidentContext
 (CaptureRunID,RequestedDatabaseName,IncidentDescription,RequestedBy,StartedFromHost,StartedFromProgram)
 VALUES(@CaptureRunID,@DatabaseName,@IncidentDescription,ORIGINAL_LOGIN(),HOST_NAME(),PROGRAM_NAME());

 SELECT ReportSection='RCA STARTED',CaptureRunID=@CaptureRunID,
        DatabaseName=COALESCE(@DatabaseName,N'ALL DATABASES'),
        IncidentDescription=COALESCE(@IncidentDescription,N'Not supplied'),
        Status='CAPTURING',
        NextStep=CONCAT(N'EXEC DBA.dbo.usp_RCA_Status @CaptureRunID=',@CaptureRunID,N';');
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Status
 @CaptureRunID bigint
AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
   THROW 52230,N'Invalid CaptureRunID.',1;

 DECLARE @DB sysname;
 SELECT @DB=RequestedDatabaseName FROM dbo.RCA_IncidentContext WHERE CaptureRunID=@CaptureRunID;

 SELECT ReportSection='1 - INCIDENT STATUS',r.CaptureRunID,
        DatabaseName=COALESCE(c.RequestedDatabaseName,N'ALL DATABASES'),
        c.IncidentDescription,r.StartTimeUTC,r.EndTimeUTC,r.CaptureStatus,
        ElapsedSeconds=DATEDIFF(second,r.StartTimeUTC,COALESCE(r.EndTimeUTC,SYSUTCDATETIME()))
 FROM dbo.RCA_CaptureRun r
 LEFT JOIN dbo.RCA_IncidentContext c ON c.CaptureRunID=r.CaptureRunID
 WHERE r.CaptureRunID=@CaptureRunID;

 SELECT ReportSection='2 - CURRENT WORKLOAD',
        ActiveRequests=COUNT(*),
        BlockedRequests=SUM(CASE WHEN blocking_session_id<>0 THEN 1 ELSE 0 END),
        LongestRequestSeconds=MAX(CONVERT(decimal(19,2),total_elapsed_time/1000.0)),
        TotalCPUms=SUM(CONVERT(bigint,cpu_time)),
        TotalLogicalReads=SUM(CONVERT(bigint,logical_reads)),
        TotalWrites=SUM(CONVERT(bigint,writes))
 FROM sys.dm_exec_requests WHERE session_id<>@@SPID;

 SELECT TOP(10) ReportSection='3 - TOP ACTIVE REQUESTS',
        r.session_id,DatabaseName=DB_NAME(r.database_id),r.status,r.command,r.wait_type,
        WaitSeconds=CONVERT(decimal(19,2),r.wait_time/1000.0),r.blocking_session_id,
        CPUms=r.cpu_time,DurationMs=r.total_elapsed_time,LogicalReads=r.logical_reads,Writes=r.writes,
        s.host_name,s.program_name,s.login_name,
        RunningStatement=SUBSTRING(t.text,(r.statement_start_offset/2)+1,
          (((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END-r.statement_start_offset)/2)+1))
 FROM sys.dm_exec_requests r
 JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
 OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)t
 WHERE r.session_id<>@@SPID AND (@DB IS NULL OR DB_NAME(r.database_id)=@DB)
 ORDER BY r.cpu_time DESC,r.logical_reads DESC,r.total_elapsed_time DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Stop
 @CaptureRunID bigint
AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
   THROW 52240,N'Invalid CaptureRunID.',1;

 IF EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID AND CaptureStatus='RUNNING')
   EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@CaptureRunID;

 EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

 SELECT ReportSection='RCA STOPPED',CaptureRunID=@CaptureRunID,
        CaptureStatus=(SELECT CaptureStatus FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID),
        NextStep=CONCAT(N'EXEC DBA.dbo.usp_RCA_Report @CaptureRunID=',@CaptureRunID,N';');
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_QueryPlan
 @CaptureRunID bigint,
 @ExecutionEvidenceID bigint=NULL
AS
BEGIN
 SET NOCOUNT ON;
 EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

 ;WITH x AS
 (
  SELECT e.*,rn=ROW_NUMBER() OVER
    (ORDER BY ISNULL(e.CPUms,0) DESC,ISNULL(e.LogicalReads,0) DESC,ISNULL(e.DurationMs,0) DESC)
  FROM dbo.RCA_ExecutionEvidence e
  WHERE e.CaptureRunID=@CaptureRunID
    AND (@ExecutionEvidenceID IS NULL OR e.ExecutionEvidenceID=@ExecutionEvidenceID)
 )
 SELECT ReportSection='QUERY / PARAMETERS / EXECUTION PLAN',
        e.ExecutionEvidenceID,e.EventTimeUTC,e.DatabaseName,e.SessionID,
        ProcedureOrObject=e.ObjectName,QueryText=e.SubmittedCommand,
        CapturedParameters=e.ParameterText,e.ParameterEvidenceStatus,
        e.HostName,e.ProgramName,e.LoginName,e.CPUms,e.DurationMs,
        e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows,
        QueryHash=CASE WHEN e.QueryHash IS NULL THEN NULL ELSE CONVERT(varchar(18),e.QueryHash,1) END,
        QueryPlanHash=CASE WHEN e.QueryPlanHash IS NULL THEN NULL ELSE CONVERT(varchar(18),e.QueryPlanHash,1) END,
        PlanAvailability=CASE WHEN p.QueryPlanXML IS NOT NULL THEN 'AVAILABLE - CLICK XML IN SSMS'
                              WHEN e.PlanHandle IS NOT NULL THEN 'PLAN HANDLE CAPTURED; XML NO LONGER AVAILABLE'
                              ELSE 'NOT CAPTURED' END,
        p.PlanSource,p.QueryPlanXML,
        PlanInterpretation=CASE WHEN p.QueryPlanXML IS NOT NULL
          THEN 'Cached plan XML resolved from captured plan handle. Do not call it an actual execution plan unless the source explicitly captured actual-showplan XML.'
          ELSE 'No plan XML is available for this execution.' END
 FROM x e
 LEFT JOIN dbo.RCA_ExecutionPlanEvidence p
   ON p.CaptureRunID=e.CaptureRunID AND p.ExecutionEvidenceID=e.ExecutionEvidenceID
 WHERE @ExecutionEvidenceID IS NOT NULL OR e.rn<=10
 ORDER BY e.rn;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Report
 @CaptureRunID bigint
AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
   THROW 52260,N'Invalid CaptureRunID.',1;

 DECLARE @Cause varchar(80),@Display nvarchar(200),@Confidence varchar(20),
         @Evidence nvarchar(max),@Action nvarchar(4000),@ExecID bigint;

 SELECT TOP(1) @Cause=CauseCategory,@Display=CauseDisplayName,@Confidence=Confidence,
        @Evidence=PrimaryEvidence,@Action=RecommendedAction,@ExecID=ImpactedExecutionEvidenceID
 FROM dbo.vw_RCA_FinalCauseRanking
 WHERE CaptureRunID=@CaptureRunID AND RootCauseRole='PRIMARY' AND Confidence IN('HIGH','MEDIUM')
 ORDER BY RoleRank,ConfidenceRank,ImpactRank,EvidenceStrengthRank;

 SELECT ReportSection='1 - WHY WAS IT SLOW?',
        Answer=CASE WHEN @Cause IS NULL THEN 'NO ROOT CAUSE CONFIRMED' ELSE 'ROOT CAUSE IDENTIFIED' END,
        PrimaryCause=COALESCE(@Display,N'No supported primary cause'),
        Confidence=COALESCE(@Confidence,'N/A'),
        Summary=CASE WHEN @Cause IS NULL
          THEN 'The captured evidence did not support a PRIMARY root cause at MEDIUM/HIGH confidence.'
          ELSE CONCAT(N'The RCA engine identified ',@Display,N' as the primary supported cause.') END;

 SELECT TOP(10) ReportSection='2 - WHO / WHAT CAUSED IT?',
        e.ExecutionEvidenceID,e.EventTimeUTC,e.DatabaseName,e.SessionID,e.ObjectName,
        e.HostName,e.ProgramName,e.LoginName,e.CPUms,e.DurationMs,e.LogicalReads,
        e.PhysicalReads,e.Writes,e.TotalRows,e.SubmittedCommand
 FROM dbo.RCA_ExecutionEvidence e
 WHERE e.CaptureRunID=@CaptureRunID
 ORDER BY CASE WHEN e.ExecutionEvidenceID=@ExecID THEN 0 ELSE 1 END,
          ISNULL(e.CPUms,0) DESC,ISNULL(e.LogicalReads,0) DESC;

 SELECT TOP(5) ReportSection='3 - QUERY + PARAMETERS',
        e.ExecutionEvidenceID,e.DatabaseName,e.SessionID,ProcedureOrObject=e.ObjectName,
        QueryText=e.SubmittedCommand,CapturedParameters=e.ParameterText,e.ParameterEvidenceStatus,
        e.HostName,e.ProgramName,e.LoginName,
        QueryHash=CASE WHEN e.QueryHash IS NULL THEN NULL ELSE CONVERT(varchar(18),e.QueryHash,1) END,
        QueryPlanHash=CASE WHEN e.QueryPlanHash IS NULL THEN NULL ELSE CONVERT(varchar(18),e.QueryPlanHash,1) END
 FROM dbo.RCA_ExecutionEvidence e
 WHERE e.CaptureRunID=@CaptureRunID
 ORDER BY CASE WHEN e.ExecutionEvidenceID=@ExecID THEN 0 ELSE 1 END,
          ISNULL(e.CPUms,0) DESC,ISNULL(e.LogicalReads,0) DESC;

 EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

 SELECT TOP(5) ReportSection='4 - EXECUTION PLAN',
        e.ExecutionEvidenceID,e.DatabaseName,e.SessionID,ProcedureOrObject=e.ObjectName,
        e.CPUms,e.DurationMs,e.LogicalReads,
        PlanAvailability=CASE WHEN p.QueryPlanXML IS NOT NULL THEN 'AVAILABLE - CLICK XML IN SSMS'
                              ELSE 'NOT AVAILABLE FROM CAPTURED PLAN HANDLE' END,
        p.PlanSource,p.QueryPlanXML,
        ImportantNote=CASE WHEN p.QueryPlanXML IS NOT NULL
          THEN 'Cached plan XML resolved from the captured plan handle; it is not automatically an actual execution plan.'
          ELSE 'No plan XML is currently available for this execution.' END
 FROM dbo.RCA_ExecutionEvidence e
 LEFT JOIN dbo.RCA_ExecutionPlanEvidence p
   ON p.CaptureRunID=e.CaptureRunID AND p.ExecutionEvidenceID=e.ExecutionEvidenceID
 WHERE e.CaptureRunID=@CaptureRunID
 ORDER BY CASE WHEN e.ExecutionEvidenceID=@ExecID THEN 0 ELSE 1 END,
          CASE WHEN p.QueryPlanXML IS NOT NULL THEN 0 ELSE 1 END,
          ISNULL(e.CPUms,0) DESC,ISNULL(e.LogicalReads,0) DESC;

 SELECT ReportSection='5 - WHY DO WE BELIEVE THIS?',
        Confidence=COALESCE(@Confidence,'N/A'),
        Evidence=COALESCE(@Evidence,N'No PRIMARY MEDIUM/HIGH-confidence evidence was established.');

 SELECT ReportSection='6 - WHAT ELSE DID WE CHECK?',
        CauseCategory,CauseDisplayName,RootCauseRole,Confidence,PrimaryEvidence
 FROM dbo.vw_RCA_FinalCauseRanking
 WHERE CaptureRunID=@CaptureRunID
 ORDER BY RoleRank,ConfidenceRank,ImpactRank,EvidenceStrengthRank;

 SELECT ReportSection='7 - WHAT SHOULD I DO?',
        RecommendedAction=COALESCE(@Action,
          N'No PRIMARY MEDIUM/HIGH-confidence cause was established. Review evidence or repeat capture during user impact.'),
        SafetyNote=CASE @Cause
          WHEN 'BLOCKING_WAIT_CHAIN' THEN 'Do not automatically kill the head blocker; confirm transaction owner, business impact and rollback risk.'
          WHEN 'CLIENT_CONNECTION_NETWORK_PRESSURE' THEN 'Do not assume ASYNC_NETWORK_IO proves a bad physical network; confirm client consumption, result-set size, pooling/retries and network path.'
          ELSE 'Apply changes only after confirming the attributed workload and business impact.' END;

 SELECT ReportSection='8 - INCIDENT CONTEXT',r.CaptureRunID,c.RequestedDatabaseName,
        c.IncidentDescription,c.RequestedBy,c.StartedFromHost,c.StartedFromProgram,
        r.StartTimeUTC,r.EndTimeUTC,r.CaptureStatus
 FROM dbo.RCA_CaptureRun r
 LEFT JOIN dbo.RCA_IncidentContext c ON c.CaptureRunID=r.CaptureRunID
 WHERE r.CaptureRunID=@CaptureRunID;

 IF OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
   EXEC dbo.usp_RCA_WhyWasItSlow @CaptureRunID=@CaptureRunID;
END;
GO

CREATE OR ALTER VIEW dbo.vw_RCA_IncidentList
AS
WITH x AS
(
 SELECT r.CaptureRunID,r.CauseDisplayName,r.Confidence,
        rn=ROW_NUMBER() OVER(PARTITION BY r.CaptureRunID
             ORDER BY r.RoleRank,r.ConfidenceRank,r.ImpactRank,r.EvidenceStrengthRank)
 FROM dbo.vw_RCA_FinalCauseRanking r
 WHERE r.RootCauseRole='PRIMARY' AND r.Confidence IN('HIGH','MEDIUM')
)
SELECT cr.CaptureRunID,DatabaseName=COALESCE(ic.RequestedDatabaseName,N'ALL DATABASES'),
       ic.IncidentDescription,cr.StartTimeUTC,cr.EndTimeUTC,cr.CaptureStatus,
       PrimaryCause=COALESCE(x.CauseDisplayName,N'Not yet confirmed'),
       Confidence=COALESCE(x.Confidence,'N/A'),ic.RequestedBy,ic.StartedFromHost
FROM dbo.RCA_CaptureRun cr
LEFT JOIN dbo.RCA_IncidentContext ic ON ic.CaptureRunID=cr.CaptureRunID
LEFT JOIN x ON x.CaptureRunID=cr.CaptureRunID AND x.rn=1;
GO

SELECT
 IncidentContext=CASE WHEN OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 ExecutionPlanEvidence=CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionPlanEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 PlanHydration=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_CaptureAvailablePlans',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 EndUserStart=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Start',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 EndUserStatus=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Status',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 EndUserStop=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 QueryPlanDrilldown=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_QueryPlan',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 EndUserReport=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Report',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 IncidentList=CASE WHEN OBJECT_ID(N'dbo.vw_RCA_IncidentList',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

/*
FIRST USER TEST
---------------
After all PASS:

EXEC dbo.usp_RCA_Start
 @DatabaseName=N'RCA',
 @IncidentDescription=N'Users reporting application slowness';

Copy returned CaptureRunID, then:

EXEC dbo.usp_RCA_Status @CaptureRunID=<id>;

Reproduce ONE already-validated incident.

EXEC dbo.usp_RCA_Status @CaptureRunID=<id>;
EXEC dbo.usp_RCA_Stop   @CaptureRunID=<id>;
EXEC dbo.usp_RCA_Report @CaptureRunID=<id>;
EXEC dbo.usp_RCA_QueryPlan @CaptureRunID=<id>;

Acceptance question:
Can a junior DBA answer:
  Why was it slow?
  Who/what caused it?
  Which query/procedure?
  Which parameters?
  Is a plan available and what kind of plan evidence is it?
  What else was checked?
  What should I do next?
without opening the underlying RCA evidence tables?
*/
