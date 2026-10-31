USE dbamaint;
GO
/*=============================================================================
RCA V1 - SCRIPT 111L v1.2
  RCA_DEMO PARAMETER + ACTUAL PLAN + HTML POSITIVE CONTROL

  PURPOSE
    Proves the user-visible evidence chain requested by the DBA team:
      parameterized RCA_Demo workload -> XE -> parsed execution evidence ->
      runtime parameters -> actual execution plan -> RCA analysis -> HTML.

  DURATION
    Normally 2-3 minutes. Five RCA sampler families run in parallel.

  SAFETY / PERSISTENCE
    * Requires the scheduled RCA_DeepCapture XE session to already be running.
    * Creates only dbo.RCA_ParameterPlanDemo and dbo.usp_RCA_ParameterPlanDemo
      in RCA_Demo; both are dropped before completion, including failure cleanup.
    * Temporary SQL Agent jobs are always removed.
    * The analyzed RCA capture and timestamped C:\RCA HTML file are preserved.
    * No detector threshold, causal edge, arbitration rule, XE definition, or
      production RCA object is changed.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 63990, 'SCRIPT 111L ABORTED: use a new SSMS query window.', 1;

DECLARE
      @TargetDatabase sysname = N'RCA_Demo'
    , @CaptureRunID bigint
    , @CaptureReason nvarchar(2000) =
        N'SCRIPT 111L v1.2 RCA_DEMO PARAMETER + ACTUAL PLAN + HTML POSITIVE CONTROL'
    , @Owner sysname = SUSER_SNAME(0)
    , @JobID uniqueidentifier
    , @JobName sysname
    , @Sampler sysname
    , @Command nvarchar(max)
    , @WorkloadStartUTC datetime2(3)
    , @WorkloadEndUTC datetime2(3)
    , @Deadline datetime2(0)
    , @BeginTimeLocal datetime2(0)
    , @EndTimeLocal datetime2(0)
    , @Iteration int = 0
    , @ExecutionRows bigint = 0
    , @PlanRows bigint = 0
    , @ActualPlanRows bigint = 0
    , @RuntimeParameterRows bigint = 0
    , @NamedRuntimeParameterRows bigint = 0
    , @FinalRows bigint = 0
    , @CaptureStatus varchar(30)
    , @FailureMessage nvarchar(2048);

DECLARE @Jobs table
(
      JobOrder int NOT NULL PRIMARY KEY
    , JobName sysname NOT NULL
    , SamplerName sysname NOT NULL
);

INSERT @Jobs(JobOrder,JobName,SamplerName)
VALUES
 (1,CONCAT(N'RCA_V1_111L_',@@SPID,N'_General'),N'usp_RCA_RunSampler')
,(2,CONCAT(N'RCA_V1_111L_',@@SPID,N'_IO'),N'usp_RCA_RunIOSampler')
,(3,CONCAT(N'RCA_V1_111L_',@@SPID,N'_TempDB'),N'usp_RCA_RunTempDBSampler')
,(4,CONCAT(N'RCA_V1_111L_',@@SPID,N'_Log'),N'usp_RCA_RunLogSampler')
,(5,CONCAT(N'RCA_V1_111L_',@@SPID,N'_Connectivity'),N'usp_RCA_RunConnectivitySampler');

IF DB_ID(@TargetDatabase) IS NULL
    THROW 63991, 'SCRIPT 111L ABORTED: RCA_Demo does not exist.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureStatus IN ('RUNNING','CAPTURING')
)
    THROW 63992, 'SCRIPT 111L ABORTED: another logical RCA capture is active.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions
    WHERE name = N'RCA_DeepCapture'
)
    THROW 63993, 'SCRIPT 111L ABORTED: RCA_DeepCapture must already be running.', 1;

IF OBJECT_ID(N'dbo.usp_RCA_SaveHTMLReport',N'P') IS NULL
    THROW 63994, 'SCRIPT 111L ABORTED: the certified HTML writer is missing.', 1;

IF OBJECT_ID(N'dbo.RCA_RuntimeParameter',N'U') IS NULL
    THROW 63989, 'SCRIPT 111L ABORTED: dbo.RCA_RuntimeParameter is missing.', 1;

/* A compile-time object-name failure in an earlier 111L version could bypass
   TRY/CATCH after its five jobs had completed. The active-capture gate above
   has already proved that no 111L test is running, so remove stale disposable
   111L jobs from any earlier SSMS session before creating replacements. */
DECLARE PreflightCleanupCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM msdb.dbo.sysjobs
    WHERE name LIKE N'RCA[_]V1[_]111L[_]%';
OPEN PreflightCleanupCursor;
FETCH NEXT FROM PreflightCleanupCursor INTO @JobName;
WHILE @@FETCH_STATUS=0
BEGIN
    IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@JobName)
        EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
    FETCH NEXT FROM PreflightCleanupCursor INTO @JobName;
END;
CLOSE PreflightCleanupCursor;
DEALLOCATE PreflightCleanupCursor;

BEGIN TRY
    /* Recreate a disposable, deterministic workload surface in empty RCA_Demo. */
    EXEC RCA_Demo.sys.sp_executesql N'
        SET NOCOUNT ON;
        IF OBJECT_ID(N''dbo.usp_RCA_ParameterPlanDemo'',N''P'') IS NOT NULL
            DROP PROCEDURE dbo.usp_RCA_ParameterPlanDemo;
        IF OBJECT_ID(N''dbo.RCA_ParameterPlanDemo'',N''U'') IS NOT NULL
            DROP TABLE dbo.RCA_ParameterPlanDemo;

        CREATE TABLE dbo.RCA_ParameterPlanDemo
        (
              WorkloadID int NOT NULL
                CONSTRAINT PK_RCA_ParameterPlanDemo PRIMARY KEY CLUSTERED
            , CustomerGroup int NOT NULL
            , SearchText varchar(220) NOT NULL
            , Amount decimal(19,4) NOT NULL
            , CreatedUTC datetime2(3) NOT NULL
        );

        ;WITH N AS
        (
            SELECT TOP (180000)
                   n = ROW_NUMBER() OVER (ORDER BY a.object_id,b.object_id)
            FROM sys.all_objects AS a
            CROSS JOIN sys.all_objects AS b
        )
        INSERT dbo.RCA_ParameterPlanDemo
        (
            WorkloadID,CustomerGroup,SearchText,Amount,CreatedUTC
        )
        SELECT
              CONVERT(int,n)
            , CONVERT(int,n % 1000)
            , CONVERT(varchar(220),
                CONCAT(''RCA_DEMO-RCA-PARAMETER-DEMO|'',n,''|'',
                       REPLICATE(CHAR(65 + (n % 20)),160)))
            , CONVERT(decimal(19,4),(n % 100000) / 17.0)
            , DATEADD(second,-CONVERT(int,n % 86400),SYSUTCDATETIME())
        FROM N;
    ';

    EXEC RCA_Demo.sys.sp_executesql N'
        CREATE OR ALTER PROCEDURE dbo.usp_RCA_ParameterPlanDemo
              @CustomerGroup int
            , @SearchToken varchar(40)
            , @MinimumAmount decimal(19,4)
        AS
        BEGIN
            SET NOCOUNT ON;

            DECLARE
                  @MatchedRows bigint
                , @CalculatedValue bigint;

            /* The LIKE predicate and grouped hash calculation are deliberate:
               they create a bounded CPU/memory-grant plan while retaining
               three meaningful runtime parameters in the actual plan XML. */
            SELECT
                  @MatchedRows = COUNT_BIG(*)
                , @CalculatedValue = CHECKSUM_AGG
                  (
                      BINARY_CHECKSUM
                      (
                          HASHBYTES
                          (
                              ''SHA2_512'',
                              CONCAT(SearchText,''|'',Amount,''|'',CreatedUTC)
                          )
                      )
                  )
            FROM dbo.RCA_ParameterPlanDemo
            WHERE CustomerGroup >= @CustomerGroup
              AND Amount >= @MinimumAmount
              AND SearchText LIKE ''%'' + @SearchToken + ''%''
            OPTION (MAXDOP 1);

            /* Consume the values without emitting a result set on every
               iteration. XE still captures the completed RPC, parameters,
               resource use, and post-execution ShowPlan. */
            IF @MatchedRows < 0 OR @CalculatedValue IS NULL
                RETURN 1;

            RETURN 0;
        END;
    ';

    /* This row defines the logical incident window. The shared scheduled XE
       remains running and is not owned by this test. */
    INSERT dbo.RCA_CaptureRun
    (
        TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus
    )
    VALUES
    (
        @TargetDatabase,@CaptureReason,SYSUTCDATETIME(),'RUNNING'
    );

    SET @CaptureRunID = CONVERT(bigint,SCOPE_IDENTITY());

    IF @CaptureRunID IS NULL
        THROW 63995, 'SCRIPT 111L FAILED: logical incident row was not created.', 1;

    /* Run the five sampler families concurrently so all seven domains overlap
       the same parameterized workload window. */
    DECLARE JobCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT JobName,SamplerName FROM @Jobs ORDER BY JobOrder;

    OPEN JobCursor;
    FETCH NEXT FROM JobCursor INTO @JobName,@Sampler;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@JobName)
            EXEC msdb.dbo.sp_delete_job @job_name=@JobName;

        SET @JobID = NULL;
        EXEC msdb.dbo.sp_add_job
             @job_name=@JobName,
             @enabled=1,
             @owner_login_name=@Owner,
             @description=N'Temporary SCRIPT 111L RCA_Demo evidence worker',
             @job_id=@JobID OUTPUT;

        SET @Command =
            N'EXEC dbamaint.dbo.' + QUOTENAME(@Sampler) +
            N' @CaptureRunID=' + CONVERT(nvarchar(30),@CaptureRunID) +
            N',@DurationMinutes=2,@SampleSeconds=5;';

        EXEC msdb.dbo.sp_add_jobstep
             @job_id=@JobID,
             @step_name=N'111L sampler',
             @subsystem=N'TSQL',
             @database_name=N'dbamaint',
             @command=@Command;

        EXEC msdb.dbo.sp_add_jobserver @job_id=@JobID;
        EXEC msdb.dbo.sp_start_job @job_id=@JobID;

        FETCH NEXT FROM JobCursor INTO @JobName,@Sampler;
    END;
    CLOSE JobCursor;
    DEALLOCATE JobCursor;

    WAITFOR DELAY '00:00:10';
    SET @WorkloadStartUTC = SYSUTCDATETIME();
    SET @Deadline = DATEADD(second,70,SYSDATETIME());

    /* Repeated procedure calls produce recognizable compiled/runtime values.
       Varying values also proves that the report is using captured evidence,
       not hard-coded test text. */
    WHILE SYSDATETIME() < @Deadline
    BEGIN
        SET @Iteration += 1;

        IF @Iteration % 3 = 1
            EXEC RCA_Demo.dbo.usp_RCA_ParameterPlanDemo
                 @CustomerGroup=100,
                 @SearchToken='RCA_DEMO-RCA-PARAMETER-DEMO',
                 @MinimumAmount=1250.0000;
        ELSE IF @Iteration % 3 = 2
            EXEC RCA_Demo.dbo.usp_RCA_ParameterPlanDemo
                 @CustomerGroup=450,
                 @SearchToken='RCA_DEMO-RCA-PARAMETER-DEMO',
                 @MinimumAmount=2750.5000;
        ELSE
            EXEC RCA_Demo.dbo.usp_RCA_ParameterPlanDemo
                 @CustomerGroup=800,
                 @SearchToken='RCA_DEMO-RCA-PARAMETER-DEMO',
                 @MinimumAmount=4250.7500;
    END;

    SET @WorkloadEndUTC = SYSUTCDATETIME();

    /* Wait for all samplers, with a bounded four-minute ceiling. */
    SET @Deadline = DATEADD(minute,4,SYSDATETIME());
    WHILE SYSDATETIME() < @Deadline
      AND EXISTS
      (
          SELECT 1
          FROM msdb.dbo.sysjobactivity AS a
          INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id=a.job_id
          WHERE j.name IN (SELECT JobName FROM @Jobs)
            AND a.start_execution_date IS NOT NULL
            AND a.stop_execution_date IS NULL
            AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
      )
        WAITFOR DELAY '00:00:05';

    IF EXISTS
    (
        SELECT 1
        FROM msdb.dbo.sysjobactivity AS a
        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id=a.job_id
        WHERE j.name IN (SELECT JobName FROM @Jobs)
          AND a.start_execution_date IS NOT NULL
          AND a.stop_execution_date IS NULL
          AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
    )
        THROW 63996, 'SCRIPT 111L FAILED: a sampler exceeded the four-minute ceiling.', 1;

    UPDATE dbo.RCA_CaptureRun
       SET EndTimeUTC=SYSUTCDATETIME(),
           CaptureStatus='CAPTURED'
     WHERE CaptureRunID=@CaptureRunID
       AND CaptureStatus='RUNNING';

    IF @@ROWCOUNT <> 1
        THROW 63997, 'SCRIPT 111L FAILED: logical incident window did not close.', 1;

    /* Allow end-of-window XE records to become visible, then use the certified
       import/parser/analyzer chain. */
    WAITFOR DELAY '00:00:05';
    EXEC dbo.usp_RCA_ImportXE @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@CaptureRunID,@Reparse=1;

    IF OBJECT_ID(N'dbo.usp_RCA_CaptureAvailablePlans',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_CaptureAvailablePlans @CaptureRunID=@CaptureRunID;

    SELECT @CaptureStatus=CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SELECT @ExecutionRows=COUNT_BIG(*)
    FROM dbo.RCA_ExecutionEvidence
    WHERE CaptureRunID=@CaptureRunID
      AND DatabaseName=@TargetDatabase
      AND EventTimeUTC BETWEEN @WorkloadStartUTC AND @WorkloadEndUTC;

    SELECT
          @PlanRows=COUNT_BIG(*)
        , @ActualPlanRows=COALESCE(SUM(CASE WHEN ActualExecutionPlanXML IS NOT NULL THEN 1 ELSE 0 END),0)
    FROM dbo.RCA_PlanEvidence
    WHERE CaptureRunID=@CaptureRunID
      AND DatabaseName=@TargetDatabase
      AND EventTimeUTC BETWEEN @WorkloadStartUTC AND @WorkloadEndUTC;

    SELECT
          @RuntimeParameterRows=COUNT_BIG(*)
        , @NamedRuntimeParameterRows=COALESCE
          (
              SUM
              (
                  CASE WHEN ParameterName IN
                  (
                      N'@CustomerGroup',N'@SearchToken',N'@MinimumAmount'
                  ) AND ParameterRuntimeValue IS NOT NULL THEN 1 ELSE 0 END
              ),0
          )
    FROM dbo.RCA_RuntimeParameter
    WHERE CaptureRunID=@CaptureRunID;

    SELECT @FinalRows=COUNT_BIG(*)
    FROM dbo.vw_RCA_FinalCauseCandidates
    WHERE CaptureRunID=@CaptureRunID;

    /* Remove disposable jobs before writing/reporting the result. */
    DECLARE CleanupCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT JobName FROM @Jobs ORDER BY JobOrder;
    OPEN CleanupCursor;
    FETCH NEXT FROM CleanupCursor INTO @JobName;
    WHILE @@FETCH_STATUS=0
    BEGIN
        IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@JobName)
            EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
        FETCH NEXT FROM CleanupCursor INTO @JobName;
    END;
    CLOSE CleanupCursor;
    DEALLOCATE CleanupCursor;

    /* Generate the timestamped HTML while evidence is fully persisted. */
    EXEC dbo.usp_RCA_SaveHTMLReport
         @CaptureRunID=@CaptureRunID,
         @OutputDirectory=N'C:\RCA';

    SET @BeginTimeLocal=CONVERT
    (
        datetime2(0),@WorkloadStartUTC AT TIME ZONE 'UTC'
        AT TIME ZONE 'Eastern Standard Time'
    );
    SET @EndTimeLocal=CONVERT
    (
        datetime2(0),@WorkloadEndUTC AT TIME ZONE 'UTC'
        AT TIME ZONE 'Eastern Standard Time'
    );

    SELECT
          ValidationSection=N'1 - SCRIPT 111L CAPTURE'
        , c.CaptureRunID
        , c.TargetDatabase
        , c.StartTimeUTC
        , c.EndTimeUTC
        , c.CaptureStatus
        , WorkloadStartUTC=@WorkloadStartUTC
        , WorkloadEndUTC=@WorkloadEndUTC
        , WorkloadIterations=@Iteration
    FROM dbo.RCA_CaptureRun AS c
    WHERE c.CaptureRunID=@CaptureRunID;

    SELECT
          ValidationSection=N'2 - PARAMETER AND PLAN GATES'
        , ExecutionRows=@ExecutionRows
        , PlanRows=@PlanRows
        , ActualPlanRows=@ActualPlanRows
        , RuntimeParameterRows=@RuntimeParameterRows
        , NamedRuntimeParameterRows=@NamedRuntimeParameterRows
        , FinalCauseRows=@FinalRows
        , ExecutionGate=CASE WHEN @ExecutionRows>0 THEN 'PASS' ELSE 'FAIL' END
        , ActualPlanGate=CASE WHEN @ActualPlanRows>0 THEN 'PASS' ELSE 'FAIL' END
        , RuntimeParameterGate=CASE WHEN @NamedRuntimeParameterRows>=3 THEN 'PASS' ELSE 'FAIL' END;

    SELECT
          ValidationSection=N'3 - EXACT RUNTIME PARAMETERS'
        , r.RuntimeParameterID
        , r.PlanEvidenceID
        , r.ExecutionEvidenceID
        , r.ParameterName
        , r.ParameterDataType
        , r.ParameterCompiledValue
        , r.ParameterRuntimeValue
        , r.EvidenceSource
    FROM dbo.RCA_RuntimeParameter AS r
    WHERE r.CaptureRunID=@CaptureRunID
    ORDER BY r.PlanEvidenceID,r.RuntimeParameterID;

    SELECT
          ValidationSection=N'4 - EXACT ACTUAL PLANS'
        , p.PlanEvidenceID
        , p.EventTimeUTC
        , p.DatabaseName
        , p.SessionID
        , p.SQLText
        , p.QueryHash
        , p.QueryPlanHash
        , p.RequestedMemoryKB
        , p.GrantedMemoryKB
        , p.MaxUsedMemoryKB
        , p.ActualDOP
        , ActualPlanCaptured=CONVERT(bit,CASE WHEN p.ActualExecutionPlanXML IS NOT NULL THEN 1 ELSE 0 END)
        , SSMSPlanQuery=CONCAT
          (
              N'SELECT ActualExecutionPlanXML FROM dbamaint.dbo.RCA_PlanEvidence WHERE PlanEvidenceID=',
              p.PlanEvidenceID,N';'
          )
    FROM dbo.RCA_PlanEvidence AS p
    WHERE p.CaptureRunID=@CaptureRunID
      AND p.DatabaseName=@TargetDatabase
      AND p.EventTimeUTC BETWEEN @WorkloadStartUTC AND @WorkloadEndUTC
    ORDER BY p.EventTimeUTC,p.PlanEvidenceID;

    SELECT
          ValidationSection=N'5 - EXACT EXECUTION EVIDENCE'
        , e.ExecutionEvidenceID
        , e.EventTimeUTC
        , e.SessionID
        , e.ObjectName
        , e.SubmittedCommand
        , e.ParameterText
        , e.ParameterEvidenceStatus
        , e.HostName
        , e.ProgramName
        , e.LoginName
        , e.CPUms
        , e.DurationMs
        , e.LogicalReads
        , e.PhysicalReads
        , e.Writes
        , e.TotalRows
    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.CaptureRunID=@CaptureRunID
      AND e.DatabaseName=@TargetDatabase
      AND e.EventTimeUTC BETWEEN @WorkloadStartUTC AND @WorkloadEndUTC
    ORDER BY e.EventTimeUTC,e.ExecutionEvidenceID;

    SELECT
          ValidationSection=N'6 - HISTORICAL FRONT-DOOR COMMAND'
        , Command=CONCAT
          (
              N'EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1 ',
              N'@DatabaseName=N''RCA_Demo'',@BeginTimeLocal=''',
              CONVERT(nvarchar(19),@BeginTimeLocal,126),
              N''',@EndTimeLocal=''',
              CONVERT(nvarchar(19),@EndTimeLocal,126),N''';'
          );

    /* Return RCA_Demo to its prior empty-workload state only after all evidence
       and the report are safely persisted. */
    EXEC RCA_Demo.sys.sp_executesql N'
        DROP PROCEDURE IF EXISTS dbo.usp_RCA_ParameterPlanDemo;
        DROP TABLE IF EXISTS dbo.RCA_ParameterPlanDemo;
    ';

    IF @CaptureStatus<>'ANALYZED'
       OR @ExecutionRows=0
       OR @ActualPlanRows=0
       OR @NamedRuntimeParameterRows<3
    BEGIN
        THROW 63998,
          'SCRIPT 111L FAILED: review the parameter/plan gates; the capture and HTML were preserved.',1;
    END;

    SELECT
          ValidationSection=N'7 - SCRIPT 111L FINAL VERDICT'
        , Result=N'PASS'
        , CaptureRunID=@CaptureRunID
        , DatabaseName=@TargetDatabase
        , ExecutionRows=@ExecutionRows
        , ActualPlanRows=@ActualPlanRows
        , RuntimeParameterRows=@RuntimeParameterRows
        , NamedRuntimeParameterRows=@NamedRuntimeParameterRows
        , WorkloadObjectResidue=
          CASE WHEN OBJECT_ID(N'RCA_Demo.dbo.RCA_ParameterPlanDemo',N'U') IS NULL
                 AND OBJECT_ID(N'RCA_Demo.dbo.usp_RCA_ParameterPlanDemo',N'P') IS NULL
               THEN 0 ELSE 1 END
        , NextStep=N'OPEN THE TIMESTAMPED C:\RCA HTML REPORT';
END TRY
BEGIN CATCH
    DECLARE @OriginalErrorNumber int=ERROR_NUMBER();
    DECLARE @OriginalErrorMessage nvarchar(2048)=ERROR_MESSAGE();

    BEGIN TRY
        DECLARE FailureCleanupCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT JobName FROM @Jobs ORDER BY JobOrder;
        OPEN FailureCleanupCursor;
        FETCH NEXT FROM FailureCleanupCursor INTO @JobName;
        WHILE @@FETCH_STATUS=0
        BEGIN
            IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@JobName)
                EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
            FETCH NEXT FROM FailureCleanupCursor INTO @JobName;
        END;
        CLOSE FailureCleanupCursor;
        DEALLOCATE FailureCleanupCursor;
    END TRY
    BEGIN CATCH
    END CATCH;

    BEGIN TRY
        EXEC RCA_Demo.sys.sp_executesql N'
            DROP PROCEDURE IF EXISTS dbo.usp_RCA_ParameterPlanDemo;
            DROP TABLE IF EXISTS dbo.RCA_ParameterPlanDemo;
        ';
    END TRY
    BEGIN CATCH
    END CATCH;

    IF @CaptureRunID IS NOT NULL
    BEGIN
        UPDATE dbo.RCA_CaptureRun
           SET CaptureStatus=CASE WHEN CaptureStatus='ANALYZED' THEN CaptureStatus ELSE 'FAILED' END,
               EndTimeUTC=COALESCE(EndTimeUTC,SYSUTCDATETIME())
         WHERE CaptureRunID=@CaptureRunID
           AND CaptureStatus IN ('RUNNING','CAPTURING','CAPTURED','ANALYZED');
    END;

    SET @FailureMessage=CONCAT
    (
        N'SCRIPT 111L failed. CaptureRunID=',
        COALESCE(CONVERT(nvarchar(30),@CaptureRunID),N'NULL'),
        N'; original error ',@OriginalErrorNumber,N': ',@OriginalErrorMessage
    );
    THROW 63999,@FailureMessage,1;
END CATCH;
GO
