USE dbamaint;
GO
/*=============================================================================
  RCA V1 - SCRIPT 111L3 v1.0
  ATOMIC STATEMENT-EXECUTION FALLBACK + CAPTURE 93 ACCEPTANCE

  ROOT CAUSE PROVED BY SCRIPT 111L2
    * Capture 93 contains RCA_Demo sp_statement_completed events and actual plans.
    * It contains no imported parent execution rows.
    * The certified parser creates executions only from rpc_completed and
      sql_batch_completed, so the plans and runtime parameters cannot link.

  CORRECTION
    Preserve rpc_completed/sql_batch_completed as the preferred parent.
    Promote sp_statement_completed to an execution only when no later parent
    completion exists for the same database and session within 120 seconds.

  SAFETY
    * One atomic transaction covers the procedure alteration and Capture 93
      reparse/analysis.
    * Any deployment or acceptance failure rolls back every change.
    * No detector threshold, causal edge, priority, confidence, or arbitration
      rule is changed.
    * The remaining deployed parser definition is preserved exactly.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 64010, 'SCRIPT 111L3 ABORTED: use a new query window with no open transaction.', 1;

DECLARE @CaptureRunID bigint = 93;
DECLARE @ParserObjectID int = OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun', N'P');
DECLARE @AnalyzerObjectID int = OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun', N'P');
DECLARE @OldDefinition nvarchar(max);
DECLARE @NewDefinition nvarchar(max);
DECLARE @ReplacementSection nvarchar(max);
DECLARE @AStart int;
DECLARE @BStart int;
DECLARE @CreatePos int;
DECLARE @ProcedurePos int;
DECLARE @HeaderText nvarchar(200);
DECLARE @FailedStage nvarchar(128) = N'PREFLIGHT';

IF @ParserObjectID IS NULL OR @AnalyzerObjectID IS NULL
    THROW 64011, 'SCRIPT 111L3 ABORTED: required parser or analyzer procedure is missing.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = @CaptureRunID
      AND TargetDatabase = N'RCA_Demo'
      AND CaptureStatus = 'ANALYZED'
)
    THROW 64012, 'SCRIPT 111L3 ABORTED: analyzed RCA_Demo CaptureRunID 93 is not available.', 1;

SELECT @OldDefinition = sm.definition
FROM sys.sql_modules AS sm
WHERE sm.object_id = @ParserObjectID;

SET @AStart = CHARINDEX(N'-- A. EXECUTION-LEVEL COMPLETED EVENTS', @OldDefinition);
SET @BStart = CHARINDEX(N'-- B. CHILD STATEMENT COMPLETED EVENTS', @OldDefinition);

IF @OldDefinition IS NULL OR @AStart = 0 OR @BStart <= @AStart
    THROW 64013, 'SCRIPT 111L3 ABORTED: certified parser section markers were not found exactly as required.', 1;

IF CHARINDEX(N'-- A. EXECUTION-LEVEL COMPLETED EVENTS', @OldDefinition, @AStart + 1) > 0
   OR CHARINDEX(N'-- B. CHILD STATEMENT COMPLETED EVENTS', @OldDefinition, @BStart + 1) > 0
    THROW 64014, 'SCRIPT 111L3 ABORTED: parser section markers are ambiguous.', 1;

SET @ReplacementSection = N'-- A. EXECUTION-LEVEL COMPLETED EVENTS
    -- Preferred parents remain rpc_completed and sql_batch_completed.
    -- A statement completion becomes a fallback execution only where the XE
    -- window contains no later parent completion for the same DB/session.
    DECLARE @ExecutionTargetDatabase sysname;

    SELECT @ExecutionTargetDatabase = TargetDatabase
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = @CaptureRunID;

    INSERT dbo.RCA_ExecutionEvidence
    (
          CaptureRunID, XERawID, EventName, EventTimeUTC, DatabaseName, SessionID
        , ObjectName, SubmittedCommand, ParameterText, ParameterEvidenceStatus
        , HostName, ProgramName, LoginName, CPUms, DurationMs, LogicalReads
        , PhysicalReads, Writes, TotalRows, QueryHash, QueryPlanHash, PlanHandle
    )
    SELECT
          @CaptureRunID
        , r.XERawID
        , r.EventName
        , r.EventTimeUTC
        , NULLIF(r.EventXML.value(''(/event/action[@name="database_name"]/value/text())[1]'',''nvarchar(128)''),N'''')
        , TRY_CONVERT(int,r.EventXML.value(''(/event/action[@name="session_id"]/value/text())[1]'',''nvarchar(20)''))
        , NULLIF(r.EventXML.value(''(/event/data[@name="object_name"]/value/text())[1]'',''nvarchar(512)''),N'''')
        , COALESCE
          (
              NULLIF(r.EventXML.value(''(/event/data[@name="statement"]/value/text())[1]'',''nvarchar(max)''),N''''),
              NULLIF(r.EventXML.value(''(/event/data[@name="batch_text"]/value/text())[1]'',''nvarchar(max)''),N''''),
              NULLIF(r.EventXML.value(''(/event/action[@name="sql_text"]/value/text())[1]'',''nvarchar(max)''),N'''')
          )
        , COALESCE
          (
              NULLIF(r.EventXML.value(''(/event/data[@name="statement"]/value/text())[1]'',''nvarchar(max)''),N''''),
              NULLIF(r.EventXML.value(''(/event/data[@name="batch_text"]/value/text())[1]'',''nvarchar(max)''),N''''),
              NULLIF(r.EventXML.value(''(/event/action[@name="sql_text"]/value/text())[1]'',''nvarchar(max)''),N'''')
          )
        , CASE WHEN r.EventName=N''sp_statement_completed''
               THEN N''STATEMENT_COMPLETED_FALLBACK''
               WHEN r.EventName=N''rpc_completed'' THEN N''RPC_SUBMITTED_TEXT''
               ELSE N''BATCH_SUBMITTED_TEXT'' END
        , NULLIF(r.EventXML.value(''(/event/action[@name="client_hostname"]/value/text())[1]'',''nvarchar(256)''),N'''')
        , NULLIF(r.EventXML.value(''(/event/action[@name="client_app_name"]/value/text())[1]'',''nvarchar(256)''),N'''')
        , NULLIF(r.EventXML.value(''(/event/action[@name="server_principal_name"]/value/text())[1]'',''nvarchar(256)''),N'''')
        , TRY_CONVERT(decimal(19,3),r.EventXML.value(''(/event/data[@name="cpu_time"]/value/text())[1]'',''nvarchar(50)''))/1000.0
        , TRY_CONVERT(decimal(19,3),r.EventXML.value(''(/event/data[@name="duration"]/value/text())[1]'',''nvarchar(50)''))/1000.0
        , TRY_CONVERT(bigint,r.EventXML.value(''(/event/data[@name="logical_reads"]/value/text())[1]'',''nvarchar(50)''))
        , COALESCE
          (
              TRY_CONVERT(bigint,r.EventXML.value(''(/event/data[@name="physical_reads"]/value/text())[1]'',''nvarchar(50)'')),
              TRY_CONVERT(bigint,r.EventXML.value(''(/event/data[@name="reads"]/value/text())[1]'',''nvarchar(50)''))
          )
        , TRY_CONVERT(bigint,r.EventXML.value(''(/event/data[@name="writes"]/value/text())[1]'',''nvarchar(50)''))
        , TRY_CONVERT(bigint,r.EventXML.value(''(/event/data[@name="row_count"]/value/text())[1]'',''nvarchar(50)''))
        , TRY_CONVERT(varbinary(8),r.EventXML.value(''(/event/action[@name="query_hash"]/value/text())[1]'',''nvarchar(34)''),1)
        , TRY_CONVERT(varbinary(8),r.EventXML.value(''(/event/action[@name="query_plan_hash"]/value/text())[1]'',''nvarchar(34)''),1)
        , TRY_CONVERT(varbinary(64),r.EventXML.value(''(/event/action[@name="plan_handle"]/value/text())[1]'',''nvarchar(130)''),1)
    FROM dbo.RCA_XERaw AS r
    CROSS APPLY
    (
        SELECT
              DatabaseName = NULLIF(r.EventXML.value(''(/event/action[@name="database_name"]/value/text())[1]'',''nvarchar(128)''),N''''),
              SessionID = TRY_CONVERT(int,r.EventXML.value(''(/event/action[@name="session_id"]/value/text())[1]'',''nvarchar(20)''))
    ) AS x
    WHERE r.EventTimeUTC >= @StartUTC
      AND r.EventTimeUTC <= DATEADD(second,5,@EndUTC)
      AND x.DatabaseName = @ExecutionTargetDatabase
      AND
      (
          r.EventName IN (N''rpc_completed'',N''sql_batch_completed'')
          OR
          (
              r.EventName = N''sp_statement_completed''
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.RCA_XERaw AS p
                  CROSS APPLY
                  (
                      SELECT
                            ParentDatabaseName = NULLIF(p.EventXML.value(''(/event/action[@name="database_name"]/value/text())[1]'',''nvarchar(128)''),N''''),
                            ParentSessionID = TRY_CONVERT(int,p.EventXML.value(''(/event/action[@name="session_id"]/value/text())[1]'',''nvarchar(20)''))
                  ) AS px
                  WHERE p.EventName IN (N''rpc_completed'',N''sql_batch_completed'')
                    AND p.EventTimeUTC >= r.EventTimeUTC
                    AND p.EventTimeUTC <= DATEADD(second,120,r.EventTimeUTC)
                    AND px.ParentDatabaseName = x.DatabaseName
                    AND px.ParentSessionID = x.SessionID
              )
          )
      );

    ';

SET @NewDefinition = STUFF
(
    @OldDefinition,
    @AStart,
    @BStart - @AStart,
    @ReplacementSection
);

-- Convert the preserved deployed CREATE/CREATE OR ALTER header into ALTER.
SET @ProcedurePos = CHARINDEX(N'PROCEDURE', UPPER(@NewDefinition));
SET @CreatePos = CHARINDEX(N'CREATE', UPPER(LEFT(@NewDefinition, @ProcedurePos)));

IF @CreatePos = 0 OR @ProcedurePos <= @CreatePos
    THROW 64015, 'SCRIPT 111L3 ABORTED: parser procedure header could not be normalized to ALTER.', 1;

SET @HeaderText = UPPER(SUBSTRING(@NewDefinition, @CreatePos, @ProcedurePos - @CreatePos));

IF @HeaderText LIKE N'%OR%ALTER%'
    SET @NewDefinition = STUFF(@NewDefinition, @CreatePos, @ProcedurePos - @CreatePos, N'ALTER ');
ELSE
    SET @NewDefinition = STUFF(@NewDefinition, @CreatePos, 6, N'ALTER');

BEGIN TRY
    BEGIN TRANSACTION;

    SET @FailedStage = N'ALTER dbo.usp_RCA_ParseCaptureRun';
    EXEC sys.sp_executesql @NewDefinition;

    IF OBJECT_DEFINITION(@ParserObjectID) NOT LIKE N'%STATEMENT_COMPLETED_FALLBACK%'
        THROW 64016, 'SCRIPT 111L3 FAILED: fallback marker is absent after parser alteration.', 1;

    SET @FailedStage = N'REPARSE AND ANALYZE CAPTURE 93';
    EXEC dbo.usp_RCA_AnalyzeCaptureRun
         @CaptureRunID = @CaptureRunID,
         @Reparse = 1;

    DECLARE @ExecutionRows int =
    (
        SELECT COUNT(*)
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND DatabaseName = N'RCA_Demo'
    );
    DECLARE @ActualPlanRows int =
    (
        SELECT COUNT(*)
        FROM dbo.RCA_PlanEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND DatabaseName = N'RCA_Demo'
          AND ActualExecutionPlanXML IS NOT NULL
    );
    DECLARE @LinkedActualPlanRows int =
    (
        SELECT COUNT(*)
        FROM dbo.RCA_PlanEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND DatabaseName = N'RCA_Demo'
          AND ActualExecutionPlanXML IS NOT NULL
          AND LinkedExecutionEvidenceID IS NOT NULL
    );
    DECLARE @NamedRuntimeParameterCount int =
    (
        SELECT COUNT(DISTINCT ParameterName)
        FROM dbo.RCA_RuntimeParameter
        WHERE CaptureRunID = @CaptureRunID
          AND ParameterName IN (N'@SearchToken',N'@MinimumAmount',N'@CustomerGroup')
          AND COALESCE(ParameterRuntimeValue,ParameterCompiledValue) IS NOT NULL
    );
    DECLARE @ForeignExecutionRows int =
    (
        SELECT COUNT(*)
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND ISNULL(DatabaseName,N'') <> N'RCA_Demo'
    );
    DECLARE @ForeignPlanRows int =
    (
        SELECT COUNT(*)
        FROM dbo.RCA_PlanEvidence
        WHERE CaptureRunID = @CaptureRunID
          AND ISNULL(DatabaseName,N'') <> N'RCA_Demo'
    );

    IF @ExecutionRows < 1
        THROW 64017, 'SCRIPT 111L3 FAILED: no target-database execution fallback was created.', 1;
    IF @ActualPlanRows < 1
        THROW 64018, 'SCRIPT 111L3 FAILED: no RCA_Demo actual execution plan survived reparse.', 1;
    IF @LinkedActualPlanRows < 1
        THROW 64019, 'SCRIPT 111L3 FAILED: no RCA_Demo actual plan linked to an execution.', 1;
    IF @NamedRuntimeParameterCount <> 3
        THROW 64020, 'SCRIPT 111L3 FAILED: the three required named runtime parameters were not preserved.', 1;
    IF @ForeignExecutionRows <> 0 OR @ForeignPlanRows <> 0
        THROW 64021, 'SCRIPT 111L3 FAILED: foreign-database execution or plan evidence entered Capture 93.', 1;

    COMMIT TRANSACTION;

    SELECT
          N'1 - SCRIPT 111L3 ACCEPTANCE GATES' AS ValidationSection
        , @CaptureRunID AS CaptureRunID
        , @ExecutionRows AS RCA_DemoExecutionRows
        , @ActualPlanRows AS RCA_DemoActualPlanRows
        , @LinkedActualPlanRows AS LinkedActualPlanRows
        , @NamedRuntimeParameterCount AS RequiredNamedRuntimeParameters
        , @ForeignExecutionRows AS ForeignExecutionRows
        , @ForeignPlanRows AS ForeignPlanRows
        , N'PASS' AS GateResult;

    SELECT
          N'2 - LINKED EXECUTION AND ACTUAL PLAN PROOF' AS ValidationSection
        , e.ExecutionEvidenceID
        , e.EventName
        , e.EventTimeUTC
        , e.DatabaseName
        , e.SessionID
        , e.ObjectName
        , e.CPUms
        , e.DurationMs
        , e.LogicalReads
        , e.ParameterEvidenceStatus
        , p.PlanEvidenceID
        , p.QueryHash
        , p.QueryPlanHash
        , CONVERT(bit,CASE WHEN p.ActualExecutionPlanXML IS NULL THEN 0 ELSE 1 END) AS HasActualExecutionPlanXML
    FROM dbo.RCA_ExecutionEvidence AS e
    INNER JOIN dbo.RCA_PlanEvidence AS p
        ON p.LinkedExecutionEvidenceID = e.ExecutionEvidenceID
       AND p.CaptureRunID = e.CaptureRunID
    WHERE e.CaptureRunID = @CaptureRunID
      AND e.DatabaseName = N'RCA_Demo'
    ORDER BY e.EventTimeUTC, e.ExecutionEvidenceID, p.PlanEvidenceID;

    SELECT
          N'3 - EXACT RUNTIME PARAMETER PROOF' AS ValidationSection
        , rp.RuntimeParameterID
        , rp.PlanEvidenceID
        , p.LinkedExecutionEvidenceID
        , rp.ParameterName
        , rp.ParameterDataType
        , rp.ParameterCompiledValue
        , rp.ParameterRuntimeValue
        , rp.EvidenceSource
    FROM dbo.RCA_RuntimeParameter AS rp
    INNER JOIN dbo.RCA_PlanEvidence AS p
        ON p.PlanEvidenceID = rp.PlanEvidenceID
       AND p.CaptureRunID = rp.CaptureRunID
    WHERE rp.CaptureRunID = @CaptureRunID
      AND rp.ParameterName IN (N'@SearchToken',N'@MinimumAmount',N'@CustomerGroup')
    ORDER BY rp.PlanEvidenceID, rp.ParameterName;

    SELECT
          N'4 - SCRIPT 111L3 FINAL VERDICT' AS ValidationSection
        , N'PASS' AS Result
        , N'STATEMENT FALLBACK EXECUTIONS LINKED TO ACTUAL PLANS AND PARAMETERS' AS Correction
        , N'RPC/BATCH PARENTS REMAIN PREFERRED; FALLBACK ONLY WHEN NO PARENT EXISTS' AS DeduplicationRule
        , N'NO DETECTOR THRESHOLD, CAUSAL EDGE, CONFIDENCE, PRIORITY, OR ARBITRATION RULE CHANGED' AS SafetyStatement
        , N'NEXT: regenerate the Capture 93 HTML report and certify its parameter/plan sections' AS NextAction;
END TRY
BEGIN CATCH
    DECLARE @ErrorNumber int = ERROR_NUMBER();
    DECLARE @ErrorMessage nvarchar(2048) = ERROR_MESSAGE();

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    DECLARE @ThrowMessage nvarchar(2048) =
        CONCAT
        (
            N'SCRIPT 111L3 failed atomically at ', @FailedStage,
            N'; no parser or Capture 93 changes were retained. Original error ',
            @ErrorNumber, N': ', @ErrorMessage
        );

    THROW 64022, @ThrowMessage, 1;
END CATCH;
GO
