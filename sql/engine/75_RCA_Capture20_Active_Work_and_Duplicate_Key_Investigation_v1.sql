USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  75_RCA_Capture20_Active_Work_and_Duplicate_Key_Investigation_v1.sql

  PURPOSE
  -------
  Read-only investigation after Script 74 aborted with:

      Msg 57410
      Capture 20 still has active work. Finalization aborted.

  and an additional parser error:

      Msg 2627
      Procedure dbo.usp_RCA_ParseCaptureRun, Line 58
      Violation of UNIQUE KEY constraint ...
      Cannot insert duplicate key in dbo.RCA_ExecutionEvidence.
      Duplicate key value = (8135).

  QUESTIONS THIS SCRIPT ANSWERS
  -----------------------------
  1. What active RCA work currently exists?
  2. Is Capture 20 itself receiving new evidence?
  3. What columns comprise the unique key on RCA_ExecutionEvidence?
  4. What existing row owns the duplicate key value 8135?
  5. Which capture/run owns that existing evidence?
  6. What does dbo.usp_RCA_ParseCaptureRun do around the failing INSERT?
  7. What tables/procedures invoke dbo.usp_RCA_ParseCaptureRun?
  8. Is the parser designed to be idempotent?
  9. Is Capture 20 evidence still changing?
 10. Is the duplicate condition tied to Capture 20 or another capture?
 11. What is the safest next step before attempting finalization again?

  SAFETY
  ------
  READ-ONLY ONLY.

  This script does NOT:
      - update dbo.RCA_CaptureRun
      - stop/start captures
      - change SQL Agent jobs
      - alter dbo.usp_RCA_ParseCaptureRun
      - modify RCA_ExecutionEvidence
      - rebuild evidence
      - change thresholds
      - change root-cause logic
      - change canonical presentation

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 75 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExecutionEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ParseCaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyInvestigation='YES'
    , Capture20Modified='NO'
    , ExecutionEvidenceModified='NO'
    , ParserModified='NO'
    , SQLAgentJobsModified='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 57500,N'dbo.RCA_CaptureRun is required.',1;

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    THROW 57501,N'dbo.RCA_ExecutionEvidence is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NULL
    THROW 57502,N'dbo.usp_RCA_ParseCaptureRun is required.',1;
GO


/*==============================================================================
  1. CAPTURE 20 CURRENT STATE
==============================================================================*/
SELECT
      DiagnosticSection='1 - CAPTURE 20 CURRENT STATE'
    , *
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;
GO


/*==============================================================================
  2. CURRENT ACTIVE RCA REQUESTS
==============================================================================*/
SELECT
      DiagnosticSection='2 - ACTIVE RCA REQUESTS'
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
    , FullBatch=t.text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE
       s.program_name LIKE N'SQLAgent%'
    OR t.text LIKE N'%usp_RCA_%'
    OR t.text LIKE N'%CaptureRunID%'
ORDER BY r.session_id;
GO


/*==============================================================================
  3. CURRENT RCA SQL AGENT JOB ACTIVITY
==============================================================================*/
IF DB_ID(N'msdb') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='3 - ACTIVE RCA SQL AGENT JOBS'
        , JobName=j.name
        , j.enabled
        , a.start_execution_date
        , a.stop_execution_date
        , a.last_executed_step_id
        , a.next_scheduled_run_date
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
           j.name LIKE N'RCA[_]%'
        OR j.name LIKE N'%Capture%'
      )
    ORDER BY j.name;
END;
GO


/*==============================================================================
  4. RCA JOB DEFINITIONS REFERENCING PARSER OR CAPTURE 20
==============================================================================*/
IF DB_ID(N'msdb') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='4 - RCA JOB DEFINITIONS'
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
           j.name LIKE N'RCA[_]%'
        OR s.command LIKE N'%usp_RCA_ParseCaptureRun%'
        OR s.command LIKE N'%CaptureRunID%20%'
        OR s.command LIKE N'%@CaptureRunID%20%'
    ORDER BY j.name,s.step_id;
END;
GO


/*==============================================================================
  5. UNIQUE CONSTRAINT / INDEX ON RCA_EXECUTIONEVIDENCE
==============================================================================*/
SELECT
      DiagnosticSection='5 - EXECUTION EVIDENCE UNIQUE KEYS'
    , IndexName=i.name
    , IsUnique=i.is_unique
    , IsPrimaryKey=i.is_primary_key
    , IndexType=i.type_desc
    , KeyOrdinal=ic.key_ordinal
    , ColumnName=c.name
    , IsIncludedColumn=ic.is_included_column
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id=i.object_id
 AND ic.index_id=i.index_id
JOIN sys.columns AS c
  ON c.object_id=ic.object_id
 AND c.column_id=ic.column_id
WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
  AND i.is_unique=1
ORDER BY i.index_id,ic.key_ordinal,ic.index_column_id;
GO


/*==============================================================================
  6. FIND THE DUPLICATE KEY COLUMN IF SINGLE-COLUMN UNIQUE KEY EXISTS
==============================================================================*/
DECLARE
      @UniqueIndexName sysname
    , @UniqueColumnName sysname;

SELECT TOP (1)
      @UniqueIndexName=i.name
    , @UniqueColumnName=c.name
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id=i.object_id
 AND ic.index_id=i.index_id
JOIN sys.columns AS c
  ON c.object_id=ic.object_id
 AND c.column_id=ic.column_id
WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
  AND i.is_unique=1
  AND i.is_primary_key=0
  AND ic.key_ordinal=1
  AND NOT EXISTS
  (
      SELECT 1
      FROM sys.index_columns AS ic2
      WHERE ic2.object_id=i.object_id
        AND ic2.index_id=i.index_id
        AND ic2.key_ordinal>1
  )
ORDER BY i.index_id;

SELECT
      DiagnosticSection='6 - DUPLICATE KEY CANDIDATE'
    , UniqueIndexName=@UniqueIndexName
    , UniqueColumnName=@UniqueColumnName
    , DuplicateValue='8135';
GO


/*==============================================================================
  7. ROW THAT OWNS DUPLICATE KEY 8135
  Dynamic because we first discover the single-column unique key.
==============================================================================*/
DECLARE
      @UniqueColumn sysname
    , @sql nvarchar(max);

SELECT TOP (1)
      @UniqueColumn=c.name
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id=i.object_id
 AND ic.index_id=i.index_id
JOIN sys.columns AS c
  ON c.object_id=ic.object_id
 AND c.column_id=ic.column_id
WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
  AND i.is_unique=1
  AND i.is_primary_key=0
  AND ic.key_ordinal=1
  AND NOT EXISTS
  (
      SELECT 1
      FROM sys.index_columns AS ic2
      WHERE ic2.object_id=i.object_id
        AND ic2.index_id=i.index_id
        AND ic2.key_ordinal>1
  )
ORDER BY i.index_id;

IF @UniqueColumn IS NOT NULL
BEGIN
    SET @sql=
        N'SELECT DiagnosticSection=N''7 - EXISTING ROW FOR DUPLICATE KEY 8135'', *
          FROM dbo.RCA_ExecutionEvidence
          WHERE TRY_CONVERT(bigint,'+QUOTENAME(@UniqueColumn)+N')=8135;';

    EXEC sys.sp_executesql @sql;
END
ELSE
BEGIN
    SELECT
          DiagnosticSection='7 - EXISTING ROW FOR DUPLICATE KEY 8135'
        , Result='REVIEW - no single-column unique key discovered';
END;
GO


/*==============================================================================
  8. EXECUTION EVIDENCE ROWS FOR CAPTURE 20
==============================================================================*/
SELECT TOP (200)
      DiagnosticSection='8 - CAPTURE 20 EXECUTION EVIDENCE'
    , *
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=20
ORDER BY ExecutionEvidenceID;
GO


/*==============================================================================
  9. PARSER DEFINITION
==============================================================================*/
SELECT
      DiagnosticSection='9 - PARSE CAPTURE RUN DEFINITION'
    , ProcedureName=N'dbo.usp_RCA_ParseCaptureRun'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'));
GO


/*==============================================================================
  10. PARSER LINE-ORIENTED TEXT AROUND INSERT LOGIC
==============================================================================*/
DECLARE @Definition nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'));

IF OBJECT_ID(N'tempdb..#ParserLines',N'U') IS NOT NULL
    DROP TABLE #ParserLines;

CREATE TABLE #ParserLines
(
      LineNumber int NOT NULL
    , LineText nvarchar(max) NULL
);

DECLARE
      @pos int=1
    , @next int
    , @line int=1
    , @len int=LEN(@Definition);

WHILE @pos<=@len+1
BEGIN
    SET @next=CHARINDEX(CHAR(10),@Definition,@pos);

    IF @next=0
        SET @next=@len+1;

    INSERT #ParserLines(LineNumber,LineText)
    VALUES
    (
        @line,
        REPLACE(SUBSTRING(@Definition,@pos,@next-@pos),CHAR(13),N'')
    );

    SET @pos=@next+1;
    SET @line+=1;

    IF @next>@len BREAK;
END;

SELECT
      DiagnosticSection='10 - PARSER LINES 45 TO 75'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN 45 AND 75
ORDER BY LineNumber;
GO


/*==============================================================================
  11. PARSER IDEMPOTENCY / DUPLICATE-PROTECTION CHECK
==============================================================================*/
DECLARE @Parser nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'));

SELECT
      ValidationSection='11 - PARSER IDEMPOTENCY CHECK'
    , UsesNotExists=
        CASE WHEN @Parser LIKE N'%NOT EXISTS%' THEN 'YES' ELSE 'NO' END
    , UsesMerge=
        CASE WHEN @Parser LIKE N'%MERGE%' THEN 'YES' ELSE 'NO' END
    , UsesLeftJoinAntiJoin=
        CASE WHEN @Parser LIKE N'%LEFT JOIN%'
               AND @Parser LIKE N'%IS NULL%'
             THEN 'YES' ELSE 'NO' END
    , UsesIgnoreDupKey=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.indexes
            WHERE object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
              AND ignore_dup_key=1
        ) THEN 'YES' ELSE 'NO' END
    , InsertsExecutionEvidence=
        CASE WHEN @Parser LIKE N'%INSERT%RCA_ExecutionEvidence%'
             THEN 'YES' ELSE 'NO' END
    , Interpretation=
        N'Presence of generic NOT EXISTS/MERGE text does not prove the exact INSERT is idempotent; inspect Section 10 and the full definition.';
GO


/*==============================================================================
  12. OBJECTS THAT CALL usp_RCA_ParseCaptureRun
==============================================================================*/
SELECT
      DiagnosticSection='12 - PARSER CALLERS'
    , ReferencingSchema=OBJECT_SCHEMA_NAME(d.referencing_id)
    , ReferencingObject=OBJECT_NAME(d.referencing_id)
    , ReferencingType=o.type_desc
FROM sys.sql_expression_dependencies AS d
JOIN sys.objects AS o
  ON o.object_id=d.referencing_id
WHERE d.referenced_id=OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun')
ORDER BY o.type_desc,OBJECT_NAME(d.referencing_id);
GO


/*==============================================================================
  13. MODULES THAT MENTION usp_RCA_ParseCaptureRun
==============================================================================*/
SELECT
      DiagnosticSection='13 - PARSER TEXT CALLERS'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ObjectName=o.name
    , ObjectType=o.type_desc
FROM sys.objects AS o
JOIN sys.sql_modules AS m
  ON m.object_id=o.object_id
WHERE m.definition LIKE N'%usp_RCA_ParseCaptureRun%'
  AND o.object_id<>OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun')
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  14. SOURCE RAW ROWS AROUND KEY 8135
  Discover likely raw-source column names first.
==============================================================================*/
SELECT
      DiagnosticSection='14 - EXECUTION EVIDENCE SOURCE ID COLUMNS'
    , ColumnID=c.column_id
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
FROM sys.columns AS c
WHERE c.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
  AND
  (
       c.name LIKE N'%Raw%'
    OR c.name LIKE N'%XE%'
    OR c.name LIKE N'%Source%'
    OR c.name LIKE N'%Event%'
  )
ORDER BY c.column_id;
GO


/*==============================================================================
  15. CAPTURE 20 EVIDENCE STABILITY TEST
==============================================================================*/
IF OBJECT_ID(N'tempdb..#Before',N'U') IS NOT NULL DROP TABLE #Before;
IF OBJECT_ID(N'tempdb..#After',N'U') IS NOT NULL DROP TABLE #After;

CREATE TABLE #Before
(
      ObjectName nvarchar(776) NOT NULL PRIMARY KEY
    , TotalRows bigint NOT NULL
);

CREATE TABLE #After
(
      ObjectName nvarchar(776) NOT NULL PRIMARY KEY
    , TotalRows bigint NOT NULL
);

DECLARE
      @s sysname
    , @o sysname
    , @q nvarchar(776)
    , @display nvarchar(776)
    , @dyn nvarchar(max);

DECLARE B CURSOR LOCAL FAST_FORWARD FOR
SELECT
      SCHEMA_NAME(t.schema_id)
    , t.name
    , QUOTENAME(SCHEMA_NAME(t.schema_id))+N'.'+QUOTENAME(t.name)
FROM sys.tables AS t
WHERE t.is_ms_shipped=0
  AND t.name LIKE N'RCA[_]%'
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id=t.object_id
        AND c.name=N'CaptureRunID'
  );

OPEN B;
FETCH NEXT FROM B INTO @s,@o,@q;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @display=QUOTENAME(@s)+N'.'+QUOTENAME(@o);

    SET @dyn=
        N'INSERT #Before(ObjectName,TotalRows)
          SELECT @display,COUNT_BIG(*)
          FROM '+@q+N'
          WHERE CaptureRunID=20;';

    EXEC sys.sp_executesql
          @dyn
        , N'@display nvarchar(776)'
        , @display=@display;

    FETCH NEXT FROM B INTO @s,@o,@q;
END;

CLOSE B;
DEALLOCATE B;

WAITFOR DELAY '00:00:10';

DECLARE A CURSOR LOCAL FAST_FORWARD FOR
SELECT
      SCHEMA_NAME(t.schema_id)
    , t.name
    , QUOTENAME(SCHEMA_NAME(t.schema_id))+N'.'+QUOTENAME(t.name)
FROM sys.tables AS t
WHERE t.is_ms_shipped=0
  AND t.name LIKE N'RCA[_]%'
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id=t.object_id
        AND c.name=N'CaptureRunID'
  );

OPEN A;
FETCH NEXT FROM A INTO @s,@o,@q;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @display=QUOTENAME(@s)+N'.'+QUOTENAME(@o);

    SET @dyn=
        N'INSERT #After(ObjectName,TotalRows)
          SELECT @display,COUNT_BIG(*)
          FROM '+@q+N'
          WHERE CaptureRunID=20;';

    EXEC sys.sp_executesql
          @dyn
        , N'@display nvarchar(776)'
        , @display=@display;

    FETCH NEXT FROM A INTO @s,@o,@q;
END;

CLOSE A;
DEALLOCATE A;

SELECT
      DiagnosticSection='15 - CAPTURE 20 EVIDENCE STABILITY DETAIL'
    , ObjectName=COALESCE(b.ObjectName,a.ObjectName)
    , BeforeRows=ISNULL(b.TotalRows,0)
    , AfterRows=ISNULL(a.TotalRows,0)
    , DeltaRows=ISNULL(a.TotalRows,0)-ISNULL(b.TotalRows,0)
FROM #Before AS b
FULL OUTER JOIN #After AS a
  ON a.ObjectName=b.ObjectName
ORDER BY COALESCE(b.ObjectName,a.ObjectName);

DECLARE @ChangedObjects int;

SELECT @ChangedObjects=COUNT(*)
FROM #Before AS b
FULL OUTER JOIN #After AS a
  ON a.ObjectName=b.ObjectName
WHERE ISNULL(b.TotalRows,0)<>ISNULL(a.TotalRows,0);

SELECT
      ValidationSection='15A - CAPTURE 20 EVIDENCE STABILITY'
    , ChangedObjects=@ChangedObjects
    , Result=
        CASE WHEN @ChangedObjects=0
             THEN 'PASS - CAPTURE 20 EVIDENCE COUNTS STABLE'
             ELSE 'ACTIVE - CAPTURE 20 EVIDENCE STILL CHANGING'
        END;
GO


/*==============================================================================
  16. RECENT EXECUTION EVIDENCE INSERT ACTIVITY
==============================================================================*/
IF COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'EventTimeUTC') IS NOT NULL
BEGIN
    SELECT TOP (100)
          DiagnosticSection='16 - RECENT EXECUTION EVIDENCE'
        , *
    FROM dbo.RCA_ExecutionEvidence
    ORDER BY EventTimeUTC DESC,ExecutionEvidenceID DESC;
END
ELSE
BEGIN
    SELECT TOP (100)
          DiagnosticSection='16 - RECENT EXECUTION EVIDENCE'
        , *
    FROM dbo.RCA_ExecutionEvidence
    ORDER BY ExecutionEvidenceID DESC;
END;
GO


/*==============================================================================
  17. DUPLICATE KEY OWNERSHIP VS CAPTURE 20
==============================================================================*/
DECLARE
      @DupColumn sysname
    , @DupSql nvarchar(max);

SELECT TOP (1)
      @DupColumn=c.name
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id=i.object_id
 AND ic.index_id=i.index_id
JOIN sys.columns AS c
  ON c.object_id=ic.object_id
 AND c.column_id=ic.column_id
WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
  AND i.is_unique=1
  AND i.is_primary_key=0
  AND ic.key_ordinal=1
  AND NOT EXISTS
  (
      SELECT 1
      FROM sys.index_columns AS ic2
      WHERE ic2.object_id=i.object_id
        AND ic2.index_id=i.index_id
        AND ic2.key_ordinal>1
  )
ORDER BY i.index_id;

IF @DupColumn IS NOT NULL
BEGIN
    SET @DupSql=
        N'SELECT
              ValidationSection=N''17 - DUPLICATE OWNERSHIP ASSESSMENT''
            , DuplicateKeyColumn=N'''+REPLACE(@DupColumn,'''','''''')+N'''
            , DuplicateKeyValue=8135
            , ExistingCaptureRunID=CaptureRunID
            , ExistingExecutionEvidenceID=ExecutionEvidenceID
            , IsCapture20=
                CASE WHEN CaptureRunID=20 THEN ''YES'' ELSE ''NO'' END
          FROM dbo.RCA_ExecutionEvidence
          WHERE TRY_CONVERT(bigint,'+QUOTENAME(@DupColumn)+N')=8135;';

    EXEC sys.sp_executesql @DupSql;
END;
GO


/*==============================================================================
  18. CURRENT SAFE-FINALIZATION READINESS
==============================================================================*/
DECLARE
      @Capture20Status nvarchar(60)
    , @Capture20End datetime2(3)
    , @ActiveRequests int=0
    , @ActiveJobs int=0;

SELECT
      @Capture20Status=CaptureStatus
    , @Capture20End=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

SELECT @ActiveRequests=COUNT(*)
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE
       t.text LIKE N'%CaptureRunID%20%'
    OR t.text LIKE N'%@CaptureRunID%20%'
    OR t.text LIKE N'%CaptureRunID = 20%'
    OR t.text LIKE N'%CaptureRunID=20%';

IF DB_ID(N'msdb') IS NOT NULL
BEGIN
    SELECT @ActiveJobs=COUNT(*)
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

SELECT
      ValidationSection='18 - SAFE FINALIZATION READINESS'
    , Capture20Status=@Capture20Status
    , Capture20EndTimeUTC=@Capture20End
    , ActiveCapture20Requests=@ActiveRequests
    , ActiveCapture20Jobs=@ActiveJobs
    , SupportedStopProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL
             THEN 'dbo.usp_RCA_Stop'
             ELSE 'NOT FOUND' END
    , RecommendedNextStep=
        CASE
          WHEN @Capture20Status<>'RUNNING'
          THEN N'Capture 20 is already closed; do not run finalization again.'
          WHEN @ActiveRequests>0 OR @ActiveJobs>0
          THEN N'Do not finalize Capture 20 yet. Identify the active RCA execution first.'
          ELSE N'Capture 20 appears idle at this instant. Review duplicate-key ownership and parser idempotency before retrying the supported finalizer.'
        END;
GO


/*==============================================================================
  19. SCRIPT 75 CONCLUSION
==============================================================================*/
SELECT
      ValidationSection='19 - SCRIPT 75 CONCLUSION'
    , ReadOnlyInvestigation='PASS'
    , Capture20EvidencePreserved='PASS'
    , ExecutionEvidencePreserved='PASS'
    , ParserPreserved='PASS'
    , SQLAgentJobsPreserved='PASS'
    , KeyQuestionsAnswered=
        N'Review Sections 2-5, 7, 10-12, 15A, 17, and 18.'
    , NextDecision=
        N'If duplicate key 8135 belongs to prior evidence and parser INSERT lacks exact duplicate protection, fix parser idempotency before attempting Capture 20 finalization again. If duplicate is unrelated and Capture 20 remains idle/stable, retry finalization only after confirming no active RCA work.';
GO


/*==============================================================================
  20. SAFETY
==============================================================================*/
SELECT
      ValidationSection='20 - SCRIPT 75 SAFETY'
    , ReadOnlyInvestigation='YES'
    , Capture20Modified='NO'
    , ExecutionEvidenceModified='NO'
    , ParserModified='NO'
    , SQLAgentJobsModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , NewCaptureStarted='NO';
GO
