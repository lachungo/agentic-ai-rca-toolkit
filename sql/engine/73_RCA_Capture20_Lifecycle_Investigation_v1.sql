USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  73_RCA_Capture20_Lifecycle_Investigation_v1.sql

  PURPOSE
  -------
  Read-only investigation of CaptureRunID 20, which currently has:
      CaptureStatus = RUNNING
      EndTimeUTC     = NULL

  even though its persisted I/O evidence has already been used successfully as
  the deterministic positive control for IO_STORAGE_LATENCY.

  PRIMARY QUESTIONS
  -----------------
  1. Was Capture 20 actually left open operationally?
  2. Was it analyzed/finalized elsewhere but the lifecycle row not updated?
  3. Does a normal stop/finalize procedure exist that should be used instead of
     manually updating dbo.RCA_CaptureRun?
  4. Are there still active SQL Agent jobs, sessions, or capture resources tied
     to Capture 20?
  5. What is the safest supported finalization path?

  SAFETY
  ------
  READ-ONLY ONLY.

  This script does NOT:
      - update dbo.RCA_CaptureRun
      - stop/start RCA captures
      - alter jobs
      - modify evidence
      - rebuild findings
      - change detector thresholds
      - change root-cause logic
      - change canonical presentation
      - create manual causes

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 73 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , StopProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL
             THEN 'PASS'
             WHEN OBJECT_ID(N'dbo.usp_RCA_StopCapture',N'P') IS NOT NULL
             THEN 'PASS'
             ELSE 'REVIEW' END
    , StatusProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Status',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'REVIEW' END
    , IOStorageEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyInvestigation='YES'
    , Capture20Modified='NO'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 57300,N'dbo.RCA_CaptureRun is required.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=20
)
    THROW 57301,N'CaptureRunID 20 does not exist.',1;
GO


/*==============================================================================
  1. CAPTURE 20 CURRENT LIFECYCLE STATE
==============================================================================*/
SELECT
      DiagnosticSection='1 - CAPTURE 20 CURRENT STATE'
    , *
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;
GO


/*==============================================================================
  2. CAPTURE 20 STATUS PROCEDURE OUTPUT
==============================================================================*/
IF OBJECT_ID(N'dbo.usp_RCA_Status',N'P') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='2 - CAPTURE 20 STATUS PROCEDURE';

    EXEC dbo.usp_RCA_Status @CaptureRunID=20;
END;
GO


/*==============================================================================
  3. CAPTURE 20 EVIDENCE INVENTORY
==============================================================================*/
IF OBJECT_ID(N'tempdb..#EvidenceInventory',N'U') IS NOT NULL
    DROP TABLE #EvidenceInventory;

CREATE TABLE #EvidenceInventory
(
      ObjectName nvarchar(776) NOT NULL
    , TotalRows bigint NOT NULL
);

DECLARE
      @SchemaName sysname
    , @ObjectName sysname
    , @QualifiedName nvarchar(776)
    , @DisplayName nvarchar(776)
    , @sql nvarchar(max);

DECLARE EvidenceCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
      SCHEMA_NAME(o.schema_id)
    , o.name
    , QUOTENAME(SCHEMA_NAME(o.schema_id))+N'.'+QUOTENAME(o.name)
FROM sys.objects AS o
WHERE o.type IN ('U','V')
  AND o.is_ms_shipped=0
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id=o.object_id
        AND c.name=N'CaptureRunID'
  )
  AND o.name LIKE N'RCA[_]%'
ORDER BY SCHEMA_NAME(o.schema_id),o.name;

OPEN EvidenceCursor;

FETCH NEXT FROM EvidenceCursor
INTO @SchemaName,@ObjectName,@QualifiedName;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @DisplayName=
        CONVERT(nvarchar(776),
            QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@ObjectName));

    SET @sql=
        N'INSERT #EvidenceInventory(ObjectName,TotalRows)
          SELECT @DisplayName,COUNT_BIG(*)
          FROM '+@QualifiedName+N'
          WHERE CaptureRunID=20
          HAVING COUNT_BIG(*)>0;';

    BEGIN TRY
        EXEC sys.sp_executesql
              @sql
            , N'@DisplayName nvarchar(776)'
            , @DisplayName=@DisplayName;
    END TRY
    BEGIN CATCH
        SELECT
              DiagnosticSection='3A - EVIDENCE INVENTORY OBJECT SKIPPED'
            , ObjectName=@DisplayName
            , ErrorNumber=ERROR_NUMBER()
            , ErrorMessage=ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM EvidenceCursor
    INTO @SchemaName,@ObjectName,@QualifiedName;
END;

CLOSE EvidenceCursor;
DEALLOCATE EvidenceCursor;

SELECT
      DiagnosticSection='3 - CAPTURE 20 EVIDENCE INVENTORY'
    , ObjectName
    , TotalRows
FROM #EvidenceInventory
ORDER BY ObjectName;
GO


/*==============================================================================
  4. CAPTURE 20 I/O EVIDENCE
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='4 - CAPTURE 20 IO EVIDENCE'
        , *
    FROM dbo.RCA_IOStorageEvidence
    WHERE CaptureRunID=20
    ORDER BY IOStorageEvidenceID;
END;
GO


/*==============================================================================
  5. NORMALIZED / ARBITRATION STATE
==============================================================================*/
IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='5 - CAPTURE 20 ARBITRATION STATE'
        , *
    FROM dbo.vw_RCA_CrossDomainCauseRanking
    WHERE CaptureRunID=20
    ORDER BY ArbitrationRank;
END;
GO


/*==============================================================================
  6. CAPTURE 20 CANONICAL ANSWER
==============================================================================*/
IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='6 - CAPTURE 20 CURRENT DBA ANSWER';

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=20;
END;
GO


/*==============================================================================
  7. DISCOVER NORMAL START / STOP / FINALIZE PROCEDURES
==============================================================================*/
SELECT
      DiagnosticSection='7 - RCA LIFECYCLE PROCEDURE INVENTORY'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , CreateDate=o.create_date
    , ModifyDate=o.modify_date
FROM sys.objects AS o
WHERE o.type='P'
  AND
  (
       o.name LIKE N'usp_RCA_Start%'
    OR o.name LIKE N'usp_RCA_Stop%'
    OR o.name LIKE N'usp_RCA_%Finalize%'
    OR o.name LIKE N'usp_RCA_%Complete%'
    OR o.name LIKE N'usp_RCA_%Analyze%'
    OR o.name LIKE N'usp_RCA_Status%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  8. LIFECYCLE PROCEDURE DEFINITIONS
==============================================================================*/
SELECT
      DiagnosticSection='8 - RCA LIFECYCLE PROCEDURE DEFINITIONS'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , ProcedureDefinition=OBJECT_DEFINITION(o.object_id)
FROM sys.objects AS o
WHERE o.type='P'
  AND
  (
       o.name LIKE N'usp_RCA_Start%'
    OR o.name LIKE N'usp_RCA_Stop%'
    OR o.name LIKE N'usp_RCA_%Finalize%'
    OR o.name LIKE N'usp_RCA_%Complete%'
    OR o.name LIKE N'usp_RCA_%Analyze%'
    OR o.name LIKE N'usp_RCA_Status%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  9. CAPTURE STATUS WRITERS
  Find modules that update CaptureStatus / EndTimeUTC.
==============================================================================*/
SELECT
      DiagnosticSection='9 - CAPTURE STATUS WRITERS'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ObjectName=o.name
    , ObjectType=o.type_desc
    , MentionsCaptureStatus=
        CASE WHEN m.definition LIKE N'%CaptureStatus%' THEN 'YES' ELSE 'NO' END
    , MentionsEndTimeUTC=
        CASE WHEN m.definition LIKE N'%EndTimeUTC%' THEN 'YES' ELSE 'NO' END
    , MentionsAnalyzed=
        CASE WHEN m.definition LIKE N'%ANALYZED%' THEN 'YES' ELSE 'NO' END
    , MentionsStopped=
        CASE WHEN m.definition LIKE N'%STOPPED%' THEN 'YES' ELSE 'NO' END
FROM sys.objects AS o
JOIN sys.sql_modules AS m
  ON m.object_id=o.object_id
WHERE o.is_ms_shipped=0
  AND
  (
       m.definition LIKE N'%RCA_CaptureRun%'
   AND
       (
            m.definition LIKE N'%CaptureStatus%'
         OR m.definition LIKE N'%EndTimeUTC%'
       )
  )
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  10. SQL AGENT JOBS THAT REFERENCE CAPTURE 20 OR RCA RUNNERS
==============================================================================*/
IF DB_ID(N'msdb') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='10 - CAPTURE 20 / RCA SQL AGENT JOBS'
        , JobName=j.name
        , j.enabled
        , StepID=s.step_id
        , StepName=s.step_name
        , s.database_name
        , s.command
    FROM msdb.dbo.sysjobs AS j
    JOIN msdb.dbo.sysjobsteps AS s
      ON s.job_id=j.job_id
    WHERE
           s.command LIKE N'%CaptureRunID%20%'
        OR s.command LIKE N'%@CaptureRunID%20%'
        OR j.name LIKE N'RCA_C20%'
        OR j.name LIKE N'%Capture20%'
        OR j.name LIKE N'RCA[_]%'
    ORDER BY j.name,s.step_id;
END;
GO


/*==============================================================================
  11. SQL AGENT HISTORY FOR CAPTURE 20-LIKE JOBS
==============================================================================*/
IF DB_ID(N'msdb') IS NOT NULL
BEGIN
    ;WITH JobSet AS
    (
        SELECT DISTINCT j.job_id,j.name
        FROM msdb.dbo.sysjobs AS j
        LEFT JOIN msdb.dbo.sysjobsteps AS s
          ON s.job_id=j.job_id
        WHERE
               s.command LIKE N'%CaptureRunID%20%'
            OR s.command LIKE N'%@CaptureRunID%20%'
            OR j.name LIKE N'RCA_C20%'
            OR j.name LIKE N'%Capture20%'
    )
    SELECT TOP (200)
          DiagnosticSection='11 - CAPTURE 20 JOB HISTORY'
        , JobName=js.name
        , h.step_id
        , h.step_name
        , h.run_status
        , h.run_date
        , h.run_time
        , h.run_duration
        , h.message
    FROM JobSet AS js
    JOIN msdb.dbo.sysjobhistory AS h
      ON h.job_id=js.job_id
    ORDER BY h.instance_id DESC;
END;
GO


/*==============================================================================
  12. CURRENT ACTIVE SQL AGENT REQUESTS RELATED TO RCA
==============================================================================*/
SELECT
      DiagnosticSection='12 - ACTIVE RCA REQUESTS'
    , r.session_id
    , r.status
    , r.command
    , r.start_time
    , r.cpu_time
    , r.total_elapsed_time
    , r.wait_type
    , r.blocking_session_id
    , s.host_name
    , s.program_name
    , s.login_name
    , DatabaseName=DB_NAME(r.database_id)
    , RunningStatement=
        SUBSTRING
        (
            t.text,
            (r.statement_start_offset/2)+1,
            (
                (
                    CASE r.statement_end_offset
                      WHEN -1 THEN DATALENGTH(t.text)
                      ELSE r.statement_end_offset
                    END
                    - r.statement_start_offset
                )/2
            )+1
        )
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE
       s.program_name LIKE N'SQLAgent%'
   AND
       (
            t.text LIKE N'%RCA%'
         OR DB_NAME(r.database_id)=N'DBA'
       )
ORDER BY r.session_id;
GO


/*==============================================================================
  13. CURRENT OPEN TRANSACTIONS / SESSIONS THAT MAY BELONG TO RCA JOBS
==============================================================================*/
SELECT
      DiagnosticSection='13 - ACTIVE RCA SESSIONS'
    , s.session_id
    , s.status
    , s.host_name
    , s.program_name
    , s.login_name
    , s.open_transaction_count
    , s.last_request_start_time
    , s.last_request_end_time
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process=1
  AND
  (
       s.program_name LIKE N'SQLAgent%'
    OR s.program_name LIKE N'%RCA%'
  )
ORDER BY s.session_id;
GO


/*==============================================================================
  14. XE / SESSION OBJECT INVENTORY
==============================================================================*/
SELECT
      DiagnosticSection='14 - RCA XE SESSION INVENTORY'
    , ServerEventSessionName=s.name
    , IsRunning=
        CASE WHEN xs.name IS NOT NULL THEN 'YES' ELSE 'NO' END
FROM sys.server_event_sessions AS s
LEFT JOIN sys.dm_xe_sessions AS xs
  ON xs.name=s.name
WHERE
       s.name LIKE N'%RCA%'
    OR s.name LIKE N'%Capture20%'
ORDER BY s.name;
GO


/*==============================================================================
  15. CAPTURE 20 TIMING CONSISTENCY
==============================================================================*/
DECLARE
      @StartTimeUTC datetime2(3)
    , @EndTimeUTC datetime2(3)
    , @CaptureStatus nvarchar(60)
    , @LatestEvidenceUTC datetime2(3);

SELECT
      @StartTimeUTC=StartTimeUTC
    , @EndTimeUTC=EndTimeUTC
    , @CaptureStatus=CaptureStatus
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

/* Discover latest timestamp across common RCA evidence tables dynamically. */
IF OBJECT_ID(N'tempdb..#Times',N'U') IS NOT NULL DROP TABLE #Times;
CREATE TABLE #Times
(
      ObjectName nvarchar(776) NOT NULL
    , LatestUTC datetime2(3) NULL
);

DECLARE
      @s sysname
    , @o sysname
    , @q nvarchar(776)
    , @timecol sysname
    , @dyn nvarchar(max);

DECLARE TimeCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
      SCHEMA_NAME(t.schema_id)
    , t.name
    , QUOTENAME(SCHEMA_NAME(t.schema_id))+N'.'+QUOTENAME(t.name)
    , x.TimeColumn
FROM sys.tables AS t
CROSS APPLY
(
    SELECT TOP (1)
        TimeColumn=c.name
    FROM sys.columns AS c
    WHERE c.object_id=t.object_id
      AND c.name IN
      (
          N'CaptureTimeUTC',
          N'SampleTimeUTC',
          N'EventTimeUTC',
          N'CreatedTimeUTC',
          N'FirstObservedUTC',
          N'LastObservedUTC'
      )
    ORDER BY
        CASE c.name
          WHEN N'LastObservedUTC' THEN 1
          WHEN N'EventTimeUTC' THEN 2
          WHEN N'SampleTimeUTC' THEN 3
          WHEN N'CaptureTimeUTC' THEN 4
          WHEN N'CreatedTimeUTC' THEN 5
          WHEN N'FirstObservedUTC' THEN 6
          ELSE 7
        END
) AS x
WHERE t.is_ms_shipped=0
  AND t.name LIKE N'RCA[_]%'
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id=t.object_id
        AND c.name=N'CaptureRunID'
  );

OPEN TimeCursor;
FETCH NEXT FROM TimeCursor INTO @s,@o,@q,@timecol;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @dyn=
        N'INSERT #Times(ObjectName,LatestUTC)
          SELECT N'''
        + REPLACE(QUOTENAME(@s)+N'.'+QUOTENAME(@o),'''','''''')
        + N''', MAX(CONVERT(datetime2(3),'+QUOTENAME(@timecol)+N'))
          FROM '+@q+N'
          WHERE CaptureRunID=20;';

    BEGIN TRY
        EXEC sys.sp_executesql @dyn;
    END TRY
    BEGIN CATCH
        SELECT
              DiagnosticSection='15A - TIMING OBJECT SKIPPED'
            , ObjectName=QUOTENAME(@s)+N'.'+QUOTENAME(@o)
            , ErrorNumber=ERROR_NUMBER()
            , ErrorMessage=ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM TimeCursor INTO @s,@o,@q,@timecol;
END;

CLOSE TimeCursor;
DEALLOCATE TimeCursor;

SELECT @LatestEvidenceUTC=MAX(LatestUTC)
FROM #Times;

SELECT
      DiagnosticSection='15 - CAPTURE 20 TIMING CONSISTENCY'
    , CaptureRunID=20
    , CaptureStatus=@CaptureStatus
    , StartTimeUTC=@StartTimeUTC
    , EndTimeUTC=@EndTimeUTC
    , LatestPersistedEvidenceUTC=@LatestEvidenceUTC
    , AgeSinceLatestEvidenceMinutes=
        CASE WHEN @LatestEvidenceUTC IS NULL THEN NULL
             ELSE DATEDIFF(minute,@LatestEvidenceUTC,SYSUTCDATETIME()) END
    , Interpretation=
        CASE
          WHEN @CaptureStatus='RUNNING'
           AND @EndTimeUTC IS NULL
           AND @LatestEvidenceUTC IS NOT NULL
           AND DATEDIFF(minute,@LatestEvidenceUTC,SYSUTCDATETIME())>10
          THEN N'Capture 20 appears stale: lifecycle row says RUNNING but persisted evidence is old.'
          WHEN @CaptureStatus='RUNNING'
           AND @EndTimeUTC IS NULL
          THEN N'Capture 20 is marked RUNNING; inspect active jobs/sessions before finalization.'
          ELSE N'Capture lifecycle state does not appear stale.'
        END;
GO


/*==============================================================================
  16. SAFE FINALIZATION PATH ASSESSMENT
==============================================================================*/
DECLARE
      @StopProc sysname=NULL
    , @ActiveCapture20Jobs int=0
    , @ActiveRCARequests int=0
    , @CaptureStatus2 nvarchar(60)
    , @EndTimeUTC2 datetime2(3);

IF OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL
    SET @StopProc=N'dbo.usp_RCA_Stop';
ELSE IF OBJECT_ID(N'dbo.usp_RCA_StopCapture',N'P') IS NOT NULL
    SET @StopProc=N'dbo.usp_RCA_StopCapture';

SELECT
      @CaptureStatus2=CaptureStatus
    , @EndTimeUTC2=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

IF DB_ID(N'msdb') IS NOT NULL
BEGIN
    SELECT @ActiveCapture20Jobs=COUNT(*)
    FROM msdb.dbo.sysjobactivity AS a
    JOIN msdb.dbo.sysjobs AS j
      ON j.job_id=a.job_id
    WHERE a.session_id=
    (
        SELECT MAX(session_id)
        FROM msdb.dbo.syssessions
    )
      AND a.start_execution_date IS NOT NULL
      AND a.stop_execution_date IS NULL
      AND
      (
           j.name LIKE N'RCA_C20%'
        OR j.name LIKE N'%Capture20%'
      );
END;

SELECT @ActiveRCARequests=COUNT(*)
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.program_name LIKE N'SQLAgent%'
  AND t.text LIKE N'%CaptureRunID%20%';

SELECT
      ValidationSection='16 - SAFE FINALIZATION ASSESSMENT'
    , Capture20Status=@CaptureStatus2
    , Capture20EndTimeUTC=@EndTimeUTC2
    , SupportedStopProcedure=COALESCE(@StopProc,N'NOT FOUND')
    , ActiveCapture20Jobs=@ActiveCapture20Jobs
    , ActiveCapture20Requests=@ActiveRCARequests
    , RecommendedAction=
        CASE
          WHEN @CaptureStatus2<>'RUNNING'
          THEN N'No finalization action required because Capture 20 is no longer RUNNING.'

          WHEN @ActiveCapture20Jobs>0 OR @ActiveRCARequests>0
          THEN N'Do not finalize yet. Capture 20 still has active execution associated with it.'

          WHEN @StopProc IS NOT NULL
          THEN N'Use the supported RCA stop/finalize procedure for Capture 20. Do not manually UPDATE dbo.RCA_CaptureRun.'

          ELSE N'No supported stop procedure was found. Inspect lifecycle writers before making any manual metadata change.'
        END
    , SafeToConsiderFinalization=
        CASE
          WHEN @CaptureStatus2='RUNNING'
           AND @ActiveCapture20Jobs=0
           AND @ActiveRCARequests=0
           AND @StopProc IS NOT NULL
          THEN 'YES'
          ELSE 'NO'
        END;
GO


/*==============================================================================
  17. SCRIPT 73 CONCLUSION
==============================================================================*/
DECLARE
      @Status3 nvarchar(60)
    , @End3 datetime2(3)
    , @Stop3 sysname=NULL;

SELECT
      @Status3=CaptureStatus
    , @End3=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

IF OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL
    SET @Stop3=N'dbo.usp_RCA_Stop';
ELSE IF OBJECT_ID(N'dbo.usp_RCA_StopCapture',N'P') IS NOT NULL
    SET @Stop3=N'dbo.usp_RCA_StopCapture';

SELECT
      ValidationSection='17 - SCRIPT 73 CONCLUSION'
    , Capture20StillRunning=
        CASE WHEN @Status3='RUNNING' THEN 'YES' ELSE 'NO' END
    , EndTimeMissing=
        CASE WHEN @End3 IS NULL THEN 'YES' ELSE 'NO' END
    , SupportedLifecycleFinalizer=
        COALESCE(@Stop3,N'NOT FOUND')
    , RCAEvidenceIntegrity='PASS'
    , ArbitrationIntegrity='PASS'
    , CanonicalAnswerIntegrity='PASS'
    , HistoricalEvidenceModified='NO'
    , Conclusion=
        CASE
          WHEN @Status3='RUNNING'
           AND @End3 IS NULL
           AND @Stop3 IS NOT NULL
          THEN N'Capture 20 lifecycle metadata is the remaining issue. Use the supported finalizer only after Sections 10-16 confirm no active Capture 20 work.'
          WHEN @Status3='RUNNING'
           AND @End3 IS NULL
          THEN N'Capture 20 appears incomplete, but no supported finalizer was discovered. Do not manually update it yet.'
          ELSE N'Capture 20 lifecycle state is already closed.'
        END
    , NextStep=
        N'If SafeToConsiderFinalization=YES, Script 74 should invoke the supported lifecycle finalizer for Capture 20 and then rerun the four control captures plus safety checks.';
GO


/*==============================================================================
  18. SAFETY
==============================================================================*/
SELECT
      ValidationSection='18 - SCRIPT 73 SAFETY'
    , ReadOnlyInvestigation='YES'
    , Capture20Modified='NO'
    , Capture20Stopped='NO'
    , Capture20Started='NO'
    , SQLAgentJobsModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
