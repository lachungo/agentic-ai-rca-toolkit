USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  63_RCA_CPU_Canonical_Answer_Gap_Discovery_v2.sql

  PURPOSE
  -------

  V2 REPAIR
  ---------
  This complete revision removes both dynamic-SQL defects found while running v1:
      1. concatenation directly inside EXEC sys.sp_executesql
      2. STRING_AGG exceeding the 8,000-byte aggregation limit

  Section 5 now uses cursor-driven read-only inventory collection instead of
  building one large UNION ALL statement.

  Read-only discovery of why Capture 44 has persisted PRIMARY/HIGH CPU scheduler
  evidence while the canonical DBA answer still returns:

      ROOT CAUSE NOT CONFIRMED

  A/B CONTROL
  -----------
  Capture 42:
      blocking evidence -> PRIMARY/HIGH -> DBA answer identifies blocking

  Capture 44:
      CPU scheduler evidence -> PRIMARY/HIGH -> DBA answer does not identify CPU

  GOAL
  ----
  Trace the data path from persisted CPU evidence through ranking/presentation
  objects and identify the exact layer where CPU attribution disappears.

  THIS SCRIPT DOES NOT:
      - alter any procedure
      - alter any view
      - rebuild findings
      - change thresholds
      - change root-cause domains
      - change ranking logic
      - modify historical evidence
      - start a capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 63 PRE-FLIGHT'
    , Capture42Exists=
        CASE WHEN EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=42)
             THEN 'PASS' ELSE 'FAIL' END
    , Capture44Exists=
        CASE WHEN EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=44)
             THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CPUSchedulerView=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CPUSchedulerEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'REVIEW' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyDiscovery='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  1. CAPTURE 42 / 44 CONTEXT
==============================================================================*/
SELECT
      DiscoverySection='1 - CAPTURE CONTEXT'
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID IN (42,44)
ORDER BY CaptureRunID;
GO


/*==============================================================================
  2. BLOCKING POSITIVE CONTROL - CAPTURE 42
==============================================================================*/
SELECT
      DiscoverySection='2 - CAPTURE 42 BLOCKING EVIDENCE'
    , *
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=42
ORDER BY BlockingEvidenceID;
GO


/*==============================================================================
  3. CPU POSITIVE EVIDENCE - CAPTURE 44
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='3 - CAPTURE 44 CPU SCHEDULER EVIDENCE'
        , *
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=44;
END;
GO


IF OBJECT_ID(N'dbo.vw_RCA_CPUSchedulerEvidence',N'V') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='3A - CAPTURE 44 CPU SCHEDULER VIEW'
        , *
    FROM dbo.vw_RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=44;
END;
GO


/*==============================================================================
  4. OBJECT INVENTORY - ROOT CAUSE / RANKING / PRESENTATION
==============================================================================*/
SELECT
      DiscoverySection='4 - RCA OBJECT INVENTORY'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ObjectName=o.name
    , ObjectType=o.type_desc
    , CreateDate=o.create_date
    , ModifyDate=o.modify_date
FROM sys.objects AS o
WHERE
       o.name LIKE N'%Cause%'
    OR o.name LIKE N'%Rank%'
    OR o.name LIKE N'%CPU%'
    OR o.name LIKE N'%Scheduler%'
    OR o.name LIKE N'%DBAAnswer%'
    OR o.name LIKE N'%WhyIsDatabaseSlow%'
    OR o.name LIKE N'%ExplainDatabaseSlowness%'
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  5. CANDIDATE TABLE/VIEWS WITH CAPTURE 42/44 DATA

  IMPLEMENTATION NOTE
  -------------------
  v2 intentionally avoids STRING_AGG entirely. The v1 discovery script hit the
  SQL Server 8,000-byte STRING_AGG return-size limit while constructing a large
  UNION ALL statement. This version inventories candidate objects one at a time
  with a LOCAL FAST_FORWARD cursor and inserts only counts into a temp table.

  This remains read-only against RCA evidence.
==============================================================================*/
IF OBJECT_ID(N'tempdb..#CaptureDataInventory',N'U') IS NOT NULL
    DROP TABLE #CaptureDataInventory;

CREATE TABLE #CaptureDataInventory
(
      ObjectName nvarchar(776) NOT NULL
    , CaptureRunID bigint NOT NULL
    , TotalRows bigint NOT NULL
);

DECLARE
      @InventorySchema sysname
    , @InventoryObject sysname
    , @InventoryQualified nvarchar(776)
    , @InventorySql nvarchar(max);

DECLARE CaptureInventoryCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
      SCHEMA_NAME(o.schema_id)
    , o.name
    , QUOTENAME(SCHEMA_NAME(o.schema_id))+N'.'+QUOTENAME(o.name)
FROM sys.objects AS o
WHERE o.type IN ('U','V')
  AND EXISTS
  (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id=o.object_id
        AND c.name=N'CaptureRunID'
  )
  AND
  (
       o.name LIKE N'%Cause%'
    OR o.name LIKE N'%Rank%'
    OR o.name LIKE N'%CPU%'
    OR o.name LIKE N'%Scheduler%'
    OR o.name LIKE N'%Evidence%'
  )
ORDER BY
      SCHEMA_NAME(o.schema_id)
    , o.name;

OPEN CaptureInventoryCursor;

FETCH NEXT FROM CaptureInventoryCursor
INTO @InventorySchema,@InventoryObject,@InventoryQualified;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @InventorySql =
        N'INSERT #CaptureDataInventory(ObjectName,CaptureRunID,TotalRows)
          SELECT
                @ObjectName
              , CaptureRunID
              , COUNT_BIG(*)
          FROM ' + @InventoryQualified + N'
          WHERE CaptureRunID IN (42,44)
          GROUP BY CaptureRunID
          HAVING COUNT_BIG(*)>0;';

    BEGIN TRY
        EXEC sys.sp_executesql
              @InventorySql
            , N'@ObjectName nvarchar(776)'
            , @ObjectName=
                CONVERT(nvarchar(776),
                    QUOTENAME(@InventorySchema)+N'.'+QUOTENAME(@InventoryObject));
    END TRY
    BEGIN CATCH
        /*
          Discovery must not stop because one candidate view/table is not
          queryable under the current login or has an unexpected runtime issue.
          Surface the skipped object explicitly instead.
        */
        SELECT
              DiscoverySection='5A - CAPTURE DATA INVENTORY OBJECT SKIPPED'
            , ObjectName=
                CONVERT(nvarchar(776),
                    QUOTENAME(@InventorySchema)+N'.'+QUOTENAME(@InventoryObject))
            , ErrorNumber=ERROR_NUMBER()
            , ErrorMessage=ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM CaptureInventoryCursor
    INTO @InventorySchema,@InventoryObject,@InventoryQualified;
END;

CLOSE CaptureInventoryCursor;
DEALLOCATE CaptureInventoryCursor;

SELECT
      DiscoverySection='5 - CAPTURE DATA INVENTORY'
    , ObjectName
    , CaptureRunID
    , TotalRows
FROM #CaptureDataInventory
ORDER BY ObjectName,CaptureRunID;
GO


/*==============================================================================
  6. FIND ALL OBJECTS THAT REFERENCE CPU SCHEDULER EVIDENCE
==============================================================================*/
SELECT
      DiscoverySection='6 - CPU EVIDENCE DEPENDENCIES'
    , ReferencingSchema=OBJECT_SCHEMA_NAME(d.referencing_id)
    , ReferencingObject=OBJECT_NAME(d.referencing_id)
    , ReferencingType=o.type_desc
    , ReferencedSchema=d.referenced_schema_name
    , ReferencedObject=d.referenced_entity_name
FROM sys.sql_expression_dependencies AS d
JOIN sys.objects AS o
  ON o.object_id=d.referencing_id
WHERE d.referenced_entity_name IN
(
      N'RCA_CPUSchedulerEvidence'
    , N'vw_RCA_CPUSchedulerEvidence'
)
ORDER BY ReferencingObject;
GO


/*==============================================================================
  7. CANONICAL DBA ANSWER DEFINITION
==============================================================================*/
SELECT
      DiscoverySection='7 - CANONICAL DBA ANSWER DEFINITION'
    , ProcedureName=N'dbo.usp_RCA_DBAAnswer'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));
GO


SELECT
      DiscoverySection='7A - TRANSACTION-AWARE ANSWER DEFINITION'
    , ProcedureName=N'dbo.usp_RCA_DBAAnswer_TransactionAware'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware'));
GO


/*==============================================================================
  8. FRIENDLY ALIAS DEFINITIONS
==============================================================================*/
SELECT
      DiscoverySection='8 - FRIENDLY ALIAS DEFINITIONS'
    , ProcedureName=o.name
    , ProcedureDefinition=OBJECT_DEFINITION(o.object_id)
FROM sys.objects AS o
WHERE o.type='P'
  AND o.name IN
  (
        N'usp_RCA_WhyIsDatabaseSlow'
      , N'usp_RCA_ExplainDatabaseSlowness'
  )
ORDER BY o.name;
GO


/*==============================================================================
  9. CPU BUILDER DEFINITION
==============================================================================*/
SELECT
      DiscoverySection='9 - CPU BUILDER DEFINITION'
    , ProcedureName=N'dbo.usp_RCA_BuildCPUSchedulerEvidence'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_BuildCPUSchedulerEvidence'));
GO


/*==============================================================================
  10. ROOT-CAUSE / SYNTHESIS PROCEDURES
==============================================================================*/
SELECT
      DiscoverySection='10 - ROOT CAUSE PROCEDURE DEFINITIONS'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , ProcedureDefinition=OBJECT_DEFINITION(o.object_id)
FROM sys.objects AS o
WHERE o.type='P'
  AND
  (
       o.name LIKE N'%Cause%'
    OR o.name LIKE N'%Rank%'
    OR o.name LIKE N'%Synth%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  11. SEARCH PROCEDURE DEFINITIONS FOR CPU REFERENCES
==============================================================================*/
SELECT
      DiscoverySection='11 - PROCEDURES REFERENCING CPU'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
FROM sys.objects AS o
JOIN sys.sql_modules AS m
  ON m.object_id=o.object_id
WHERE o.type='P'
  AND
  (
       m.definition LIKE N'%RCA_CPUSchedulerEvidence%'
    OR m.definition LIKE N'%vw_RCA_CPUSchedulerEvidence%'
    OR m.definition LIKE N'%CPU_SCHEDULER%'
    OR m.definition LIKE N'%CPU%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  12. SEARCH CANONICAL ANSWER FOR DOMAIN-SPECIFIC DEPENDENCIES
==============================================================================*/
DECLARE @Answer nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

DECLARE @TxnAnswer nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware'));

SELECT
      DiscoverySection='12 - CANONICAL ANSWER DOMAIN CHECK'
    , CanonicalReferencesBlocking=
        CASE WHEN @Answer LIKE N'%Blocking%' OR @Answer LIKE N'%TransactionAware%'
             THEN 'YES' ELSE 'NO' END
    , CanonicalReferencesCPU=
        CASE WHEN @Answer LIKE N'%CPU%' OR @Answer LIKE N'%Scheduler%'
             THEN 'YES' ELSE 'NO' END
    , TransactionAwareReferencesBlocking=
        CASE WHEN @TxnAnswer LIKE N'%RCA_BlockingEvidence%'
               OR @TxnAnswer LIKE N'%HeadBlocker%'
               OR @TxnAnswer LIKE N'%Blocking%'
             THEN 'YES' ELSE 'NO' END
    , TransactionAwareReferencesCPU=
        CASE WHEN @TxnAnswer LIKE N'%RCA_CPUSchedulerEvidence%'
               OR @TxnAnswer LIKE N'%CPU%'
               OR @TxnAnswer LIKE N'%Scheduler%'
             THEN 'YES' ELSE 'NO' END;
GO


/*==============================================================================
  13. EXECUTE CANONICAL ANSWER FOR BOTH CONTROLS
==============================================================================*/
SELECT
      DiscoverySection='13 - CAPTURE 42 CANONICAL ANSWER'
    , CaptureRunID=42;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO

SELECT
      DiscoverySection='13A - CAPTURE 44 CANONICAL ANSWER'
    , CaptureRunID=44;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO


/*==============================================================================
  14. CPU EVIDENCE QUALITY SUMMARY
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='14 - CAPTURE 44 CPU EVIDENCE QUALITY'
        , CaptureRunID
        , CPUSchedulerEvidenceRows=COUNT(*)
        , HighConfidenceRows=
            SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , PrimaryRows=
            SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , PeakSqlCpuPercent=MAX(PeakSqlCpuPercent)
        , AvgSqlCpuPercent=MAX(AvgSqlCpuPercent)
        , LowestSystemIdlePercent=MIN(LowestSystemIdlePercent)
        , PeakRunnableTasks=MAX(PeakRunnableTasks)
        , AvgRunnableTasks=MAX(AvgRunnableTasks)
        , HighRunnableSampleCount=MAX(HighRunnableSampleCount)
        , PrimaryExecutionEvidenceID=MAX(PrimaryExecutionEvidenceID)
        , PrimarySessionID=MAX(PrimarySessionID)
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=44
    GROUP BY CaptureRunID;
END;
GO


/*==============================================================================
  15. PRIMARY CPU EXECUTION ATTRIBUTION
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='15 - PRIMARY CPU EXECUTION ATTRIBUTION'
        , c.CaptureRunID
        , c.CPUSchedulerEvidenceID
        , c.PrimaryExecutionEvidenceID
        , c.PrimarySessionID
        , e.EventTimeUTC
        , e.DatabaseName
        , e.SessionID
        , e.ObjectName
        , e.HostName
        , e.ProgramName
        , e.LoginName
        , e.CPUms
        , e.DurationMs
        , e.LogicalReads
        , e.SubmittedCommand
    FROM dbo.RCA_CPUSchedulerEvidence AS c
    LEFT JOIN dbo.RCA_ExecutionEvidence AS e
      ON e.ExecutionEvidenceID=c.PrimaryExecutionEvidenceID
    WHERE c.CaptureRunID=44;
END;
GO


/*==============================================================================
  16. FINAL GAP ASSESSMENT
==============================================================================*/
DECLARE
      @CPUPrimary int=0
    , @CPUHigh int=0
    , @CanonicalRefsCPU bit=0
    , @TxnRefsCPU bit=0
    , @CanonicalRefsTxn bit=0;

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          @CPUPrimary=
              ISNULL(SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END),0)
        , @CPUHigh=
              ISNULL(SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END),0)
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=44;
END;

DECLARE @A nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));
DECLARE @TA nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer_TransactionAware'));

SET @CanonicalRefsCPU=
    CASE WHEN @A LIKE N'%CPU%' OR @A LIKE N'%Scheduler%' THEN 1 ELSE 0 END;

SET @TxnRefsCPU=
    CASE WHEN @TA LIKE N'%CPU%' OR @TA LIKE N'%Scheduler%' THEN 1 ELSE 0 END;

SET @CanonicalRefsTxn=
    CASE WHEN @A LIKE N'%TransactionAware%' THEN 1 ELSE 0 END;

SELECT
      ValidationSection='16 - CPU CANONICAL ANSWER GAP ASSESSMENT'
    , Capture44CPUPrimaryRows=@CPUPrimary
    , Capture44CPUHighConfidenceRows=@CPUHigh
    , CanonicalAnswerDelegatesToTransactionAware=
        CASE WHEN @CanonicalRefsTxn=1 THEN 'YES' ELSE 'NO' END
    , CanonicalAnswerReferencesCPU=
        CASE WHEN @CanonicalRefsCPU=1 THEN 'YES' ELSE 'NO' END
    , TransactionAwareAnswerReferencesCPU=
        CASE WHEN @TxnRefsCPU=1 THEN 'YES' ELSE 'NO' END
    , GapAssessment=
        CASE
          WHEN @CPUPrimary>0
           AND @CPUHigh>0
           AND @CanonicalRefsTxn=1
           AND @TxnRefsCPU=0
          THEN
              'CONFIRMED - CPU ROOT CAUSE EXISTS, BUT CANONICAL DBA ANSWER ROUTES ONLY THROUGH BLOCKING/TRANSACTION PRESENTATION.'

          WHEN @CPUPrimary=0
          THEN
              'CPU PRIMARY CAUSE NOT PRESENT - PRESENTATION GAP NOT PROVEN.'

          ELSE
              'REVIEW OBJECT DEFINITIONS AND CAPTURE DATA INVENTORY TO LOCATE THE GAP.'
        END
    , RecommendedNextStep=
        CASE
          WHEN @CPUPrimary>0
           AND @CPUHigh>0
           AND @CanonicalRefsTxn=1
           AND @TxnRefsCPU=0
          THEN
              'Build a multi-domain DBA presentation router that dispatches to blocking, CPU, memory, I/O, and other evidence-specific narrators without changing detector thresholds or root-cause ranking.'
          ELSE
              'Do not modify presentation yet; review Script 63 discovery output.'
        END;
GO


/*==============================================================================
  17. SAFETY
==============================================================================*/
SELECT
      ValidationSection='17 - SCRIPT 63 SAFETY'
    , ReadOnlyDiscovery='YES'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , ExistingEvidenceModified='NO'
    , ProceduresAltered='NO'
    , ViewsAltered='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        'Use the confirmed A/B gap to decide whether Script 64 should add a multi-domain presentation router. Do not change RCA thresholds from this discovery.';
GO
