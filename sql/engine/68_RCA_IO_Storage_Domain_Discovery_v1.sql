USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  68_RCA_IO_Storage_Domain_Discovery_v1.sql

  PURPOSE
  -------
  Read-only discovery for the next RCA root-cause domain: I/O / storage latency.

  We are NOT implementing a detector yet. This script establishes:
    - what persisted I/O evidence already exists,
    - what capture/run tables expose I/O-related columns,
    - what procedures/views already reference I/O concepts,
    - whether the normalized arbitration layer already knows an I/O category,
    - what server/database-file evidence can safely support a future detector.

  ARCHITECTURAL RULE
  ------------------
  Scripts 63-67 are frozen.
  The new domain must plug into the normalized cross-domain contract rather than
  add new IF/ELSE priority logic inside dbo.usp_RCA_DBAAnswer.

  SAFETY
  ------
  Read-only discovery. No evidence, synthesis, findings, thresholds, routing,
  historical captures, or canonical answers are modified.
==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 68 PRE-FLIGHT'
    , CaptureRun=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExecutionEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , NormalizedCauseCandidates=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainRanking=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
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
GO


/*==============================================================================
  1. I/O-RELATED RCA OBJECT INVENTORY
==============================================================================*/
SELECT
      DiscoverySection='1 - IO RCA OBJECT INVENTORY'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ObjectName=o.name
    , ObjectType=o.type_desc
    , CreateDate=o.create_date
    , ModifyDate=o.modify_date
FROM sys.objects AS o
WHERE o.is_ms_shipped=0
  AND
  (
       o.name LIKE N'%IO%'
    OR o.name LIKE N'%Storage%'
    OR o.name LIKE N'%Disk%'
    OR o.name LIKE N'%FileLatency%'
    OR o.name LIKE N'%Latency%'
    OR o.name LIKE N'%PAGEIOLATCH%'
  )
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  2. RCA TABLE COLUMNS THAT MAY ALREADY CONTAIN I/O EVIDENCE
==============================================================================*/
SELECT
      DiscoverySection='2 - IO RELATED RCA COLUMNS'
    , SchemaName=SCHEMA_NAME(t.schema_id)
    , TableName=t.name
    , ColumnID=c.column_id
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
    , MaxLength=c.max_length
    , IsNullable=c.is_nullable
FROM sys.tables AS t
JOIN sys.columns AS c
  ON c.object_id=t.object_id
WHERE t.is_ms_shipped=0
  AND t.name LIKE N'RCA[_]%'
  AND
  (
       c.name LIKE N'%Read%'
    OR c.name LIKE N'%Write%'
    OR c.name LIKE N'%IO%'
    OR c.name LIKE N'%Latency%'
    OR c.name LIKE N'%Stall%'
    OR c.name LIKE N'%File%'
    OR c.name LIKE N'%PAGEIOLATCH%'
    OR c.name LIKE N'%Wait%'
  )
ORDER BY t.name,c.column_id;
GO


/*==============================================================================
  3. EXISTING RCA MODULES THAT REFERENCE I/O / STORAGE CONCEPTS
==============================================================================*/
SELECT
      DiscoverySection='3 - IO MODULE REFERENCES'
    , SchemaName=SCHEMA_NAME(o.schema_id)
    , ObjectName=o.name
    , ObjectType=o.type_desc
    , MentionsPAGEIOLATCH=
        CASE WHEN m.definition LIKE N'%PAGEIOLATCH%' THEN 'YES' ELSE 'NO' END
    , MentionsVirtualFileStats=
        CASE WHEN m.definition LIKE N'%dm_io_virtual_file_stats%' THEN 'YES' ELSE 'NO' END
    , MentionsIOStall=
        CASE WHEN m.definition LIKE N'%io_stall%' THEN 'YES' ELSE 'NO' END
    , MentionsPhysicalReads=
        CASE WHEN m.definition LIKE N'%PhysicalReads%' THEN 'YES' ELSE 'NO' END
    , MentionsReads=
        CASE WHEN m.definition LIKE N'%LogicalReads%'
               OR m.definition LIKE N'%Reads%'
             THEN 'YES' ELSE 'NO' END
    , MentionsWrites=
        CASE WHEN m.definition LIKE N'%Writes%' THEN 'YES' ELSE 'NO' END
    , MentionsStorage=
        CASE WHEN m.definition LIKE N'%Storage%'
               OR m.definition LIKE N'%Disk%'
             THEN 'YES' ELSE 'NO' END
FROM sys.objects AS o
JOIN sys.sql_modules AS m
  ON m.object_id=o.object_id
WHERE o.is_ms_shipped=0
  AND
  (
       m.definition LIKE N'%PAGEIOLATCH%'
    OR m.definition LIKE N'%dm_io_virtual_file_stats%'
    OR m.definition LIKE N'%io_stall%'
    OR m.definition LIKE N'%PhysicalReads%'
    OR m.definition LIKE N'%LogicalReads%'
    OR m.definition LIKE N'%Writes%'
    OR m.definition LIKE N'%Storage%'
  )
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  4. EXISTING NORMALIZED CAUSE CATEGORIES
==============================================================================*/
IF OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
BEGIN
    SELECT
          DiscoverySection='4 - NORMALIZED CAUSE CATEGORIES'
        , CauseCategory
        , CauseDisplayName
        , RootCauseRole
        , Confidence
        , CandidateRows=COUNT_BIG(*)
        , DistinctCaptures=COUNT_BIG(DISTINCT CaptureRunID)
    FROM dbo.vw_RCA_NormalizedCauseCandidates
    GROUP BY
          CauseCategory
        , CauseDisplayName
        , RootCauseRole
        , Confidence
    ORDER BY CauseCategory,RootCauseRole,Confidence;
END;
GO


/*==============================================================================
  5. DOES NORMALIZATION ALREADY REFERENCE AN I/O DOMAIN?
==============================================================================*/
DECLARE @NormalizedDefinition nvarchar(max)=
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates'));

SELECT
      ValidationSection='5 - IO NORMALIZATION GAP'
    , MentionsIOCategory=
        CASE WHEN @NormalizedDefinition LIKE N'%IO[_]STORAGE%'
               OR @NormalizedDefinition LIKE N'%STORAGE[_]IO%'
               OR @NormalizedDefinition LIKE N'%IO[_]LATENCY%'
             THEN 'YES' ELSE 'NO' END
    , MentionsPAGEIOLATCH=
        CASE WHEN @NormalizedDefinition LIKE N'%PAGEIOLATCH%'
             THEN 'YES' ELSE 'NO' END
    , Interpretation=
        CASE WHEN @NormalizedDefinition LIKE N'%IO[_]STORAGE%'
               OR @NormalizedDefinition LIKE N'%STORAGE[_]IO%'
               OR @NormalizedDefinition LIKE N'%IO[_]LATENCY%'
             THEN N'An I/O category appears to already exist in normalization; inspect before adding anything.'
             ELSE N'No normalized I/O cause category detected. A future I/O detector will require one new normalized mapping, not a canonical-router rewrite.'
        END;
GO


/*==============================================================================
  6. CURRENT DATABASE FILE I/O BASELINE
  Snapshot only. This is NOT persisted and is NOT root-cause attribution.
==============================================================================*/
IF OBJECT_ID(N'sys.dm_io_virtual_file_stats') IS NOT NULL
BEGIN
    ;WITH VFS AS
    (
        SELECT
              DatabaseID=v.database_id
            , FileID=v.file_id
            , v.num_of_reads
            , v.num_of_bytes_read
            , v.io_stall_read_ms
            , v.num_of_writes
            , v.num_of_bytes_written
            , v.io_stall_write_ms
            , v.io_stall
        FROM sys.dm_io_virtual_file_stats(NULL,NULL) AS v
    )
    SELECT
          DiscoverySection='6 - CURRENT FILE IO BASELINE'
        , DatabaseName=DB_NAME(v.DatabaseID)
        , v.DatabaseID
        , v.FileID
        , FileType=mf.type_desc
        , LogicalFileName=mf.name
        , PhysicalName=mf.physical_name
        , v.num_of_reads
        , ReadMB=CONVERT(decimal(19,2),v.num_of_bytes_read/1048576.0)
        , AvgReadLatencyMs=
            CONVERT(decimal(19,2),
                CASE WHEN v.num_of_reads=0 THEN 0
                     ELSE (1.0*v.io_stall_read_ms)/v.num_of_reads END)
        , v.num_of_writes
        , WrittenMB=CONVERT(decimal(19,2),v.num_of_bytes_written/1048576.0)
        , AvgWriteLatencyMs=
            CONVERT(decimal(19,2),
                CASE WHEN v.num_of_writes=0 THEN 0
                     ELSE (1.0*v.io_stall_write_ms)/v.num_of_writes END)
        , AvgOverallLatencyMs=
            CONVERT(decimal(19,2),
                CASE WHEN v.num_of_reads+v.num_of_writes=0 THEN 0
                     ELSE (1.0*v.io_stall)/(v.num_of_reads+v.num_of_writes) END)
    FROM VFS AS v
    LEFT JOIN sys.master_files AS mf
      ON mf.database_id=v.DatabaseID
     AND mf.file_id=v.FileID
    ORDER BY
        CASE WHEN v.num_of_reads+v.num_of_writes=0 THEN 0
             ELSE (1.0*v.io_stall)/(v.num_of_reads+v.num_of_writes) END DESC,
        DB_NAME(v.DatabaseID),
        v.FileID;
END;
GO


/*==============================================================================
  7. CURRENT I/O-RELATED WAITS
  Snapshot only. Cumulative waits alone must never become root-cause proof.
==============================================================================*/
SELECT
      DiscoverySection='7 - CURRENT IO RELATED WAITS'
    , wait_type
    , waiting_tasks_count
    , wait_time_ms
    , signal_wait_time_ms
    , ResourceWaitMs=wait_time_ms-signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE
       wait_type LIKE N'PAGEIOLATCH[_]%'
    OR wait_type LIKE N'WRITELOG%'
    OR wait_type LIKE N'IO[_]COMPLETION%'
    OR wait_type LIKE N'ASYNC[_]IO[_]COMPLETION%'
    OR wait_type LIKE N'BACKUPIO%'
ORDER BY wait_time_ms DESC;
GO


/*==============================================================================
  8. EXECUTION EVIDENCE I/O SIGNAL AVAILABILITY
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
BEGIN
    DECLARE
          @HasLogicalReads bit =
              CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'LogicalReads') IS NOT NULL
                   THEN 1 ELSE 0 END
        , @HasPhysicalReads bit =
              CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'PhysicalReads') IS NOT NULL
                   THEN 1 ELSE 0 END
        , @HasWrites bit =
              CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'Writes') IS NOT NULL
                   THEN 1 ELSE 0 END;

    SELECT
          ValidationSection='8 - EXECUTION IO SIGNAL AVAILABILITY'
        , LogicalReads=CASE WHEN @HasLogicalReads=1 THEN 'PASS' ELSE 'MISSING' END
        , PhysicalReads=CASE WHEN @HasPhysicalReads=1 THEN 'PASS' ELSE 'MISSING' END
        , Writes=CASE WHEN @HasWrites=1 THEN 'PASS' ELSE 'MISSING' END
        , Interpretation=
            N'Execution-level read/write counters are useful correlation evidence, but do not by themselves prove storage latency.';
END;
GO


/*==============================================================================
  9. CAPTURE 42 / 44 EXECUTION I/O PROFILE
  Dynamic projection avoids assuming all optional columns exist.
==============================================================================*/
DECLARE @Projection nvarchar(max)=
      N'SELECT '
    + N'DiscoverySection=N''9 - CONTROL CAPTURE IO PROFILE'','
    + N'CaptureRunID,ExecutionEvidenceID,SessionID,DatabaseName'
    + CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'CPUms') IS NOT NULL
           THEN N',CPUms' ELSE N'' END
    + CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'DurationMs') IS NOT NULL
           THEN N',DurationMs' ELSE N'' END
    + CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'LogicalReads') IS NOT NULL
           THEN N',LogicalReads' ELSE N'' END
    + CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'PhysicalReads') IS NOT NULL
           THEN N',PhysicalReads' ELSE N'' END
    + CASE WHEN COL_LENGTH(N'dbo.RCA_ExecutionEvidence',N'Writes') IS NOT NULL
           THEN N',Writes' ELSE N'' END
    + N' FROM dbo.RCA_ExecutionEvidence'
    + N' WHERE CaptureRunID IN (42,44)'
    + N' ORDER BY CaptureRunID,ExecutionEvidenceID;';

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
    EXEC sys.sp_executesql @Projection;
GO


/*==============================================================================
  10. EXISTING SERVER SNAPSHOT / CAPTURE TABLES THAT COULD SUPPORT DELTAS
==============================================================================*/
SELECT
      DiscoverySection='10 - IO SNAPSHOT CANDIDATE TABLES'
    , SchemaName=SCHEMA_NAME(t.schema_id)
    , TableName=t.name
    , HasCaptureRunID=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id=t.object_id
              AND c.name=N'CaptureRunID'
        ) THEN 'YES' ELSE 'NO' END
    , HasCaptureTime=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id=t.object_id
              AND
              (
                   c.name LIKE N'%CaptureTime%'
                OR c.name LIKE N'%SampleTime%'
                OR c.name LIKE N'%CreatedTime%'
              )
        ) THEN 'YES' ELSE 'NO' END
    , HasIOSignal=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id=t.object_id
              AND
              (
                   c.name LIKE N'%Read%'
                OR c.name LIKE N'%Write%'
                OR c.name LIKE N'%IO%'
                OR c.name LIKE N'%Latency%'
                OR c.name LIKE N'%Stall%'
              )
        ) THEN 'YES' ELSE 'NO' END
FROM sys.tables AS t
WHERE t.is_ms_shipped=0
  AND t.name LIKE N'RCA[_]%'
ORDER BY t.name;
GO


/*==============================================================================
  11. PROPOSED I/O DOMAIN CONTRACT
  This is design output only -- no objects are created.
==============================================================================*/
SELECT
      DiscoverySection='11 - PROPOSED IO DOMAIN CONTRACT'
    , ProposedCauseCategory='IO_STORAGE_LATENCY'
    , ProposedDisplayName='I/O / storage latency'
    , ProposedEvidenceObject='RCA_IOStorageEvidence'
    , RequiredCorrelation=
        'CaptureRunID + database/file + time-window + affected execution/session where available'
    , PrimaryEvidenceRequirement=
        'Persisted interval/delta evidence showing material file I/O latency or I/O wait pressure during the incident window'
    , ContributingEvidence=
        'Execution physical reads/writes, PAGEIOLATCH/WRITELOG/IO_COMPLETION signals, file-level latency, affected database/file'
    , MustNotUseAsSoleProof=
        'Single cumulative dm_io_virtual_file_stats snapshot, cumulative wait stats, logical reads alone, or generic disk assumptions'
    , ArbitrationIntegration=
        'Add IO_STORAGE_LATENCY to normalized cause candidates; existing cross-domain ranking/summary should arbitrate it'
    , CanonicalRouterChangeExpected=
        'Narrator plug-in only; no detector-specific priority IF/ELSE should be added';
GO


/*==============================================================================
  12. DISCOVERY ACCEPTANCE
==============================================================================*/
DECLARE
      @NormalizedDefinition2 nvarchar(max)=
          OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates'))
    , @CanonicalDefinition nvarchar(max)=
          OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer'));

SELECT
      ValidationSection='12 - SCRIPT 68 DISCOVERY ACCEPTANCE'
    , NormalizedContractPresent=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainArbitrationPresent=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
              AND OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingIOCategory=
        CASE WHEN @NormalizedDefinition2 LIKE N'%IO[_]STORAGE%'
               OR @NormalizedDefinition2 LIKE N'%STORAGE[_]IO%'
               OR @NormalizedDefinition2 LIKE N'%IO[_]LATENCY%'
             THEN 'YES' ELSE 'NO' END
    , CanonicalStillUsesArbitration=
        CASE WHEN @CanonicalDefinition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS' ELSE 'FAIL' END
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO'
    , OverallResult=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V') IS NOT NULL
               AND OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseRanking',N'V') IS NOT NULL
               AND OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL
               AND @CanonicalDefinition LIKE N'%vw_RCA_CrossDomainCauseSummary%'
             THEN 'PASS - READY TO DESIGN IO / STORAGE LATENCY EVIDENCE'
             ELSE 'REVIEW - REQUIRED ARBITRATION DEPENDENCIES ARE MISSING'
        END
    , NextStep=
        N'Use this discovery output to design Script 69. Do not choose latency thresholds until we know which persisted interval/delta signals already exist.';
GO


/*==============================================================================
  13. SAFETY
==============================================================================*/
SELECT
      ValidationSection='13 - SCRIPT 68 SAFETY'
    , ReadOnlyDiscovery='YES'
    , Capture38Modified='NO'
    , Capture42Modified='NO'
    , Capture44Modified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , ManualCauseInserted='NO'
    , NewCaptureStarted='NO';
GO
