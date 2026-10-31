USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  74_RCA_Capture20_Safe_Finalization_and_Regression_v1.sql

  PURPOSE
  -------
  Safely finalize CaptureRunID 20 through the SUPPORTED RCA lifecycle procedure
  discovered by Script 73, then prove that the canonical RCA controls still
  behave correctly.

  SCRIPT 73 ESTABLISHED
  ---------------------
      Capture 20 status              = RUNNING
      Capture 20 EndTimeUTC          = NULL
      Supported finalizer            = dbo.usp_RCA_Stop
      Active Capture 20 jobs         = 0
      Active Capture 20 requests     = 0
      SafeToConsiderFinalization     = YES

  SAFETY DESIGN
  -------------
  Before invoking dbo.usp_RCA_Stop this script rechecks:

      1. Capture 20 is still RUNNING.
      2. EndTimeUTC is still NULL.
      3. dbo.usp_RCA_Stop exists.
      4. The procedure exposes @CaptureRunID.
      5. No Capture-20 SQL Agent job is executing.
      6. No active request references CaptureRunID 20.
      7. Capture-20 evidence remains stable across a short observation window.

  ONLY THEN does the script execute the supported lifecycle finalizer.

  AFTER FINALIZATION
  ------------------
      Capture 20 -> must no longer be RUNNING
      EndTimeUTC -> must be populated
      I/O arbitration -> must remain PRIMARY / MEDIUM
      Capture 38 -> uncertainty preserved
      Capture 42 -> BLOCKING_WAIT_CHAIN / PRIMARY / HIGH
      Capture 44 -> CPU_SCHEDULER / PRIMARY / HIGH

  IMPORTANT
  ---------
  This script does NOT manually UPDATE dbo.RCA_CaptureRun.

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 74 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , StopProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , StopHasCaptureRunIDParameter=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.parameters
            WHERE object_id=OBJECT_ID(N'dbo.usp_RCA_Stop')
              AND name=N'@CaptureRunID'
        ) THEN 'PASS' ELSE 'FAIL' END
    , IOStorageEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ManualCaptureRunUpdate='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 57400,N'dbo.RCA_CaptureRun is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NULL
    THROW 57401,N'dbo.usp_RCA_Stop is required.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.parameters
    WHERE object_id=OBJECT_ID(N'dbo.usp_RCA_Stop')
      AND name=N'@CaptureRunID'
)
    THROW 57402,N'dbo.usp_RCA_Stop does not expose @CaptureRunID. Aborting rather than guessing the lifecycle signature.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=20
)
    THROW 57403,N'CaptureRunID 20 does not exist.',1;
GO


/*==============================================================================
  1. STOP PROCEDURE SIGNATURE
==============================================================================*/
SELECT
      ValidationSection='1 - STOP PROCEDURE SIGNATURE'
    , ParameterID=p.parameter_id
    , ParameterName=p.name
    , DataType=TYPE_NAME(p.user_type_id)
    , MaxLength=p.max_length
    , IsOutput=p.is_output
    , HasDefaultValue=p.has_default_value
FROM sys.parameters AS p
WHERE p.object_id=OBJECT_ID(N'dbo.usp_RCA_Stop')
ORDER BY p.parameter_id;
GO


/*==============================================================================
  2. CAPTURE 20 BEFORE STATE
==============================================================================*/
SELECT
      ValidationSection='2 - CAPTURE 20 BEFORE FINALIZATION'
    , *
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;
GO


/*==============================================================================
  3. BEFORE SNAPSHOT - CONTROL ARBITRATION
==============================================================================*/
SELECT
      ValidationSection='3 - BEFORE ARBITRATION STATE'
    , CaptureRunID
    , PrimaryCauseCategory
    , PrimaryCauseRole
    , PrimaryConfidence
    , PrimaryEvidenceObject
    , PrimaryEvidenceID
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , SupportedCauseCount
    , PrimaryCauseCount
    , ArbitrationStatus
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID IN (20,38,42,44)
ORDER BY CaptureRunID;
GO


/*==============================================================================
  4. BEFORE SNAPSHOT - CAPTURE 20 I/O EVIDENCE
==============================================================================*/
SELECT
      ValidationSection='4 - CAPTURE 20 IO EVIDENCE BEFORE'
    , *
FROM dbo.RCA_IOStorageEvidence
WHERE CaptureRunID=20
ORDER BY IOStorageEvidenceID;
GO


/*==============================================================================
  5. SAFETY RECHECK: ACTIVE CAPTURE-20 JOBS / REQUESTS
==============================================================================*/
DECLARE
      @ActiveCapture20Jobs int=0
    , @ActiveCapture20Requests int=0;

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

SELECT @ActiveCapture20Requests=COUNT(*)
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE
       t.text LIKE N'%CaptureRunID%20%'
    OR t.text LIKE N'%@CaptureRunID%20%'
    OR t.text LIKE N'%CaptureRunID = 20%'
    OR t.text LIKE N'%CaptureRunID=20%';

SELECT
      ValidationSection='5 - ACTIVE WORK SAFETY RECHECK'
    , ActiveCapture20Jobs=@ActiveCapture20Jobs
    , ActiveCapture20Requests=@ActiveCapture20Requests
    , Result=
        CASE
          WHEN @ActiveCapture20Jobs=0
           AND @ActiveCapture20Requests=0
          THEN 'PASS - NO ACTIVE CAPTURE 20 WORK DETECTED'
          ELSE 'FAIL - ACTIVE CAPTURE 20 WORK EXISTS'
        END;

IF @ActiveCapture20Jobs>0 OR @ActiveCapture20Requests>0
    THROW 57410,N'Capture 20 still has active work. Finalization aborted.',1;
GO


/*==============================================================================
  6. SAFETY RECHECK: EVIDENCE STABILITY WINDOW

  We compare row counts for CaptureRunID 20 across RCA tables that contain a
  CaptureRunID column. If any count changes during the observation interval,
  finalization is aborted.

  This is intentionally conservative.
==============================================================================*/
IF OBJECT_ID(N'tempdb..#BeforeCounts',N'U') IS NOT NULL DROP TABLE #BeforeCounts;
IF OBJECT_ID(N'tempdb..#AfterCounts',N'U') IS NOT NULL DROP TABLE #AfterCounts;

CREATE TABLE #BeforeCounts
(
      ObjectName nvarchar(776) NOT NULL PRIMARY KEY
    , TotalRows bigint NOT NULL
);

CREATE TABLE #AfterCounts
(
      ObjectName nvarchar(776) NOT NULL PRIMARY KEY
    , TotalRows bigint NOT NULL
);

DECLARE
      @SchemaName sysname
    , @ObjectName sysname
    , @QualifiedName nvarchar(776)
    , @DisplayName nvarchar(776)
    , @sql nvarchar(max);

DECLARE C1 CURSOR LOCAL FAST_FORWARD FOR
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
  )
ORDER BY SCHEMA_NAME(t.schema_id),t.name;

OPEN C1;
FETCH NEXT FROM C1 INTO @SchemaName,@ObjectName,@QualifiedName;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @DisplayName=QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@ObjectName);

    SET @sql=
        N'INSERT #BeforeCounts(ObjectName,TotalRows)
          SELECT @DisplayName,COUNT_BIG(*)
          FROM '+@QualifiedName+N'
          WHERE CaptureRunID=20;';

    EXEC sys.sp_executesql
          @sql
        , N'@DisplayName nvarchar(776)'
        , @DisplayName=@DisplayName;

    FETCH NEXT FROM C1 INTO @SchemaName,@ObjectName,@QualifiedName;
END;

CLOSE C1;
DEALLOCATE C1;

WAITFOR DELAY '00:00:05';

DECLARE C2 CURSOR LOCAL FAST_FORWARD FOR
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
  )
ORDER BY SCHEMA_NAME(t.schema_id),t.name;

OPEN C2;
FETCH NEXT FROM C2 INTO @SchemaName,@ObjectName,@QualifiedName;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @DisplayName=QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@ObjectName);

    SET @sql=
        N'INSERT #AfterCounts(ObjectName,TotalRows)
          SELECT @DisplayName,COUNT_BIG(*)
          FROM '+@QualifiedName+N'
          WHERE CaptureRunID=20;';

    EXEC sys.sp_executesql
          @sql
        , N'@DisplayName nvarchar(776)'
        , @DisplayName=@DisplayName;

    FETCH NEXT FROM C2 INTO @SchemaName,@ObjectName,@QualifiedName;
END;

CLOSE C2;
DEALLOCATE C2;

SELECT
      ValidationSection='6 - EVIDENCE STABILITY DETAIL'
    , ObjectName=COALESCE(b.ObjectName,a.ObjectName)
    , BeforeRows=ISNULL(b.TotalRows,0)
    , AfterRows=ISNULL(a.TotalRows,0)
    , DeltaRows=ISNULL(a.TotalRows,0)-ISNULL(b.TotalRows,0)
FROM #BeforeCounts AS b
FULL OUTER JOIN #AfterCounts AS a
  ON a.ObjectName=b.ObjectName
ORDER BY COALESCE(b.ObjectName,a.ObjectName);

DECLARE @EvidenceChanges int;

SELECT @EvidenceChanges=COUNT(*)
FROM #BeforeCounts AS b
FULL OUTER JOIN #AfterCounts AS a
  ON a.ObjectName=b.ObjectName
WHERE ISNULL(a.TotalRows,0)<>ISNULL(b.TotalRows,0);

SELECT
      ValidationSection='6A - EVIDENCE STABILITY RESULT'
    , ChangedObjects=@EvidenceChanges
    , Result=
        CASE WHEN @EvidenceChanges=0
             THEN 'PASS - CAPTURE 20 EVIDENCE COUNTS STABLE'
             ELSE 'FAIL - CAPTURE 20 EVIDENCE IS STILL CHANGING'
        END;

IF @EvidenceChanges<>0
    THROW 57411,N'Capture 20 evidence changed during the safety window. Finalization aborted.',1;
GO


/*==============================================================================
  7. FINAL PRE-STOP LIFECYCLE CHECK
==============================================================================*/
DECLARE
      @CaptureStatus nvarchar(60)
    , @EndTimeUTC datetime2(3);

SELECT
      @CaptureStatus=CaptureStatus
    , @EndTimeUTC=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

SELECT
      ValidationSection='7 - FINAL PRE-STOP CHECK'
    , CaptureRunID=20
    , CaptureStatus=@CaptureStatus
    , EndTimeUTC=@EndTimeUTC
    , Result=
        CASE
          WHEN @CaptureStatus='RUNNING'
           AND @EndTimeUTC IS NULL
          THEN 'PASS - READY FOR SUPPORTED FINALIZATION'
          WHEN @CaptureStatus<>'RUNNING'
          THEN 'NO ACTION - CAPTURE ALREADY CLOSED'
          ELSE 'REVIEW'
        END;

IF @CaptureStatus<>'RUNNING'
BEGIN
    SELECT
          ValidationSection='7A - FINALIZATION SKIPPED'
        , Reason='Capture 20 is already closed. No stop procedure was executed.';
END
ELSE IF @EndTimeUTC IS NOT NULL
BEGIN
    THROW 57412,N'Capture 20 has RUNNING status but EndTimeUTC is already populated. Review lifecycle metadata before stopping.',1;
END;
GO


/*==============================================================================
  8. SUPPORTED FINALIZATION

  IMPORTANT:
  No UPDATE against dbo.RCA_CaptureRun exists in this script.
  The supported RCA lifecycle procedure owns the state transition.
==============================================================================*/
DECLARE
      @CaptureStatusBefore nvarchar(60)
    , @EndBefore datetime2(3);

SELECT
      @CaptureStatusBefore=CaptureStatus
    , @EndBefore=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

IF @CaptureStatusBefore='RUNNING'
   AND @EndBefore IS NULL
BEGIN
    BEGIN TRY
        SELECT
              ValidationSection='8 - INVOKING SUPPORTED FINALIZER'
            , ProcedureCalled='dbo.usp_RCA_Stop'
            , CaptureRunID=20
            , ManualUpdateUsed='NO';

        EXEC dbo.usp_RCA_Stop
             @CaptureRunID=20;
    END TRY
    BEGIN CATCH
        SELECT
              ValidationSection='8A - FINALIZER ERROR'
            , ErrorNumber=ERROR_NUMBER()
            , ErrorSeverity=ERROR_SEVERITY()
            , ErrorState=ERROR_STATE()
            , ErrorProcedure=ERROR_PROCEDURE()
            , ErrorLine=ERROR_LINE()
            , ErrorMessage=ERROR_MESSAGE();

        THROW;
    END CATCH;
END;
GO


/*==============================================================================
  9. CAPTURE 20 AFTER STATE
==============================================================================*/
SELECT
      ValidationSection='9 - CAPTURE 20 AFTER FINALIZATION'
    , *
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;
GO


/*==============================================================================
  10. LIFECYCLE ACCEPTANCE
==============================================================================*/
DECLARE
      @AfterStatus nvarchar(60)
    , @AfterEnd datetime2(3);

SELECT
      @AfterStatus=CaptureStatus
    , @AfterEnd=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=20;

SELECT
      ValidationSection='10 - CAPTURE 20 LIFECYCLE ACCEPTANCE'
    , CaptureRunID=20
    , CaptureStatus=@AfterStatus
    , EndTimeUTC=@AfterEnd
    , NoLongerRunning=
        CASE WHEN @AfterStatus<>'RUNNING' THEN 'PASS' ELSE 'FAIL' END
    , EndTimePopulated=
        CASE WHEN @AfterEnd IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , Result=
        CASE
          WHEN @AfterStatus<>'RUNNING'
           AND @AfterEnd IS NOT NULL
          THEN 'PASS - CAPTURE 20 FINALIZED THROUGH SUPPORTED RCA LIFECYCLE'
          ELSE 'FAIL - CAPTURE 20 LIFECYCLE DID NOT CLOSE CLEANLY'
        END;
GO


/*==============================================================================
  11. CAPTURE 20 I/O EVIDENCE AFTER
==============================================================================*/
SELECT
      ValidationSection='11 - CAPTURE 20 IO EVIDENCE AFTER'
    , *
FROM dbo.RCA_IOStorageEvidence
WHERE CaptureRunID=20
ORDER BY IOStorageEvidenceID;
GO


/*==============================================================================
  12. FOUR-CONTROL ARBITRATION REGRESSION
==============================================================================*/
SELECT
      ValidationSection='12 - FOUR-CONTROL ARBITRATION REGRESSION'
    , c.CaptureRunID
    , c.CaptureStatus
    , c.EndTimeUTC
    , s.PrimaryCauseCategory
    , s.PrimaryCauseRole
    , s.PrimaryConfidence
    , s.PrimaryEvidenceObject
    , s.PrimaryEvidenceID
    , s.PrimaryExecutionEvidenceID
    , s.PrimarySessionID
    , s.SupportedCauseCount
    , s.PrimaryCauseCount
    , s.ArbitrationStatus
FROM dbo.RCA_CaptureRun AS c
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=c.CaptureRunID
WHERE c.CaptureRunID IN (20,38,42,44)
ORDER BY c.CaptureRunID;
GO


/*==============================================================================
  13. CAPTURE 20 CANONICAL ANSWER AFTER FINALIZATION
==============================================================================*/
SELECT
      ValidationSection='13 - CAPTURE 20 CANONICAL ANSWER AFTER FINALIZATION'
    , Expected='ROOT CAUSE IDENTIFIED - IO / STORAGE LATENCY - MEDIUM';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=20;
GO


/*==============================================================================
  14. CAPTURE 38 NEGATIVE CONTROL
==============================================================================*/
SELECT
      ValidationSection='14 - CAPTURE 38 NEGATIVE CONTROL'
    , Expected='ROOT CAUSE NOT CONFIRMED';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;
GO


/*==============================================================================
  15. CAPTURE 42 BLOCKING CONTROL
==============================================================================*/
SELECT
      ValidationSection='15 - CAPTURE 42 BLOCKING CONTROL'
    , Expected='ROOT CAUSE IDENTIFIED - BLOCKING / WAIT-CHAIN - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO


/*==============================================================================
  16. CAPTURE 44 CPU CONTROL
==============================================================================*/
SELECT
      ValidationSection='16 - CAPTURE 44 CPU CONTROL'
    , Expected='ROOT CAUSE IDENTIFIED - CPU / SCHEDULER - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO


/*==============================================================================
  17. FINAL REGRESSION ACCEPTANCE
==============================================================================*/
DECLARE
      @Status20 nvarchar(60)
    , @End20 datetime2(3)
    , @Cause20 varchar(60)
    , @Role20 varchar(20)
    , @Confidence20 varchar(20)
    , @Exec20 bigint
    , @Session20 int
    , @Primary38 int=0
    , @Cause42 varchar(60)
    , @Role42 varchar(20)
    , @Confidence42 varchar(20)
    , @Cause44 varchar(60)
    , @Role44 varchar(20)
    , @Confidence44 varchar(20);

SELECT
      @Status20=c.CaptureStatus
    , @End20=c.EndTimeUTC
    , @Cause20=s.PrimaryCauseCategory
    , @Role20=s.PrimaryCauseRole
    , @Confidence20=s.PrimaryConfidence
    , @Exec20=s.PrimaryExecutionEvidenceID
    , @Session20=s.PrimarySessionID
FROM dbo.RCA_CaptureRun AS c
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=c.CaptureRunID
WHERE c.CaptureRunID=20;

SELECT
      @Primary38=ISNULL(PrimaryCauseCount,0)
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=38;

SELECT
      @Cause42=PrimaryCauseCategory
    , @Role42=PrimaryCauseRole
    , @Confidence42=PrimaryConfidence
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=42;

SELECT
      @Cause44=PrimaryCauseCategory
    , @Role44=PrimaryCauseRole
    , @Confidence44=PrimaryConfidence
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID=44;

SELECT
      ValidationSection='17 - SCRIPT 74 FINAL ACCEPTANCE'

    , Capture20Closed=
        CASE WHEN @Status20<>'RUNNING' AND @End20 IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END

    , Capture20IO=
        CASE WHEN @Cause20='IO_STORAGE_LATENCY'
                  AND @Role20='PRIMARY'
                  AND @Confidence20 IN ('HIGH','MEDIUM')
             THEN 'PASS' ELSE 'FAIL' END

    , Capture20NoFabricatedSession=
        CASE WHEN @Exec20 IS NULL AND @Session20 IS NULL
             THEN 'PASS' ELSE 'FAIL' END

    , Capture38Uncertainty=
        CASE WHEN ISNULL(@Primary38,0)=0
             THEN 'PASS' ELSE 'FAIL' END

    , Capture42Blocking=
        CASE WHEN @Cause42='BLOCKING_WAIT_CHAIN'
                  AND @Role42='PRIMARY'
                  AND @Confidence42='HIGH'
             THEN 'PASS' ELSE 'FAIL' END

    , Capture44CPU=
        CASE WHEN @Cause44='CPU_SCHEDULER'
                  AND @Role44='PRIMARY'
                  AND @Confidence44='HIGH'
             THEN 'PASS' ELSE 'FAIL' END

    , ManualCaptureRunUpdate='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , NewCaptureStarted='NO'

    , OverallResult=
        CASE
          WHEN @Status20<>'RUNNING'
           AND @End20 IS NOT NULL
           AND @Cause20='IO_STORAGE_LATENCY'
           AND @Role20='PRIMARY'
           AND @Confidence20 IN ('HIGH','MEDIUM')
           AND @Exec20 IS NULL
           AND @Session20 IS NULL
           AND ISNULL(@Primary38,0)=0
           AND @Cause42='BLOCKING_WAIT_CHAIN'
           AND @Role42='PRIMARY'
           AND @Confidence42='HIGH'
           AND @Cause44='CPU_SCHEDULER'
           AND @Role44='PRIMARY'
           AND @Confidence44='HIGH'
          THEN 'PASS - CAPTURE 20 CLOSED AND RCA V1 CONTROLS REMAIN VALID'
          ELSE 'REVIEW - CAPTURE 20 FINALIZATION OR CONTROL REGRESSION FAILED'
        END

    , NextStep=
        N'If this row passes, Capture 20 lifecycle cleanup is complete and the RCA v1 exercise can move to freeze/documentation/operational packaging.';
GO


/*==============================================================================
  18. FINAL SAFETY
==============================================================================*/
SELECT
      ValidationSection='18 - SCRIPT 74 FINAL SAFETY'
    , SupportedLifecycleProcedureUsed='YES'
    , ManualCaptureRunUpdate='NO'
    , NewCaptureStarted='NO'
    , SQLAgentJobsModified='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , ManualCauseInserted='NO';
GO
