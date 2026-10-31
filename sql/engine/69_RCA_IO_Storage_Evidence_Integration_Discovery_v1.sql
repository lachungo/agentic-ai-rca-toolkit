USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  69_RCA_IO_Storage_Evidence_Integration_Discovery_v1.sql

  PURPOSE
  -------
  Inspect the EXISTING I/O / storage evidence implementation so we can integrate
  it into the normalized cross-domain arbitration layer without creating a
  duplicate detector.

  THIS SCRIPT ANSWERS
  -------------------
  1. What is the exact schema of dbo.RCA_IOStorageEvidence?
  2. What does dbo.usp_RCA_BuildIOStorageEvidence actually do?
  3. Which source tables/views feed it?
  4. Does it already assign RootCauseRole / Confidence?
  5. Which historical captures already contain I/O evidence?
  6. Can the existing evidence be mapped cleanly into:
         CauseCategory = IO_STORAGE_LATENCY
     without changing detector thresholds or canonical routing?
  7. What exact columns should Script 70 use?

  SAFETY
  ------
  Read-only discovery only.

  This script does NOT:
      - alter dbo.RCA_IOStorageEvidence
      - alter dbo.usp_RCA_BuildIOStorageEvidence
      - rebuild I/O evidence
      - change detector thresholds
      - change root-cause logic
      - change normalized ranking
      - change dbo.usp_RCA_DBAAnswer
      - modify historical captures
      - start a new capture

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 69 PRE-FLIGHT'
    , IOStorageEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageBuilder=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , NormalizedCauseCandidates=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CanonicalDBAAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyDiscovery='YES'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NULL
    THROW 56900,N'dbo.RCA_IOStorageEvidence is required.',1;

IF OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence',N'P') IS NULL
    THROW 56901,N'dbo.usp_RCA_BuildIOStorageEvidence is required.',1;
GO


/*==============================================================================
  1. EXACT I/O EVIDENCE TABLE SCHEMA
==============================================================================*/
SELECT
      DiscoverySection='1 - IO STORAGE EVIDENCE SCHEMA'
    , ColumnID=c.column_id
    , ColumnName=c.name
    , DataType=t.name
    , MaxLength=c.max_length
    , PrecisionValue=c.precision
    , ScaleValue=c.scale
    , IsNullable=c.is_nullable
    , DefaultDefinition=dc.definition
FROM sys.columns AS c
JOIN sys.types AS t
  ON t.user_type_id=c.user_type_id
LEFT JOIN sys.default_constraints AS dc
  ON dc.parent_object_id=c.object_id
 AND dc.parent_column_id=c.column_id
WHERE c.object_id=OBJECT_ID(N'dbo.RCA_IOStorageEvidence')
ORDER BY c.column_id;
GO


/*==============================================================================
  2. KEYS / INDEXES / CONSTRAINTS
==============================================================================*/
SELECT
      DiscoverySection='2 - IO STORAGE EVIDENCE INDEXES'
    , IndexName=i.name
    , IndexType=i.type_desc
    , IsUnique=i.is_unique
    , IsPrimaryKey=i.is_primary_key
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
WHERE i.object_id=OBJECT_ID(N'dbo.RCA_IOStorageEvidence')
ORDER BY i.index_id,ic.key_ordinal,ic.index_column_id;
GO


/*==============================================================================
  3. BUILDER DEFINITION
==============================================================================*/
SELECT
      DiscoverySection='3 - IO STORAGE BUILDER DEFINITION'
    , ProcedureName=N'dbo.usp_RCA_BuildIOStorageEvidence'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence'));
GO


/*==============================================================================
  4. BUILDER KEYWORD / CAPABILITY CHECK
==============================================================================*/
DECLARE @Builder nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence'));

SELECT
      DiscoverySection='4 - IO BUILDER CAPABILITY CHECK'
    , ReferencesVirtualFileStats=
        CASE WHEN @Builder LIKE N'%dm_io_virtual_file_stats%' THEN 'YES' ELSE 'NO' END
    , ReferencesWaitStats=
        CASE WHEN @Builder LIKE N'%wait_stats%' OR @Builder LIKE N'%PAGEIOLATCH%'
                  OR @Builder LIKE N'%WRITELOG%'
             THEN 'YES' ELSE 'NO' END
    , ReferencesExecutionEvidence=
        CASE WHEN @Builder LIKE N'%RCA_ExecutionEvidence%' THEN 'YES' ELSE 'NO' END
    , ReferencesServerSnapshot=
        CASE WHEN @Builder LIKE N'%RCA_ServerSnapshot%' THEN 'YES' ELSE 'NO' END
    , ReferencesIOStorageEvidence=
        CASE WHEN @Builder LIKE N'%RCA_IOStorageEvidence%' THEN 'YES' ELSE 'NO' END
    , MentionsRootCauseRole=
        CASE WHEN @Builder LIKE N'%RootCauseRole%' THEN 'YES' ELSE 'NO' END
    , MentionsConfidence=
        CASE WHEN @Builder LIKE N'%Confidence%' THEN 'YES' ELSE 'NO' END
    , MentionsThreshold=
        CASE WHEN @Builder LIKE N'%Threshold%' THEN 'YES' ELSE 'NO' END
    , MentionsReadLatency=
        CASE WHEN @Builder LIKE N'%ReadLatency%' OR @Builder LIKE N'%io_stall_read%'
             THEN 'YES' ELSE 'NO' END
    , MentionsWriteLatency=
        CASE WHEN @Builder LIKE N'%WriteLatency%' OR @Builder LIKE N'%io_stall_write%'
             THEN 'YES' ELSE 'NO' END;
GO


/*==============================================================================
  5. DEPENDENCIES OF THE I/O BUILDER
==============================================================================*/
SELECT
      DiscoverySection='5 - IO BUILDER DEPENDENCIES'
    , ReferencedServerName=d.referenced_server_name
    , ReferencedDatabaseName=d.referenced_database_name
    , ReferencedSchemaName=d.referenced_schema_name
    , ReferencedEntityName=d.referenced_entity_name
    , ReferencedClassDesc=d.referenced_class_desc
FROM sys.sql_expression_dependencies AS d
WHERE d.referencing_id=OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence')
ORDER BY
      d.referenced_database_name
    , d.referenced_schema_name
    , d.referenced_entity_name;
GO


/*==============================================================================
  6. OBJECTS THAT CONSUME I/O STORAGE EVIDENCE
==============================================================================*/
SELECT
      DiscoverySection='6 - IO EVIDENCE CONSUMERS'
    , ReferencingSchema=OBJECT_SCHEMA_NAME(d.referencing_id)
    , ReferencingObject=OBJECT_NAME(d.referencing_id)
    , ReferencingType=o.type_desc
FROM sys.sql_expression_dependencies AS d
JOIN sys.objects AS o
  ON o.object_id=d.referencing_id
WHERE d.referenced_entity_name=N'RCA_IOStorageEvidence'
ORDER BY o.type_desc,OBJECT_NAME(d.referencing_id);
GO


/*==============================================================================
  7. I/O STORAGE EVIDENCE ROW COUNTS BY CAPTURE
==============================================================================*/
SELECT
      DiscoverySection='7 - IO EVIDENCE BY CAPTURE'
    , CaptureRunID
    , TotalRows=COUNT_BIG(*)
FROM dbo.RCA_IOStorageEvidence
GROUP BY CaptureRunID
ORDER BY CaptureRunID;
GO


/*==============================================================================
  8. SAMPLE EXISTING I/O EVIDENCE
  Dynamic SELECT * is intentional here: we need to see the actual persisted
  contract before designing normalization.
==============================================================================*/
SELECT TOP (100)
      DiscoverySection='8 - IO STORAGE EVIDENCE SAMPLE'
    , *
FROM dbo.RCA_IOStorageEvidence
ORDER BY
      CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'CaptureRunID') IS NOT NULL
           THEN CaptureRunID ELSE NULL END,
      1;
GO


/*==============================================================================
  9. ROOT-CAUSE ROLE / CONFIDENCE COLUMN DISCOVERY
==============================================================================*/
SELECT
      ValidationSection='9 - IO ATTRIBUTION COLUMN CHECK'
    , HasCaptureRunID=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'CaptureRunID') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HasRootCauseRole=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'RootCauseRole') IS NOT NULL
             THEN 'YES' ELSE 'NO' END
    , HasConfidence=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'Confidence') IS NOT NULL
             THEN 'YES' ELSE 'NO' END
    , HasPrimaryExecutionEvidenceID=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'PrimaryExecutionEvidenceID') IS NOT NULL
             THEN 'YES' ELSE 'NO' END
    , HasPrimarySessionID=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'PrimarySessionID') IS NOT NULL
             THEN 'YES' ELSE 'NO' END
    , HasEvidenceSummary=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'EvidenceSummary') IS NOT NULL
             THEN 'YES' ELSE 'NO' END
    , HasRecommendedAction=
        CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'RecommendedAction') IS NOT NULL
             THEN 'YES' ELSE 'NO' END;
GO


/*==============================================================================
  10. DISCOVER LIKELY I/O METRIC COLUMNS
==============================================================================*/
SELECT
      DiscoverySection='10 - IO METRIC COLUMN DISCOVERY'
    , ColumnID=c.column_id
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
FROM sys.columns AS c
WHERE c.object_id=OBJECT_ID(N'dbo.RCA_IOStorageEvidence')
  AND
  (
       c.name LIKE N'%Latency%'
    OR c.name LIKE N'%Read%'
    OR c.name LIKE N'%Write%'
    OR c.name LIKE N'%Stall%'
    OR c.name LIKE N'%Wait%'
    OR c.name LIKE N'%File%'
    OR c.name LIKE N'%Database%'
    OR c.name LIKE N'%Sample%'
    OR c.name LIKE N'%Peak%'
    OR c.name LIKE N'%Avg%'
  )
ORDER BY c.column_id;
GO


/*==============================================================================
  11. DISCOVER LIKELY GENERIC MAPPING COLUMNS
==============================================================================*/
SELECT
      DiscoverySection='11 - IO NORMALIZATION MAPPING COLUMNS'
    , ColumnName=c.name
    , MappingPurpose=
        CASE
          WHEN c.name=N'CaptureRunID' THEN 'CaptureRunID'
          WHEN c.name=N'RootCauseRole' THEN 'RootCauseRole'
          WHEN c.name=N'Confidence' THEN 'Confidence'
          WHEN c.name LIKE N'%ExecutionEvidenceID%' THEN 'PrimaryExecutionEvidenceID candidate'
          WHEN c.name LIKE N'%SessionID%' THEN 'PrimarySessionID candidate'
          WHEN c.name LIKE N'%EvidenceSummary%' THEN 'PrimaryEvidence'
          WHEN c.name LIKE N'%RecommendedAction%' THEN 'RecommendedAction'
          WHEN c.name LIKE N'%Database%' THEN 'CorrelationKey component'
          WHEN c.name LIKE N'%File%' THEN 'CorrelationKey component'
          ELSE 'Metric / supporting evidence'
        END
FROM sys.columns AS c
WHERE c.object_id=OBJECT_ID(N'dbo.RCA_IOStorageEvidence')
ORDER BY c.column_id;
GO


/*==============================================================================
  12. HISTORICAL CAPTURE CONTEXT FOR I/O EVIDENCE
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='12 - IO CAPTURE CONTEXT'
        , e.CaptureRunID
        , c.TargetDatabase
        , c.CaptureReason
        , c.StartTimeUTC
        , c.EndTimeUTC
        , c.CaptureStatus
        , IOEvidenceRows=COUNT_BIG(*)
    FROM dbo.RCA_IOStorageEvidence AS e
    LEFT JOIN dbo.RCA_CaptureRun AS c
      ON c.CaptureRunID=e.CaptureRunID
    GROUP BY
          e.CaptureRunID
        , c.TargetDatabase
        , c.CaptureReason
        , c.StartTimeUTC
        , c.EndTimeUTC
        , c.CaptureStatus
    ORDER BY e.CaptureRunID;
END;
GO


/*==============================================================================
  13. CHECK WHETHER CURRENT NORMALIZATION REFERENCES I/O EVIDENCE
==============================================================================*/
DECLARE @Normalized nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates'));

SELECT
      ValidationSection='13 - CURRENT IO NORMALIZATION STATUS'
    , ReferencesIOStorageEvidence=
        CASE WHEN @Normalized LIKE N'%RCA_IOStorageEvidence%' THEN 'YES' ELSE 'NO' END
    , ContainsIOStorageLatencyCategory=
        CASE WHEN @Normalized LIKE N'%IO_STORAGE_LATENCY%' THEN 'YES' ELSE 'NO' END
    , Interpretation=
        CASE
          WHEN @Normalized LIKE N'%RCA_IOStorageEvidence%'
           AND @Normalized LIKE N'%IO_STORAGE_LATENCY%'
          THEN N'I/O evidence is already normalized; Script 70 should validate rather than duplicate it.'
          ELSE N'Existing I/O evidence is not yet part of the normalized cross-domain contract.'
        END;
GO


/*==============================================================================
  14. CHECK FOR EXISTING I/O CAUSE IN OLD SYNTHESIS / FINAL RANKING
==============================================================================*/
DECLARE @HasRootCauseSynthesis bit=
    CASE WHEN OBJECT_ID(N'dbo.RCA_RootCauseSynthesis',N'U') IS NOT NULL
         THEN 1 ELSE 0 END;

IF @HasRootCauseSynthesis=1
BEGIN
    SELECT TOP (100)
          DiscoverySection='14 - LEGACY SYNTHESIS IO REFERENCES'
        , *
    FROM dbo.RCA_RootCauseSynthesis
    WHERE
           PrimaryCause LIKE N'%IO%'
        OR PrimaryCause LIKE N'%storage%'
        OR PrimaryCause LIKE N'%disk%'
        OR PrimaryCause LIKE N'%latency%'
        OR PrimaryEvidence LIKE N'%PAGEIOLATCH%'
        OR PrimaryEvidence LIKE N'%WRITELOG%'
    ORDER BY RootCauseSynthesisID DESC;
END;
GO


/*==============================================================================
  15. BUILDER EXECUTION HISTORY / MODIFY DATE
==============================================================================*/
SELECT
      DiscoverySection='15 - IO BUILDER OBJECT STATE'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ProcedureName=o.name
    , CreateDate=o.create_date
    , ModifyDate=o.modify_date
FROM sys.objects AS o
WHERE o.object_id=OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence');
GO


/*==============================================================================
  16. DESIGN READINESS
==============================================================================*/
DECLARE
      @HasRole bit=
          CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'RootCauseRole') IS NOT NULL
               THEN 1 ELSE 0 END
    , @HasConfidence bit=
          CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'Confidence') IS NOT NULL
               THEN 1 ELSE 0 END
    , @HasCapture bit=
          CASE WHEN COL_LENGTH(N'dbo.RCA_IOStorageEvidence',N'CaptureRunID') IS NOT NULL
               THEN 1 ELSE 0 END
    , @Normalized2 nvarchar(max)=
          OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates'));

SELECT
      ValidationSection='16 - SCRIPT 69 DESIGN READINESS'
    , ExistingIOEvidenceTable='PASS'
    , ExistingIOBuilder='PASS'
    , CaptureRunIDAvailable=
        CASE WHEN @HasCapture=1 THEN 'PASS' ELSE 'FAIL' END
    , RootCauseRoleAvailable=
        CASE WHEN @HasRole=1 THEN 'PASS' ELSE 'REVIEW' END
    , ConfidenceAvailable=
        CASE WHEN @HasConfidence=1 THEN 'PASS' ELSE 'REVIEW' END
    , AlreadyNormalized=
        CASE WHEN @Normalized2 LIKE N'%RCA_IOStorageEvidence%'
                   AND @Normalized2 LIKE N'%IO_STORAGE_LATENCY%'
             THEN 'YES' ELSE 'NO' END
    , RecommendedArchitecture=
        CASE
          WHEN @HasCapture=1 AND @HasRole=1 AND @HasConfidence=1
          THEN N'Normalize existing RCA_IOStorageEvidence directly into CauseCategory IO_STORAGE_LATENCY. Do not create a second detector.'
          WHEN @HasCapture=1
          THEN N'Existing evidence can be integrated, but Script 70 must derive normalization only from persisted fields already produced by the I/O builder. Do not invent detector thresholds in the presentation layer.'
          ELSE N'I/O evidence schema is not yet suitable for normalized arbitration; review before proceeding.'
        END
    , NextStep=
        N'Use the exact schema and builder output from Sections 1, 3, 8, 9, 10, and 11 to build Script 70 safely.';
GO


/*==============================================================================
  17. SAFETY
==============================================================================*/
SELECT
      ValidationSection='17 - SCRIPT 69 SAFETY'
    , ReadOnlyDiscovery='YES'
    , IOEvidenceModified='NO'
    , IOBuilderModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NormalizedRankingChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
