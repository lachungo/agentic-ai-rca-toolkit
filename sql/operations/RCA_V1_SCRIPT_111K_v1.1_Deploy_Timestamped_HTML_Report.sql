USE dbamaint;
GO
/*=============================================================================
  RCA V1 - SCRIPT 111K v1.1
  DEPLOY TIMESTAMPED HTML INCIDENT REPORT

  PURPOSE
    Creates a presentation-only HTML layer over the certified RCA evidence.
    No collector, detector, threshold, causal edge, or arbitration object is
    changed.

  OUTPUT
    C:\RCA\RCA_Incident_<Database>_<CaptureRunID>_<yyyyMMdd_HHmmss>.html

  NORMAL USE
    EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
         @DatabaseName  = N'RCA',
         @BeginTimeLocal = '2026-08-23T06:35:38',
         @EndTimeLocal   = '2026-08-23T06:36:23';

  REQUIREMENTS
    * C:\RCA exists and the SQL Server service account can write to it.
    * xp_cmdshell is already enabled (this script never enables it).
    * bcp.exe is installed on the SQL Server host.

  v1.1 CORRECTION
    Removes the invalid BCP -h-1 load hint. BCP does not permit load hints
    with QUERYOUT. No report, detector, or arbitration behavior is weakened.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 63980, 'SCRIPT 111K ABORTED: use a new query window.', 1;

DECLARE @Required TABLE(ObjectName sysname, ObjectType char(2));
INSERT @Required VALUES
 (N'dbo.RCA_CaptureRun',N'U'),
 (N'dbo.vw_RCA_FinalCauseCandidates',N'V'),
 (N'dbo.vw_RCA_CrossDomainCauseSummary',N'V'),
 (N'dbo.usp_RCA_DBAAnswer',N'P');

IF EXISTS
(
    SELECT 1 FROM @Required
    WHERE OBJECT_ID(ObjectName,ObjectType) IS NULL
)
    THROW 63981, 'SCRIPT 111K ABORTED: required certified RCA objects are missing.', 1;
GO

CREATE OR ALTER FUNCTION dbo.ufn_RCA_HTMLEncode(@Value nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    IF @Value IS NULL RETURN N'';
    SET @Value=REPLACE(@Value,N'&',N'&amp;');
    SET @Value=REPLACE(@Value,N'<',N'&lt;');
    SET @Value=REPLACE(@Value,N'>',N'&gt;');
    SET @Value=REPLACE(@Value,N'"',N'&quot;');
    SET @Value=REPLACE(@Value,N'''',N'&#39;');
    RETURN @Value;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_RenderHTMLReport
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @DatabaseName sysname,
        @CaptureReason nvarchar(2000),
        @StartUTC datetime2(3),
        @EndUTC datetime2(3),
        @CaptureStatus varchar(30),
        @CauseCategory nvarchar(128),
        @CauseName nvarchar(400),
        @CauseRole nvarchar(30),
        @Confidence nvarchar(30),
        @EvidenceObject sysname,
        @EvidenceID bigint,
        @PrimaryExecutionID bigint,
        @PrimarySessionID int,
        @SupportedCauseCount int,
        @PrimaryCauseCount int,
        @ArbitrationStatus nvarchar(200),
        @GeneratedUTC datetime2(3)=SYSUTCDATETIME(),
        @AnswerState nvarchar(60),
        @Narrative nvarchar(max)=N'',
        @Kpis nvarchar(max)=N'',
        @DomainRows nvarchar(max)=N'',
        @ParameterRows nvarchar(max)=N'',
        @ExecutionRows nvarchar(max)=N'',
        @AffectedRows nvarchar(max)=N'',
        @PlanRows nvarchar(max)=N'',
        @FindingRows nvarchar(max)=N'',
        @FinalRows nvarchar(max)=N'',
        @Html nvarchar(max);

    SELECT
        @DatabaseName=TargetDatabase,
        @CaptureReason=CaptureReason,
        @StartUTC=StartTimeUTC,
        @EndUTC=EndTimeUTC,
        @CaptureStatus=CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    IF @DatabaseName IS NULL
        THROW 63982, 'Invalid CaptureRunID.', 1;

    SELECT TOP(1)
        @CauseCategory=PrimaryCauseCategory,
        @CauseName=PrimaryCauseDisplayName,
        @CauseRole=PrimaryCauseRole,
        @Confidence=PrimaryConfidence,
        @EvidenceObject=PrimaryEvidenceObject,
        @EvidenceID=PrimaryEvidenceID,
        @PrimaryExecutionID=PrimaryExecutionEvidenceID,
        @PrimarySessionID=PrimarySessionID,
        @SupportedCauseCount=SupportedCauseCount,
        @PrimaryCauseCount=PrimaryCauseCount,
        @ArbitrationStatus=ArbitrationStatus
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=@CaptureRunID;

    SET @AnswerState=CASE WHEN @CauseCategory IS NULL
                          THEN N'ROOT CAUSE NOT CONFIRMED'
                          ELSE N'ROOT CAUSE IDENTIFIED' END;

    DECLARE @Answer TABLE
    (
        SectionOrder int,
        ReportSection nvarchar(200),
        Narrative nvarchar(max)
    );
    BEGIN TRY
        INSERT @Answer EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=@CaptureRunID;
    END TRY
    BEGIN CATCH
        INSERT @Answer VALUES
        (1,N'ANSWER',N'The certified DBA-answer procedure could not be rendered: '+ERROR_MESSAGE());
    END CATCH;

    SELECT @Narrative=COALESCE
    (
        (
            SELECT N'<div class="qa"><div class="ql">'+
                   dbo.ufn_RCA_HTMLEncode(ReportSection)+N'</div><div class="av">'+
                   dbo.ufn_RCA_HTMLEncode(Narrative)+N'</div></div>'
            FROM @Answer
            ORDER BY SectionOrder
            FOR XML PATH(''),TYPE
        ).value('.','nvarchar(max)'),N''
    );

    DECLARE
        @ExecutionCount bigint=0,
        @DistinctWorkloads bigint=0,
        @SessionCount bigint=0,
        @TotalCPU decimal(38,2)=0,
        @TotalDuration decimal(38,2)=0,
        @LogicalReads bigint=0,
        @PlanCount bigint=0,
        @ParameterCount bigint=0,
        @BlockingCount bigint=0;

    IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
    BEGIN
        SELECT
            @ExecutionCount=COUNT_BIG(*),
            @DistinctWorkloads=COUNT_BIG(DISTINCT COALESCE(NULLIF(ObjectName,N''),NULLIF(SubmittedCommand,N''))),
            @SessionCount=COUNT_BIG(DISTINCT SessionID),
            @TotalCPU=COALESCE(SUM(COALESCE(CPUms,0))/1000.0,0),
            @TotalDuration=COALESCE(SUM(COALESCE(DurationMs,0))/1000.0,0),
            @LogicalReads=COALESCE(SUM(COALESCE(LogicalReads,0)),0)
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID=@CaptureRunID;
    END;
    IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NOT NULL
        SELECT @PlanCount=COUNT_BIG(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID;
    IF OBJECT_ID(N'dbo.RCA_RuntimeParameter',N'U') IS NOT NULL
        SELECT @ParameterCount=COUNT_BIG(*) FROM dbo.RCA_RuntimeParameter WHERE CaptureRunID=@CaptureRunID;
    IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL
        SELECT @BlockingCount=COUNT_BIG(*) FROM dbo.RCA_BlockingEvidence WHERE CaptureRunID=@CaptureRunID;

    SET @Kpis=
      N'<div class="kpi"><b>'+CONVERT(nvarchar(30),@ExecutionCount)+N'</b><span>Executions</span></div>'+
      N'<div class="kpi"><b>'+CONVERT(nvarchar(30),@SessionCount)+N'</b><span>Sessions</span></div>'+
      N'<div class="kpi"><b>'+CONVERT(nvarchar(30),@DistinctWorkloads)+N'</b><span>Workloads</span></div>'+
      N'<div class="kpi"><b>'+CONVERT(nvarchar(30),@BlockingCount)+N'</b><span>Blocking rows</span></div>'+
      N'<div class="kpi"><b>'+CONVERT(nvarchar(30),@PlanCount)+N'</b><span>Actual plans</span></div>'+
      N'<div class="kpi"><b>'+CONVERT(nvarchar(30),@ParameterCount)+N'</b><span>Parameters</span></div>';

    DECLARE @Domains TABLE(DomainOrder int, DomainKey nvarchar(100), DisplayName nvarchar(100));
    INSERT @Domains VALUES
     (1,N'CPU_SCHEDULER',N'CPU / Scheduler'),
     (2,N'BLOCKING_WAIT_CHAIN',N'Blocking / Wait Chain'),
     (3,N'IO_STORAGE_LATENCY',N'I/O Storage Latency'),
     (4,N'MEMORY_PRESSURE',N'Memory Pressure'),
     (5,N'TEMPDB_PRESSURE',N'TempDB Pressure'),
     (6,N'TRANSACTION_LOG_PRESSURE',N'Transaction Log Pressure'),
     (7,N'CONNECTIVITY_PRESSURE',N'Connectivity Pressure');

    SELECT @DomainRows=COALESCE
    (
      (
        SELECT N'<tr><td>'+dbo.ufn_RCA_HTMLEncode(d.DisplayName)+N'</td><td>'+COALESCE
               (dbo.ufn_RCA_HTMLEncode(f.CauseDisplayName),N'No supported cause')+N'</td><td><span class="pill '+
               CASE WHEN f.RootCauseRole=N'PRIMARY' THEN N'bad' WHEN f.RootCauseRole=N'CONTRIBUTING' THEN N'warn' ELSE N'ok' END+N'">'+
               COALESCE(dbo.ufn_RCA_HTMLEncode(f.RootCauseRole),N'NOT CONFIRMED')+N'</span></td><td>'+COALESCE
               (dbo.ufn_RCA_HTMLEncode(f.Confidence),N'—')+N'</td></tr>'
        FROM @Domains d
        OUTER APPLY
        (
          SELECT TOP(1) CauseDisplayName,RootCauseRole,Confidence
          FROM dbo.vw_RCA_FinalCauseCandidates x
          WHERE x.CaptureRunID=@CaptureRunID
            AND (x.CauseCategory=d.DomainKey OR
                 (d.DomainKey=N'CPU_SCHEDULER' AND x.CauseCategory LIKE N'CPU%') OR
                 (d.DomainKey=N'IO_STORAGE_LATENCY' AND x.CauseCategory LIKE N'IO%') OR
                 (d.DomainKey=N'CONNECTIVITY_PRESSURE' AND x.CauseCategory LIKE N'CLIENT_CONNECT%'))
          ORDER BY CASE RootCauseRole WHEN N'PRIMARY' THEN 1 WHEN N'CONTRIBUTING' THEN 2 ELSE 3 END,
                   CASE Confidence WHEN N'HIGH' THEN 1 WHEN N'MEDIUM' THEN 2 ELSE 3 END
        ) f
        ORDER BY d.DomainOrder
        FOR XML PATH(''),TYPE
      ).value('.','nvarchar(max)'),N''
    );

    IF OBJECT_ID(N'dbo.RCA_RuntimeParameter',N'U') IS NOT NULL
      SELECT @ParameterRows=COALESCE
      ((
        SELECT TOP(50) N'<tr><td>'+dbo.ufn_RCA_HTMLEncode(ParameterName)+N'</td><td>'+dbo.ufn_RCA_HTMLEncode(ParameterDataType)+
               N'</td><td><code>'+dbo.ufn_RCA_HTMLEncode(COALESCE(ParameterRuntimeValue,ParameterCompiledValue,N'(not captured)'))+
               N'</code></td><td>'+dbo.ufn_RCA_HTMLEncode(EvidenceSource)+N'</td></tr>'
        FROM dbo.RCA_RuntimeParameter
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY PlanEvidenceID,RuntimeParameterID
        FOR XML PATH(''),TYPE
      ).value('.','nvarchar(max)'),N'');

    IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
      SELECT @ExecutionRows=COALESCE
      ((
        SELECT TOP(20) N'<tr><td>'+CONVERT(nvarchar(20),ExecutionEvidenceID)+N'</td><td>'+COALESCE(CONVERT(nvarchar(20),SessionID),N'—')+
               N'</td><td>'+dbo.ufn_RCA_HTMLEncode(COALESCE(NULLIF(ObjectName,N''),LEFT(SubmittedCommand,250),N'(unknown workload)'))+
               N'</td><td>'+FORMAT(COALESCE(CPUms,0)/1000.0,N'N2')+N'</td><td>'+FORMAT(COALESCE(DurationMs,0)/1000.0,N'N2')+
               N'</td><td>'+FORMAT(COALESCE(LogicalReads,0),N'N0')+N'</td><td>'+dbo.ufn_RCA_HTMLEncode(COALESCE(HostName,N'—'))+
               N'</td><td>'+dbo.ufn_RCA_HTMLEncode(COALESCE(ProgramName,N'—'))+N'</td></tr>'
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CASE WHEN ExecutionEvidenceID=@PrimaryExecutionID THEN 0 ELSE 1 END,
                 COALESCE(CPUms,0) DESC,COALESCE(DurationMs,0) DESC
        FOR XML PATH(''),TYPE
      ).value('.','nvarchar(max)'),N'');

    IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
      SELECT @AffectedRows=COALESCE
      ((
        SELECT TOP(20) N'<tr><td>'+COALESCE(CONVERT(nvarchar(20),SessionID),N'—')+N'</td><td>'+dbo.ufn_RCA_HTMLEncode
               (CASE WHEN SessionID=@PrimarySessionID THEN N'PRIMARY / CULPRIT' ELSE N'OBSERVED' END)+N'</td><td>'+dbo.ufn_RCA_HTMLEncode
               (COALESCE(NULLIF(ObjectName,N''),LEFT(SubmittedCommand,200),N'(unknown workload)'))+N'</td><td>'+dbo.ufn_RCA_HTMLEncode
               (COALESCE(HostName,N'—'))+N'</td><td>'+dbo.ufn_RCA_HTMLEncode(COALESCE(LoginName,N'—'))+N'</td><td>'+FORMAT
               (COALESCE(DurationMs,0)/1000.0,N'N2')+N'</td></tr>'
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CASE WHEN SessionID=@PrimarySessionID THEN 0 ELSE 1 END,COALESCE(DurationMs,0) DESC
        FOR XML PATH(''),TYPE
      ).value('.','nvarchar(max)'),N'');

    IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NOT NULL
      SELECT @PlanRows=COALESCE
      ((
        SELECT TOP(10) N'<tr><td>'+CONVERT(nvarchar(20),PlanEvidenceID)+N'</td><td>'+COALESCE(CONVERT(nvarchar(20),SessionID),N'—')+
               N'</td><td>'+CONVERT(nvarchar(30),EventTimeUTC,121)+N'</td><td>'+dbo.ufn_RCA_HTMLEncode(LEFT(COALESCE(SQLText,N'(SQL text unavailable)'),350))+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),RequestedMemoryKB),N'—')+N'</td><td>'+COALESCE(CONVERT(nvarchar(30),GrantedMemoryKB),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(20),ActualDOP),N'—')+N'</td></tr>'
        FROM dbo.RCA_PlanEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CASE WHEN LinkedExecutionEvidenceID=@PrimaryExecutionID THEN 0 ELSE 1 END,EventTimeUTC
        FOR XML PATH(''),TYPE
      ).value('.','nvarchar(max)'),N'');

    IF OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NOT NULL
      SELECT @FindingRows=COALESCE
      ((
        SELECT TOP(30) N'<div class="action"><span class="pill '+CASE WHEN Severity=N'HIGH' THEN N'bad' ELSE N'warn' END+N'">'+
               dbo.ufn_RCA_HTMLEncode(Severity)+N'</span><b>'+dbo.ufn_RCA_HTMLEncode(FindingType)+N'</b><p>'+dbo.ufn_RCA_HTMLEncode
               (FindingText)+N'</p><p><strong>Start here:</strong> '+dbo.ufn_RCA_HTMLEncode(RecommendedAction)+N'</p></div>'
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CASE Severity WHEN N'HIGH' THEN 1 WHEN N'MEDIUM' THEN 2 ELSE 3 END,PlanFindingID
        FOR XML PATH(''),TYPE
      ).value('.','nvarchar(max)'),N'');

    SELECT @FinalRows=COALESCE
    ((
      SELECT N'<tr><td>'+dbo.ufn_RCA_HTMLEncode(CauseDisplayName)+N'</td><td>'+dbo.ufn_RCA_HTMLEncode(RootCauseRole)+
             N'</td><td>'+dbo.ufn_RCA_HTMLEncode(Confidence)+N'</td><td>'+dbo.ufn_RCA_HTMLEncode(CorrelationKey)+N'</td></tr>'
      FROM dbo.vw_RCA_FinalCauseCandidates
      WHERE CaptureRunID=@CaptureRunID
      ORDER BY CASE RootCauseRole WHEN N'PRIMARY' THEN 1 WHEN N'CONTRIBUTING' THEN 2 ELSE 3 END
      FOR XML PATH(''),TYPE
    ).value('.','nvarchar(max)'),N'');

    SET @Html=N'<!doctype html><html><head><meta charset="utf-8"><title>RCA Incident '+
      dbo.ufn_RCA_HTMLEncode(@DatabaseName)+N'</title><style>'+N'
body{margin:0;background:#eef3f9;color:#17243b;font-family:Segoe UI,Arial,sans-serif} .page{max-width:1420px;margin:20px auto;background:#fff;padding:26px 30px;box-shadow:0 2px 16px #9aa9bb66}.head{display:flex;justify-content:space-between;gap:30px;border-bottom:1px solid #ccd6e2;padding-bottom:18px}.head h1{margin:0;color:#0b285e;font-size:30px}.sub{color:#52627a}.meta{display:grid;grid-template-columns:repeat(3,minmax(150px,1fr));gap:12px;font-size:13px}.meta b{display:block;color:#071b3f}.section{margin-top:20px}.section h2{font-size:18px;color:#083678;border-bottom:1px solid #d6e0ec;padding-bottom:8px}.num{display:inline-grid;place-items:center;background:#064795;color:#fff;border-radius:50%;width:28px;height:28px;margin-right:8px}.banner{border:1px solid '+CASE WHEN @CauseCategory IS NULL THEN N'#d5a52d;background:#fff8df' ELSE N'#ef4343;background:#fff4f4' END+N';border-radius:7px;padding:18px;display:grid;grid-template-columns:210px 1fr;gap:20px}.banner strong{font-size:19px;color:'+CASE WHEN @CauseCategory IS NULL THEN N'#8b6300' ELSE N'#c71919' END+N'}.kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:9px;margin-top:12px}.kpi{border:1px solid #d9e2ed;border-radius:6px;padding:13px;text-align:center}.kpi b{font-size:22px;color:#092d68;display:block}.kpi span{font-size:12px;color:#53627a}.grid2{display:grid;grid-template-columns:1fr 1fr;gap:14px}.card{border:1px solid #d8e1ec;border-radius:7px;padding:16px;background:#fff}.qa{display:grid;grid-template-columns:190px 1fr;border-bottom:1px solid #e5eaf0;padding:8px 0}.ql{font-weight:700;color:#123b75}.av{line-height:1.45}table{border-collapse:collapse;width:100%;font-size:12px}th{background:#eef4fb;color:#133b73;text-align:left}th,td{border:1px solid #dbe3ed;padding:7px;vertical-align:top}code{white-space:pre-wrap;word-break:break-word}.pill{display:inline-block;padding:3px 7px;border-radius:9px;font-size:10px;font-weight:700}.bad{background:#d71920;color:#fff}.warn{background:#f3a000;color:#fff}.ok{background:#e5f5e9;color:#167636}.action{border-left:4px solid #1b67b2;background:#f4f8fd;padding:10px 12px;margin:8px 0}.action b{margin-left:7px}.action p{margin:6px 0}.conclusion{background:#edf8ec;border:1px solid #b7dbb4;padding:15px;border-radius:7px}.muted{color:#657287;font-size:12px}.scroll{overflow-x:auto}@media(max-width:900px){.grid2,.kpis,.head{display:block}.kpi,.card{margin-top:8px}.meta{grid-template-columns:1fr}.qa{grid-template-columns:1fr}}</style></head><body><main class="page">'+
      N'<header class="head"><div><h1>Incident Analysis Report</h1><div class="sub">SQL Server RCA V1 — Database Performance Flight Recorder</div></div><div class="meta">'+
      N'<div><b>Capture ID</b>'+CONVERT(nvarchar(30),@CaptureRunID)+N'</div><div><b>Database</b>'+dbo.ufn_RCA_HTMLEncode(@DatabaseName)+N'</div><div><b>Server</b>'+dbo.ufn_RCA_HTMLEncode(CONVERT(sysname,SERVERPROPERTY('ServerName')))+N'</div><div><b>Window (UTC)</b>'+CONVERT(nvarchar(30),@StartUTC,121)+N'<br>'+COALESCE(CONVERT(nvarchar(30),@EndUTC,121),N'(open)')+N'</div><div><b>Status</b>'+dbo.ufn_RCA_HTMLEncode(@CaptureStatus)+N'</div><div><b>Generated (UTC)</b>'+CONVERT(nvarchar(30),@GeneratedUTC,121)+N'</div></div></header>'+
      N'<section class="section"><h2><span class="num">1</span>Executive Summary</h2><div class="banner"><strong>'+dbo.ufn_RCA_HTMLEncode(@AnswerState)+N'</strong><div><b>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@CauseName,N'No supported PRIMARY cause'))+N'</b><br>Role: '+dbo.ufn_RCA_HTMLEncode(COALESCE(@CauseRole,N'—'))+N' &nbsp; Confidence: '+dbo.ufn_RCA_HTMLEncode(COALESCE(@Confidence,N'—'))+N'<br><span class="muted">'+dbo.ufn_RCA_HTMLEncode(COALESCE(@ArbitrationStatus,N'No final winner'))+N'</span></div></div><div class="kpis">'+@Kpis+N'</div></section>'+
      N'<section class="section"><h2><span class="num">2</span>DBA Answer</h2><div class="card">'+@Narrative+N'</div></section>'+
      N'<section class="section"><h2><span class="num">3</span>Root Cause / Culprit Details</h2><div class="grid2"><div class="card"><b>Cause</b><p>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@CauseName,N'Not confirmed'))+N'</p><b>Category</b><p>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@CauseCategory,N'—'))+N'</p><b>Evidence</b><p>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@EvidenceObject,N'—'))+N' #'+COALESCE(CONVERT(nvarchar(30),@EvidenceID),N'—')+N'</p><b>Primary session</b><p>'+COALESCE(CONVERT(nvarchar(20),@PrimarySessionID),N'—')+N'</p></div><div class="card scroll"><table><thead><tr><th>Candidate</th><th>Role</th><th>Confidence</th><th>Correlation</th></tr></thead><tbody>'+@FinalRows+N'</tbody></table></div></div></section>'+
      N'<section class="section"><h2><span class="num">4</span>Runtime Parameters</h2><div class="card scroll"><table><thead><tr><th>Parameter</th><th>Type</th><th>Captured value</th><th>Source</th></tr></thead><tbody>'+CASE WHEN @ParameterRows=N'' THEN N'<tr><td colspan="4">No runtime parameter values were captured for this incident.</td></tr>' ELSE @ParameterRows END+N'</tbody></table><p class="muted">Runtime value is preferred; compiled value is shown only when runtime evidence is unavailable.</p></div></section>'+
      N'<section class="section"><h2><span class="num">5</span>Execution Plan Evidence</h2><div class="card scroll"><table><thead><tr><th>Plan ID</th><th>Session</th><th>Captured UTC</th><th>SQL text</th><th>Requested KB</th><th>Granted KB</th><th>DOP</th></tr></thead><tbody>'+CASE WHEN @PlanRows=N'' THEN N'<tr><td colspan="7">No actual plan was captured for this incident.</td></tr>' ELSE @PlanRows END+N'</tbody></table><p><b>View a plan in SSMS:</b> SELECT ActualExecutionPlanXML FROM dbamaint.dbo.RCA_PlanEvidence WHERE PlanEvidenceID=&lt;Plan ID&gt;; Then click the XML value or save it as .sqlplan.</p></div></section>'+
      N'<section class="section"><h2><span class="num">6</span>Top Workloads and Affected Sessions</h2><div class="card scroll"><table><thead><tr><th>Execution ID</th><th>Session</th><th>Workload</th><th>CPU s</th><th>Duration s</th><th>Logical reads</th><th>Host</th><th>Application</th></tr></thead><tbody>'+CASE WHEN @ExecutionRows=N'' THEN N'<tr><td colspan="8">No completed execution evidence was captured in this incident window.</td></tr>' ELSE @ExecutionRows END+N'</tbody></table><h3>Observed sessions</h3><table><thead><tr><th>Session</th><th>Role</th><th>Workload</th><th>Host</th><th>Login</th><th>Duration s</th></tr></thead><tbody>'+CASE WHEN @AffectedRows=N'' THEN N'<tr><td colspan="6">No session-level execution evidence was captured.</td></tr>' ELSE @AffectedRows END+N'</tbody></table></div></section>'+
      N'<section class="section"><h2><span class="num">7</span>Seven-Domain Assessment</h2><div class="card scroll"><table><thead><tr><th>Domain</th><th>Finding</th><th>Disposition</th><th>Confidence</th></tr></thead><tbody>'+@DomainRows+N'</tbody></table><p class="muted">“Not confirmed” means the persisted evidence did not satisfy that detector; it does not mean telemetry existed for every possible symptom.</p></div></section>'+
      N'<section class="section"><h2><span class="num">8</span>Junior DBA Starting Actions</h2><div class="card">'+CASE WHEN @FindingRows=N'' THEN N'<div class="action"><b>No plan-specific finding was generated.</b><p>Start by correlating the complaint window with the top workloads, host/application, waits, and seven-domain assessment. Do not change instance-wide settings without a supported cause.</p></div>' ELSE @FindingRows END+N'<div class="action"><b>Do not change yet</b><p>Do not change MAXDOP, cost threshold, max server memory, TempDB layout, autogrowth, indexes, or statistics solely because they are common tuning targets. Require evidence from this incident first.</p></div></div></section>'+
      N'<section class="section"><h2><span class="num">9</span>Causal Conclusion</h2><div class="conclusion">'+CASE WHEN @CauseCategory IS NULL THEN N'The RCA framework did not confirm a supported PRIMARY cause for this capture. This is a valid result: preserve the evidence, verify telemetry coverage, and collect a window that overlaps the user-visible slowdown.' ELSE N'The deterministic arbitration layer selected <b>'+dbo.ufn_RCA_HTMLEncode(@CauseName)+N'</b> as '+dbo.ufn_RCA_HTMLEncode(@CauseRole)+N' with '+dbo.ufn_RCA_HTMLEncode(@Confidence)+N' confidence. Investigate the correlated workload/evidence above before making broader changes.' END+N'</div></section>'+
      N'<footer class="muted" style="margin-top:20px">Capture reason: '+dbo.ufn_RCA_HTMLEncode(COALESCE(@CaptureReason,N''))+N'<br>All times are UTC unless explicitly labeled. Generated by dbamaint RCA V1.</footer></main></body></html>';

    SELECT HtmlDocument=@Html;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_SaveHTMLReport
    @CaptureRunID bigint,
    @OutputDirectory nvarchar(260)=N'C:\RCA'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatabaseName sysname;
    SELECT @DatabaseName=TargetDatabase
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;
    IF @DatabaseName IS NULL THROW 63982,'Invalid CaptureRunID.',1;

    DECLARE @xp bit=0;
    SELECT @xp=CONVERT(bit,value_in_use)
    FROM sys.configurations WHERE name=N'xp_cmdshell';
    IF @xp=0
        THROW 63983,'HTML rendered but file output is unavailable because xp_cmdshell is disabled. This procedure does not enable it.',1;

    SET @DatabaseName=REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@DatabaseName,N'\\',N'_'),N'/',N'_'),N':',N'_'),N'*',N'_'),N'?',N'_');
    DECLARE @Stamp char(15)=CONVERT(char(8),GETDATE(),112)+N'_'+REPLACE(CONVERT(char(8),GETDATE(),108),N':',N'');
    DECLARE @File nvarchar(4000)=@OutputDirectory+CASE WHEN RIGHT(@OutputDirectory,1)=N'\' THEN N'' ELSE N'\' END+
        N'RCA_Incident_'+@DatabaseName+N'_'+CONVERT(nvarchar(30),@CaptureRunID)+N'_'+@Stamp+N'.html';

    DECLARE @Server nvarchar(256)=CONVERT(nvarchar(256),SERVERPROPERTY('ServerName'));
    DECLARE @Command nvarchar(4000)=N'bcp "EXEC dbamaint.dbo.usp_RCA_RenderHTMLReport @CaptureRunID='+
        CONVERT(nvarchar(30),@CaptureRunID)+N'" queryout "'+REPLACE(@File,N'"',N'')+
        N'" -S "'+REPLACE(@Server,N'"',N'')+N'" -T -c -C 65001';

    DECLARE @Output TABLE(Line nvarchar(4000));
    INSERT @Output EXEC master.dbo.xp_cmdshell @Command;

    IF NOT EXISTS(SELECT 1 FROM @Output WHERE Line LIKE N'%rows copied%')
    BEGIN
        SELECT ReportSection=N'HTML FILE OUTPUT DIAGNOSTIC',Line FROM @Output WHERE Line IS NOT NULL;
        THROW 63984,'HTML report file was not written. Verify C:\RCA permissions, bcp.exe, and the SQL Server xp_cmdshell proxy/service identity.',1;
    END;

    SELECT
        ReportSection=N'RCA HTML REPORT',
        CaptureRunID=@CaptureRunID,
        DatabaseName=@DatabaseName,
        HtmlFile=@File,
        Result=N'PASS';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
    @DatabaseName sysname,
    @BeginTimeLocal datetime2(0),
    @EndTimeLocal datetime2(0),
    @InputTimeZone sysname=N'Eastern Standard Time',
    @OutputDirectory nvarchar(260)=N'C:\RCA'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF DB_ID(@DatabaseName) IS NULL
        THROW 63986,'The requested database does not exist on this SQL Server.',1;
    IF @BeginTimeLocal IS NULL OR @EndTimeLocal IS NULL OR @BeginTimeLocal>=@EndTimeLocal
        THROW 63987,'Enter a valid local incident window; begin time must precede end time.',1;

    DECLARE @BeginUTC datetime2(3),@EndUTC datetime2(3),@CaptureRunID bigint;
    BEGIN TRY
        SET @BeginUTC=CONVERT(datetime2(3),@BeginTimeLocal AT TIME ZONE @InputTimeZone AT TIME ZONE 'UTC');
        SET @EndUTC=CONVERT(datetime2(3),@EndTimeLocal AT TIME ZONE @InputTimeZone AT TIME ZONE 'UTC');
    END TRY
    BEGIN CATCH
        THROW 63988,'The input time-zone name is invalid. Use a SQL Server Windows time-zone name such as Eastern Standard Time.',1;
    END CATCH;

    SELECT TOP(1) @CaptureRunID=CaptureRunID
    FROM dbo.RCA_CaptureRun
    WHERE TargetDatabase=@DatabaseName
      AND CaptureStatus=N'ANALYZED'
      AND StartTimeUTC<=@BeginUTC
      AND EndTimeUTC>=@EndUTC
    ORDER BY StartTimeUTC DESC,CaptureRunID DESC;

    IF @CaptureRunID IS NULL
    BEGIN
        SELECT
            ReportSection=N'RCA HTML REQUEST',
            DatabaseName=@DatabaseName,
            BeginTimeLocal=@BeginTimeLocal,
            EndTimeLocal=@EndTimeLocal,
            InputTimeZone=@InputTimeZone,
            BeginTimeUTC=@BeginUTC,
            EndTimeUTC=@EndUTC,
            RequestStatus=N'NO ANALYZED CAPTURE COVERS THE COMPLETE WINDOW';
        THROW 63989,'No analyzed capture for this database covers the complete requested incident window.',1;
    END;

    EXEC dbo.usp_RCA_SaveHTMLReport
         @CaptureRunID=@CaptureRunID,
         @OutputDirectory=@OutputDirectory;
END;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'dbo.ufn_RCA_HTMLEncode',N'FN') IS NULL
       OR OBJECT_ID(N'dbo.usp_RCA_RenderHTMLReport',N'P') IS NULL
       OR OBJECT_ID(N'dbo.usp_RCA_SaveHTMLReport',N'P') IS NULL
       OR OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1',N'P') IS NULL
        THROW 63985,'SCRIPT 111K deployment object gate failed.',1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

DECLARE @XpState bit=(SELECT CONVERT(bit,value_in_use) FROM sys.configurations WHERE name=N'xp_cmdshell');
SELECT
    ValidationSection=N'SCRIPT 111K v1.1 DEPLOYMENT VERDICT',
    Result=N'PASS',
    Renderer=N'dbo.usp_RCA_RenderHTMLReport',
    FileWriter=N'dbo.usp_RCA_SaveHTMLReport',
    UserFrontDoor=N'dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1',
    OutputPattern=N'C:\RCA\RCA_Incident_<Database>_<CaptureRunID>_<yyyyMMdd_HHmmss>.html',
    XpCmdShellReady=@XpState,
    SafetyStatement=N'PRESENTATION OBJECTS ONLY; CERTIFIED RCA COLLECTION, DETECTION, AND ARBITRATION UNCHANGED';

SELECT
    NormalCommand=N'EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1 @DatabaseName=N''RCA'', @BeginTimeLocal=''2026-08-23T06:35:38'', @EndTimeLocal=''2026-08-23T06:36:23'';',
    PositiveControlCommand=N'EXEC dbamaint.dbo.usp_RCA_SaveHTMLReport @CaptureRunID=18;',
    PreviewWithoutWriting=N'EXEC dbamaint.dbo.usp_RCA_RenderHTMLReport @CaptureRunID=91;';
GO
