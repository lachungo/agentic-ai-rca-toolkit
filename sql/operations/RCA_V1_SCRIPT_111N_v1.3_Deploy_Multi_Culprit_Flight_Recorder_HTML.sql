USE dbamaint;
GO
/*=============================================================================
  RCA V1 - SCRIPT 111N v1.3
  DEPLOY COMPACT MULTI-CULPRIT FLIGHT-RECORDER HTML

  USER EXPERIENCE
    Bhuvan, Will, or a junior DBA supplies only database and local incident time:

      EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
          @DatabaseName   = N'RCA_Demo',
          @BeginTimeLocal = '2026-08-23T13:56:00',
          @EndTimeLocal   = '2026-08-23T13:59:00';

  REPORTING RULES
    * Shows every supported final cause, not only one winner.
    * Shows the final winner transaction and its directly linked actual plan.
    * Shows a parameterized captured transaction when available, with its own
      directly linked actual plan.  It is clearly labelled as an exemplar when
      it is not the winning transaction.
    * Never attaches parameters or a plan from an unrelated capture.

  SAFETY
    Presentation layer only.  No detector, threshold, causal edge, confidence,
    arbitration rule, evidence row, XE session, or Agent job is changed.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 64020, 'SCRIPT 111N ABORTED: run in a new query window.', 1;

DECLARE @Required TABLE(ObjectName sysname, ExpectedType char(2));
INSERT @Required VALUES
 (N'dbo.RCA_CaptureRun',N'U'),
 (N'dbo.vw_RCA_CrossDomainCauseSummary',N'V'),
 (N'dbo.vw_RCA_FinalCauseCandidates',N'V'),
 (N'dbo.RCA_ExecutionEvidence',N'U'),
 (N'dbo.RCA_PlanEvidence',N'U'),
 (N'dbo.RCA_RuntimeParameter',N'U'),
 (N'dbo.RCA_PlanFinding',N'U'),
 (N'dbo.RCA_PlanOperator',N'U'),
 (N'dbo.ufn_RCA_HTMLEncode',N'FN'),
 (N'dbo.usp_RCA_SaveHTMLReport',N'P'),
 (N'dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1',N'P');

IF EXISTS (SELECT 1 FROM @Required WHERE OBJECT_ID(ObjectName,ExpectedType) IS NULL)
BEGIN
    SELECT ObjectName,ExpectedType,
           ObjectState=CASE WHEN OBJECT_ID(ObjectName,ExpectedType) IS NULL THEN 'MISSING' ELSE 'PRESENT' END
    FROM @Required;
    THROW 64021, 'SCRIPT 111N ABORTED: a required reporting/evidence object is missing.', 1;
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
        @GeneratedUTC datetime2(3)=SYSUTCDATETIME(),
        @WinnerExecutionID bigint,
        @WinnerPlanID bigint,
        @WinnerSessionID int,
        @WinnerCause nvarchar(400),
        @WinnerConfidence nvarchar(30),
        @ArbitrationStatus nvarchar(200),
        @ExampleExecutionID bigint,
        @ExamplePlanID bigint,
        @ExampleSessionID int,
        @CauseRows nvarchar(max)=N'',
        @MemoryRows nvarchar(max)=N'',
        @CPURows nvarchar(max)=N'',
        @BlockingRows nvarchar(max)=N'',
        @WinnerBlock nvarchar(max)=N'',
        @ExampleBlock nvarchar(max)=N'',
        @CoverageRows nvarchar(max)=N'',
        @Html nvarchar(max);

    SELECT @DatabaseName=TargetDatabase,@CaptureReason=CaptureReason,
           @StartUTC=StartTimeUTC,@EndUTC=EndTimeUTC,@CaptureStatus=CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    IF @DatabaseName IS NULL THROW 63982, 'Invalid CaptureRunID.', 1;

    SELECT TOP(1)
        @WinnerExecutionID=PrimaryExecutionEvidenceID,
        @WinnerSessionID=PrimarySessionID,
        @WinnerCause=PrimaryCauseDisplayName,
        @WinnerConfidence=PrimaryConfidence,
        @ArbitrationStatus=ArbitrationStatus
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=@CaptureRunID;

    IF @WinnerExecutionID IS NULL
        SELECT TOP(1) @WinnerExecutionID=ImpactedExecutionEvidenceID
        FROM dbo.vw_RCA_FinalCauseCandidates
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole=N'PRIMARY'
          AND ImpactedExecutionEvidenceID IS NOT NULL
        ORDER BY ImpactedExecutionEvidenceID;

    SELECT TOP(1) @WinnerPlanID=PlanEvidenceID
    FROM dbo.RCA_PlanEvidence
    WHERE CaptureRunID=@CaptureRunID
      AND LinkedExecutionEvidenceID=@WinnerExecutionID
      AND ActualExecutionPlanXML IS NOT NULL
    ORDER BY PlanEvidenceID;

    /* Best parameterized transaction in this same capture.  Direct linkage is
       mandatory. Prefer the winner, then the richest parameter set. */
    SELECT TOP(1)
        @ExamplePlanID=p.PlanEvidenceID,
        @ExampleExecutionID=p.LinkedExecutionEvidenceID,
        @ExampleSessionID=e.SessionID
    FROM dbo.RCA_PlanEvidence AS p
    JOIN dbo.RCA_ExecutionEvidence AS e
      ON e.CaptureRunID=p.CaptureRunID
     AND e.ExecutionEvidenceID=p.LinkedExecutionEvidenceID
    CROSS APPLY
    (
        SELECT ParameterCount=COUNT_BIG(*)
        FROM dbo.RCA_RuntimeParameter AS rp
        WHERE rp.CaptureRunID=p.CaptureRunID
          AND rp.PlanEvidenceID=p.PlanEvidenceID
    ) AS pc
    WHERE p.CaptureRunID=@CaptureRunID
      AND e.DatabaseName=@DatabaseName
      AND p.ActualExecutionPlanXML IS NOT NULL
      AND pc.ParameterCount>0
    ORDER BY CASE WHEN p.LinkedExecutionEvidenceID=@WinnerExecutionID THEN 0 ELSE 1 END,
             pc.ParameterCount DESC,p.PlanEvidenceID;

    SELECT @CauseRows=COALESCE((
        SELECT N'<tr><td><span class="pill '+
               CASE RootCauseRole WHEN N'PRIMARY' THEN N'primary' ELSE N'contributing' END+N'">'+
               dbo.ufn_RCA_HTMLEncode(RootCauseRole)+N'</span></td><td><b>'+dbo.ufn_RCA_HTMLEncode(CauseDisplayName)+
               N'</b><br><span class="muted">'+dbo.ufn_RCA_HTMLEncode(CauseCategory)+N'</span></td><td>'+dbo.ufn_RCA_HTMLEncode(Confidence)+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),ImpactedExecutionEvidenceID),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),ImpactedRequestCount),N'—')+N'</td></tr>'
        FROM dbo.vw_RCA_FinalCauseCandidates
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CASE RootCauseRole WHEN N'PRIMARY' THEN 1 WHEN N'CONTRIBUTING' THEN 2 ELSE 3 END,CauseDisplayName
        FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');

    /* Seven-domain coverage distinguishes "not supported" from "not observed". */
    DECLARE @Domains TABLE(DomainOrder int,DomainKey nvarchar(60));
    INSERT @Domains VALUES
      (1,N'CPU_SCHEDULER'),(2,N'BLOCKING_WAIT_CHAIN'),(3,N'IO_STORAGE_LATENCY'),
      (4,N'MEMORY_PRESSURE'),(5,N'TEMPDB_PRESSURE'),
      (6,N'TRANSACTION_LOG_PRESSURE'),(7,N'CONNECTIVITY_PRESSURE');

    SELECT @CoverageRows=COALESCE((
        SELECT N'<tr><td>'+dbo.ufn_RCA_HTMLEncode(d.DomainKey)+N'</td><td>'+COALESCE(x.Outcome,N'NOT SUPPORTED BY THIS WINDOW')+N'</td></tr>'
        FROM @Domains AS d
        OUTER APPLY
        (
            SELECT TOP(1) Outcome=N'<b>'+dbo.ufn_RCA_HTMLEncode(f.RootCauseRole)+N'</b> / '+dbo.ufn_RCA_HTMLEncode(f.Confidence)
            FROM dbo.vw_RCA_FinalCauseCandidates AS f
            WHERE f.CaptureRunID=@CaptureRunID
              AND (f.CauseCategory=d.DomainKey
                   OR (d.DomainKey=N'CPU_SCHEDULER' AND f.CauseCategory LIKE N'CPU_SCHEDULER%')
                   OR (d.DomainKey=N'TEMPDB_PRESSURE' AND f.CauseCategory LIKE N'%SPILL%'))
            ORDER BY CASE f.RootCauseRole WHEN N'PRIMARY' THEN 1 ELSE 2 END
        ) AS x
        ORDER BY d.DomainOrder
        FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');

    /* Preserve the full flight-recorder evidence behind the compressed final
       cause rows. These sections report captured facts whether causal support
       was positive or negative; role/confidence retain the detector verdict. */
    SELECT @MemoryRows=COALESCE((
        SELECT N'<tr><td><b>'+dbo.ufn_RCA_HTMLEncode(PressureSubtype)+N'</b><br><span class="muted">'+
               dbo.ufn_RCA_HTMLEncode(RootCauseRole)+N' / '+dbo.ufn_RCA_HTMLEncode(Confidence)+N'</span></td><td>'+ 
               COALESCE(CONVERT(nvarchar(30),MinBufferCacheHitRatio),N'—')+N' / '+COALESCE(CONVERT(nvarchar(30),AvgBufferCacheHitRatio),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),MinPLESeconds),N'—')+N' / '+COALESCE(CONVERT(nvarchar(30),AvgPLESeconds),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),PeakMemoryGrantsPending),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),MinAvailablePhysicalMemoryMB),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),MaxTargetMemoryDeficitMB),N'—')+
               N'</td><td>'+dbo.ufn_RCA_HTMLEncode(EvidenceSummary)+N'<br><span class="action">Start here: '+dbo.ufn_RCA_HTMLEncode(RecommendedAction)+N'</span></td></tr>'
        FROM dbo.RCA_MemoryPressureEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY MemoryPressureEvidenceID
        FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');

    SELECT @CPURows=COALESCE((
        SELECT N'<tr><td><b>'+dbo.ufn_RCA_HTMLEncode(c.RootCauseRole)+N'</b><br>'+dbo.ufn_RCA_HTMLEncode(c.Confidence)+N'</td><td>'+ 
               COALESCE(CONVERT(nvarchar(30),c.PrimaryExecutionEvidenceID),N'—')+N'</td><td>'+ 
               COALESCE(CONVERT(nvarchar(30),c.PeakSqlCpuPercent),N'—')+N' / '+COALESCE(CONVERT(nvarchar(30),c.AvgSqlCpuPercent),N'—')+
               N'</td><td>'+COALESCE(CONVERT(nvarchar(30),c.PeakRunnableTasks),N'—')+N' / '+COALESCE(CONVERT(nvarchar(30),c.AvgRunnableTasks),N'—')+
               N'</td><td>'+CONVERT(nvarchar(30),c.CapturedExecutionCount)+N'</td><td>'+COALESCE(CONVERT(nvarchar(30),c.TopExecutionCPUSharePercent),N'—')+
               N'</td><td><pre>'+dbo.ufn_RCA_HTMLEncode(COALESCE(e.SubmittedCommand,c.PrimaryStatement,N'(statement unavailable)'))+N'</pre>'+ 
               CASE WHEN p.PlanEvidenceID IS NULL THEN N'<span class="muted">No directly linked actual plan.</span>'
                    ELSE N'<span class="muted">Actual Plan '+CONVERT(nvarchar(30),p.PlanEvidenceID)+N': </span><code>'+dbo.ufn_RCA_HTMLEncode(N'SELECT ActualExecutionPlanXML FROM dbamaint.dbo.RCA_PlanEvidence WHERE CaptureRunID='+CONVERT(nvarchar(30),@CaptureRunID)+N' AND PlanEvidenceID='+CONVERT(nvarchar(30),p.PlanEvidenceID)+N';')+N'</code>' END+
               N'<br><span class="action">Start here: '+dbo.ufn_RCA_HTMLEncode(c.RecommendedAction)+N'</span></td></tr>'
        FROM dbo.RCA_CPUSchedulerEvidence AS c
        LEFT JOIN dbo.RCA_ExecutionEvidence AS e
          ON e.CaptureRunID=c.CaptureRunID AND e.ExecutionEvidenceID=c.PrimaryExecutionEvidenceID
        OUTER APPLY
        (
            SELECT TOP(1) pe.PlanEvidenceID
            FROM dbo.RCA_PlanEvidence AS pe
            WHERE pe.CaptureRunID=c.CaptureRunID
              AND pe.LinkedExecutionEvidenceID=c.PrimaryExecutionEvidenceID
              AND pe.ActualExecutionPlanXML IS NOT NULL
            ORDER BY pe.PlanEvidenceID
        ) AS p
        WHERE c.CaptureRunID=@CaptureRunID
        ORDER BY c.CPUSchedulerEvidenceID
        FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');

    SELECT @BlockingRows=COALESCE((
        SELECT N'<tr><td><b>'+COALESCE(CONVERT(nvarchar(20),HeadBlockerSessionID),N'—')+N'</b></td><td>'+ 
               CONVERT(nvarchar(20),VictimSessionID)+N'</td><td>'+COALESCE(CONVERT(nvarchar(30),VictimExecutionEvidenceID),N'—')+
               N'</td><td>'+dbo.ufn_RCA_HTMLEncode(COALESCE(WaitType,N'—'))+N'</td><td>'+COALESCE(CONVERT(nvarchar(30),WaitDurationMs),N'—')+
               N'</td><td>'+CONVERT(nvarchar(20),BlockingDepth)+N'</td><td>'+COALESCE(CONVERT(nvarchar(20),SampleCount),N'—')+
               N'</td><td><pre>'+dbo.ufn_RCA_HTMLEncode(COALESCE(VictimStatement,N'(victim statement unavailable)'))+N'</pre></td><td><pre>'+dbo.ufn_RCA_HTMLEncode(COALESCE(HeadBlockerStatement,BlockerStatement,N'(blocker statement unavailable)'))+N'</pre></td></tr>'
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY HeadBlockerSessionID,VictimSessionID,BlockingEvidenceID
        FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');

    /* Build one transaction card. The same code is repeated for winner and
       exemplar deliberately so each block retains exact execution-plan lineage. */
    IF @WinnerExecutionID IS NOT NULL
    BEGIN
        DECLARE @WSQL nvarchar(max),@WEventUTC datetime2(3),@WHost nvarchar(256),@WProgram nvarchar(512),@WLogin nvarchar(256),
                @WCPU decimal(38,3),@WDuration decimal(38,3),@WReads bigint,@WParams nvarchar(max)=N'',@WFindings nvarchar(max)=N'',@WPlanQuery nvarchar(max)=N'';
        SELECT @WEventUTC=EventTimeUTC,@WinnerSessionID=COALESCE(@WinnerSessionID,SessionID),
               @WSQL=COALESCE(NULLIF(SubmittedCommand,N''),ParameterText),@WHost=HostName,@WProgram=ProgramName,@WLogin=LoginName,
               @WCPU=CPUms,@WDuration=DurationMs,@WReads=LogicalReads
        FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID AND ExecutionEvidenceID=@WinnerExecutionID;

        IF @WinnerPlanID IS NOT NULL
        BEGIN
            SELECT @WParams=COALESCE((SELECT N'<tr><td><code>'+dbo.ufn_RCA_HTMLEncode(ParameterName)+N'</code></td><td>'+dbo.ufn_RCA_HTMLEncode(ParameterDataType)+N'</td><td><code>'+dbo.ufn_RCA_HTMLEncode(COALESCE(ParameterRuntimeValue,N'(not emitted)'))+N'</code></td><td><code>'+dbo.ufn_RCA_HTMLEncode(COALESCE(ParameterCompiledValue,N'(not emitted)'))+N'</code></td></tr>' FROM dbo.RCA_RuntimeParameter WHERE CaptureRunID=@CaptureRunID AND PlanEvidenceID=@WinnerPlanID ORDER BY RuntimeParameterID FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');
            SELECT @WFindings=COALESCE((SELECT TOP(5) N'<li><b>'+dbo.ufn_RCA_HTMLEncode(Severity)+N' — '+dbo.ufn_RCA_HTMLEncode(FindingType)+N':</b> '+dbo.ufn_RCA_HTMLEncode(FindingText)+N'<br><span class="action">Start here: '+dbo.ufn_RCA_HTMLEncode(COALESCE(RecommendedAction,N'Review the matching actual plan.'))+N'</span></li>' FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND PlanEvidenceID=@WinnerPlanID ORDER BY CASE Severity WHEN N'HIGH' THEN 1 WHEN N'MEDIUM' THEN 2 ELSE 3 END,PlanFindingID FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');
            SET @WPlanQuery=N'SELECT ActualExecutionPlanXML FROM dbamaint.dbo.RCA_PlanEvidence WHERE CaptureRunID='+CONVERT(nvarchar(30),@CaptureRunID)+N' AND PlanEvidenceID='+CONVERT(nvarchar(30),@WinnerPlanID)+N';';
        END;

        SET @WinnerBlock=N'<div class="transaction"><h3>Final winner transaction</h3><div class="facts"><div><b>'+COALESCE(CONVERT(nvarchar(20),@WinnerSessionID),N'—')+N'</b>Session</div><div><b>'+CONVERT(nvarchar(30),@WinnerExecutionID)+N'</b>Execution</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@WinnerPlanID),N'—')+N'</b>Actual plan</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@WCPU),N'—')+N'</b>CPU ms</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@WDuration),N'—')+N'</b>Duration ms</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@WReads),N'—')+N'</b>Logical reads</div></div><p class="muted">Captured '+COALESCE(CONVERT(nvarchar(30),@WEventUTC,121),N'—')+N' UTC · '+dbo.ufn_RCA_HTMLEncode(COALESCE(@WHost,N'—'))+N' · '+dbo.ufn_RCA_HTMLEncode(COALESCE(@WProgram,N'—'))+N' · '+dbo.ufn_RCA_HTMLEncode(COALESCE(@WLogin,N'—'))+N'</p><pre>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@WSQL,N'(SQL text unavailable)'))+N'</pre>'+
          CASE WHEN @WParams=N'' THEN N'<div class="note">This exact winner plan emitted no runtime parameter list.</div>' ELSE N'<h4>Runtime parameters — exact winner plan</h4><table><tr><th>Name</th><th>Type</th><th>Runtime</th><th>Compiled</th></tr>'+@WParams+N'</table>' END+
          CASE WHEN @WinnerPlanID IS NULL THEN N'<div class="note">No actual plan is directly linked to this winner; no substitute plan is shown.</div>' ELSE N'<h4>Matching actual execution plan</h4><pre>'+dbo.ufn_RCA_HTMLEncode(@WPlanQuery)+N'</pre>' END+
          CASE WHEN @WFindings=N'' THEN N'' ELSE N'<h4>Plan findings and investigative starting points</h4><ul>'+@WFindings+N'</ul>' END+N'</div>';
    END;

    IF @ExamplePlanID IS NOT NULL AND (@ExampleExecutionID<>@WinnerExecutionID OR @WinnerPlanID IS NULL)
    BEGIN
        DECLARE @ESQL nvarchar(max),@EEventUTC datetime2(3),@ECPU decimal(38,3),@EDuration decimal(38,3),@EReads bigint,@EParams nvarchar(max)=N'',@EFindings nvarchar(max)=N'',@EPlanQuery nvarchar(max);
        SELECT @EEventUTC=EventTimeUTC,@ESQL=COALESCE(NULLIF(SubmittedCommand,N''),ParameterText),@ECPU=CPUms,@EDuration=DurationMs,@EReads=LogicalReads
        FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID AND ExecutionEvidenceID=@ExampleExecutionID;
        SELECT @EParams=COALESCE((SELECT N'<tr><td><code>'+dbo.ufn_RCA_HTMLEncode(ParameterName)+N'</code></td><td>'+dbo.ufn_RCA_HTMLEncode(ParameterDataType)+N'</td><td><code>'+dbo.ufn_RCA_HTMLEncode(COALESCE(ParameterRuntimeValue,N'(not emitted)'))+N'</code></td><td><code>'+dbo.ufn_RCA_HTMLEncode(COALESCE(ParameterCompiledValue,N'(not emitted)'))+N'</code></td></tr>' FROM dbo.RCA_RuntimeParameter WHERE CaptureRunID=@CaptureRunID AND PlanEvidenceID=@ExamplePlanID ORDER BY RuntimeParameterID FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');
        SELECT @EFindings=COALESCE((SELECT TOP(5) N'<li><b>'+dbo.ufn_RCA_HTMLEncode(Severity)+N' — '+dbo.ufn_RCA_HTMLEncode(FindingType)+N':</b> '+dbo.ufn_RCA_HTMLEncode(FindingText)+N'<br><span class="action">Start here: '+dbo.ufn_RCA_HTMLEncode(COALESCE(RecommendedAction,N'Review the matching actual plan.'))+N'</span></li>' FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND PlanEvidenceID=@ExamplePlanID ORDER BY CASE Severity WHEN N'HIGH' THEN 1 WHEN N'MEDIUM' THEN 2 ELSE 3 END,PlanFindingID FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),N'');
        SET @EPlanQuery=N'SELECT ActualExecutionPlanXML FROM dbamaint.dbo.RCA_PlanEvidence WHERE CaptureRunID='+CONVERT(nvarchar(30),@CaptureRunID)+N' AND PlanEvidenceID='+CONVERT(nvarchar(30),@ExamplePlanID)+N';';
        SET @ExampleBlock=N'<div class="transaction exemplar"><h3>Captured query with runtime parameters and matching plan</h3><div class="note"><b>Evidence label:</b> This is the exact captured query shown below. Its runtime parameters and actual plan are linked to this same execution. It is shown separately when the final winner did not emit runtime parameters.</div><div class="facts"><div><b>'+COALESCE(CONVERT(nvarchar(20),@ExampleSessionID),N'—')+N'</b>Session</div><div><b>'+CONVERT(nvarchar(30),@ExampleExecutionID)+N'</b>Execution</div><div><b>'+CONVERT(nvarchar(30),@ExamplePlanID)+N'</b>Actual plan</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@ECPU),N'—')+N'</b>CPU ms</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@EDuration),N'—')+N'</b>Duration ms</div><div><b>'+COALESCE(CONVERT(nvarchar(30),@EReads),N'—')+N'</b>Logical reads</div></div><p class="muted">Captured '+CONVERT(nvarchar(30),@EEventUTC,121)+N' UTC</p><pre>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@ESQL,N'(SQL text unavailable)'))+N'</pre><h4>Runtime parameters — this exact plan</h4><table><tr><th>Name</th><th>Type</th><th>Runtime</th><th>Compiled</th></tr>'+@EParams+N'</table><h4>Matching actual execution plan</h4><pre>'+dbo.ufn_RCA_HTMLEncode(@EPlanQuery)+N'</pre>'+CASE WHEN @EFindings=N'' THEN N'' ELSE N'<h4>Plan findings and investigative starting points</h4><ul>'+@EFindings+N'</ul>' END+N'</div>';
    END;

    SET @Html=N'<!doctype html><html><head><meta charset="utf-8"><title>RCA '+dbo.ufn_RCA_HTMLEncode(@DatabaseName)+N'</title><style>
body{margin:0;background:#eef3f8;color:#18243a;font:14px Segoe UI,Arial,sans-serif}.page{max-width:1180px;margin:20px auto;background:#fff;padding:28px 34px;box-shadow:0 2px 15px #7893aa55}.head{display:flex;justify-content:space-between;gap:25px;border-bottom:1px solid #ccd7e4;padding-bottom:15px}.head h1{margin:0;color:#092a62}.meta{display:grid;grid-template-columns:repeat(2,minmax(170px,1fr));gap:8px;font-size:12px}.meta b{display:block;color:#092a62}.section{margin-top:20px}.section h2{color:#083b80;font-size:18px;border-bottom:1px solid #d8e2ee;padding-bottom:7px}.hero{border:1px solid #e54747;background:#fff5f5;border-radius:7px;padding:18px}.hero h3{margin:6px 0;color:#c71820}.pill{display:inline-block;padding:4px 9px;border-radius:12px;color:#fff;font-weight:700;font-size:11px}.primary{background:#d71920}.contributing{background:#e99b00}.transaction{border:1px solid #d8e2ed;border-radius:7px;padding:16px;margin:12px 0}.exemplar{border-color:#73a6df;background:#f8fbff}.facts{display:grid;grid-template-columns:repeat(6,1fr);gap:8px;margin:12px 0}.facts div{border:1px solid #dce4ed;border-radius:6px;padding:9px;text-align:center}.facts b{display:block;color:#0a3470;font-size:17px}pre,code{font-family:Consolas,monospace}pre{white-space:pre-wrap;word-break:break-word;background:#fff9e8;border:1px solid #ead9a2;padding:11px;border-radius:5px;max-height:260px;overflow:auto}table{width:100%;border-collapse:collapse;font-size:12px}th{background:#edf4fb;color:#123c74;text-align:left}th,td{padding:7px;border:1px solid #dce4ed;vertical-align:top}.note{background:#eef6ff;border:1px solid #c9ddf4;padding:11px;border-radius:5px}.muted{color:#667489;font-size:12px}.action{color:#155e2d}.guard{background:#edf8ec;border:1px solid #b8ddb5;padding:13px;border-radius:6px}@media(max-width:850px){.head{display:block}.facts{grid-template-columns:repeat(2,1fr)}.meta{margin-top:12px}}
    </style></head><body><main class="page"><header class="head"><div><h1>Incident Analysis Report</h1><div class="muted">RCA V1 multi-cause flight recorder</div></div><div class="meta"><div><b>Database</b>'+dbo.ufn_RCA_HTMLEncode(@DatabaseName)+N'</div><div><b>Internal capture</b>'+CONVERT(nvarchar(30),@CaptureRunID)+N'</div><div><b>Window (UTC)</b>'+CONVERT(nvarchar(30),@StartUTC,121)+N'<br>'+COALESCE(CONVERT(nvarchar(30),@EndUTC,121),N'(open)')+N'</div><div><b>Generated (UTC)</b>'+CONVERT(nvarchar(30),@GeneratedUTC,121)+N'</div></div></header>'+
    N'<section class="section"><h2>1. Executive Summary</h2><div class="hero"><span class="pill primary">'+dbo.ufn_RCA_HTMLEncode(COALESCE(@WinnerConfidence,N'NOT CONFIRMED'))+N'</span><h3>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@WinnerCause,N'Root cause not confirmed'))+N'</h3><div>'+dbo.ufn_RCA_HTMLEncode(COALESCE(@ArbitrationStatus,N'No supported final winner'))+N'</div></div></section>'+
    N'<section class="section"><h2>2. All Supported Causes</h2>'+CASE WHEN @CauseRows=N'' THEN N'<div class="note">No supported final cause was established for this window.</div>' ELSE N'<table><tr><th>Role</th><th>Cause</th><th>Confidence</th><th>Execution</th><th>Impacted requests</th></tr>'+@CauseRows+N'</table>' END+N'</section>'+
    N'<section class="section"><h2>3. Cause Evidence and Impacted Requests</h2>'+
      N'<h3>Memory and buffer pool</h3>'+CASE WHEN @MemoryRows=N'' THEN N'<div class="note">No memory-pressure evidence row was persisted.</div>' ELSE N'<table><tr><th>Subtype / verdict</th><th>Buffer Cache Hit Ratio<br>min / avg %</th><th>PLE<br>min / avg sec</th><th>Peak grants pending</th><th>Min available MB</th><th>Max target deficit MB</th><th>Evidence and action</th></tr>'+@MemoryRows+N'</table>' END+
      N'<h3>CPU and scheduler</h3>'+CASE WHEN @CPURows=N'' THEN N'<div class="note">No CPU/scheduler evidence row was persisted.</div>' ELSE N'<table><tr><th>Verdict</th><th>Primary execution</th><th>SQL CPU<br>peak / avg %</th><th>Runnable tasks<br>peak / avg</th><th>Captured executions</th><th>Top CPU share %</th><th>Exact statement, plan, and action</th></tr>'+@CPURows+N'</table>' END+
      N'<h3>Blocking chains and every impacted request</h3>'+CASE WHEN @BlockingRows=N'' THEN N'<div class="note">No blocking chain was supported for this capture.</div>' ELSE N'<table><tr><th>Head blocker</th><th>Victim session</th><th>Victim execution</th><th>Wait</th><th>Wait ms</th><th>Depth</th><th>Samples</th><th>Victim statement</th><th>Head-blocker statement</th></tr>'+@BlockingRows+N'</table>' END+N'</section>'+
    N'<section class="section"><h2>4. Transactions, Parameters, and Matching Plans</h2>'+CASE WHEN @WinnerBlock=N'' THEN N'<div class="note">No execution-level final winner was persisted.</div>' ELSE @WinnerBlock END+@ExampleBlock+N'</section>'+
    N'<section class="section"><h2>5. Seven-Domain Flight-Recorder View</h2><table><tr><th>Domain</th><th>Final support in this window</th></tr>'+@CoverageRows+N'</table><p class="muted">“Not supported by this window” means the final arbitration layer did not support that domain as causal. It does not claim the subsystem never experienced activity.</p></section>'+
    N'<section class="section"><h2>6. Guardrail</h2><div class="guard"><b>Start with the PRIMARY transaction and its exact plan.</b> Then review each CONTRIBUTING cause shown above. Do not change MAXDOP, max server memory, TempDB layout, log growth, indexes, or statistics unless the captured evidence and matching plan support that specific change.</div></section>'+
    N'<footer class="muted" style="margin-top:18px">Capture status: '+dbo.ufn_RCA_HTMLEncode(@CaptureStatus)+N'. '+dbo.ufn_RCA_HTMLEncode(COALESCE(@CaptureReason,N''))+N'. Report lineage is confined to CaptureRunID '+CONVERT(nvarchar(30),@CaptureRunID)+N'.</footer></main></body></html>';

    SELECT HtmlDocument=@Html;
END;
GO

DECLARE @RendererObjectID int=OBJECT_ID(N'dbo.usp_RCA_RenderHTMLReport',N'P');
DECLARE @Definition nvarchar(max)=OBJECT_DEFINITION(@RendererObjectID);

DECLARE @RendererObjectGate varchar(4)=CASE WHEN @RendererObjectID IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
DECLARE @MultiCauseGate varchar(4)=CASE WHEN @Definition LIKE N'%All Supported Causes%' THEN 'PASS' ELSE 'FAIL' END;
DECLARE @CapturedQueryGate varchar(4)=CASE WHEN @Definition LIKE N'%Captured query with runtime parameters and matching plan%' THEN 'PASS' ELSE 'FAIL' END;
DECLARE @StrictLineageGate varchar(4)=CASE WHEN @Definition LIKE N'%ExecutionEvidenceID=p.LinkedExecutionEvidenceID%' THEN 'PASS' ELSE 'FAIL' END;
DECLARE @MemoryMetricsGate varchar(4)=CASE WHEN @Definition LIKE N'%MinBufferCacheHitRatio%' AND @Definition LIKE N'%AvgBufferCacheHitRatio%' THEN 'PASS' ELSE 'FAIL' END;
DECLARE @BlockingRequestsGate varchar(4)=CASE WHEN @Definition LIKE N'%Blocking chains and every impacted request%' AND @Definition LIKE N'%VictimExecutionEvidenceID%' THEN 'PASS' ELSE 'FAIL' END;
DECLARE @CPUEvidenceGate varchar(4)=CASE WHEN @Definition LIKE N'%PeakSqlCpuPercent%' AND @Definition LIKE N'%CapturedExecutionCount%' THEN 'PASS' ELSE 'FAIL' END;

SELECT ValidationSection=N'1 - SCRIPT 111N DEPLOYMENT VERDICT',
       Result=CASE WHEN @RendererObjectGate='PASS'
                        AND @MultiCauseGate='PASS'
                        AND @CapturedQueryGate='PASS'
                        AND @StrictLineageGate='PASS'
                        AND @MemoryMetricsGate='PASS'
                        AND @BlockingRequestsGate='PASS'
                        AND @CPUEvidenceGate='PASS'
                   THEN N'PASS' ELSE N'FAIL' END,
       RendererObjectGate=@RendererObjectGate,
       MultiCauseGate=@MultiCauseGate,
       CapturedQueryGate=@CapturedQueryGate,
       StrictLineageGate=@StrictLineageGate,
       MemoryMetricsGate=@MemoryMetricsGate,
       BlockingRequestsGate=@BlockingRequestsGate,
       CPUEvidenceGate=@CPUEvidenceGate,
       ReportScope=N'ALL FINAL CAUSES + WINNER TRANSACTION + PARAMETERIZED EXACT-PLAN EXAMPLE',
       UserInput=N'DATABASE NAME + LOCAL BEGIN/END TIME; NO CAPTURE ID',
       SafetyStatement=N'PRESENTATION OBJECT ONLY; CERTIFIED RCA LOGIC AND EVIDENCE UNCHANGED';

IF @RendererObjectGate='FAIL'
   OR @MultiCauseGate='FAIL'
   OR @CapturedQueryGate='FAIL'
   OR @StrictLineageGate='FAIL'
   OR @MemoryMetricsGate='FAIL'
   OR @BlockingRequestsGate='FAIL'
   OR @CPUEvidenceGate='FAIL'
    THROW 64022, 'SCRIPT 111N FAILED: multi-cause renderer deployment contract did not pass.', 1;

SELECT NormalUserCommand=
N'EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
    @DatabaseName=N''RCA_Demo'',
    @BeginTimeLocal=''2026-08-23T13:56:00'',
    @EndTimeLocal=''2026-08-23T13:59:00'';',
       DirectPositiveControlSave=N'EXEC dbamaint.dbo.usp_RCA_SaveHTMLReport @CaptureRunID=93,@OutputDirectory=N''C:\RCA'';',
       Important=N'Bhuvan uses NormalUserCommand. CaptureRunID is internal and is resolved automatically.';
GO
