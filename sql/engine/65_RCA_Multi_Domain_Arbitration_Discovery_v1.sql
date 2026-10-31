USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  65_RCA_Multi_Domain_Arbitration_Discovery_v1.sql

  PURPOSE
  -------
  Read-only discovery of the existing RCA synthesis / ranking architecture so
  we can determine how to arbitrate multiple simultaneously-supported causes
  without creating a second, parallel root-cause engine.

  WHY THIS MATTERS
  ----------------
  Script 64 proved that the canonical DBA answer can route correctly between:

      - Blocking / wait-chain
      - CPU / scheduler
      - Uncertainty / no supported cause

  The next architectural problem is mixed incidents:

      Example:
          CPU scheduler pressure = PRIMARY/HIGH
          Blocking              = CONTRIBUTING/MEDIUM

      or:
          Blocking              = PRIMARY/HIGH
          Memory pressure       = CONTRIBUTING/MEDIUM

  We need one authoritative ranking / synthesis layer that decides:

      - PRIMARY cause
      - CONTRIBUTING causes
      - confidence
      - correlation key
      - evidence count
      - reason one cause outranked another

  THIS SCRIPT DOES NOT
  --------------------
      - change detector thresholds
      - change root-cause domains
      - change ranking logic
      - modify synthesis rows
      - modify existing evidence
      - alter dbo.usp_RCA_DBAAnswer
      - start a capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 65 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , RootCauseSynthesis=
        CASE WHEN OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL THEN 'PASS' ELSE 'REVIEW' END
    , CPUSchedulerEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyDiscovery='YES'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  1. ROOT CAUSE / SYNTHESIS OBJECT INVENTORY
==============================================================================*/
SELECT
      DiscoverySection='1 - ROOT CAUSE OBJECT INVENTORY'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ObjectName=o.name
    , ObjectType=o.type_desc
    , CreateDate=o.create_date
    , ModifyDate=o.modify_date
FROM sys.objects AS o
WHERE
       o.name LIKE N'%RootCause%'
    OR o.name LIKE N'%Synthesis%'
    OR o.name LIKE N'%FinalCause%'
    OR o.name LIKE N'%CauseRank%'
    OR o.name LIKE N'%IncidentAssessment%'
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  2. ROOT CAUSE SYNTHESIS TABLE SCHEMA
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='2 - ROOT CAUSE SYNTHESIS SCHEMA'
        , ColumnID=c.column_id
        , ColumnName=c.name
        , DataType=t.name
        , MaxLength=c.max_length
        , PrecisionValue=c.precision
        , ScaleValue=c.scale
        , IsNullable=c.is_nullable
    FROM sys.columns AS c
    JOIN sys.types AS t
      ON t.user_type_id=c.user_type_id
    WHERE c.object_id=OBJECT_ID(N'dbo.RCA_RootCauseSynthesis')
    ORDER BY c.column_id;
END;
GO


/*==============================================================================
  3. CAPTURE 42 / 44 SYNTHESIS ROWS
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='3 - ROOT CAUSE SYNTHESIS DATA'
        , *
    FROM dbo.RCA_RootCauseSynthesis
    WHERE CaptureRunID IN (42,44)
    ORDER BY CaptureRunID;
END;
GO


/*==============================================================================
  4. PROCEDURES THAT BUILD / APPLY SYNTHESIS
==============================================================================*/
SELECT
      DiscoverySection='4 - SYNTHESIS PROCEDURE INVENTORY'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , CreateDate=o.create_date
    , ModifyDate=o.modify_date
FROM sys.objects AS o
WHERE o.type='P'
  AND
  (
       o.name LIKE N'%Synthesis%'
    OR o.name LIKE N'%RootCause%'
    OR o.name LIKE N'%IncidentAssessment%'
    OR o.name LIKE N'%FinalCause%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  5. PROCEDURE DEFINITIONS FOR SYNTHESIS / ARBITRATION
==============================================================================*/
SELECT
      DiscoverySection='5 - SYNTHESIS PROCEDURE DEFINITIONS'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , ProcedureDefinition=OBJECT_DEFINITION(o.object_id)
FROM sys.objects AS o
WHERE o.type='P'
  AND
  (
       o.name LIKE N'%Synthesis%'
    OR o.name LIKE N'%RootCause%'
    OR o.name LIKE N'%IncidentAssessment%'
    OR o.name LIKE N'%FinalCause%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  6. VIEWS THAT SURFACE SYNTHESIS / CAUSE RANKING
==============================================================================*/
SELECT
      DiscoverySection='6 - SYNTHESIS VIEW INVENTORY'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ViewName=o.name
    , ViewDefinition=OBJECT_DEFINITION(o.object_id)
FROM sys.objects AS o
WHERE o.type='V'
  AND
  (
       o.name LIKE N'%Synthesis%'
    OR o.name LIKE N'%RootCause%'
    OR o.name LIKE N'%Cause%'
    OR o.name LIKE N'%IncidentAssessment%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  7. PROCEDURES REFERENCING ROOT CAUSE SYNTHESIS
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='7 - SYNTHESIS DEPENDENCIES'
        , ReferencingSchema=OBJECT_SCHEMA_NAME(d.referencing_id)
        , ReferencingObject=OBJECT_NAME(d.referencing_id)
        , ReferencingType=o.type_desc
        , ReferencedSchema=d.referenced_schema_name
        , ReferencedObject=d.referenced_entity_name
    FROM sys.sql_expression_dependencies AS d
    JOIN sys.objects AS o
      ON o.object_id=d.referencing_id
    WHERE d.referenced_entity_name=N'RCA_RootCauseSynthesis'
    ORDER BY ReferencingObject;
END;
GO


/*==============================================================================
  8. CAUSE-DOMAIN EVIDENCE FOR CAPTURE 42 / 44
==============================================================================*/
SELECT
      DiscoverySection='8 - BLOCKING CAUSE EVIDENCE'
    , CaptureRunID
    , BlockingEvidenceID
    , RootCauseRole
    , Confidence
    , VictimSessionID
    , HeadBlockerSessionID
    , WaitType
    , WaitDurationMs
    , SampleCount
    , EvidenceSummary
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID IN (42,44)
ORDER BY CaptureRunID,BlockingEvidenceID;
GO


SELECT
      DiscoverySection='8A - CPU CAUSE EVIDENCE'
    , CaptureRunID
    , CPUSchedulerEvidenceID
    , RootCauseRole
    , Confidence
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , PeakSqlCpuPercent
    , AvgSqlCpuPercent
    , LowestSystemIdlePercent
    , PeakRunnableTasks
    , AvgRunnableTasks
    , HighRunnableSampleCount
    , ServerSampleCount
FROM dbo.RCA_CPUSchedulerEvidence
WHERE CaptureRunID IN (42,44)
ORDER BY CaptureRunID,CPUSchedulerEvidenceID;
GO


/*==============================================================================
  9. ALL ROOT-CAUSE-LIKE TABLES WITH CAPTURE 42 / 44 DATA
==============================================================================*/
IF OBJECT_ID(N'tempdb..#CauseInventory',N'U') IS NOT NULL
    DROP TABLE #CauseInventory;

CREATE TABLE #CauseInventory
(
      ObjectName nvarchar(776) NOT NULL
    , CaptureRunID bigint NOT NULL
    , TotalRows bigint NOT NULL
);

DECLARE
      @SchemaName sysname
    , @ObjectName sysname
    , @QualifiedName nvarchar(776)
    , @DisplayName nvarchar(776)
    , @sql nvarchar(max);

DECLARE CauseCursor CURSOR LOCAL FAST_FORWARD FOR
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
    OR o.name LIKE N'%Synthesis%'
    OR o.name LIKE N'%Evidence%'
    OR o.name LIKE N'%Assessment%'
  )
ORDER BY SCHEMA_NAME(o.schema_id),o.name;

OPEN CauseCursor;

FETCH NEXT FROM CauseCursor
INTO @SchemaName,@ObjectName,@QualifiedName;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @DisplayName=
        CONVERT(nvarchar(776),
            QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@ObjectName));

    SET @sql=
        N'INSERT #CauseInventory(ObjectName,CaptureRunID,TotalRows)
          SELECT
                @DisplayName
              , CaptureRunID
              , COUNT_BIG(*)
          FROM '+@QualifiedName+N'
          WHERE CaptureRunID IN (42,44)
          GROUP BY CaptureRunID
          HAVING COUNT_BIG(*)>0;';

    BEGIN TRY
        EXEC sys.sp_executesql
              @sql
            , N'@DisplayName nvarchar(776)'
            , @DisplayName=@DisplayName;
    END TRY
    BEGIN CATCH
        SELECT
              DiscoverySection='9A - CAUSE INVENTORY OBJECT SKIPPED'
            , ObjectName=@DisplayName
            , ErrorNumber=ERROR_NUMBER()
            , ErrorMessage=ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM CauseCursor
    INTO @SchemaName,@ObjectName,@QualifiedName;
END;

CLOSE CauseCursor;
DEALLOCATE CauseCursor;

SELECT
      DiscoverySection='9 - CAUSE DATA INVENTORY'
    , ObjectName
    , CaptureRunID
    , TotalRows
FROM #CauseInventory
ORDER BY ObjectName,CaptureRunID;
GO


/*==============================================================================
  10. CANONICAL ROUTER DEFINITION
==============================================================================*/
SELECT
      DiscoverySection='10 - CANONICAL ROUTER DEFINITION'
    , ProcedureName=N'dbo.usp_RCA_DBAAnswer'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));
GO


/*==============================================================================
  11. CURRENT ROUTER DOMAIN PRIORITY CHECK
==============================================================================*/
DECLARE @Router nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      DiscoverySection='11 - ROUTER DOMAIN PRIORITY'
    , ReferencesBlocking=
        CASE WHEN @Router LIKE N'%RCA_BlockingEvidence%' THEN 'YES' ELSE 'NO' END
    , ReferencesCPU=
        CASE WHEN @Router LIKE N'%RCA_CPUSchedulerEvidence%' THEN 'YES' ELSE 'NO' END
    , BlockingCheckedBeforeCPU=
        CASE
          WHEN CHARINDEX(N'RCA_BlockingEvidence',@Router)>0
           AND CHARINDEX(N'RCA_CPUSchedulerEvidence',@Router)>0
           AND CHARINDEX(N'RCA_BlockingEvidence',@Router)
               < CHARINDEX(N'RCA_CPUSchedulerEvidence',@Router)
          THEN 'YES'
          ELSE 'NO'
        END
    , Interpretation=
        CASE
          WHEN CHARINDEX(N'RCA_BlockingEvidence',@Router)>0
           AND CHARINDEX(N'RCA_CPUSchedulerEvidence',@Router)>0
           AND CHARINDEX(N'RCA_BlockingEvidence',@Router)
               < CHARINDEX(N'RCA_CPUSchedulerEvidence',@Router)
          THEN
              'Current presentation router hard-codes blocking precedence over CPU.'
          ELSE
              'Router ordering requires manual review.'
        END;
GO


/*==============================================================================
  12. SEARCH SYNTHESIS DEFINITIONS FOR PRIORITY / CONFIDENCE / ROLE LOGIC
==============================================================================*/
SELECT
      DiscoverySection='12 - SYNTHESIS LOGIC KEYWORDS'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , MentionsPrimary=
        CASE WHEN m.definition LIKE N'%PRIMARY%' THEN 'YES' ELSE 'NO' END
    , MentionsContributing=
        CASE WHEN m.definition LIKE N'%CONTRIBUT%' THEN 'YES' ELSE 'NO' END
    , MentionsConfidence=
        CASE WHEN m.definition LIKE N'%Confidence%' THEN 'YES' ELSE 'NO' END
    , MentionsPriority=
        CASE WHEN m.definition LIKE N'%Priority%' THEN 'YES' ELSE 'NO' END
    , MentionsBlocking=
        CASE WHEN m.definition LIKE N'%BLOCKING%' THEN 'YES' ELSE 'NO' END
    , MentionsCPU=
        CASE WHEN m.definition LIKE N'%CPU%' OR m.definition LIKE N'%SCHEDUL%'
             THEN 'YES' ELSE 'NO' END
FROM sys.objects AS o
JOIN sys.sql_modules AS m
  ON m.object_id=o.object_id
WHERE o.type='P'
  AND
  (
       o.name LIKE N'%Synthesis%'
    OR o.name LIKE N'%RootCause%'
    OR o.name LIKE N'%IncidentAssessment%'
    OR o.name LIKE N'%FinalCause%'
  )
ORDER BY o.name;
GO


/*==============================================================================
  13. CAPTURE 42 / 44 CURRENT DBA ANSWERS
==============================================================================*/
SELECT
      DiscoverySection='13 - CAPTURE 42 CURRENT DBA ANSWER'
    , CaptureRunID=42;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;
GO


SELECT
      DiscoverySection='13A - CAPTURE 44 CURRENT DBA ANSWER'
    , CaptureRunID=44;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;
GO


/*==============================================================================
  14. MIXED-CAUSE READINESS CHECK

  We are not manufacturing a mixed incident here.
  This section asks whether the current persisted architecture has enough
  standardized fields to arbitrate domains generically.
==============================================================================*/
DECLARE
      @RootCauseTableExists bit=
        CASE WHEN OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL
             THEN 1 ELSE 0 END
    , @HasCaptureRunID bit=0
    , @HasCauseCategory bit=0
    , @HasRole bit=0
    , @HasConfidence bit=0
    , @HasEvidenceCount bit=0
    , @HasCorrelationKey bit=0
    , @HasPriority bit=0;

IF @RootCauseTableExists=1
BEGIN
    SET @HasCaptureRunID=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'CaptureRunID') IS NOT NULL
             THEN 1 ELSE 0 END;

    SET @HasCauseCategory=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'CauseCategory') IS NOT NULL
               OR COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'CauseName') IS NOT NULL
               OR COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'FindingType') IS NOT NULL
             THEN 1 ELSE 0 END;

    SET @HasRole=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'RootCauseRole') IS NOT NULL
               OR COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'PrimaryRole') IS NOT NULL
             THEN 1 ELSE 0 END;

    SET @HasConfidence=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'Confidence') IS NOT NULL
             THEN 1 ELSE 0 END;

    SET @HasEvidenceCount=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'EvidenceCount') IS NOT NULL
             THEN 1 ELSE 0 END;

    SET @HasCorrelationKey=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'CorrelationKey') IS NOT NULL
             THEN 1 ELSE 0 END;

    SET @HasPriority=
        CASE WHEN COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'Priority') IS NOT NULL
               OR COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'Rank') IS NOT NULL
               OR COL_LENGTH(N'dbo.RCA_RootCauseSynthesis',N'CauseRank') IS NOT NULL
             THEN 1 ELSE 0 END;
END;

SELECT
      ValidationSection='14 - MULTI-DOMAIN ARBITRATION READINESS'
    , RootCauseSynthesisTable=
        CASE WHEN @RootCauseTableExists=1 THEN 'PASS' ELSE 'REVIEW' END
    , CaptureRunIDStandardized=
        CASE WHEN @HasCaptureRunID=1 THEN 'PASS' ELSE 'REVIEW' END
    , CauseCategoryStandardized=
        CASE WHEN @HasCauseCategory=1 THEN 'PASS' ELSE 'REVIEW' END
    , RootCauseRoleStandardized=
        CASE WHEN @HasRole=1 THEN 'PASS' ELSE 'REVIEW' END
    , ConfidenceStandardized=
        CASE WHEN @HasConfidence=1 THEN 'PASS' ELSE 'REVIEW' END
    , EvidenceCountStandardized=
        CASE WHEN @HasEvidenceCount=1 THEN 'PASS' ELSE 'REVIEW' END
    , CorrelationKeyStandardized=
        CASE WHEN @HasCorrelationKey=1 THEN 'PASS' ELSE 'REVIEW' END
    , ExplicitPriorityOrRank=
        CASE WHEN @HasPriority=1 THEN 'PASS' ELSE 'REVIEW' END
    , CurrentRouterHardCodesDomainOrder='YES'
    , Interpretation=
        CASE
          WHEN @RootCauseTableExists=1
           AND @HasCaptureRunID=1
           AND @HasCauseCategory=1
           AND @HasRole=1
           AND @HasConfidence=1
          THEN
              'Existing synthesis appears capable of becoming the authoritative cross-domain arbitration layer. Review missing generic ranking fields before changing the router.'
          ELSE
              'Existing synthesis is not yet sufficiently standardized for generic cross-domain arbitration. Do not create presentation-side ranking logic.'
        END;
GO


/*==============================================================================
  15. FINAL DISCOVERY ASSESSMENT
==============================================================================*/
DECLARE
      @SynthesisExists bit=
          CASE WHEN OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL
               THEN 1 ELSE 0 END
    , @RouterText nvarchar(max)=
          OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='15 - SCRIPT 65 DISCOVERY CONCLUSION'
    , ExistingSynthesisLayer=
        CASE WHEN @SynthesisExists=1 THEN 'YES' ELSE 'NO' END
    , RouterCurrentlyHardCodesBlockingThenCPU=
        CASE
          WHEN CHARINDEX(N'RCA_BlockingEvidence',@RouterText)>0
           AND CHARINDEX(N'RCA_CPUSchedulerEvidence',@RouterText)>0
           AND CHARINDEX(N'RCA_BlockingEvidence',@RouterText)
               < CHARINDEX(N'RCA_CPUSchedulerEvidence',@RouterText)
          THEN 'YES'
          ELSE 'NO'
        END
    , RecommendedArchitecture=
        CASE
          WHEN @SynthesisExists=1
          THEN
              'Use RCA_RootCauseSynthesis (or its existing successor/view) as the authoritative arbitration source. Do not let usp_RCA_DBAAnswer rank domains independently.'
          ELSE
              'Create one normalized cross-domain cause-ranking layer before adding more DBA narrators.'
        END
    , RecommendedNextStep=
        CASE
          WHEN @SynthesisExists=1
          THEN
              'Script 66 should normalize and validate cross-domain synthesis/ranking using existing detector outputs, preserving Capture 42 and 44 results.'
          ELSE
              'Script 66 should create a normalized cause arbitration view/table from existing domain evidence without changing detector thresholds.'
        END;
GO


/*==============================================================================
  16. SAFETY
==============================================================================*/
SELECT
      ValidationSection='16 - SCRIPT 65 SAFETY'
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
    , NewCaptureStarted='NO';
GO
