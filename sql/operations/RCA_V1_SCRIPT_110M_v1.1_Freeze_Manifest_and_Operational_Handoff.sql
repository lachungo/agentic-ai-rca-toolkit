USE dbamaint;
GO
/*==============================================================================
 RCA V1
 SCRIPT 110M v1.1

 FREEZE MANIFEST AND OPERATIONAL HANDOFF

 PREREQUISITE
 ------------
 SCRIPT 110L v1.3 completed with PASS on 2026-08-23.

 PURPOSE
 -------
 Produce the read-only closure record for the certified RCA V1 deployment:
   * required-object inventory;
   * SHA-256 definitions for the 12 frozen programmable objects;
   * certified seven-domain and cross-domain topology record;
   * analyzer and DBA-answer consumer contract verification;
   * current repository operational snapshot.

 v1.1 CORRECTION
 ---------------
 v1.0 tested the canonical-summary and final-view relationship with literal
 procedure-definition text. The certified implementation is a transitive SQL
 dependency path. v1.1 uses sys.sql_expression_dependencies recursively, which
 is the same consumer-path contract certified by SCRIPT 110K and SCRIPT 110L.

 SAFETY
 ------
 This script performs SELECT operations only. It creates no permanent or
 temporary objects, starts no transaction, and changes no RCA data or code.
==============================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
      @ScriptName varchar(30)='SCRIPT 110M'
    , @ScriptVersion varchar(10)='1.1'
    , @StartUTC datetime2(3)=SYSUTCDATETIME()
    , @AnalyzerDef nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P'))
    , @AnswerDef nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P'))
    , @NormalizedDef nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V'))
    , @FinalDef nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V'))
    , @SummaryDef nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V'));

DECLARE @RequiredObjects TABLE
(
      ObjectOrder int NOT NULL PRIMARY KEY
    , ObjectName sysname NOT NULL
    , ExpectedType char(1) NOT NULL
);

INSERT @RequiredObjects(ObjectOrder,ObjectName,ExpectedType)
VALUES
 (1, 'dbo.RCA_CaptureRun',                       'U'),
 (2, 'dbo.RCA_IOFileSnapshot',                   'U'),
 (3, 'dbo.RCA_ServerSnapshot',                   'U'),
 (4, 'dbo.RCA_TempDBSnapshot',                   'U'),
 (5, 'dbo.RCA_LogSnapshot',                      'U'),
 (6, 'dbo.RCA_ConnectivitySnapshot',             'U'),
 (7, 'dbo.RCA_CPUSchedulerEvidence',             'U'),
 (8, 'dbo.RCA_BlockingEvidence',                 'U'),
 (9, 'dbo.RCA_IOStorageEvidence',                'U'),
 (10,'dbo.RCA_MemoryPressureEvidence',           'U'),
 (11,'dbo.RCA_TempDBEvidence',                   'U'),
 (12,'dbo.RCA_TransactionLogEvidence',           'U'),
 (13,'dbo.RCA_ConnectivityEvidence',             'U'),
 (14,'dbo.usp_RCA_BuildCPUSchedulerEvidence',    'P'),
 (15,'dbo.usp_RCA_BuildBlockingEvidence',        'P'),
 (16,'dbo.usp_RCA_BuildIOStorageEvidence',       'P'),
 (17,'dbo.usp_RCA_BuildMemoryPressureEvidence',  'P'),
 (18,'dbo.usp_RCA_BuildTempDBEvidence',          'P'),
 (19,'dbo.usp_RCA_BuildTransactionLogEvidence',  'P'),
 (20,'dbo.usp_RCA_BuildConnectivityEvidence',    'P'),
 (21,'dbo.usp_RCA_AnalyzeCaptureRun',             'P'),
 (22,'dbo.vw_RCA_NormalizedCauseCandidates',     'V'),
 (23,'dbo.vw_RCA_FinalCauseCandidates',          'V'),
 (24,'dbo.vw_RCA_CrossDomainCauseSummary',       'V'),
 (25,'dbo.usp_RCA_DBAAnswer',                    'P');

DECLARE @Domains TABLE
(
      DomainOrder int NOT NULL PRIMARY KEY
    , DomainKey varchar(80) NOT NULL
    , BuilderProcedure sysname NOT NULL
    , EvidenceObject sysname NOT NULL
);

INSERT @Domains(DomainOrder,DomainKey,BuilderProcedure,EvidenceObject)
VALUES
 (1,'CPU_SCHEDULER',            'usp_RCA_BuildCPUSchedulerEvidence',    'RCA_CPUSchedulerEvidence'),
 (2,'BLOCKING_WAIT_CHAIN',      'usp_RCA_BuildBlockingEvidence',       'RCA_BlockingEvidence'),
 (3,'IO_STORAGE_LATENCY',       'usp_RCA_BuildIOStorageEvidence',      'RCA_IOStorageEvidence'),
 (4,'MEMORY_PRESSURE',          'usp_RCA_BuildMemoryPressureEvidence', 'RCA_MemoryPressureEvidence'),
 (5,'TEMPDB_PRESSURE',          'usp_RCA_BuildTempDBEvidence',         'RCA_TempDBEvidence'),
 (6,'TRANSACTION_LOG_PRESSURE', 'usp_RCA_BuildTransactionLogEvidence','RCA_TransactionLogEvidence'),
 (7,'CONNECTIVITY_PRESSURE',    'usp_RCA_BuildConnectivityEvidence',   'RCA_ConnectivityEvidence');

DECLARE @Topology TABLE
(
      EdgeOrder int NOT NULL PRIMARY KEY
    , UpstreamDomain varchar(80) NOT NULL
    , DownstreamDomain varchar(80) NOT NULL
    , RelationshipClassification varchar(30) NOT NULL
    , CertificationSource varchar(30) NOT NULL
);

INSERT @Topology
VALUES
 (1,'CPU_SCHEDULER',       'IO_STORAGE_LATENCY','CERTIFIED_CAUSAL','SCRIPT 109B'),
 (2,'BLOCKING_WAIT_CHAIN', 'IO_STORAGE_LATENCY','CERTIFIED_CAUSAL','SCRIPT 110B'),
 (3,'CPU_SCHEDULER',       'MEMORY_PRESSURE',   'CERTIFIED_CAUSAL','SCRIPT 110C'),
 (4,'BLOCKING_WAIT_CHAIN', 'MEMORY_PRESSURE',   'CERTIFIED_CAUSAL','SCRIPT 110D'),
 (5,'CPU_SCHEDULER',       'TEMPDB_PRESSURE',   'CERTIFIED_CAUSAL','SCRIPT 110E'),
 (6,'BLOCKING_WAIT_CHAIN', 'TEMPDB_PRESSURE',   'CERTIFIED_CAUSAL','SCRIPT 110F'),
 (7,'IO_STORAGE_LATENCY',  'TEMPDB_PRESSURE',   'REFERENCE_ONLY',  'SCRIPT 110G1');

DECLARE
      @AnswerObjectID int=OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P')
    , @FinalObjectID int=OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V')
    , @SummaryObjectID int=OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V')
    , @AnswerReferencesSummary bit=0
    , @AnswerReferencesFinalTransitive bit=0
    , @ObjectGate varchar(10)='FAIL'
    , @BuilderGate varchar(10)='FAIL'
    , @ArbitrationGate varchar(10)='FAIL'
    , @ConsumerGate varchar(10)='FAIL';

DECLARE @DependencyPath TABLE
(
      Depth int NOT NULL
    , ReferencingObjectID int NOT NULL
    , ReferencedObjectID int NULL
    , ReferencedEntityName sysname NULL
    , ObjectPath nvarchar(max) NULL
);

;WITH DependencyTree AS
(
    SELECT
          1 AS Depth
        , d.referencing_id AS ReferencingObjectID
        , d.referenced_id AS ReferencedObjectID
        , d.referenced_entity_name AS ReferencedEntityName
        , CONVERT
          (
              nvarchar(max),
              N'|'+CONVERT(nvarchar(20),d.referencing_id)+N'|'
              +COALESCE(CONVERT(nvarchar(20),d.referenced_id),N'NULL')+N'|'
          ) AS ObjectPath
    FROM sys.sql_expression_dependencies AS d
    WHERE d.referencing_id=@AnswerObjectID

    UNION ALL

    SELECT
          t.Depth+1
        , d.referencing_id
        , d.referenced_id
        , d.referenced_entity_name
        , CONVERT
          (
              nvarchar(max),
              t.ObjectPath+COALESCE(CONVERT(nvarchar(20),d.referenced_id),N'NULL')+N'|'
          )
    FROM DependencyTree AS t
    JOIN sys.sql_expression_dependencies AS d
      ON d.referencing_id=t.ReferencedObjectID
    WHERE t.Depth<16
      AND
      (
          d.referenced_id IS NULL
          OR CHARINDEX(N'|'+CONVERT(nvarchar(20),d.referenced_id)+N'|',t.ObjectPath)=0
      )
)
INSERT @DependencyPath
SELECT Depth,ReferencingObjectID,ReferencedObjectID,ReferencedEntityName,ObjectPath
FROM DependencyTree
OPTION (MAXRECURSION 32);

SET @AnswerReferencesSummary=
    CASE WHEN EXISTS
    (
        SELECT 1
        FROM @DependencyPath
        WHERE ReferencedObjectID=@SummaryObjectID
           OR ReferencedEntityName=N'vw_RCA_CrossDomainCauseSummary'
    ) THEN 1 ELSE 0 END;

SET @AnswerReferencesFinalTransitive=
    CASE WHEN EXISTS
    (
        SELECT 1
        FROM @DependencyPath
        WHERE ReferencedObjectID=@FinalObjectID
           OR ReferencedEntityName=N'vw_RCA_FinalCauseCandidates'
    ) THEN 1 ELSE 0 END;

SET @ObjectGate=CASE WHEN NOT EXISTS
(
    SELECT 1 FROM @RequiredObjects
    WHERE OBJECT_ID(ObjectName,ExpectedType) IS NULL
) THEN 'PASS' ELSE 'FAIL' END;

SET @BuilderGate=CASE WHEN @AnalyzerDef IS NOT NULL AND NOT EXISTS
(
    SELECT 1 FROM @Domains
    WHERE CHARINDEX(BuilderProcedure,@AnalyzerDef)=0
) THEN 'PASS' ELSE 'FAIL' END;

SET @ArbitrationGate=CASE
    WHEN @NormalizedDef LIKE '%RootCauseRole%'
     AND @NormalizedDef LIKE '%Confidence%'
     AND @NormalizedDef LIKE '%PriorityScore%'
     AND @FinalDef LIKE '%RootCauseRole%'
     AND @FinalDef LIKE '%Confidence%'
     AND @FinalDef LIKE '%PRIMARY%'
     AND @FinalDef LIKE '%CONTRIBUTING%'
    THEN 'PASS' ELSE 'FAIL' END;

SET @ConsumerGate=CASE
    WHEN EXISTS
         (
             SELECT 1
             FROM sys.parameters
             WHERE object_id=@AnswerObjectID
               AND name=N'@CaptureRunID'
         )
     AND @AnswerDef LIKE '%PRIMARY%'
     AND @AnswerDef LIKE '%Confidence%'
     AND @AnswerReferencesSummary=1
     AND @AnswerReferencesFinalTransitive=1
    THEN 'PASS' ELSE 'FAIL' END;

SELECT
      '0 - RCA V1 FREEZE HANDOFF ENVIRONMENT' AS ValidationSection
    , @ScriptName AS ScriptName
    , @ScriptVersion AS ScriptVersion
    , @@SERVERNAME AS ServerName
    , DB_NAME() AS RepositoryDatabase
    , @StartUTC AS StartUTC
    , 'READ ONLY' AS SafetyClassification;

SELECT
      '1 - REQUIRED OBJECT INVENTORY' AS ValidationSection
    , r.ObjectOrder
    , r.ObjectName
    , r.ExpectedType
    , OBJECT_ID(r.ObjectName,r.ExpectedType) AS ObjectID
    , CASE WHEN OBJECT_ID(r.ObjectName,r.ExpectedType) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS ObjectGate
FROM @RequiredObjects AS r
ORDER BY r.ObjectOrder;

SELECT
      '2 - CERTIFIED DOMAIN CONTRACT' AS ValidationSection
    , d.DomainOrder
    , d.DomainKey
    , d.BuilderProcedure
    , d.EvidenceObject
    , CHARINDEX(d.BuilderProcedure,@AnalyzerDef) AS AnalyzerInvocationPosition
    , CASE WHEN CHARINDEX(d.BuilderProcedure,@AnalyzerDef)>0 THEN 'PASS' ELSE 'FAIL' END AS BuilderInvocationGate
FROM @Domains AS d
ORDER BY d.DomainOrder;

SELECT
      '3 - CERTIFIED CROSS DOMAIN TOPOLOGY' AS ValidationSection
    , *
FROM @Topology
ORDER BY EdgeOrder;

SELECT
      '4 - RCA V1 PROGRAMMABLE OBJECT FREEZE MANIFEST' AS ValidationSection
    , o.object_id AS ObjectID
    , QUOTENAME(OBJECT_SCHEMA_NAME(o.object_id))+N'.'+QUOTENAME(o.name) AS ObjectName
    , o.type_desc AS ObjectType
    , o.create_date AS CreateDate
    , o.modify_date AS ModifyDate
    , LEN(sm.definition) AS DefinitionLength
    , CONVERT(varchar(64),HASHBYTES('SHA2_256',CONVERT(varbinary(max),sm.definition)),2) AS DefinitionSHA256
FROM sys.objects AS o
JOIN sys.sql_modules AS sm
  ON sm.object_id=o.object_id
WHERE o.object_id IN
(
      OBJECT_ID(N'dbo.usp_RCA_BuildCPUSchedulerEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_BuildMemoryPressureEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_BuildTempDBEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_BuildTransactionLogEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_BuildConnectivityEvidence',N'P')
    , OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P')
    , OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V')
    , OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V')
    , OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V')
    , OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P')
)
ORDER BY ObjectName;

SELECT TOP (20)
      '5 - CURRENT OPERATIONAL CAPTURE SNAPSHOT' AS ValidationSection
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
FROM dbo.RCA_CaptureRun
ORDER BY CaptureRunID DESC;

SELECT
      '6 - RCA V1 FREEZE HANDOFF VERDICT' AS ValidationSection
    , CASE
          WHEN @ObjectGate='PASS'
           AND @BuilderGate='PASS'
           AND @ArbitrationGate='PASS'
           AND @ConsumerGate='PASS'
          THEN 'PASS' ELSE 'FAIL'
      END AS Result
    , @ObjectGate AS RequiredObjectGate
    , @BuilderGate AS SevenBuilderInvocationGate
    , @ArbitrationGate AS DeterministicArbitrationContractGate
    , @ConsumerGate AS DBAAnswerConsumerContractGate
    , @AnswerReferencesSummary AS CrossDomainSummaryReference
    , @AnswerReferencesFinalTransitive AS TransitiveFinalCauseReference
    , 7 AS CertifiedDomainCount
    , (SELECT COUNT(*) FROM @Topology WHERE RelationshipClassification='CERTIFIED_CAUSAL') AS CertifiedCausalEdgeCount
    , (SELECT COUNT(*) FROM @Topology WHERE RelationshipClassification='REFERENCE_ONLY') AS ReferenceOnlyRelationshipCount
    , 'CANONICAL SUMMARY -> FINAL TRANSITIVE PATH' AS CertifiedDBAAnswerConsumerPath
    , 'SCRIPT 110L v1.3 PASS' AS ReleaseCertificationBasis
    , 'RCA V1 FROZEN' AS ReleaseState;
GO
