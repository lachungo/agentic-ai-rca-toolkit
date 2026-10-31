USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  49_RCA_Blocker_Transaction_Attribution_Discovery_v1.sql

  PURPOSE
  -------
  Determine whether the EXISTING RCA evidence can explain not only:

      "Session 69 was the head blocker"

  but also:

      "Why was session 69 holding the lock for ~35 seconds?"

  Capture 39 already proves:
      - victim session = 74
      - head blocker = 69
      - wait type = LCK_M_X
      - max observed wait = 35426 ms
      - sample count = 8
      - blocker batch = EXEC dbo.usp_RCA_Capture39_Blocker
      - sampler-observed blocker statement = WAITFOR DELAY '00:00:45'

  THIS SCRIPT IS READ ONLY.

  It does NOT:
      - modify RCA evidence
      - rebuild findings
      - change thresholds
      - alter capture
      - insert transaction attribution
      - start a new capture

  QUESTIONS TO ANSWER
  -------------------
  1. Do we already persist open transaction count for the head blocker?
  2. Do we persist transaction begin time / age?
  3. Do we persist transaction IDs?
  4. Do we persist lock ownership details?
  5. Do we persist blocker statement separately from blocker batch?
  6. Can we correlate session 69 to a transaction snapshot/evidence table?
  7. If not, what exact transaction evidence is missing?

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max)=N'';
DECLARE @Message nvarchar(2048);

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockingEvidence;';

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ExecutionEvidence;';

IF OBJECT_ID(N'dbo.vw_RCA_HeadBlockerAttribution',N'V') IS NULL
    SET @Missing += N' dbo.vw_RCA_HeadBlockerAttribution;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message=CONCAT(N'Script 49 prerequisites are missing:',@Missing);
    THROW 54900,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 49 PRE-FLIGHT'
    , BlockingEvidence='PASS'
    , ExecutionEvidence='PASS'
    , HeadBlockerAttribution='PASS'
    , ReadOnlyDiscovery='YES'
    , SourceEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  1. GOLDEN CAPTURE 39 BLOCKER ATTRIBUTION
==============================================================================*/
SELECT
      DiscoverySection='1 - CAPTURE 39 HEAD BLOCKER'
    , CaptureRunID
    , BlockingEvidenceID
    , VictimSessionID
    , VictimExecutionEvidenceID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , WaitType
    , WaitDurationMs
    , BlockingDepth
    , SampleCount
    , FirstObservedUTC
    , LastObservedUTC
    , HeadBlockerHostName
    , HeadBlockerProgramName
    , HeadBlockerLoginName
    , HeadBlockerStatement
    , HeadBlockerOpenTransactionCount
    , HeadBlockerExecutionEvidenceID
    , HeadBlockerExecutionEventUTC
    , HeadBlockerSubmittedCommand
    , HeadBlockerDurationMs
    , BlockerExecutionCorrelation
    , AttributionStrength
FROM dbo.vw_RCA_HeadBlockerAttribution
WHERE CaptureRunID=39
ORDER BY BlockingEvidenceID;
GO


/*==============================================================================
  2. RCA TABLES WITH TRANSACTION / LOCK / BLOCKER COLUMNS
==============================================================================*/
SELECT
      DiscoverySection='2 - POSSIBLE TRANSACTION EVIDENCE SOURCES'
    , SchemaName=s.name
    , TableName=t.name
    , ColumnID=c.column_id
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
    , MaxLength=c.max_length
    , IsNullable=c.is_nullable
FROM sys.tables t
JOIN sys.schemas s
  ON s.schema_id=t.schema_id
JOIN sys.columns c
  ON c.object_id=t.object_id
WHERE t.name LIKE 'RCA[_]%'
  AND
  (
         c.name LIKE '%Tran%'
      OR c.name LIKE '%Transaction%'
      OR c.name LIKE '%Open%'
      OR c.name LIKE '%Lock%'
      OR c.name LIKE '%Block%'
      OR c.name LIKE '%Session%'
      OR c.name LIKE '%Wait%'
      OR c.name LIKE '%Begin%'
      OR c.name LIKE '%Start%'
      OR c.name LIKE '%Age%'
  )
ORDER BY t.name,c.column_id;
GO


/*==============================================================================
  3. FULL RCA TABLE INVENTORY
==============================================================================*/
SELECT
      DiscoverySection='3 - RCA TABLE INVENTORY'
    , SchemaName=s.name
    , TableName=t.name
    , CreateDate=t.create_date
    , ModifyDate=t.modify_date
FROM sys.tables t
JOIN sys.schemas s
  ON s.schema_id=t.schema_id
WHERE t.name LIKE 'RCA[_]%'
ORDER BY t.name;
GO


/*==============================================================================
  4. BLOCKING EVIDENCE COMPLETE ROW

  We know this table already contains blocker-side identity and statement.
  This confirms whether transaction-specific fields have values in Capture 39.
==============================================================================*/
SELECT
      DiscoverySection='4 - COMPLETE BLOCKING EVIDENCE'
    , *
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=39
ORDER BY BlockingEvidenceID;
GO


/*==============================================================================
  5. EXECUTION TIMELINE FOR HEAD BLOCKER SESSION 69
==============================================================================*/
SELECT
      DiscoverySection='5 - HEAD BLOCKER EXECUTION TIMELINE'
    , ExecutionEvidenceID
    , EventName
    , EventTimeUTC
    , DatabaseName
    , SessionID
    , ObjectName
    , SubmittedCommand
    , ParameterText
    , ParameterEvidenceStatus
    , HostName
    , ProgramName
    , LoginName
    , CPUms
    , DurationMs
    , LogicalReads
    , PhysicalReads
    , Writes
    , TotalRows
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=39
  AND SessionID=69
ORDER BY EventTimeUTC,ExecutionEvidenceID;
GO


/*==============================================================================
  6. STATEMENT EVIDENCE FOR SESSION 69
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_StatementEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='6A - STATEMENT EVIDENCE SCHEMA'
        , ColumnID=c.column_id
        , ColumnName=c.name
        , DataType=TYPE_NAME(c.user_type_id)
        , MaxLength=c.max_length
    FROM sys.columns c
    WHERE c.object_id=OBJECT_ID(N'dbo.RCA_StatementEvidence')
    ORDER BY c.column_id;

    IF EXISTS
    (
        SELECT 1
        FROM sys.columns
        WHERE object_id=OBJECT_ID(N'dbo.RCA_StatementEvidence')
          AND name='CaptureRunID'
    )
    AND EXISTS
    (
        SELECT 1
        FROM sys.columns
        WHERE object_id=OBJECT_ID(N'dbo.RCA_StatementEvidence')
          AND name='SessionID'
    )
    BEGIN
        SELECT
              DiscoverySection='6B - HEAD BLOCKER STATEMENT EVIDENCE'
            , *
        FROM dbo.RCA_StatementEvidence
        WHERE CaptureRunID=39
          AND SessionID=69
        ORDER BY EventTimeUTC;
    END;
END
ELSE
BEGIN
    SELECT
          DiscoverySection='6 - STATEMENT EVIDENCE'
        , Result='RCA_StatementEvidence does not exist';
END;
GO


/*==============================================================================
  7. PROCEDURES THAT CAPTURE BLOCKING / TRANSACTION STATE

  This is critical. We need to know whether transaction fields were already
  intended to be captured but were NULL because of timing, or whether no
  transaction capture exists at all.
==============================================================================*/
SELECT
      DiscoverySection='7 - PROCEDURES REFERENCING TRANSACTION OR BLOCKING STATE'
    , SchemaName=OBJECT_SCHEMA_NAME(o.object_id)
    , ProcedureName=o.name
    , ProcedureDefinition=m.definition
FROM sys.objects o
JOIN sys.sql_modules m
  ON m.object_id=o.object_id
WHERE o.type='P'
  AND
  (
         m.definition LIKE '%RCA_BlockingEvidence%'
      OR m.definition LIKE '%open_transaction_count%'
      OR m.definition LIKE '%dm_tran_session_transactions%'
      OR m.definition LIKE '%dm_tran_active_transactions%'
      OR m.definition LIKE '%dm_tran_locks%'
      OR m.definition LIKE '%transaction_begin_time%'
      OR m.definition LIKE '%transaction_id%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  8. VIEWS REFERENCING TRANSACTION OR BLOCKING STATE
==============================================================================*/
SELECT
      DiscoverySection='8 - VIEWS REFERENCING TRANSACTION OR BLOCKING STATE'
    , SchemaName=OBJECT_SCHEMA_NAME(o.object_id)
    , ViewName=o.name
    , ViewDefinition=m.definition
FROM sys.objects o
JOIN sys.sql_modules m
  ON m.object_id=o.object_id
WHERE o.type='V'
  AND
  (
         m.definition LIKE '%RCA_BlockingEvidence%'
      OR m.definition LIKE '%open_transaction_count%'
      OR m.definition LIKE '%transaction%'
      OR m.definition LIKE '%lock%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  9. SEARCH ALL RCA TABLE COLUMNS FOR KNOWN TRANSACTION SEMANTICS
==============================================================================*/
SELECT
      DiscoverySection='9 - TRANSACTION SEMANTIC COLUMN SEARCH'
    , SchemaName=OBJECT_SCHEMA_NAME(c.object_id)
    , ObjectName=OBJECT_NAME(c.object_id)
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
FROM sys.columns c
WHERE OBJECT_NAME(c.object_id) LIKE 'RCA[_]%'
  AND
  (
         c.name IN
         (
             'TransactionID',
             'TransactionId',
             'transaction_id',
             'TransactionBeginTime',
             'TransactionStartTime',
             'OpenTransactionCount',
             'HeadBlockerOpenTransactionCount'
         )
      OR c.name LIKE '%Transaction%'
      OR c.name LIKE '%TranCount%'
      OR c.name LIKE '%OpenTran%'
      OR c.name LIKE '%LockOwner%'
      OR c.name LIKE '%Resource%'
  )
ORDER BY ObjectName,c.column_id;
GO


/*==============================================================================
  10. DYNAMIC CAPTURE-39 ROW CHECK FOR ALL RCA TABLES WITH CaptureRunID + SessionID

  This discovers whether session 69 exists in another persisted evidence table.
==============================================================================*/
DECLARE
      @sql nvarchar(max)=N''
    , @CRLF nchar(2)=NCHAR(13)+NCHAR(10);

SELECT @sql = @sql +
N'
IF EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(s.name)+N'.'+QUOTENAME(t.name) + N'
    WHERE CaptureRunID=39
      AND SessionID=69
)
BEGIN
    SELECT
          DiscoverySection=''10 - SESSION 69 FOUND IN RCA TABLE''
        , SourceTable=''' + REPLACE(QUOTENAME(s.name)+N'.'+QUOTENAME(t.name),'''','''''') + N'''
        , *
    FROM ' + QUOTENAME(s.name)+N'.'+QUOTENAME(t.name) + N'
    WHERE CaptureRunID=39
      AND SessionID=69;
END;
'
FROM sys.tables t
JOIN sys.schemas s
  ON s.schema_id=t.schema_id
WHERE t.name LIKE 'RCA[_]%'
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns c
      WHERE c.object_id=t.object_id
        AND c.name='CaptureRunID'
  )
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns c
      WHERE c.object_id=t.object_id
        AND c.name='SessionID'
  );

IF NULLIF(@sql,N'') IS NULL
BEGIN
    SELECT
          DiscoverySection='10 - SESSION 69 RCA TABLE SEARCH'
        , Result='No RCA table exposes both CaptureRunID and SessionID.';
END
ELSE
BEGIN
    EXEC sys.sp_executesql @sql;
END;
GO


/*==============================================================================
  11. DYNAMIC CAPTURE-39 ROW CHECK FOR TABLES WITH HeadBlockerSessionID
==============================================================================*/
DECLARE @sql nvarchar(max)=N'';

SELECT @sql = @sql +
N'
SELECT
      DiscoverySection=''11 - HEAD BLOCKER TABLE ROW''
    , SourceTable=''' + REPLACE(QUOTENAME(s.name)+N'.'+QUOTENAME(t.name),'''','''''') + N'''
    , *
FROM ' + QUOTENAME(s.name)+N'.'+QUOTENAME(t.name) + N'
WHERE HeadBlockerSessionID=69'
+
CASE
    WHEN EXISTS
    (
        SELECT 1
        FROM sys.columns c
        WHERE c.object_id=t.object_id
          AND c.name='CaptureRunID'
    )
    THEN N' AND CaptureRunID=39'
    ELSE N''
END
+N';
'
FROM sys.tables t
JOIN sys.schemas s
  ON s.schema_id=t.schema_id
WHERE t.name LIKE 'RCA[_]%'
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns c
      WHERE c.object_id=t.object_id
        AND c.name='HeadBlockerSessionID'
  );

IF NULLIF(@sql,N'') IS NULL
BEGIN
    SELECT
          DiscoverySection='11 - HEAD BLOCKER TABLE SEARCH'
        , Result='No RCA table exposes HeadBlockerSessionID.';
END
ELSE
BEGIN
    EXEC sys.sp_executesql @sql;
END;
GO


/*==============================================================================
  12. TRANSACTION ATTRIBUTION CAPABILITY MATRIX
==============================================================================*/
DECLARE
      @HasHeadBlockerOpenTranColumn bit=0
    , @HeadBlockerOpenTranPopulated bit=0
    , @HasTransactionIdColumn bit=0
    , @HasTransactionBeginColumn bit=0
    , @HasLockResourceColumn bit=0
    , @HasBlockerStatement bit=0
    , @HasBlockerBatch bit=0
    , @HasBlockerIdentity bit=0;

SET @HasHeadBlockerOpenTranColumn =
    CASE WHEN COL_LENGTH('dbo.RCA_BlockingEvidence','HeadBlockerOpenTransactionCount') IS NOT NULL
         THEN 1 ELSE 0 END;

IF @HasHeadBlockerOpenTranColumn=1
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID=39
          AND HeadBlockerSessionID=69
          AND HeadBlockerOpenTransactionCount IS NOT NULL
    )
        SET @HeadBlockerOpenTranPopulated=1;
END;

IF EXISTS
(
    SELECT 1
    FROM sys.columns c
    JOIN sys.tables t
      ON t.object_id=c.object_id
    WHERE t.name LIKE 'RCA[_]%'
      AND
      (
             c.name LIKE '%TransactionID%'
          OR c.name='transaction_id'
      )
)
    SET @HasTransactionIdColumn=1;

IF EXISTS
(
    SELECT 1
    FROM sys.columns c
    JOIN sys.tables t
      ON t.object_id=c.object_id
    WHERE t.name LIKE 'RCA[_]%'
      AND
      (
             c.name LIKE '%TransactionBegin%'
          OR c.name LIKE '%TransactionStart%'
          OR c.name LIKE '%BeginTran%'
      )
)
    SET @HasTransactionBeginColumn=1;

IF EXISTS
(
    SELECT 1
    FROM sys.columns c
    JOIN sys.tables t
      ON t.object_id=c.object_id
    WHERE t.name LIKE 'RCA[_]%'
      AND
      (
             c.name LIKE '%ResourceDescription%'
          OR c.name LIKE '%ResourceType%'
          OR c.name LIKE '%LockResource%'
          OR c.name LIKE '%ResourceDatabase%'
      )
)
    SET @HasLockResourceColumn=1;

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=39
      AND HeadBlockerSessionID=69
      AND NULLIF(LTRIM(RTRIM(HeadBlockerStatement)),N'') IS NOT NULL
)
    SET @HasBlockerStatement=1;

IF EXISTS
(
    SELECT 1
    FROM dbo.vw_RCA_HeadBlockerAttribution
    WHERE CaptureRunID=39
      AND HeadBlockerSessionID=69
      AND NULLIF(LTRIM(RTRIM(HeadBlockerSubmittedCommand)),N'') IS NOT NULL
)
    SET @HasBlockerBatch=1;

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=39
      AND HeadBlockerSessionID=69
      AND HeadBlockerHostName IS NOT NULL
      AND HeadBlockerProgramName IS NOT NULL
      AND HeadBlockerLoginName IS NOT NULL
)
    SET @HasBlockerIdentity=1;

SELECT
      DiscoverySection='12 - TRANSACTION ATTRIBUTION CAPABILITY MATRIX'

    , BlockerIdentity =
        CASE WHEN @HasBlockerIdentity=1 THEN 'AVAILABLE' ELSE 'MISSING' END

    , BlockerBatch =
        CASE WHEN @HasBlockerBatch=1 THEN 'AVAILABLE' ELSE 'MISSING' END

    , BlockerCurrentStatement =
        CASE WHEN @HasBlockerStatement=1 THEN 'AVAILABLE' ELSE 'MISSING' END

    , OpenTransactionCountColumn =
        CASE WHEN @HasHeadBlockerOpenTranColumn=1 THEN 'AVAILABLE' ELSE 'MISSING' END

    , OpenTransactionCountCapture39 =
        CASE WHEN @HeadBlockerOpenTranPopulated=1 THEN 'POPULATED'
             WHEN @HasHeadBlockerOpenTranColumn=1 THEN 'NULL / NOT CAPTURED'
             ELSE 'NO COLUMN'
        END

    , TransactionID =
        CASE WHEN @HasTransactionIdColumn=1 THEN 'PERSISTED SOMEWHERE'
             ELSE 'NOT FOUND'
        END

    , TransactionBeginTime =
        CASE WHEN @HasTransactionBeginColumn=1 THEN 'PERSISTED SOMEWHERE'
             ELSE 'NOT FOUND'
        END

    , LockResourceDetails =
        CASE WHEN @HasLockResourceColumn=1 THEN 'PERSISTED SOMEWHERE'
             ELSE 'NOT FOUND'
        END

    , Interpretation =
        CASE
          WHEN @HasBlockerIdentity=1
           AND @HasBlockerBatch=1
           AND @HasBlockerStatement=1
           AND @HeadBlockerOpenTranPopulated=1
           AND @HasTransactionIdColumn=1
           AND @HasTransactionBeginColumn=1
          THEN 'TRANSACTION ATTRIBUTION APPEARS COMPLETE'

          WHEN @HasBlockerIdentity=1
           AND @HasBlockerBatch=1
           AND @HasBlockerStatement=1
          THEN 'BLOCKER ATTRIBUTION IS STRONG; TRANSACTION-LIFETIME DETAIL REQUIRES REVIEW'

          ELSE 'BLOCKER OR TRANSACTION ATTRIBUTION HAS A MATERIAL EVIDENCE GAP'
        END;
GO


/*==============================================================================
  13. SCRIPT 49 SAFETY
==============================================================================*/
SELECT
      ValidationSection='13 - SCRIPT 49 DISCOVERY SAFETY'
    , CaptureRunID=39
    , HeadBlockerSessionID=69
    , ExistingCaptureReused='YES'
    , ReadOnlyDiscovery='YES'
    , SourceXEEvidenceChanged='NO'
    , ExistingEvidenceModified='NO'
    , BlockingEvidenceModified='NO'
    , ExecutionEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        'Use Sections 7, 9, 10, 11, and 12 to decide whether existing evidence can explain transaction lifetime/lock ownership. Do not change capture until the exact missing evidence is proven.';
GO
