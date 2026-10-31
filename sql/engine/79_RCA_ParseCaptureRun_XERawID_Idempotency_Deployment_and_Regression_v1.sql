USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  79_RCA_ParseCaptureRun_XERawID_Idempotency_Deployment_and_Regression_v1.sql

  PURPOSE
  -------
  Deploy the proven XERawID collision fix to dbo.usp_RCA_ParseCaptureRun,
  reparse CaptureRunID 20, and regression-test the established RCA controls.

  ROOT CAUSE ALREADY PROVEN
  -------------------------
  - Capture 20 and Capture 38 had overlapping capture windows.
  - XERawID 8135 is legitimate RCA_XERaw evidence.
  - XERawID 8135 is already persisted in RCA_ExecutionEvidence for Capture 38.
  - RCA_ExecutionEvidence.XERawID is globally UNIQUE.
  - RCA_StatementEvidence.XERawID is globally UNIQUE.
  - RCA_PlanEvidence.XERawID is globally UNIQUE.
  - The parser deletes derived rows only for @CaptureRunID.
  - The parser then rereads RCA_XERaw by time window.
  - The three raw-XE INSERT paths had no anti-collision predicate.

  DESIGN
  ------
  Preserve global XERawID uniqueness.

  Add ONLY these guards:

      ExecutionEvidence:
          NOT EXISTS against dbo.RCA_ExecutionEvidence(XERawID)

      StatementEvidence:
          NOT EXISTS against dbo.RCA_StatementEvidence(XERawID)

      PlanEvidence:
          NOT EXISTS against dbo.RCA_PlanEvidence(XERawID)

  Then deliberately execute:
      dbo.usp_RCA_ParseCaptureRun @CaptureRunID = 20

  and prove:
      - no duplicate-key failure occurs;
      - XERawID 8135 remains owned by Capture 38;
      - Capture 20 reaches ANALYZED;
      - Capture 20 I/O root cause remains valid;
      - Capture 38 uncertainty remains preserved;
      - Capture 42 remains blocking;
      - Capture 44 remains CPU / scheduler;
      - no duplicate XERawID groups exist.

  TRANSACTIONAL SAFETY
  --------------------
  The parser ALTER and Capture 20 reparse are performed inside one explicit
  transaction.

  If deployment, reparse, or the hard regression assertions fail, the script
  rolls the transaction back so both the procedure definition and Capture 20
  derived evidence return to their pre-Script-79 state.

==============================================================================*/

DECLARE @TargetCaptureRunID bigint = 20;
DECLARE @DuplicateXERawID bigint = 8135;

DECLARE
      @OriginalDefinition nvarchar(max)
    , @PatchedDefinition nvarchar(max)
    , @BeforeParserHash varbinary(32)
    , @AfterParserHash varbinary(32)
    , @BeforeCapture20Status nvarchar(60)
    , @BeforeCapture20EndTimeUTC datetime2(3)
    , @Before8135CaptureRunID bigint
    , @Before8135ExecutionEvidenceID bigint;


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      @OriginalDefinition = sm.definition
    , @BeforeParserHash =
        HASHBYTES('SHA2_256',CONVERT(varbinary(max),sm.definition))
FROM sys.sql_modules AS sm
WHERE sm.object_id=OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun');

SELECT
      @BeforeCapture20Status=CaptureStatus
    , @BeforeCapture20EndTimeUTC=EndTimeUTC
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=@TargetCaptureRunID;

SELECT TOP (1)
      @Before8135CaptureRunID=CaptureRunID
    , @Before8135ExecutionEvidenceID=ExecutionEvidenceID
FROM dbo.RCA_ExecutionEvidence
WHERE XERawID=@DuplicateXERawID;

SELECT
      ValidationSection='0 - SCRIPT 79 PRE-FLIGHT'
    , ParseCaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , Capture20=
        CASE WHEN EXISTS
             (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=20)
             THEN 'PASS' ELSE 'FAIL' END
    , ExecutionEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , StatementEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_StatementEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , PlanEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , XERaw=
        CASE WHEN OBJECT_ID(N'dbo.RCA_XERaw',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , Capture20Status=@BeforeCapture20Status
    , Capture20EndTimeUTC=@BeforeCapture20EndTimeUTC
    , XERaw8135OwnerCapture=@Before8135CaptureRunID
    , XERaw8135ExecutionEvidenceID=@Before8135ExecutionEvidenceID
    , ExistingEvidenceModified='NO'
    , UniqueIndexesModified='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';

IF @OriginalDefinition IS NULL
    THROW 62900,N'Unable to read dbo.usp_RCA_ParseCaptureRun.',1;

IF @BeforeCapture20Status <> N'STOPPED'
    THROW 62901,N'Capture 20 must be STOPPED before parser repair/reparse.',1;

IF @BeforeCapture20EndTimeUTC IS NULL
    THROW 62902,N'Capture 20 must have EndTimeUTC populated before parser repair/reparse.',1;

IF @Before8135CaptureRunID <> 38
    THROW 62903,N'XERawID 8135 is no longer owned by Capture 38. Abort and investigate before deployment.',1;


/*==============================================================================
  1. VERIFY THE THREE GLOBAL XERawID UNIQUE CONTRACTS
==============================================================================*/
IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes i
    JOIN sys.index_columns ic
      ON ic.object_id=i.object_id
     AND ic.index_id=i.index_id
    JOIN sys.columns c
      ON c.object_id=ic.object_id
     AND c.column_id=ic.column_id
    WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
      AND i.is_unique=1
      AND i.ignore_dup_key=0
      AND c.name=N'XERawID'
)
    THROW 62910,N'Expected UNIQUE XERawID contract missing from RCA_ExecutionEvidence.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes i
    JOIN sys.index_columns ic
      ON ic.object_id=i.object_id
     AND ic.index_id=i.index_id
    JOIN sys.columns c
      ON c.object_id=ic.object_id
     AND c.column_id=ic.column_id
    WHERE i.object_id=OBJECT_ID(N'dbo.RCA_StatementEvidence')
      AND i.is_unique=1
      AND i.ignore_dup_key=0
      AND c.name=N'XERawID'
)
    THROW 62911,N'Expected UNIQUE XERawID contract missing from RCA_StatementEvidence.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes i
    JOIN sys.index_columns ic
      ON ic.object_id=i.object_id
     AND ic.index_id=i.index_id
    JOIN sys.columns c
      ON c.object_id=ic.object_id
     AND c.column_id=ic.column_id
    WHERE i.object_id=OBJECT_ID(N'dbo.RCA_PlanEvidence')
      AND i.is_unique=1
      AND i.ignore_dup_key=0
      AND c.name=N'XERawID'
)
    THROW 62912,N'Expected UNIQUE XERawID contract missing from RCA_PlanEvidence.',1;

SELECT
      ValidationSection='1 - XERAWID UNIQUE CONTRACT'
    , TableName=t.name
    , IndexName=i.name
    , IsUnique=i.is_unique
    , IgnoreDupKey=i.ignore_dup_key
    , ColumnName=c.name
FROM sys.tables t
JOIN sys.indexes i
  ON i.object_id=t.object_id
JOIN sys.index_columns ic
  ON ic.object_id=i.object_id
 AND ic.index_id=i.index_id
JOIN sys.columns c
  ON c.object_id=ic.object_id
 AND c.column_id=ic.column_id
WHERE t.object_id IN
(
    OBJECT_ID(N'dbo.RCA_ExecutionEvidence'),
    OBJECT_ID(N'dbo.RCA_StatementEvidence'),
    OBJECT_ID(N'dbo.RCA_PlanEvidence')
)
  AND i.is_unique=1
  AND c.name=N'XERawID'
ORDER BY t.name;


/*==============================================================================
  2. EXACT SOURCE-PATTERN CONTRACT

  These strings come from the current parser definition extracted immediately
  before this deployment. We require exactly one occurrence of each vulnerable
  source predicate before modifying anything.
==============================================================================*/
DECLARE @ExecutionOld nvarchar(max)=
N'FROM dbo.RCA_XERaw r     WHERE r.EventTimeUTC>=@StartUTC       AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)       AND r.EventName IN(N''rpc_completed'',N''sql_batch_completed'');';

DECLARE @ExecutionNew nvarchar(max)=
N'FROM dbo.RCA_XERaw r     WHERE r.EventTimeUTC>=@StartUTC       AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)       AND r.EventName IN(N''rpc_completed'',N''sql_batch_completed'')       AND NOT EXISTS       (           SELECT 1           FROM dbo.RCA_ExecutionEvidence AS existing           WHERE existing.XERawID=r.XERawID       );';

DECLARE @StatementOld nvarchar(max)=
N'FROM dbo.RCA_XERaw r     WHERE r.EventTimeUTC>=@StartUTC       AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)       AND r.EventName=N''sp_statement_completed'';';

DECLARE @StatementNew nvarchar(max)=
N'FROM dbo.RCA_XERaw r     WHERE r.EventTimeUTC>=@StartUTC       AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)       AND r.EventName=N''sp_statement_completed''       AND NOT EXISTS       (           SELECT 1           FROM dbo.RCA_StatementEvidence AS existing           WHERE existing.XERawID=r.XERawID       );';

DECLARE @PlanOld nvarchar(max)=
N'FROM dbo.RCA_XERaw r         WHERE r.EventTimeUTC>=@StartUTC           AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)           AND r.EventName=N''query_post_execution_showplan''     )';

DECLARE @PlanNew nvarchar(max)=
N'FROM dbo.RCA_XERaw r         WHERE r.EventTimeUTC>=@StartUTC           AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)           AND r.EventName=N''query_post_execution_showplan''           AND NOT EXISTS           (               SELECT 1               FROM dbo.RCA_PlanEvidence AS existing               WHERE existing.XERawID=r.XERawID           )     )';

DECLARE
      @ExecutionMatches int
    , @StatementMatches int
    , @PlanMatches int;

SELECT
    @ExecutionMatches =
      (LEN(@OriginalDefinition)-LEN(REPLACE(@OriginalDefinition,@ExecutionOld,N'')))
      / NULLIF(LEN(@ExecutionOld),0);

SELECT
    @StatementMatches =
      (LEN(@OriginalDefinition)-LEN(REPLACE(@OriginalDefinition,@StatementOld,N'')))
      / NULLIF(LEN(@StatementOld),0);

SELECT
    @PlanMatches =
      (LEN(@OriginalDefinition)-LEN(REPLACE(@OriginalDefinition,@PlanOld,N'')))
      / NULLIF(LEN(@PlanOld),0);

SELECT
      ValidationSection='2 - EXACT PARSER SOURCE CONTRACT'
    , ExecutionPredicateMatches=@ExecutionMatches
    , StatementPredicateMatches=@StatementMatches
    , PlanPredicateMatches=@PlanMatches
    , ExistingExecutionGuard=
        CASE WHEN @OriginalDefinition LIKE N'%FROM dbo.RCA_ExecutionEvidence AS existing%XERawID%'
             THEN 'YES' ELSE 'NO' END
    , ExistingStatementGuard=
        CASE WHEN @OriginalDefinition LIKE N'%FROM dbo.RCA_StatementEvidence AS existing%XERawID%'
             THEN 'YES' ELSE 'NO' END
    , ExistingPlanGuard=
        CASE WHEN @OriginalDefinition LIKE N'%FROM dbo.RCA_PlanEvidence AS existing%XERawID%'
             THEN 'YES' ELSE 'NO' END;

IF @ExecutionMatches<>1
    THROW 62920,N'ExecutionEvidence source predicate did not match exactly once. No deployment performed.',1;

IF @StatementMatches<>1
    THROW 62921,N'StatementEvidence source predicate did not match exactly once. No deployment performed.',1;

IF @PlanMatches<>1
    THROW 62922,N'PlanEvidence source predicate did not match exactly once. No deployment performed.',1;


/*==============================================================================
  3. ACTIVE WORK SAFETY CHECK
==============================================================================*/
DECLARE @ActiveRCAParserRequests int=0;

SELECT @ActiveRCAParserRequests=COUNT(*)
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s
  ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id<>@@SPID
  AND
  (
       t.text LIKE N'%usp_RCA_ParseCaptureRun%'
    OR t.text LIKE N'%usp_RCA_AnalyzeCaptureRun%'
  );

SELECT
      ValidationSection='3 - ACTIVE PARSER SAFETY'
    , ActiveOtherParserRequests=@ActiveRCAParserRequests
    , Result=
        CASE WHEN @ActiveRCAParserRequests=0
             THEN 'PASS'
             ELSE 'FAIL - ANOTHER PARSER/ANALYZER REQUEST IS ACTIVE'
        END;

IF @ActiveRCAParserRequests<>0
    THROW 62930,N'Another RCA parser/analyzer request is active. Deployment aborted.',1;


/*==============================================================================
  4. BUILD PATCHED DEFINITION
==============================================================================*/
SET @PatchedDefinition=@OriginalDefinition;

SET @PatchedDefinition=REPLACE(@PatchedDefinition,@ExecutionOld,@ExecutionNew);
SET @PatchedDefinition=REPLACE(@PatchedDefinition,@StatementOld,@StatementNew);
SET @PatchedDefinition=REPLACE(@PatchedDefinition,@PlanOld,@PlanNew);

/*
    Convert the stored CREATE declaration to ALTER.
    Current definition is proven to contain:
        CREATE    PROCEDURE dbo.usp_RCA_ParseCaptureRun
*/
DECLARE @CreateToken nvarchar(200)=
    N'CREATE    PROCEDURE dbo.usp_RCA_ParseCaptureRun';

DECLARE @AlterToken nvarchar(200)=
    N'ALTER     PROCEDURE dbo.usp_RCA_ParseCaptureRun';

IF CHARINDEX(@CreateToken,@PatchedDefinition)=0
    THROW 62940,N'Expected CREATE PROCEDURE declaration not found. No deployment performed.',1;

SET @PatchedDefinition=
    STUFF
    (
        @PatchedDefinition,
        CHARINDEX(@CreateToken,@PatchedDefinition),
        LEN(@CreateToken),
        @AlterToken
    );


/*==============================================================================
  5. TRANSACTIONAL DEPLOYMENT + CAPTURE 20 REPARSE
==============================================================================*/
BEGIN TRY
    BEGIN TRANSACTION;

    EXEC sys.sp_executesql @PatchedDefinition;

    DECLARE @InstalledDefinition nvarchar(max);

    SELECT
          @InstalledDefinition=sm.definition
        , @AfterParserHash=
            HASHBYTES('SHA2_256',CONVERT(varbinary(max),sm.definition))
    FROM sys.sql_modules sm
    WHERE sm.object_id=OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun');

    SELECT
          ValidationSection='4 - PARSER PATCH INSTALLED'
        , ParserChanged=
            CASE WHEN @AfterParserHash<>@BeforeParserHash
                 THEN 'PASS' ELSE 'FAIL' END
        , ExecutionCollisionGuard=
            CASE WHEN @InstalledDefinition LIKE
                 N'%FROM dbo.RCA_ExecutionEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
                 THEN 'PASS' ELSE 'FAIL' END
        , StatementCollisionGuard=
            CASE WHEN @InstalledDefinition LIKE
                 N'%FROM dbo.RCA_StatementEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
                 THEN 'PASS' ELSE 'FAIL' END
        , PlanCollisionGuard=
            CASE WHEN @InstalledDefinition LIKE
                 N'%FROM dbo.RCA_PlanEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
                 THEN 'PASS' ELSE 'FAIL' END;

    IF @AfterParserHash=@BeforeParserHash
        THROW 62950,N'Parser definition did not change.',1;

    IF @InstalledDefinition NOT LIKE
       N'%FROM dbo.RCA_ExecutionEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
        THROW 62951,N'ExecutionEvidence collision guard verification failed.',1;

    IF @InstalledDefinition NOT LIKE
       N'%FROM dbo.RCA_StatementEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
        THROW 62952,N'StatementEvidence collision guard verification failed.',1;

    IF @InstalledDefinition NOT LIKE
       N'%FROM dbo.RCA_PlanEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
        THROW 62953,N'PlanEvidence collision guard verification failed.',1;


    /*-------------------------------------------------------------------------
      Deliberate reproduction test:
      This is the same Capture 20 reparse that previously collided with
      globally-owned XERawID 8135.
    -------------------------------------------------------------------------*/
    SELECT
          ValidationSection='5 - CAPTURE 20 REPARSE TEST'
        , CaptureRunID=@TargetCaptureRunID
        , Action='EXEC dbo.usp_RCA_ParseCaptureRun @CaptureRunID=20'
        , Expected='COMPLETES WITHOUT UNIQUE XERawID VIOLATION';

    EXEC dbo.usp_RCA_ParseCaptureRun
         @CaptureRunID=@TargetCaptureRunID;


    /*-------------------------------------------------------------------------
      HARD ASSERTION 1:
      8135 must still belong to Capture 38.
    -------------------------------------------------------------------------*/
    DECLARE
          @After8135Owner bigint
        , @After8135EvidenceID bigint
        , @After8135Rows bigint;

    SELECT
          @After8135Rows=COUNT_BIG(*)
        , @After8135Owner=MAX(CaptureRunID)
        , @After8135EvidenceID=MAX(ExecutionEvidenceID)
    FROM dbo.RCA_ExecutionEvidence
    WHERE XERawID=@DuplicateXERawID;

    SELECT
          ValidationSection='6 - XERAWID 8135 OWNERSHIP AFTER REPARSE'
        , XERawID=@DuplicateXERawID
        , TotalRows=@After8135Rows
        , CaptureRunID=@After8135Owner
        , ExecutionEvidenceID=@After8135EvidenceID
        , Result=
            CASE WHEN @After8135Rows=1
                       AND @After8135Owner=38
                       AND @After8135EvidenceID=@Before8135ExecutionEvidenceID
                 THEN 'PASS - ORIGINAL OWNER PRESERVED'
                 ELSE 'FAIL'
            END;

    IF @After8135Rows<>1
       OR @After8135Owner<>38
       OR @After8135EvidenceID<>@Before8135ExecutionEvidenceID
        THROW 62960,N'XERawID 8135 ownership changed during Capture 20 reparse.',1;


    /*-------------------------------------------------------------------------
      HARD ASSERTION 2:
      No persisted XERawID duplicates may exist.
    -------------------------------------------------------------------------*/
    DECLARE
          @ExecutionDuplicateGroups bigint
        , @StatementDuplicateGroups bigint
        , @PlanDuplicateGroups bigint;

    SELECT @ExecutionDuplicateGroups=COUNT_BIG(*)
    FROM
    (
        SELECT XERawID
        FROM dbo.RCA_ExecutionEvidence
        WHERE XERawID IS NOT NULL
        GROUP BY XERawID
        HAVING COUNT_BIG(*)>1
    ) d;

    SELECT @StatementDuplicateGroups=COUNT_BIG(*)
    FROM
    (
        SELECT XERawID
        FROM dbo.RCA_StatementEvidence
        WHERE XERawID IS NOT NULL
        GROUP BY XERawID
        HAVING COUNT_BIG(*)>1
    ) d;

    SELECT @PlanDuplicateGroups=COUNT_BIG(*)
    FROM
    (
        SELECT XERawID
        FROM dbo.RCA_PlanEvidence
        WHERE XERawID IS NOT NULL
        GROUP BY XERawID
        HAVING COUNT_BIG(*)>1
    ) d;

    SELECT
          ValidationSection='7 - GLOBAL XERAWID DUPLICATE CHECK'
        , ExecutionDuplicateGroups=@ExecutionDuplicateGroups
        , StatementDuplicateGroups=@StatementDuplicateGroups
        , PlanDuplicateGroups=@PlanDuplicateGroups
        , Result=
            CASE WHEN @ExecutionDuplicateGroups=0
                       AND @StatementDuplicateGroups=0
                       AND @PlanDuplicateGroups=0
                 THEN 'PASS'
                 ELSE 'FAIL'
            END;

    IF @ExecutionDuplicateGroups<>0
       OR @StatementDuplicateGroups<>0
       OR @PlanDuplicateGroups<>0
        THROW 62961,N'Duplicate persisted XERawID groups detected after parser repair.',1;


    /*-------------------------------------------------------------------------
      HARD ASSERTION 3:
      Capture 20 must now be ANALYZED and retain its closed EndTimeUTC.
    -------------------------------------------------------------------------*/
    DECLARE
          @Capture20StatusAfter nvarchar(60)
        , @Capture20EndAfter datetime2(3);

    SELECT
          @Capture20StatusAfter=CaptureStatus
        , @Capture20EndAfter=EndTimeUTC
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=20;

    SELECT
          ValidationSection='8 - CAPTURE 20 POST-REPARSE LIFECYCLE'
        , CaptureRunID=20
        , CaptureStatus=@Capture20StatusAfter
        , EndTimeUTC=@Capture20EndAfter
        , EndTimePreserved=
            CASE WHEN @Capture20EndAfter=@BeforeCapture20EndTimeUTC
                 THEN 'PASS' ELSE 'FAIL' END
        , Result=
            CASE WHEN @Capture20StatusAfter=N'ANALYZED'
                       AND @Capture20EndAfter=@BeforeCapture20EndTimeUTC
                 THEN 'PASS - CAPTURE 20 ANALYZED WITH ORIGINAL END TIME'
                 ELSE 'FAIL'
            END;

    IF @Capture20StatusAfter<>N'ANALYZED'
       OR @Capture20EndAfter<>@BeforeCapture20EndTimeUTC
        THROW 62962,N'Capture 20 lifecycle state is not valid after reparse.',1;


    /*-------------------------------------------------------------------------
      HARD ASSERTION 4:
      Established normalized control outcomes remain unchanged.
    -------------------------------------------------------------------------*/
    DECLARE
          @Cause20 varchar(60)
        , @Role20 varchar(30)
        , @Confidence20 varchar(30)
        , @Exec20 bigint
        , @Session20 int
        , @Primary38 int
        , @Cause42 varchar(60)
        , @Role42 varchar(30)
        , @Confidence42 varchar(30)
        , @Cause44 varchar(60)
        , @Role44 varchar(30)
        , @Confidence44 varchar(30);

    SELECT
          @Cause20=PrimaryCauseCategory
        , @Role20=PrimaryCauseRole
        , @Confidence20=PrimaryConfidence
        , @Exec20=PrimaryExecutionEvidenceID
        , @Session20=PrimarySessionID
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=20;

    SELECT
          @Primary38=ISNULL(PrimaryCauseCount,0)
    FROM dbo.vw_RCA_CrossDomainCauseSummary
    WHERE CaptureRunID=38;

    SET @Primary38=ISNULL(@Primary38,0);

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
          ValidationSection='9 - FOUR CONTROL REGRESSION'
        , Capture20IO=
            CASE WHEN @Cause20='IO_STORAGE_LATENCY'
                       AND @Role20='PRIMARY'
                       AND @Confidence20='MEDIUM'
                 THEN 'PASS' ELSE 'FAIL' END
        , Capture20NoFabricatedSession=
            CASE WHEN @Exec20 IS NULL AND @Session20 IS NULL
                 THEN 'PASS' ELSE 'FAIL' END
        , Capture38Uncertainty=
            CASE WHEN @Primary38=0
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
                 THEN 'PASS' ELSE 'FAIL' END;

    IF NOT
    (
           @Cause20='IO_STORAGE_LATENCY'
       AND @Role20='PRIMARY'
       AND @Confidence20='MEDIUM'
       AND @Exec20 IS NULL
       AND @Session20 IS NULL
       AND @Primary38=0
       AND @Cause42='BLOCKING_WAIT_CHAIN'
       AND @Role42='PRIMARY'
       AND @Confidence42='HIGH'
       AND @Cause44='CPU_SCHEDULER'
       AND @Role44='PRIMARY'
       AND @Confidence44='HIGH'
    )
        THROW 62963,N'One or more established RCA control outcomes regressed.',1;


    COMMIT TRANSACTION;

    SELECT
          ValidationSection='10 - SCRIPT 79 DEPLOYMENT COMMIT'
        , TransactionResult='COMMITTED'
        , ParserPatch='DEPLOYED'
        , Capture20Reparse='PASS'
        , Duplicate8135Collision='RESOLVED'
        , XERaw8135Owner='CAPTURE 38 PRESERVED'
        , Capture20Lifecycle='ANALYZED'
        , FourControlRegression='PASS'
        , OverallResult=
            'PASS - XERAWID PARSER IDEMPOTENCY FIX DEPLOYED AND REGRESSION VALIDATED';

END TRY
BEGIN CATCH

    IF XACT_STATE()<>0
        ROLLBACK TRANSACTION;

    SELECT
          ValidationSection='10A - SCRIPT 79 ROLLBACK'
        , TransactionResult='ROLLED BACK'
        , ParserRestoredByTransaction='YES'
        , Capture20DerivedChangesRolledBack='YES'
        , ErrorNumber=ERROR_NUMBER()
        , ErrorSeverity=ERROR_SEVERITY()
        , ErrorState=ERROR_STATE()
        , ErrorProcedure=ERROR_PROCEDURE()
        , ErrorLine=ERROR_LINE()
        , ErrorMessage=ERROR_MESSAGE();

    THROW;
END CATCH;


/*==============================================================================
  11. POST-COMMIT CANONICAL ANSWERS
==============================================================================*/
SELECT
      ValidationSection='11 - CAPTURE 20 CANONICAL ANSWER'
    , Expected='ROOT CAUSE IDENTIFIED - IO / STORAGE LATENCY - MEDIUM';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=20;

SELECT
      ValidationSection='11A - CAPTURE 38 CANONICAL ANSWER'
    , Expected='ROOT CAUSE NOT CONFIRMED';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;

SELECT
      ValidationSection='11B - CAPTURE 42 CANONICAL ANSWER'
    , Expected='ROOT CAUSE IDENTIFIED - BLOCKING / WAIT-CHAIN - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;

SELECT
      ValidationSection='11C - CAPTURE 44 CANONICAL ANSWER'
    , Expected='ROOT CAUSE IDENTIFIED - CPU / SCHEDULER - HIGH';

EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;


/*==============================================================================
  12. POST-COMMIT PARSER FINGERPRINT
==============================================================================*/
SELECT
      ValidationSection='12 - PARSER FINGERPRINT'
    , ProcedureName=N'dbo.usp_RCA_ParseCaptureRun'
    , ModifyDate=p.modify_date
    , DefinitionLength=LEN(sm.definition)
    , DefinitionSHA256=
        CONVERT(varchar(64),
                HASHBYTES('SHA2_256',CONVERT(varbinary(max),sm.definition)),
                2)
    , ExecutionGuard=
        CASE WHEN sm.definition LIKE
             N'%FROM dbo.RCA_ExecutionEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
             THEN 'PASS' ELSE 'FAIL' END
    , StatementGuard=
        CASE WHEN sm.definition LIKE
             N'%FROM dbo.RCA_StatementEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
             THEN 'PASS' ELSE 'FAIL' END
    , PlanGuard=
        CASE WHEN sm.definition LIKE
             N'%FROM dbo.RCA_PlanEvidence AS existing%WHERE existing.XERawID=r.XERawID%'
             THEN 'PASS' ELSE 'FAIL' END
FROM sys.procedures p
JOIN sys.sql_modules sm
  ON sm.object_id=p.object_id
WHERE p.object_id=OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun');


/*==============================================================================
  13. FINAL SAFETY
==============================================================================*/
SELECT
      ValidationSection='13 - SCRIPT 79 FINAL SAFETY'
    , ParserModified='YES - IDEMPOTENCY ONLY'
    , Capture20Reparsed='YES'
    , Capture20EndTimeManuallyChanged='NO'
    , Capture38EvidenceModified='NO'
    , UniqueIndexesModified='NO'
    , RCA_XERawModified='NO'
    , SQLAgentJobsModified='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalRouterChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
