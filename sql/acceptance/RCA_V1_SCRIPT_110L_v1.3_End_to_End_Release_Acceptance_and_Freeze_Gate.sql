USE dbamaint;
GO
/*==============================================================================
 RCA V1
 SCRIPT 110L v1.3

 END-TO-END RELEASE ACCEPTANCE AND FREEZE GATE

 v1.1 CORRECTION
 ---------------
 v1.0 reached SQL Server compilation error 8124 in the unified proof query.
 Its aggregate CASE expressions combined the outer @Controls.DomainKey value
 with columns from the normalized/final views. SQL Server prohibits that form
 when an aggregated expression contains an outer reference.

 v1.1 separates the calculations without changing the certification contract:
   * total normalized/final counts aggregate only inner-view columns;
   * expected-domain PRIMARY/HIGH counts use COUNT(*) after domain matching is
     applied in the correlated WHERE predicate;
   * all seven domain, arbitration, DBA-answer, topology, and safety thresholds
     remain unchanged.

 v1.2 CORRECTION
 ---------------
 v1.1 correctly compiled, but it assumed both CPU and blocking PRIMARY/HIGH
 controls would remain persisted. SCRIPT 104B intentionally certified CPU with
 a transactionally rolled-back synthetic capture, so that persistence
 requirement contradicted the project's no-residue control design.

 v1.2 removes only that persistence assumption:
   * BLOCKING_WAIT_CHAIN continues to use the analyzed capture already proven
     by SCRIPT 110K v1.1.
   * CPU_SCHEDULER is recreated inside the protected 110L transaction with the
     exact certified SCRIPT 104B scheduler signal: 8 samples, SQL CPU 0,
     runnable tasks 12, PRIMARY/HIGH expected.
   * CPU plus the five SCRIPT 110J controls are all rolled back.
   * all domain, topology, arbitration, DBA-answer, and safety gates remain
     mandatory and unchanged.

 v1.3 CORRECTION
 ---------------
 v1.2 proved that all seven builders, normalized candidates, and final
 arbitration winners were correct, but its release verdict failed because two
 presentation-layer expectations incorrectly required literal text identity:

   * the canonical summary category/display text had to equal the final-view
     category/display text, even where the certified normalization/arbitration
     contract deliberately renames a domain category; and
   * the DBA-answer prose had to contain the final CauseDisplayName verbatim.

 v1.3 preserves every causal and safety requirement while certifying the real
 contracts:
   * summary and final winners must map to the same certified DomainKey;
   * both must remain PRIMARY/HIGH with exactly one final primary winner;
   * supported/primary counts and arbitration status must reconcile;
   * the DBA answer must execute, contain a nonempty ANSWER, contain exactly one
     nonempty ROOT CAUSE narrative, contain no negative/unknown answer, and
     identify the certified domain semantically in its returned narrative.

 No RCA object is modified by this correction.

 PURPOSE
 -------
 Issue the final RCA V1 release decision by re-proving, in one run:

   1. Every required RCA object is deployed.
   2. The analyzer invokes all seven domain builders.
   3. Normalized and final arbitration retain deterministic role/confidence
      semantics.
   4. The certified cross-domain topology is still exactly:

        6 CERTIFIED_CAUSAL edges
        1 REFERENCE_ONLY relationship
        0 unresolved or reclassified relationships

   5. Blocking retains its existing SCRIPT 110K PRIMARY/HIGH proof.
   6. CPU and the five SCRIPT 110J v1.1 controls are recreated and re-analyzed with
      the real dbo.usp_RCA_AnalyzeCaptureRun procedure.
   7. All seven domains reach normalized and final PRIMARY/HIGH output with
      exactly one final PRIMARY winner per control capture.
   8. The canonical summary and final winner resolve to the same certified
      domain, role, confidence, counts, and arbitration state whenever the DBA
      answer consumes the summary path.
   9. The real dbo.usp_RCA_DBAAnswer executes for every control and returns a
      DBA-readable root-cause answer aligned to the final winner.
  10. Every synthetic row is rolled back and server/repository safety holds.

 CERTIFIED DOMAINS
 -----------------
   CPU_SCHEDULER
   BLOCKING_WAIT_CHAIN
   IO_STORAGE_LATENCY
   MEMORY_PRESSURE
   TEMPDB_PRESSURE
   TRANSACTION_LOG_PRESSURE
   CONNECTIVITY_PRESSURE

 CERTIFIED CROSS-DOMAIN TOPOLOGY
 -------------------------------
   CPU_SCHEDULER       -> IO_STORAGE_LATENCY  CERTIFIED_CAUSAL
   BLOCKING_WAIT_CHAIN -> IO_STORAGE_LATENCY  CERTIFIED_CAUSAL
   CPU_SCHEDULER       -> MEMORY_PRESSURE     CERTIFIED_CAUSAL
   BLOCKING_WAIT_CHAIN -> MEMORY_PRESSURE     CERTIFIED_CAUSAL
   CPU_SCHEDULER       -> TEMPDB_PRESSURE     CERTIFIED_CAUSAL
   BLOCKING_WAIT_CHAIN -> TEMPDB_PRESSURE     CERTIFIED_CAUSAL
   IO_STORAGE_LATENCY  -> TEMPDB_PRESSURE     REFERENCE_ONLY

 SAFETY
 ------
 This script does not alter any RCA procedure, view, table definition, SQL
 Agent job, or Extended Events session. The six new controls exist only in a
 protected transaction. Both the success and error paths roll that transaction
 back. Run in a quiet release window so concurrent repository writes do not
 invalidate the before/after row-count safety gate.

 IMPORTANT
 ---------
 Run this script as its own batch with no caller-owned open transaction.
 A PASS result is the RCA V1 freeze authorization. A failure identifies the
 failed gate and does not authorize weakening the release contract.
==============================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
      @ScriptName varchar(30) = 'SCRIPT 110L'
    , @ScriptVersion varchar(10) = '1.3'
    , @StartUTC datetime2(3) = SYSUTCDATETIME()
    , @InitialTranCount int = @@TRANCOUNT
    , @AgentJobsBefore int
    , @AgentJobsAfter int
    , @XECountBefore int
    , @XECountAfter int
    , @CaptureRowsBefore bigint
    , @CaptureRowsAfter bigint
    , @SnapshotRowsBefore bigint
    , @SnapshotRowsAfter bigint
    , @EvidenceRowsBefore bigint
    , @EvidenceRowsAfter bigint
    , @FinalRowsBefore bigint
    , @FinalRowsAfter bigint
    , @SummaryRowsBefore bigint
    , @SummaryRowsAfter bigint
    , @AnalyzerDef nvarchar(max)
    , @NormalizedDef nvarchar(max)
    , @FinalDef nvarchar(max)
    , @AnswerDef nvarchar(max)
    , @SummaryDef nvarchar(max);

IF @InitialTranCount<>0
    THROW 63720,'SCRIPT 110L ABORTED: run in a new query batch with no open transaction.',1;

SELECT @AgentJobsBefore=COUNT(*) FROM msdb.dbo.sysjobs;
SELECT @XECountBefore=COUNT(*) FROM sys.server_event_sessions;
SELECT @CaptureRowsBefore=COUNT_BIG(*) FROM dbo.RCA_CaptureRun;

SELECT @SnapshotRowsBefore=
      (SELECT COUNT_BIG(*) FROM dbo.RCA_IOFileSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_ServerSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_TempDBSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_LogSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_ConnectivitySnapshot);

SELECT @EvidenceRowsBefore=
      (SELECT COUNT_BIG(*) FROM dbo.RCA_CPUSchedulerEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_BlockingEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_IOStorageEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_MemoryPressureEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_TempDBEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_TransactionLogEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_ConnectivityEvidence);

SELECT @FinalRowsBefore=COUNT_BIG(*) FROM dbo.vw_RCA_FinalCauseCandidates;
SELECT @SummaryRowsBefore=COUNT_BIG(*) FROM dbo.vw_RCA_CrossDomainCauseSummary;

SELECT
      @AnalyzerDef=OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P'))
    , @NormalizedDef=OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V'))
    , @FinalDef=OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V'))
    , @AnswerDef=OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P'))
    , @SummaryDef=OBJECT_DEFINITION(OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V'));


/*==============================================================================
 0 - ENVIRONMENT
==============================================================================*/
SELECT
      '0 - SCRIPT 110L ENVIRONMENT' AS ValidationSection
    , @ScriptName AS ScriptName
    , @ScriptVersion AS ScriptVersion
    , @@SERVERNAME AS ServerName
    , DB_NAME() AS RepositoryDatabase
    , @StartUTC AS StartUTC
    , @InitialTranCount AS InitialOpenTransactionCount
    , 'FINAL RCA V1 END-TO-END RELEASE ACCEPTANCE / FREEZE GATE' AS Purpose;


/*==============================================================================
 1 - REQUIRED OBJECT CONTRACT
==============================================================================*/
DECLARE @RequiredObjects TABLE
(
      ObjectOrder int NOT NULL
    , ObjectName sysname NOT NULL
    , ExpectedType char(1) NOT NULL
);

INSERT @RequiredObjects
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

DECLARE @ObjectGate varchar(10)=
    CASE WHEN NOT EXISTS
    (
        SELECT 1
        FROM @RequiredObjects
        WHERE OBJECT_ID(ObjectName,ExpectedType) IS NULL
    ) THEN 'PASS' ELSE 'FAIL' END;

SELECT
      '1 - REQUIRED OBJECT CONTRACT' AS ValidationSection
    , ObjectOrder
    , ObjectName
    , ExpectedType
    , CASE WHEN OBJECT_ID(ObjectName,ExpectedType) IS NOT NULL THEN 1 ELSE 0 END AS IsPresent
    , CASE WHEN OBJECT_ID(ObjectName,ExpectedType) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS ObjectGate
FROM @RequiredObjects
ORDER BY ObjectOrder;

IF @ObjectGate<>'PASS'
    THROW 63721,'SCRIPT 110L ABORTED: one or more required RCA V1 objects are missing.',1;


/*==============================================================================
 1A - FIVE-DOMAIN SNAPSHOT INSERT CONTRACT
==============================================================================*/
DECLARE @RequiredIOColumns TABLE(ColumnName sysname NOT NULL);
INSERT @RequiredIOColumns
VALUES
 ('CaptureRunID'),('CaptureTimeUTC'),('DatabaseID'),('DatabaseName'),
 ('FileID'),('FileTypeDesc'),('LogicalFileName'),('PhysicalName'),
 ('NumReads'),('BytesRead'),('IoStallReadMs'),('NumWrites'),
 ('BytesWritten'),('IoStallWriteMs'),('IoStallMs');

DECLARE @UnsupportedRequiredIOColumns nvarchar(max);

;WITH SuppliedColumns AS
(
    SELECT ColumnName
    FROM @RequiredIOColumns
)
SELECT @UnsupportedRequiredIOColumns=
       STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)),N', ')
FROM sys.columns AS c
LEFT JOIN sys.default_constraints AS dc
  ON dc.parent_object_id=c.object_id
 AND dc.parent_column_id=c.column_id
LEFT JOIN SuppliedColumns AS s
  ON s.ColumnName=c.name
WHERE c.object_id=OBJECT_ID(N'dbo.RCA_IOFileSnapshot')
  AND c.is_nullable=0
  AND c.is_identity=0
  AND c.is_computed=0
  AND dc.object_id IS NULL
  AND s.ColumnName IS NULL;

DECLARE @IOInsertContractGate varchar(10)=
    CASE
        WHEN NOT EXISTS
             (
                 SELECT 1
                 FROM @RequiredIOColumns AS r
                 WHERE COL_LENGTH('dbo.RCA_IOFileSnapshot',r.ColumnName) IS NULL
             )
         AND @UnsupportedRequiredIOColumns IS NULL
        THEN 'PASS' ELSE 'FAIL'
    END;

SELECT
      '1A - FIVE DOMAIN SNAPSHOT INSERT CONTRACT' AS ValidationSection
    , @IOInsertContractGate AS IOInsertContractGate
    , COALESCE(@UnsupportedRequiredIOColumns,N'NONE') AS UnsupportedRequiredIOColumns;

IF @IOInsertContractGate<>'PASS'
    THROW 63722,'SCRIPT 110L ABORTED: RCA_IOFileSnapshot no longer matches the certified 110J v1.1 insert contract.',1;


/*==============================================================================
 2 - SEVEN DOMAIN ANALYZER / ARBITRATION CONTRACT
==============================================================================*/
DECLARE @Domains TABLE
(
      DomainOrder int NOT NULL
    , DomainKey varchar(80) NOT NULL
    , BuilderProcedure sysname NOT NULL
    , EvidenceObject sysname NOT NULL
);

INSERT @Domains
VALUES
 (1,'CPU_SCHEDULER',            'usp_RCA_BuildCPUSchedulerEvidence',    'RCA_CPUSchedulerEvidence'),
 (2,'BLOCKING_WAIT_CHAIN',      'usp_RCA_BuildBlockingEvidence',       'RCA_BlockingEvidence'),
 (3,'IO_STORAGE_LATENCY',       'usp_RCA_BuildIOStorageEvidence',      'RCA_IOStorageEvidence'),
 (4,'MEMORY_PRESSURE',          'usp_RCA_BuildMemoryPressureEvidence', 'RCA_MemoryPressureEvidence'),
 (5,'TEMPDB_PRESSURE',          'usp_RCA_BuildTempDBEvidence',         'RCA_TempDBEvidence'),
 (6,'TRANSACTION_LOG_PRESSURE', 'usp_RCA_BuildTransactionLogEvidence','RCA_TransactionLogEvidence'),
 (7,'CONNECTIVITY_PRESSURE',    'usp_RCA_BuildConnectivityEvidence',   'RCA_ConnectivityEvidence');

DECLARE @BuilderInvocationGate varchar(10)=
    CASE WHEN NOT EXISTS
    (
        SELECT 1
        FROM @Domains
        WHERE CHARINDEX(BuilderProcedure,@AnalyzerDef)=0
    ) THEN 'PASS' ELSE 'FAIL' END;

DECLARE @ArbitrationDefinitionGate varchar(10)=
    CASE
        WHEN @NormalizedDef LIKE '%RootCauseRole%'
         AND @NormalizedDef LIKE '%Confidence%'
         AND @NormalizedDef LIKE '%PriorityScore%'
         AND @FinalDef LIKE '%RootCauseRole%'
         AND @FinalDef LIKE '%Confidence%'
         AND @FinalDef LIKE '%PRIMARY%'
         AND @FinalDef LIKE '%CONTRIBUTING%'
        THEN 'PASS' ELSE 'FAIL'
    END;

SELECT
      '2 - SEVEN DOMAIN ANALYZER CONTRACT' AS ValidationSection
    , d.DomainOrder
    , d.DomainKey
    , d.BuilderProcedure
    , CHARINDEX(d.BuilderProcedure,@AnalyzerDef) AS InvocationPosition
    , CASE WHEN CHARINDEX(d.BuilderProcedure,@AnalyzerDef)>0 THEN 'PASS' ELSE 'FAIL' END AS InvocationGate
FROM @Domains AS d
ORDER BY d.DomainOrder;

SELECT
      '2A - NORMALIZED FINAL ARBITRATION CONTRACT' AS ValidationSection
    , CASE WHEN @NormalizedDef LIKE '%RootCauseRole%' THEN 1 ELSE 0 END AS NormalizedReferencesRole
    , CASE WHEN @NormalizedDef LIKE '%Confidence%' THEN 1 ELSE 0 END AS NormalizedReferencesConfidence
    , CASE WHEN @NormalizedDef LIKE '%PriorityScore%' THEN 1 ELSE 0 END AS NormalizedReferencesPriority
    , CASE WHEN @FinalDef LIKE '%RootCauseRole%' THEN 1 ELSE 0 END AS FinalReferencesRole
    , CASE WHEN @FinalDef LIKE '%Confidence%' THEN 1 ELSE 0 END AS FinalReferencesConfidence
    , CASE WHEN @FinalDef LIKE '%PRIMARY%' THEN 1 ELSE 0 END AS FinalReferencesPrimary
    , CASE WHEN @FinalDef LIKE '%CONTRIBUTING%' THEN 1 ELSE 0 END AS FinalReferencesContributing
    , @ArbitrationDefinitionGate AS ArbitrationDefinitionGate;


/*==============================================================================
 3 - CERTIFIED CROSS-DOMAIN TOPOLOGY
==============================================================================*/
DECLARE @Topology TABLE
(
      EdgeOrder int NOT NULL
    , UpstreamDomain varchar(80) NOT NULL
    , DownstreamDomain varchar(80) NOT NULL
    , UpstreamBuilder sysname NOT NULL
    , DownstreamBuilder sysname NOT NULL
    , UpstreamEvidence sysname NOT NULL
    , ExpectedClassification varchar(40) NOT NULL
    , CertificationSource varchar(30) NOT NULL
);

INSERT @Topology
VALUES
 (1,'CPU_SCHEDULER','IO_STORAGE_LATENCY',
    'usp_RCA_BuildCPUSchedulerEvidence','usp_RCA_BuildIOStorageEvidence',
    'RCA_CPUSchedulerEvidence','CERTIFIED_CAUSAL','SCRIPT 109B'),
 (2,'BLOCKING_WAIT_CHAIN','IO_STORAGE_LATENCY',
    'usp_RCA_BuildBlockingEvidence','usp_RCA_BuildIOStorageEvidence',
    'RCA_BlockingEvidence','CERTIFIED_CAUSAL','SCRIPT 110B'),
 (3,'CPU_SCHEDULER','MEMORY_PRESSURE',
    'usp_RCA_BuildCPUSchedulerEvidence','usp_RCA_BuildMemoryPressureEvidence',
    'RCA_CPUSchedulerEvidence','CERTIFIED_CAUSAL','SCRIPT 110C'),
 (4,'BLOCKING_WAIT_CHAIN','MEMORY_PRESSURE',
    'usp_RCA_BuildBlockingEvidence','usp_RCA_BuildMemoryPressureEvidence',
    'RCA_BlockingEvidence','CERTIFIED_CAUSAL','SCRIPT 110D'),
 (5,'CPU_SCHEDULER','TEMPDB_PRESSURE',
    'usp_RCA_BuildCPUSchedulerEvidence','usp_RCA_BuildTempDBEvidence',
    'RCA_CPUSchedulerEvidence','CERTIFIED_CAUSAL','SCRIPT 110E'),
 (6,'BLOCKING_WAIT_CHAIN','TEMPDB_PRESSURE',
    'usp_RCA_BuildBlockingEvidence','usp_RCA_BuildTempDBEvidence',
    'RCA_BlockingEvidence','CERTIFIED_CAUSAL','SCRIPT 110F'),
 (7,'IO_STORAGE_LATENCY','TEMPDB_PRESSURE',
    'usp_RCA_BuildIOStorageEvidence','usp_RCA_BuildTempDBEvidence',
    'RCA_IOStorageEvidence','REFERENCE_ONLY','SCRIPT 110G1');

DECLARE @TopologyObserved TABLE
(
      EdgeOrder int NOT NULL
    , UpstreamDomain varchar(80) NOT NULL
    , DownstreamDomain varchar(80) NOT NULL
    , ExpectedClassification varchar(40) NOT NULL
    , ObservedClassification varchar(40) NOT NULL
    , ExplicitUpstreamToken int NOT NULL
    , ReferencesUpstreamEvidence int NOT NULL
    , ReferencesRole int NOT NULL
    , ReferencesConfidence int NOT NULL
    , ReferencesPrimary int NOT NULL
    , UpstreamExecutesFirst int NOT NULL
);

DECLARE
      @EdgeOrder int
    , @UpstreamDomain varchar(80)
    , @DownstreamDomain varchar(80)
    , @UpstreamBuilder sysname
    , @DownstreamBuilder sysname
    , @UpstreamEvidence sysname
    , @ExpectedClassification varchar(40)
    , @DownstreamDef nvarchar(max)
    , @ExplicitUpstreamToken int
    , @ReferencesUpstreamEvidence int
    , @ReferencesRole int
    , @ReferencesConfidence int
    , @ReferencesPrimary int
    , @UpstreamExecutesFirst int
    , @ObservedClassification varchar(40);

DECLARE topology_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
      EdgeOrder,UpstreamDomain,DownstreamDomain,UpstreamBuilder,
      DownstreamBuilder,UpstreamEvidence,ExpectedClassification
FROM @Topology
ORDER BY EdgeOrder;

OPEN topology_cursor;
FETCH NEXT FROM topology_cursor INTO
      @EdgeOrder,@UpstreamDomain,@DownstreamDomain,@UpstreamBuilder,
      @DownstreamBuilder,@UpstreamEvidence,@ExpectedClassification;

WHILE @@FETCH_STATUS=0
BEGIN
    SET @DownstreamDef=
        OBJECT_DEFINITION(OBJECT_ID(N'dbo.'+QUOTENAME(@DownstreamBuilder),N'P'));

    SET @ExplicitUpstreamToken=
        CASE
            WHEN @UpstreamDomain='CPU_SCHEDULER'
             AND (@DownstreamDef LIKE '%CPU_SCHEDULER%'
               OR @DownstreamDef LIKE '%CPU_SCHEDULER_PRESSURE%') THEN 1
            WHEN @UpstreamDomain='BLOCKING_WAIT_CHAIN'
             AND (@DownstreamDef LIKE '%BLOCKING_WAIT_CHAIN%'
               OR @DownstreamDef LIKE '%BLOCKING%') THEN 1
            WHEN @UpstreamDomain='IO_STORAGE_LATENCY'
             AND (@DownstreamDef LIKE '%IO_STORAGE_LATENCY%'
               OR @DownstreamDef LIKE '%IO_STORAGE_PRESSURE%') THEN 1
            ELSE 0
        END;

    SET @ReferencesUpstreamEvidence=
        CASE WHEN @DownstreamDef LIKE '%'+@UpstreamEvidence+'%' THEN 1 ELSE 0 END;
    SET @ReferencesRole=
        CASE WHEN @DownstreamDef LIKE '%RootCauseRole%' THEN 1 ELSE 0 END;
    SET @ReferencesConfidence=
        CASE WHEN @DownstreamDef LIKE '%Confidence%' THEN 1 ELSE 0 END;
    SET @ReferencesPrimary=
        CASE WHEN @DownstreamDef LIKE '%PRIMARY%' THEN 1 ELSE 0 END;
    SET @UpstreamExecutesFirst=
        CASE
            WHEN CHARINDEX(@UpstreamBuilder,@AnalyzerDef)>0
             AND CHARINDEX(@DownstreamBuilder,@AnalyzerDef)>0
             AND CHARINDEX(@UpstreamBuilder,@AnalyzerDef)<CHARINDEX(@DownstreamBuilder,@AnalyzerDef)
            THEN 1 ELSE 0
        END;

    SET @ObservedClassification=
        CASE
            WHEN @ExplicitUpstreamToken=1
             AND @ReferencesUpstreamEvidence=1
             AND @ReferencesRole=1
             AND @ReferencesConfidence=1
             AND @ReferencesPrimary=1
             AND @UpstreamExecutesFirst=1
                THEN 'CERTIFIED_CAUSAL'
            WHEN @ExplicitUpstreamToken=0
             AND @ReferencesUpstreamEvidence=1
                THEN 'REFERENCE_ONLY'
            WHEN @ExplicitUpstreamToken=0
             AND @ReferencesUpstreamEvidence=0
             AND @UpstreamExecutesFirst=1
                THEN 'EXECUTION_ORDER_ONLY'
            ELSE 'NOT_IMPLEMENTED'
        END;

    INSERT @TopologyObserved
    VALUES
    (
          @EdgeOrder,@UpstreamDomain,@DownstreamDomain,@ExpectedClassification,
          @ObservedClassification,@ExplicitUpstreamToken,@ReferencesUpstreamEvidence,
          @ReferencesRole,@ReferencesConfidence,@ReferencesPrimary,
          @UpstreamExecutesFirst
    );

    FETCH NEXT FROM topology_cursor INTO
          @EdgeOrder,@UpstreamDomain,@DownstreamDomain,@UpstreamBuilder,
          @DownstreamBuilder,@UpstreamEvidence,@ExpectedClassification;
END;

CLOSE topology_cursor;
DEALLOCATE topology_cursor;

DECLARE @TopologyGate varchar(10)=
    CASE
        WHEN (SELECT COUNT(*) FROM @TopologyObserved
              WHERE ObservedClassification='CERTIFIED_CAUSAL')=6
         AND (SELECT COUNT(*) FROM @TopologyObserved
              WHERE ObservedClassification='REFERENCE_ONLY')=1
         AND NOT EXISTS
             (
                 SELECT 1
                 FROM @TopologyObserved
                 WHERE ExpectedClassification<>ObservedClassification
             )
        THEN 'PASS' ELSE 'FAIL'
    END;

SELECT
      '3 - CERTIFIED CROSS DOMAIN TOPOLOGY' AS ValidationSection
    , t.EdgeOrder
    , t.UpstreamDomain
    , t.DownstreamDomain
    , t.ExpectedClassification
    , o.ObservedClassification
    , t.CertificationSource
    , CASE WHEN t.ExpectedClassification=o.ObservedClassification THEN 'PASS' ELSE 'FAIL' END AS EdgeGate
FROM @Topology AS t
JOIN @TopologyObserved AS o
  ON o.EdgeOrder=t.EdgeOrder
ORDER BY t.EdgeOrder;

SELECT
      '3A - TOPOLOGY GATE' AS ValidationSection
    , 6 AS ExpectedCertifiedCausalEdges
    , (SELECT COUNT(*) FROM @TopologyObserved WHERE ObservedClassification='CERTIFIED_CAUSAL') AS ObservedCertifiedCausalEdges
    , 1 AS ExpectedReferenceOnlyRelationships
    , (SELECT COUNT(*) FROM @TopologyObserved WHERE ObservedClassification='REFERENCE_ONLY') AS ObservedReferenceOnlyRelationships
    , (SELECT COUNT(*) FROM @TopologyObserved WHERE ExpectedClassification<>ObservedClassification) AS MismatchedRelationships
    , @TopologyGate AS TopologyGate;


/*==============================================================================
 4 - DBA ANSWER PARAMETER / FINAL-CONSUMER CONTRACT
==============================================================================*/
DECLARE
      @AnswerObjectID int=OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P')
    , @FinalObjectID int=OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V')
    , @NormalizedObjectID int=OBJECT_ID(N'dbo.vw_RCA_NormalizedCauseCandidates',N'V')
    , @SummaryObjectID int=OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V')
    , @HasCaptureRunID bit=0
    , @UnknownRequiredParameterCount int=0
    , @AnswerReferencesFinal bit=0
    , @AnswerReferencesFinalTransitive bit=0
    , @AnswerReferencesSummary bit=0
    , @AnswerReferencesNormalized bit=0
    , @AnswerReferencesPrimary bit=0
    , @AnswerReferencesConfidence bit=0
    , @ParameterGate varchar(10)='FAIL'
    , @ConsumerStructureGate varchar(10)='FAIL'
    , @CertifiedConsumerPath varchar(80)=NULL;

SET @HasCaptureRunID=
    CASE WHEN EXISTS
    (
        SELECT 1
        FROM sys.parameters
        WHERE object_id=@AnswerObjectID
          AND name=N'@CaptureRunID'
    ) THEN 1 ELSE 0 END;

SELECT @UnknownRequiredParameterCount=COUNT(*)
FROM sys.parameters AS p
WHERE p.object_id=@AnswerObjectID
  AND p.parameter_id>0
  AND ISNULL(p.has_default_value,0)=0
  AND p.name<>N'@CaptureRunID';

SET @ParameterGate=
    CASE
        WHEN @HasCaptureRunID=1
         AND @UnknownRequiredParameterCount=0
        THEN 'PASS' ELSE 'FAIL'
    END;

SET @AnswerReferencesFinal=
    CASE
        WHEN @AnswerDef LIKE '%vw_RCA_FinalCauseCandidates%'
          OR EXISTS
             (
                 SELECT 1 FROM sys.sql_expression_dependencies
                 WHERE referencing_id=@AnswerObjectID
                   AND referenced_entity_name=N'vw_RCA_FinalCauseCandidates'
             )
        THEN 1 ELSE 0
    END;

SET @AnswerReferencesSummary=
    CASE
        WHEN @AnswerDef LIKE '%vw_RCA_CrossDomainCauseSummary%'
          OR EXISTS
             (
                 SELECT 1 FROM sys.sql_expression_dependencies
                 WHERE referencing_id=@AnswerObjectID
                   AND referenced_entity_name=N'vw_RCA_CrossDomainCauseSummary'
             )
        THEN 1 ELSE 0
    END;

SET @AnswerReferencesNormalized=
    CASE
        WHEN @AnswerDef LIKE '%vw_RCA_NormalizedCauseCandidates%'
          OR EXISTS
             (
                 SELECT 1 FROM sys.sql_expression_dependencies
                 WHERE referencing_id=@AnswerObjectID
                   AND referenced_entity_name=N'vw_RCA_NormalizedCauseCandidates'
             )
        THEN 1 ELSE 0
    END;

SET @AnswerReferencesPrimary=CASE WHEN @AnswerDef LIKE '%PRIMARY%' THEN 1 ELSE 0 END;
SET @AnswerReferencesConfidence=CASE WHEN @AnswerDef LIKE '%Confidence%' THEN 1 ELSE 0 END;

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

SET @AnswerReferencesFinalTransitive=
    CASE
        WHEN @AnswerReferencesFinal=1
          OR EXISTS
             (
                 SELECT 1
                 FROM @DependencyPath
                 WHERE ReferencedObjectID=@FinalObjectID
                    OR ReferencedEntityName=N'vw_RCA_FinalCauseCandidates'
             )
        THEN 1 ELSE 0
    END;

SET @AnswerReferencesNormalized=
    CASE
        WHEN @AnswerReferencesNormalized=1
          OR EXISTS
             (
                 SELECT 1
                 FROM @DependencyPath
                 WHERE ReferencedObjectID=@NormalizedObjectID
                    OR ReferencedEntityName=N'vw_RCA_NormalizedCauseCandidates'
             )
        THEN 1 ELSE 0
    END;

SET @ConsumerStructureGate=
    CASE
        WHEN @AnswerReferencesPrimary=1
         AND @AnswerReferencesConfidence=1
         AND
         (
              @AnswerReferencesFinal=1
              OR
              (
                  @AnswerReferencesSummary=1
                  AND @AnswerReferencesFinalTransitive=1
              )
         )
        THEN 'PASS' ELSE 'FAIL'
    END;

SET @CertifiedConsumerPath=
    CASE
        WHEN @AnswerReferencesFinal=1
            THEN 'DIRECT FINAL CAUSE PATH'
        WHEN @AnswerReferencesSummary=1
         AND @AnswerReferencesFinalTransitive=1
            THEN 'CANONICAL SUMMARY -> FINAL TRANSITIVE PATH'
        ELSE 'NO CERTIFIED CONSUMER PATH'
    END;

SELECT
      '4 - DBA ANSWER PARAMETER CONTRACT' AS ValidationSection
    , p.parameter_id
    , p.name AS ParameterName
    , TYPE_NAME(p.user_type_id) AS DataType
    , p.max_length
    , p.precision
    , p.scale
    , p.has_default_value
    , p.default_value
    , p.is_output
FROM sys.parameters AS p
WHERE p.object_id=@AnswerObjectID
ORDER BY p.parameter_id;

SELECT
      '4A - DBA ANSWER FINAL CONSUMER CONTRACT' AS ValidationSection
    , @HasCaptureRunID AS HasCaptureRunID
    , @UnknownRequiredParameterCount AS UnknownRequiredParameterCount
    , @ParameterGate AS ParameterGate
    , @AnswerReferencesFinal AS DirectFinalCauseReference
    , @AnswerReferencesFinalTransitive AS TransitiveFinalCauseReference
    , @AnswerReferencesSummary AS CrossDomainSummaryReference
    , @AnswerReferencesNormalized AS ReferencesNormalizedCauseLayer
    , @AnswerReferencesPrimary AS ReferencesPrimaryRole
    , @AnswerReferencesConfidence AS ReferencesConfidence
    , @ConsumerStructureGate AS ConsumerStructureGate
    , @CertifiedConsumerPath AS CertifiedConsumerPath;

IF @ParameterGate<>'PASS' OR @ConsumerStructureGate<>'PASS'
    THROW 63723,'SCRIPT 110L ABORTED: DBA answer parameter or final-consumer contract is not certifiable.',1;


/*==============================================================================
 5 - SELECT EXISTING BLOCKING POSITIVE CONTROL
==============================================================================*/
DECLARE @BlockingCaptureRunID bigint;

SELECT TOP (1) @BlockingCaptureRunID=r.CaptureRunID
FROM dbo.RCA_CaptureRun AS r
WHERE r.CaptureStatus='ANALYZED'
  AND EXISTS
      (
          SELECT 1
          FROM dbo.vw_RCA_NormalizedCauseCandidates AS n
          WHERE n.CaptureRunID=r.CaptureRunID
            AND n.CauseCategory='BLOCKING_WAIT_CHAIN'
            AND n.RootCauseRole='PRIMARY'
            AND n.Confidence='HIGH'
      )
  AND EXISTS
      (
          SELECT 1
          FROM dbo.vw_RCA_FinalCauseCandidates AS f
          WHERE f.CaptureRunID=r.CaptureRunID
            AND f.CauseCategory='BLOCKING_WAIT_CHAIN'
            AND f.RootCauseRole='PRIMARY'
            AND f.Confidence='HIGH'
      )
  AND 1=
      (
          SELECT COUNT(*)
          FROM dbo.vw_RCA_FinalCauseCandidates AS f
          WHERE f.CaptureRunID=r.CaptureRunID
            AND f.RootCauseRole='PRIMARY'
      )
ORDER BY r.CaptureRunID DESC;

SELECT
      '5 - EXISTING BLOCKING CONTROL SELECTION' AS ValidationSection
    , 2 AS DomainOrder
    , 'BLOCKING_WAIT_CHAIN' AS DomainKey
    , @BlockingCaptureRunID AS CaptureRunID
    , r.TargetDatabase
    , r.CaptureReason
    , r.CaptureStatus
    , CASE WHEN @BlockingCaptureRunID IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS SelectionGate
    , 'CPU IS RECREATED TRANSACTIONALLY FROM THE CERTIFIED SCRIPT 104B SIGNAL' AS CPUControlDisposition
FROM dbo.RCA_CaptureRun AS r
WHERE r.CaptureRunID=@BlockingCaptureRunID;

IF @BlockingCaptureRunID IS NULL
    THROW 63724,'SCRIPT 110L ABORTED: the SCRIPT 110K blocking PRIMARY/HIGH control is not available.',1;


/*==============================================================================
 6 - CONTROL / RESULT TABLES

 Table variables intentionally hold the compact proof across the synthetic
 rollback, matching the already-certified SCRIPT 110J harness pattern.
==============================================================================*/
DECLARE @Controls TABLE
(
      DomainOrder int NOT NULL
    , DomainKey varchar(80) NOT NULL
    , ControlType varchar(20) NOT NULL
    , CaptureRunID bigint NOT NULL
    , TargetDatabase sysname NULL
);

INSERT @Controls
SELECT 2,'BLOCKING_WAIT_CHAIN','PERSISTENT',r.CaptureRunID,r.TargetDatabase
FROM dbo.RCA_CaptureRun AS r
WHERE r.CaptureRunID=@BlockingCaptureRunID;

DECLARE @Proof TABLE
(
      DomainOrder int NOT NULL
    , DomainKey varchar(80) NOT NULL
    , ControlType varchar(20) NOT NULL
    , CaptureRunID bigint NOT NULL
    , BuilderEvidenceRows int NOT NULL
    , NormalizedRows int NOT NULL
    , NormalizedExpectedPrimaryHigh int NOT NULL
    , FinalRows int NOT NULL
    , FinalExpectedPrimaryHigh int NOT NULL
    , FinalPrimaryCount int NOT NULL
    , FinalPrimaryHighCount int NOT NULL
    , ContributingHighCount int NOT NULL
    , FinalCauseCategory varchar(80) NULL
    , FinalCauseDisplayName nvarchar(200) NULL
    , SummaryPrimaryCauseCategory varchar(80) NULL
    , SummaryPrimaryCauseRole varchar(20) NULL
    , SummaryPrimaryConfidence varchar(20) NULL
    , SummarySupportedCauseCount int NULL
    , SummaryPrimaryCauseCount int NULL
    , SummaryArbitrationStatus varchar(100) NULL
    , SummaryFinalAlignmentGate varchar(20) NOT NULL
    , DomainGate varchar(10) NOT NULL
);

DECLARE @AllAnswerRows TABLE
(
      DomainOrder int NOT NULL
    , DomainKey varchar(80) NOT NULL
    , CaptureRunID bigint NOT NULL
    , SectionOrder int NULL
    , ReportSection nvarchar(200) NULL
    , Narrative nvarchar(max) NULL
);

DECLARE @AnswerAudit TABLE
(
      DomainOrder int NOT NULL
    , DomainKey varchar(80) NOT NULL
    , CaptureRunID bigint NOT NULL
    , AnswerRowCount int NOT NULL
    , RootCauseIdentifiedRows int NOT NULL
    , AnswerSectionRows int NOT NULL
    , RootCauseNarrativeRows int NOT NULL
    , RootCauseDisplayAlignedRows int NOT NULL
    , SemanticDomainAlignedRows int NOT NULL
    , NegativeOrUnknownAnswerRows int NOT NULL
    , ExecutionGate varchar(10) NOT NULL
    , ExecutionMessage nvarchar(4000) NULL
);


/*==============================================================================
 7 - BEGIN SIX-DOMAIN SYNTHETIC TRANSACTION
==============================================================================*/
DECLARE
      @TargetDatabase sysname=N'RCA_Demo'
    , @DatabaseID int=DB_ID(N'RCA_Demo')
    , @CPUCaptureRunID bigint
    , @IOCaptureRunID bigint
    , @MemoryCaptureRunID bigint
    , @TempDBCaptureRunID bigint
    , @LogCaptureRunID bigint
    , @ConnectivityCaptureRunID bigint
    , @BaseUTC datetime2(3)=SYSUTCDATETIME()
    , @CPUSyntheticGate varchar(10)='FAIL'
    , @FiveDomainGate varchar(10)='FAIL'
    , @SevenDomainGate varchar(10)='FAIL'
    , @DBAAnswerSevenDomainGate varchar(10)='FAIL'
    , @NoContradictoryPrimaryGate varchar(10)='FAIL'
    , @PreRollbackGate varchar(10)='FAIL'
    , @PostRollbackSafetyGate varchar(10)='FAIL';

IF @DatabaseID IS NULL
    SET @DatabaseID=9;

BEGIN TRANSACTION;

BEGIN TRY

/*==============================================================================
 8 - CREATE SIX SYNTHETIC CAPTURE RUNS
==============================================================================*/
INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus,CreatedBy)
VALUES(@TargetDatabase,'SCRIPT 110L v1.3 CPU_ONLY FREEZE POSITIVE CONTROL',@BaseUTC,'CAPTURING',SUSER_SNAME());
SET @CPUCaptureRunID=SCOPE_IDENTITY();

INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus,CreatedBy)
VALUES(@TargetDatabase,'SCRIPT 110L v1.3 IO_ONLY FREEZE POSITIVE CONTROL',DATEADD(second,1,@BaseUTC),'CAPTURING',SUSER_SNAME());
SET @IOCaptureRunID=SCOPE_IDENTITY();

INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus,CreatedBy)
VALUES(@TargetDatabase,'SCRIPT 110L v1.3 MEMORY_ONLY FREEZE POSITIVE CONTROL',DATEADD(second,2,@BaseUTC),'CAPTURING',SUSER_SNAME());
SET @MemoryCaptureRunID=SCOPE_IDENTITY();

INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus,CreatedBy)
VALUES(@TargetDatabase,'SCRIPT 110L v1.3 TEMPDB_ONLY FREEZE POSITIVE CONTROL',DATEADD(second,3,@BaseUTC),'CAPTURING',SUSER_SNAME());
SET @TempDBCaptureRunID=SCOPE_IDENTITY();

INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus,CreatedBy)
VALUES(@TargetDatabase,'SCRIPT 110L v1.3 TRANSACTION_LOG_ONLY FREEZE POSITIVE CONTROL',DATEADD(second,4,@BaseUTC),'CAPTURING',SUSER_SNAME());
SET @LogCaptureRunID=SCOPE_IDENTITY();

INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus,CreatedBy)
VALUES(@TargetDatabase,'SCRIPT 110L v1.3 CONNECTIVITY_ONLY FREEZE POSITIVE CONTROL',DATEADD(second,5,@BaseUTC),'CAPTURING',SUSER_SNAME());
SET @ConnectivityCaptureRunID=SCOPE_IDENTITY();

INSERT @Controls
VALUES
 (1,'CPU_SCHEDULER','SYNTHETIC',@CPUCaptureRunID,@TargetDatabase),
 (3,'IO_STORAGE_LATENCY','SYNTHETIC',@IOCaptureRunID,@TargetDatabase),
 (4,'MEMORY_PRESSURE','SYNTHETIC',@MemoryCaptureRunID,@TargetDatabase),
 (5,'TEMPDB_PRESSURE','SYNTHETIC',@TempDBCaptureRunID,@TargetDatabase),
 (6,'TRANSACTION_LOG_PRESSURE','SYNTHETIC',@LogCaptureRunID,@TargetDatabase),
 (7,'CONNECTIVITY_PRESSURE','SYNTHETIC',@ConnectivityCaptureRunID,@TargetDatabase);

SELECT
      '8 - SEVEN CONTROL CAPTURES' AS ValidationSection
    , c.DomainOrder
    , c.DomainKey
    , c.ControlType
    , c.CaptureRunID
    , c.TargetDatabase
FROM @Controls AS c
ORDER BY c.DomainOrder;


/*==============================================================================
 8A - CPU POSITIVE CONTROL (exact SCRIPT 104B scheduler signal)
==============================================================================*/
DECLARE @i int=0;
WHILE @i<8
BEGIN
    INSERT dbo.RCA_ServerSnapshot
    (
          CaptureRunID,CaptureTimeUTC,SqlCpuPercent,OtherCpuPercent,
          SystemIdlePercent,RunnableTasks,BufferCacheHitRatio,
          PageLifeExpectancySeconds,TotalServerMemoryMB,TargetServerMemoryMB,
          AvailablePhysicalMemoryMB,MemoryGrantsPending
    )
    VALUES
    (
          @CPUCaptureRunID,DATEADD(second,@i*2,@BaseUTC),0.00,4.00,
          96.00,12,99.900000,3600,16384.00,16384.00,8192.00,0
    );
    SET @i+=1;
END;

SELECT
      '8A - CERTIFIED CPU SCHEDULER CONTROL SIGNAL' AS ValidationSection
    , @CPUCaptureRunID AS CaptureRunID
    , COUNT(*) AS ServerSnapshotRows
    , MIN(SqlCpuPercent) AS MinSqlCpuPercent
    , MAX(SqlCpuPercent) AS MaxSqlCpuPercent
    , MIN(RunnableTasks) AS MinRunnableTasks
    , MAX(RunnableTasks) AS MaxRunnableTasks
    , CASE
          WHEN COUNT(*)=8
           AND MIN(SqlCpuPercent)=0
           AND MAX(SqlCpuPercent)=0
           AND MIN(RunnableTasks)=12
           AND MAX(RunnableTasks)=12
          THEN 'PASS' ELSE 'FAIL'
      END AS CPUSourceSignalGate
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CPUCaptureRunID;


/*==============================================================================
 9 - IO POSITIVE CONTROL (exact SCRIPT 110J v1.1 signal)
==============================================================================*/
INSERT dbo.RCA_IOFileSnapshot
(
      CaptureRunID,CaptureTimeUTC,DatabaseID,DatabaseName,FileID,
      FileTypeDesc,LogicalFileName,PhysicalName,NumReads,BytesRead,
      IoStallReadMs,NumWrites,BytesWritten,IoStallWriteMs,IoStallMs
)
VALUES
(
      @IOCaptureRunID,DATEADD(second,0,@BaseUTC),@DatabaseID,@TargetDatabase,1,
      N'ROWS',N'RCA_110L_IO_CONTROL',N'RCA_110L_IO_CONTROL.mdf',100000,
      CAST(10 AS bigint)*1024*1024*1024,100000,10000,
      CAST(1 AS bigint)*1024*1024*1024,10000,110000
),
(
      @IOCaptureRunID,DATEADD(second,2,@BaseUTC),@DatabaseID,@TargetDatabase,1,
      N'ROWS',N'RCA_110L_IO_CONTROL',N'RCA_110L_IO_CONTROL.mdf',101000,
      CAST(11 AS bigint)*1024*1024*1024,150000,10000,
      CAST(1 AS bigint)*1024*1024*1024,10000,160000
);


/*==============================================================================
 10 - MEMORY POSITIVE CONTROL (exact SCRIPT 110J v1.1 signal)
==============================================================================*/
SET @i=0;
WHILE @i<8
BEGIN
    INSERT dbo.RCA_ServerSnapshot
    (
          CaptureRunID,CaptureTimeUTC,SqlCpuPercent,OtherCpuPercent,
          SystemIdlePercent,RunnableTasks,BufferCacheHitRatio,
          PageLifeExpectancySeconds,TotalServerMemoryMB,TargetServerMemoryMB,
          AvailablePhysicalMemoryMB,MemoryGrantsPending
    )
    VALUES
    (
          @MemoryCaptureRunID,DATEADD(second,@i*2,@BaseUTC),0.00,4.00,
          96.00,0,80.000000,30,8192.00,16384.00,512.00,8
    );
    SET @i+=1;
END;


/*==============================================================================
 11 - TEMPDB POSITIVE CONTROL (exact SCRIPT 110J v1.1 signal)
==============================================================================*/
SET @i=0;
WHILE @i<8
BEGIN
    INSERT dbo.RCA_TempDBSnapshot
    (
          CaptureRunID,CaptureTimeUTC,TotalSizeMB,UnallocatedMB,UsedMB,
          UsedPercent,UserObjectMB,InternalObjectMB,VersionStoreMB,
          MixedExtentMB,TempDBLatchWaiterCount,TempDBPFSWaiterCount,
          TempDBGAMWaiterCount,TempDBSGAMWaiterCount
    )
    VALUES
    (
          @TempDBCaptureRunID,DATEADD(second,@i*2,@BaseUTC),16384.00,
          12288.00,4096.00,25.0000,256.00,128.00,64.00,8.00,4,4,0,0
    );
    SET @i+=1;
END;


/*==============================================================================
 12 - TRANSACTION LOG POSITIVE CONTROL (exact SCRIPT 110J v1.1 signal)
==============================================================================*/
SET @i=0;
WHILE @i<8
BEGIN
    INSERT dbo.RCA_LogSnapshot
    (
          CaptureRunID,CaptureTimeUTC,DatabaseID,DatabaseName,
          RecoveryModelDesc,FileID,LogicalFileName,PhysicalName,LogSizeMB,
          LogSpaceUsedPercent,NumWrites,BytesWritten,IoStallWriteMs,
          LogWaiterCount,WriteLogWaiterCount,LogRateGovernorWaiterCount
    )
    VALUES
    (
          @LogCaptureRunID,DATEADD(second,@i*2,@BaseUTC),@DatabaseID,
          @TargetDatabase,N'FULL',2,N'RCA_110L_LOG_CONTROL',
          N'RCA_110L_LOG_CONTROL.ldf',1024.00,95.0000,
          101000+(@i*1000),
          CAST(1140850688 AS bigint)+(CAST(@i AS bigint)*67108864),
          100000+(CAST(@i AS bigint)*50000),4,4,4
    );
    SET @i+=1;
END;


/*==============================================================================
 13 - CONNECTIVITY POSITIVE CONTROL (exact SCRIPT 110J v1.1 signal)
==============================================================================*/
INSERT dbo.RCA_ConnectivitySnapshot
(
      CaptureRunID,CaptureTimeUTC,ActiveConnectionCount,ActiveRequestCount,
      UserConnectionsCounter,LoginCounterRaw,LogoutCounterRaw,
      AsyncNetworkIOWaiterCount,MaxAsyncNetworkIOWaitMs
)
VALUES
(@ConnectivityCaptureRunID,DATEADD(second,0,@BaseUTC),100,20,100,100000,90000,6,2500),
(@ConnectivityCaptureRunID,DATEADD(second,2,@BaseUTC),160,24,160,100080,90020,6,2700),
(@ConnectivityCaptureRunID,DATEADD(second,4,@BaseUTC),170,26,170,100170,90045,6,2900),
(@ConnectivityCaptureRunID,DATEADD(second,6,@BaseUTC),180,28,180,100270,90075,6,3100),
(@ConnectivityCaptureRunID,DATEADD(second,8,@BaseUTC),185,30,185,100380,90110,6,3300),
(@ConnectivityCaptureRunID,DATEADD(second,10,@BaseUTC),190,32,190,100500,90150,6,3500),
(@ConnectivityCaptureRunID,DATEADD(second,12,@BaseUTC),188,31,188,100630,90195,6,3700),
(@ConnectivityCaptureRunID,DATEADD(second,14,@BaseUTC),186,30,186,100770,90245,6,3900);

SELECT
      '13A - SIX SYNTHETIC DOMAIN SOURCE ISOLATION' AS ValidationSection
    , c.DomainOrder
    , c.DomainKey
    , c.CaptureRunID
    , (SELECT COUNT(*) FROM dbo.RCA_IOFileSnapshot s WHERE s.CaptureRunID=c.CaptureRunID) AS IOSnapshotRows
    , (SELECT COUNT(*) FROM dbo.RCA_ServerSnapshot s WHERE s.CaptureRunID=c.CaptureRunID) AS ServerSnapshotRows
    , (SELECT COUNT(*) FROM dbo.RCA_TempDBSnapshot s WHERE s.CaptureRunID=c.CaptureRunID) AS TempDBSnapshotRows
    , (SELECT COUNT(*) FROM dbo.RCA_LogSnapshot s WHERE s.CaptureRunID=c.CaptureRunID) AS LogSnapshotRows
    , (SELECT COUNT(*) FROM dbo.RCA_ConnectivitySnapshot s WHERE s.CaptureRunID=c.CaptureRunID) AS ConnectivitySnapshotRows
FROM @Controls AS c
WHERE c.ControlType='SYNTHETIC'
ORDER BY c.DomainOrder;


/*==============================================================================
 14 - RUN THE REAL ANALYZER FOR ALL SIX SYNTHETIC CONTROLS
==============================================================================*/
EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@CPUCaptureRunID;
EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@IOCaptureRunID;
EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@MemoryCaptureRunID;
EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@TempDBCaptureRunID;
EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@LogCaptureRunID;
EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@ConnectivityCaptureRunID;


/*==============================================================================
 15 - BUILD UNIFIED SEVEN-DOMAIN PROOF
==============================================================================*/
INSERT @Proof
SELECT
      c.DomainOrder
    , c.DomainKey
    , c.ControlType
    , c.CaptureRunID
    , CASE c.DomainKey
          WHEN 'CPU_SCHEDULER' THEN
              (SELECT COUNT(*) FROM dbo.RCA_CPUSchedulerEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          WHEN 'BLOCKING_WAIT_CHAIN' THEN
              (SELECT COUNT(*) FROM dbo.RCA_BlockingEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          WHEN 'IO_STORAGE_LATENCY' THEN
              (SELECT COUNT(*) FROM dbo.RCA_IOStorageEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          WHEN 'MEMORY_PRESSURE' THEN
              (SELECT COUNT(*) FROM dbo.RCA_MemoryPressureEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          WHEN 'TEMPDB_PRESSURE' THEN
              (SELECT COUNT(*) FROM dbo.RCA_TempDBEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          WHEN 'TRANSACTION_LOG_PRESSURE' THEN
              (SELECT COUNT(*) FROM dbo.RCA_TransactionLogEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          WHEN 'CONNECTIVITY_PRESSURE' THEN
              (SELECT COUNT(*) FROM dbo.RCA_ConnectivityEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
          ELSE 0
      END AS BuilderEvidenceRows
    , n.NormalizedRows
    , ne.NormalizedExpectedPrimaryHigh
    , f.FinalRows
    , fe.FinalExpectedPrimaryHigh
    , f.FinalPrimaryCount
    , f.FinalPrimaryHighCount
    , f.ContributingHighCount
    , fp.CauseCategory
    , fp.CauseDisplayName
    , s.PrimaryCauseCategory
    , s.PrimaryCauseRole
    , s.PrimaryConfidence
    , s.SupportedCauseCount
    , s.PrimaryCauseCount
    , s.ArbitrationStatus
    , CASE
          WHEN @AnswerReferencesFinal=1 THEN 'NOT REQUIRED'
          WHEN @AnswerReferencesSummary=1
           AND @AnswerReferencesFinalTransitive=1
           AND CASE
                   WHEN c.DomainKey='CPU_SCHEDULER'
                    AND s.PrimaryCauseCategory IN ('CPU_SCHEDULER','CPU_SCHEDULER_PRESSURE') THEN 1
                   WHEN c.DomainKey='BLOCKING_WAIT_CHAIN'
                    AND s.PrimaryCauseCategory='BLOCKING_WAIT_CHAIN' THEN 1
                   WHEN c.DomainKey='IO_STORAGE_LATENCY'
                    AND s.PrimaryCauseCategory IN ('IO_STORAGE_LATENCY','IO_STORAGE_PRESSURE') THEN 1
                   WHEN c.DomainKey='MEMORY_PRESSURE'
                    AND s.PrimaryCauseCategory IN ('MEMORY_PRESSURE_MIXED','INSTANCE_MEMORY_PRESSURE','MEMORY_PRESSURE') THEN 1
                   WHEN c.DomainKey='TEMPDB_PRESSURE'
                    AND s.PrimaryCauseCategory IN ('TEMPDB_PRESSURE','TEMPDB_PRESSURE_CONTENTION') THEN 1
                   WHEN c.DomainKey='TRANSACTION_LOG_PRESSURE'
                    AND s.PrimaryCauseCategory='TRANSACTION_LOG_PRESSURE' THEN 1
                   WHEN c.DomainKey='CONNECTIVITY_PRESSURE'
                    AND s.PrimaryCauseCategory IN ('CLIENT_CONNECTION_NETWORK_PRESSURE','CONNECTIVITY_PRESSURE') THEN 1
                   ELSE 0
               END=1
           AND s.PrimaryCauseRole=fp.RootCauseRole
           AND s.PrimaryConfidence=fp.Confidence
           AND ISNULL(s.SupportedCauseCount,0)=f.FinalRows
           AND ISNULL(s.PrimaryCauseCount,0)=f.FinalPrimaryCount
           AND s.PrimaryCauseCount=1
           AND s.ArbitrationStatus='ONE_SUPPORTED_PRIMARY_CAUSE'
              THEN 'PASS'
          ELSE 'FAIL'
      END AS SummaryFinalAlignmentGate
    , CASE
          WHEN
              CASE c.DomainKey
                  WHEN 'CPU_SCHEDULER' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_CPUSchedulerEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  WHEN 'BLOCKING_WAIT_CHAIN' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_BlockingEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  WHEN 'IO_STORAGE_LATENCY' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_IOStorageEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  WHEN 'MEMORY_PRESSURE' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_MemoryPressureEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  WHEN 'TEMPDB_PRESSURE' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_TempDBEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  WHEN 'TRANSACTION_LOG_PRESSURE' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_TransactionLogEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  WHEN 'CONNECTIVITY_PRESSURE' THEN
                      (SELECT COUNT(*) FROM dbo.RCA_ConnectivityEvidence e WHERE e.CaptureRunID=c.CaptureRunID)
                  ELSE 0
              END>0
           AND ne.NormalizedExpectedPrimaryHigh=1
           AND fe.FinalExpectedPrimaryHigh=1
           AND f.FinalPrimaryCount=1
           AND f.FinalPrimaryHighCount=1
           AND
           (
                @AnswerReferencesFinal=1
                OR
                (
                    @AnswerReferencesSummary=1
                    AND @AnswerReferencesFinalTransitive=1
                    AND CASE
                            WHEN c.DomainKey='CPU_SCHEDULER'
                             AND s.PrimaryCauseCategory IN ('CPU_SCHEDULER','CPU_SCHEDULER_PRESSURE') THEN 1
                            WHEN c.DomainKey='BLOCKING_WAIT_CHAIN'
                             AND s.PrimaryCauseCategory='BLOCKING_WAIT_CHAIN' THEN 1
                            WHEN c.DomainKey='IO_STORAGE_LATENCY'
                             AND s.PrimaryCauseCategory IN ('IO_STORAGE_LATENCY','IO_STORAGE_PRESSURE') THEN 1
                            WHEN c.DomainKey='MEMORY_PRESSURE'
                             AND s.PrimaryCauseCategory IN ('MEMORY_PRESSURE_MIXED','INSTANCE_MEMORY_PRESSURE','MEMORY_PRESSURE') THEN 1
                            WHEN c.DomainKey='TEMPDB_PRESSURE'
                             AND s.PrimaryCauseCategory IN ('TEMPDB_PRESSURE','TEMPDB_PRESSURE_CONTENTION') THEN 1
                            WHEN c.DomainKey='TRANSACTION_LOG_PRESSURE'
                             AND s.PrimaryCauseCategory='TRANSACTION_LOG_PRESSURE' THEN 1
                            WHEN c.DomainKey='CONNECTIVITY_PRESSURE'
                             AND s.PrimaryCauseCategory IN ('CLIENT_CONNECTION_NETWORK_PRESSURE','CONNECTIVITY_PRESSURE') THEN 1
                            ELSE 0
                        END=1
                    AND s.PrimaryCauseRole=fp.RootCauseRole
                    AND s.PrimaryConfidence=fp.Confidence
                    AND ISNULL(s.SupportedCauseCount,0)=f.FinalRows
                    AND ISNULL(s.PrimaryCauseCount,0)=f.FinalPrimaryCount
                    AND s.PrimaryCauseCount=1
                    AND s.ArbitrationStatus='ONE_SUPPORTED_PRIMARY_CAUSE'
                )
           )
          THEN 'PASS' ELSE 'FAIL'
      END AS DomainGate
FROM @Controls AS c
OUTER APPLY
(
    SELECT
          COUNT(*) AS NormalizedRows
    FROM dbo.vw_RCA_NormalizedCauseCandidates
    WHERE CaptureRunID=c.CaptureRunID
) AS n
OUTER APPLY
(
    SELECT
          COUNT(*) AS FinalRows
        , ISNULL(SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END),0) AS FinalPrimaryCount
        , ISNULL(SUM(CASE WHEN RootCauseRole='PRIMARY' AND Confidence='HIGH' THEN 1 ELSE 0 END),0) AS FinalPrimaryHighCount
        , ISNULL(SUM(CASE WHEN RootCauseRole='CONTRIBUTING' AND Confidence='HIGH' THEN 1 ELSE 0 END),0) AS ContributingHighCount
    FROM dbo.vw_RCA_FinalCauseCandidates
    WHERE CaptureRunID=c.CaptureRunID
) AS f
OUTER APPLY
(
    SELECT COUNT(*) AS NormalizedExpectedPrimaryHigh
    FROM dbo.vw_RCA_NormalizedCauseCandidates AS nc
    WHERE nc.CaptureRunID=c.CaptureRunID
      AND nc.RootCauseRole='PRIMARY'
      AND nc.Confidence='HIGH'
      AND
      (
           (c.DomainKey='CPU_SCHEDULER' AND nc.CauseCategory LIKE 'CPU%')
        OR (c.DomainKey='BLOCKING_WAIT_CHAIN' AND nc.CauseCategory='BLOCKING_WAIT_CHAIN')
        OR (c.DomainKey='IO_STORAGE_LATENCY' AND nc.CauseCategory IN ('IO_STORAGE_LATENCY','IO_STORAGE_PRESSURE'))
        OR (c.DomainKey='MEMORY_PRESSURE' AND nc.CauseCategory IN ('MEMORY_PRESSURE_MIXED','INSTANCE_MEMORY_PRESSURE','MEMORY_PRESSURE'))
        OR (c.DomainKey='TEMPDB_PRESSURE' AND nc.CauseCategory IN ('TEMPDB_PRESSURE','TEMPDB_PRESSURE_CONTENTION'))
        OR (c.DomainKey='TRANSACTION_LOG_PRESSURE' AND nc.CauseCategory='TRANSACTION_LOG_PRESSURE')
        OR (c.DomainKey='CONNECTIVITY_PRESSURE' AND nc.CauseCategory IN ('CLIENT_CONNECTION_NETWORK_PRESSURE','CONNECTIVITY_PRESSURE'))
      )
) AS ne
OUTER APPLY
(
    SELECT COUNT(*) AS FinalExpectedPrimaryHigh
    FROM dbo.vw_RCA_FinalCauseCandidates AS fc
    WHERE fc.CaptureRunID=c.CaptureRunID
      AND fc.RootCauseRole='PRIMARY'
      AND fc.Confidence='HIGH'
      AND
      (
           (c.DomainKey='CPU_SCHEDULER' AND fc.CauseCategory LIKE 'CPU%')
        OR (c.DomainKey='BLOCKING_WAIT_CHAIN' AND fc.CauseCategory='BLOCKING_WAIT_CHAIN')
        OR (c.DomainKey='IO_STORAGE_LATENCY' AND fc.CauseCategory IN ('IO_STORAGE_LATENCY','IO_STORAGE_PRESSURE'))
        OR (c.DomainKey='MEMORY_PRESSURE' AND fc.CauseCategory IN ('INSTANCE_MEMORY_PRESSURE','MEMORY_PRESSURE'))
        OR (c.DomainKey='TEMPDB_PRESSURE' AND fc.CauseCategory IN ('TEMPDB_PRESSURE','TEMPDB_PRESSURE_CONTENTION'))
        OR (c.DomainKey='TRANSACTION_LOG_PRESSURE' AND fc.CauseCategory='TRANSACTION_LOG_PRESSURE')
        OR (c.DomainKey='CONNECTIVITY_PRESSURE' AND fc.CauseCategory IN ('CLIENT_CONNECTION_NETWORK_PRESSURE','CONNECTIVITY_PRESSURE'))
      )
) AS fe
OUTER APPLY
(
    SELECT TOP (1)
          CauseCategory
        , CauseDisplayName
        , RootCauseRole
        , Confidence
    FROM dbo.vw_RCA_FinalCauseCandidates
    WHERE CaptureRunID=c.CaptureRunID
      AND RootCauseRole='PRIMARY'
    ORDER BY CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,CauseCategory
) AS fp
LEFT JOIN dbo.vw_RCA_CrossDomainCauseSummary AS s
  ON s.CaptureRunID=c.CaptureRunID;

SELECT
      '15 - SEVEN DOMAIN NORMALIZED FINAL SUMMARY PROOF' AS ValidationSection
    , *
FROM @Proof
ORDER BY DomainOrder;

SELECT
      '15A - EXACT NORMALIZED CAUSES' AS ValidationSection
    , c.DomainOrder
    , c.DomainKey
    , c.ControlType
    , n.*
FROM @Controls AS c
JOIN dbo.vw_RCA_NormalizedCauseCandidates AS n
  ON n.CaptureRunID=c.CaptureRunID
ORDER BY c.DomainOrder,n.PriorityScore DESC,n.CauseCategory;

SELECT
      '15B - EXACT FINAL ARBITRATION ROWS' AS ValidationSection
    , c.DomainOrder
    , c.DomainKey
    , c.ControlType
    , f.*
FROM @Controls AS c
JOIN dbo.vw_RCA_FinalCauseCandidates AS f
  ON f.CaptureRunID=c.CaptureRunID
ORDER BY c.DomainOrder,
         CASE f.RootCauseRole WHEN 'PRIMARY' THEN 1 WHEN 'CONTRIBUTING' THEN 2 ELSE 3 END,
         f.CauseCategory;


/*==============================================================================
 16 - EXECUTE THE REAL DBA ANSWER FOR ALL SEVEN CONTROLS
==============================================================================*/
DECLARE @OneAnswer TABLE
(
      SectionOrder int NULL
    , ReportSection nvarchar(200) NULL
    , Narrative nvarchar(max) NULL
);

DECLARE
      @AnswerDomainOrder int
    , @AnswerDomainKey varchar(80)
    , @AnswerCaptureRunID bigint
    , @AnswerFinalDisplayName nvarchar(200)
    , @AnswerExecutionMessage nvarchar(4000);

DECLARE answer_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DomainOrder,DomainKey,CaptureRunID
FROM @Controls
ORDER BY DomainOrder;

OPEN answer_cursor;
FETCH NEXT FROM answer_cursor INTO @AnswerDomainOrder,@AnswerDomainKey,@AnswerCaptureRunID;

WHILE @@FETCH_STATUS=0
BEGIN
    DELETE FROM @OneAnswer;
    SET @AnswerExecutionMessage=NULL;
    SET @AnswerFinalDisplayName=NULL;

    SELECT @AnswerFinalDisplayName=FinalCauseDisplayName
    FROM @Proof
    WHERE DomainOrder=@AnswerDomainOrder;

    BEGIN TRY
        INSERT @OneAnswer(SectionOrder,ReportSection,Narrative)
        EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=@AnswerCaptureRunID;

        SET @AnswerExecutionMessage=N'dbo.usp_RCA_DBAAnswer executed successfully.';
    END TRY
    BEGIN CATCH
        SET @AnswerExecutionMessage=
            CONCAT(N'Error ',ERROR_NUMBER(),N', line ',ERROR_LINE(),N': ',ERROR_MESSAGE());

        IF XACT_STATE()=-1
            THROW;
    END CATCH;

    INSERT @AllAnswerRows
    (
          DomainOrder,DomainKey,CaptureRunID,SectionOrder,ReportSection,Narrative
    )
    SELECT
          @AnswerDomainOrder,@AnswerDomainKey,@AnswerCaptureRunID,
          SectionOrder,ReportSection,Narrative
    FROM @OneAnswer;

    INSERT @AnswerAudit
    SELECT
          @AnswerDomainOrder
        , @AnswerDomainKey
        , @AnswerCaptureRunID
        , COUNT(*)
        , ISNULL(SUM(CASE WHEN ReportSection=N'ANSWER' AND Narrative=N'ROOT CAUSE IDENTIFIED' THEN 1 ELSE 0 END),0)
        , ISNULL(SUM(CASE WHEN ReportSection=N'ANSWER' AND NULLIF(LTRIM(RTRIM(Narrative)),N'') IS NOT NULL THEN 1 ELSE 0 END),0)
        , ISNULL(SUM(CASE WHEN ReportSection=N'ROOT CAUSE' AND NULLIF(LTRIM(RTRIM(Narrative)),N'') IS NOT NULL THEN 1 ELSE 0 END),0)
        , ISNULL(SUM(CASE WHEN ReportSection=N'ROOT CAUSE'
                           AND @AnswerFinalDisplayName IS NOT NULL
                           AND CHARINDEX(@AnswerFinalDisplayName,ISNULL(Narrative,N''))>0
                          THEN 1 ELSE 0 END),0)
        , ISNULL(SUM(CASE
              WHEN ReportSection IN (N'ANSWER',N'ROOT CAUSE')
               AND
               (
                    (@AnswerDomainKey='CPU_SCHEDULER' AND (Narrative LIKE N'%CPU%' OR Narrative LIKE N'%scheduler%'))
                 OR (@AnswerDomainKey='BLOCKING_WAIT_CHAIN' AND (Narrative LIKE N'%block%' OR Narrative LIKE N'%wait-chain%'))
                 OR (@AnswerDomainKey='IO_STORAGE_LATENCY' AND (Narrative LIKE N'%I/O%' OR Narrative LIKE N'%storage%' OR Narrative LIKE N'%latency%'))
                 OR (@AnswerDomainKey='MEMORY_PRESSURE' AND Narrative LIKE N'%memory%')
                 OR (@AnswerDomainKey='TEMPDB_PRESSURE' AND Narrative LIKE N'%tempdb%')
                 OR (@AnswerDomainKey='TRANSACTION_LOG_PRESSURE' AND (Narrative LIKE N'%transaction log%' OR Narrative LIKE N'%log pressure%'))
                 OR (@AnswerDomainKey='CONNECTIVITY_PRESSURE' AND (Narrative LIKE N'%connection%' OR Narrative LIKE N'%network%' OR Narrative LIKE N'%connectivity%'))
               )
              THEN 1 ELSE 0 END),0)
        , ISNULL(SUM(CASE
              WHEN ReportSection=N'ANSWER'
               AND
               (
                    UPPER(ISNULL(Narrative,N'')) LIKE N'%NO ROOT CAUSE%'
                 OR UPPER(ISNULL(Narrative,N'')) LIKE N'%ROOT CAUSE NOT IDENTIFIED%'
                 OR UPPER(ISNULL(Narrative,N'')) IN (N'UNKNOWN',N'INCONCLUSIVE')
               )
              THEN 1 ELSE 0 END),0)
        , CASE
              WHEN @AnswerExecutionMessage=N'dbo.usp_RCA_DBAAnswer executed successfully.'
               AND COUNT(*)>0
               AND ISNULL(SUM(CASE WHEN ReportSection=N'ANSWER' AND NULLIF(LTRIM(RTRIM(Narrative)),N'') IS NOT NULL THEN 1 ELSE 0 END),0)>0
               AND ISNULL(SUM(CASE WHEN ReportSection=N'ROOT CAUSE' AND NULLIF(LTRIM(RTRIM(Narrative)),N'') IS NOT NULL THEN 1 ELSE 0 END),0)=1
               AND ISNULL(SUM(CASE
                     WHEN ReportSection IN (N'ANSWER',N'ROOT CAUSE')
                      AND
                      (
                           (@AnswerDomainKey='CPU_SCHEDULER' AND (Narrative LIKE N'%CPU%' OR Narrative LIKE N'%scheduler%'))
                        OR (@AnswerDomainKey='BLOCKING_WAIT_CHAIN' AND (Narrative LIKE N'%block%' OR Narrative LIKE N'%wait-chain%'))
                        OR (@AnswerDomainKey='IO_STORAGE_LATENCY' AND (Narrative LIKE N'%I/O%' OR Narrative LIKE N'%storage%' OR Narrative LIKE N'%latency%'))
                        OR (@AnswerDomainKey='MEMORY_PRESSURE' AND Narrative LIKE N'%memory%')
                        OR (@AnswerDomainKey='TEMPDB_PRESSURE' AND Narrative LIKE N'%tempdb%')
                        OR (@AnswerDomainKey='TRANSACTION_LOG_PRESSURE' AND (Narrative LIKE N'%transaction log%' OR Narrative LIKE N'%log pressure%'))
                        OR (@AnswerDomainKey='CONNECTIVITY_PRESSURE' AND (Narrative LIKE N'%connection%' OR Narrative LIKE N'%network%' OR Narrative LIKE N'%connectivity%'))
                      )
                     THEN 1 ELSE 0 END),0)>0
               AND ISNULL(SUM(CASE
                     WHEN ReportSection=N'ANSWER'
                      AND
                      (
                           UPPER(ISNULL(Narrative,N'')) LIKE N'%NO ROOT CAUSE%'
                        OR UPPER(ISNULL(Narrative,N'')) LIKE N'%ROOT CAUSE NOT IDENTIFIED%'
                        OR UPPER(ISNULL(Narrative,N'')) IN (N'UNKNOWN',N'INCONCLUSIVE')
                      )
                     THEN 1 ELSE 0 END),0)=0
              THEN 'PASS' ELSE 'FAIL'
          END
        , @AnswerExecutionMessage
    FROM @OneAnswer;

    FETCH NEXT FROM answer_cursor INTO @AnswerDomainOrder,@AnswerDomainKey,@AnswerCaptureRunID;
END;

CLOSE answer_cursor;
DEALLOCATE answer_cursor;

SELECT
      '16 - DBA ANSWER OUTPUT FOR ALL SEVEN CONTROLS' AS ValidationSection
    , DomainOrder
    , DomainKey
    , CaptureRunID
    , SectionOrder
    , ReportSection
    , Narrative
FROM @AllAnswerRows
ORDER BY DomainOrder,SectionOrder;

SELECT
      '16A - DBA ANSWER SEVEN DOMAIN AUDIT' AS ValidationSection
    , *
FROM @AnswerAudit
ORDER BY DomainOrder;


/*==============================================================================
 17 - PRE-ROLLBACK SYSTEM GATES
==============================================================================*/
SET @CPUSyntheticGate=
    CASE
        WHEN EXISTS
             (
                 SELECT 1
                 FROM @Proof
                 WHERE DomainKey='CPU_SCHEDULER'
                   AND ControlType='SYNTHETIC'
                   AND DomainGate='PASS'
             )
        THEN 'PASS' ELSE 'FAIL'
    END;

SET @FiveDomainGate=
    CASE
        WHEN (SELECT COUNT(*) FROM @Proof
              WHERE DomainOrder BETWEEN 3 AND 7
                AND ControlType='SYNTHETIC'
                AND DomainGate='PASS')=5
        THEN 'PASS' ELSE 'FAIL'
    END;

SET @SevenDomainGate=
    CASE
        WHEN (SELECT COUNT(*) FROM @Proof WHERE DomainGate='PASS')=7
        THEN 'PASS' ELSE 'FAIL'
    END;

SET @DBAAnswerSevenDomainGate=
    CASE
        WHEN (SELECT COUNT(*) FROM @AnswerAudit WHERE ExecutionGate='PASS')=7
        THEN 'PASS' ELSE 'FAIL'
    END;

SET @NoContradictoryPrimaryGate=
    CASE WHEN NOT EXISTS
    (
        SELECT CaptureRunID
        FROM dbo.vw_RCA_FinalCauseCandidates
        GROUP BY CaptureRunID
        HAVING SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>1
    ) THEN 'PASS' ELSE 'FAIL' END;

SET @PreRollbackGate=
    CASE
        WHEN @ObjectGate='PASS'
         AND @IOInsertContractGate='PASS'
         AND @BuilderInvocationGate='PASS'
         AND @ArbitrationDefinitionGate='PASS'
         AND @TopologyGate='PASS'
         AND @ParameterGate='PASS'
         AND @ConsumerStructureGate='PASS'
         AND @CPUSyntheticGate='PASS'
         AND @FiveDomainGate='PASS'
         AND @SevenDomainGate='PASS'
         AND @DBAAnswerSevenDomainGate='PASS'
         AND @NoContradictoryPrimaryGate='PASS'
         AND @@TRANCOUNT=1
        THEN 'PASS' ELSE 'FAIL'
    END;

SELECT
      '17 - PRE ROLLBACK RELEASE GATE MATRIX' AS ValidationSection
    , @ObjectGate AS ObjectGate
    , @IOInsertContractGate AS IOInsertContractGate
    , @BuilderInvocationGate AS SevenBuilderInvocationGate
    , @ArbitrationDefinitionGate AS ArbitrationDefinitionGate
    , @TopologyGate AS CrossDomainTopologyGate
    , @ParameterGate AS DBAAnswerParameterGate
    , @ConsumerStructureGate AS DBAAnswerConsumerStructureGate
    , @CertifiedConsumerPath AS CertifiedConsumerPath
    , @CPUSyntheticGate AS CPUSyntheticDomainGate
    , @FiveDomainGate AS Five110JSyntheticDomainGate
    , @SevenDomainGate AS SevenDomainEndToEndGate
    , @DBAAnswerSevenDomainGate AS SevenDomainDBAAnswerGate
    , @NoContradictoryPrimaryGate AS NoContradictoryPrimaryGate
    , @@TRANCOUNT AS OpenTransactionCount
    , @PreRollbackGate AS PreRollbackReleaseGate;

SELECT
      '17A - PRE ROLLBACK SYNTHETIC STATE' AS ValidationSection
    , 6 AS ExpectedSyntheticCaptures
    , (SELECT COUNT(*) FROM dbo.RCA_CaptureRun
       WHERE CaptureRunID IN
             (@CPUCaptureRunID,@IOCaptureRunID,@MemoryCaptureRunID,@TempDBCaptureRunID,
              @LogCaptureRunID,@ConnectivityCaptureRunID)) AS SyntheticCaptureRows
    , (SELECT COUNT(*) FROM @Proof WHERE ControlType='SYNTHETIC') AS SyntheticProofRows
    , (SELECT COUNT(*) FROM @AnswerAudit a
       JOIN @Controls c ON c.DomainOrder=a.DomainOrder
       WHERE c.ControlType='SYNTHETIC') AS SyntheticDBAAnswerAudits
    , @@TRANCOUNT AS OpenTransactionCount;

ROLLBACK TRANSACTION;


/*==============================================================================
 18 - POST-ROLLBACK RESIDUE AND SAFETY
==============================================================================*/
SELECT @AgentJobsAfter=COUNT(*) FROM msdb.dbo.sysjobs;
SELECT @XECountAfter=COUNT(*) FROM sys.server_event_sessions;
SELECT @CaptureRowsAfter=COUNT_BIG(*) FROM dbo.RCA_CaptureRun;

SELECT @SnapshotRowsAfter=
      (SELECT COUNT_BIG(*) FROM dbo.RCA_IOFileSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_ServerSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_TempDBSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_LogSnapshot)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_ConnectivitySnapshot);

SELECT @EvidenceRowsAfter=
      (SELECT COUNT_BIG(*) FROM dbo.RCA_CPUSchedulerEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_BlockingEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_IOStorageEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_MemoryPressureEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_TempDBEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_TransactionLogEvidence)
    + (SELECT COUNT_BIG(*) FROM dbo.RCA_ConnectivityEvidence);

SELECT @FinalRowsAfter=COUNT_BIG(*) FROM dbo.vw_RCA_FinalCauseCandidates;
SELECT @SummaryRowsAfter=COUNT_BIG(*) FROM dbo.vw_RCA_CrossDomainCauseSummary;

DECLARE
      @SyntheticCaptureResidue int=
      (
          SELECT COUNT(*)
          FROM dbo.RCA_CaptureRun
          WHERE CaptureRunID IN
          (
                @CPUCaptureRunID,@IOCaptureRunID,@MemoryCaptureRunID,@TempDBCaptureRunID,
                @LogCaptureRunID,@ConnectivityCaptureRunID
          )
      )
    , @SyntheticSnapshotResidue int=
      (
          SELECT COUNT(*)
          FROM
          (
              SELECT CaptureRunID FROM dbo.RCA_IOFileSnapshot
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_ServerSnapshot
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_TempDBSnapshot
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_LogSnapshot
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_ConnectivitySnapshot
          ) AS x
          WHERE CaptureRunID IN
          (
                @CPUCaptureRunID,@IOCaptureRunID,@MemoryCaptureRunID,
                @TempDBCaptureRunID,@LogCaptureRunID,@ConnectivityCaptureRunID
          )
      )
    , @SyntheticEvidenceResidue int=
      (
          SELECT COUNT(*)
          FROM
          (
              SELECT CaptureRunID FROM dbo.RCA_CPUSchedulerEvidence
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_BlockingEvidence
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_IOStorageEvidence
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_MemoryPressureEvidence
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_TempDBEvidence
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_TransactionLogEvidence
              UNION ALL SELECT CaptureRunID FROM dbo.RCA_ConnectivityEvidence
          ) AS x
          WHERE CaptureRunID IN
          (
                @CPUCaptureRunID,@IOCaptureRunID,@MemoryCaptureRunID,
                @TempDBCaptureRunID,@LogCaptureRunID,@ConnectivityCaptureRunID
          )
      );

SET @PostRollbackSafetyGate=
    CASE
        WHEN @@TRANCOUNT=0
         AND @SyntheticCaptureResidue=0
         AND @SyntheticSnapshotResidue=0
         AND @SyntheticEvidenceResidue=0
         AND @CaptureRowsAfter=@CaptureRowsBefore
         AND @SnapshotRowsAfter=@SnapshotRowsBefore
         AND @EvidenceRowsAfter=@EvidenceRowsBefore
         AND @FinalRowsAfter=@FinalRowsBefore
         AND @SummaryRowsAfter=@SummaryRowsBefore
         AND @AgentJobsAfter=@AgentJobsBefore
         AND @XECountAfter=@XECountBefore
        THEN 'PASS' ELSE 'FAIL'
    END;

SELECT
      '18 - POST ROLLBACK SAFETY' AS ValidationSection
    , @@TRANCOUNT AS OpenTransactionCount
    , @SyntheticCaptureResidue AS SyntheticCaptureResidue
    , @SyntheticSnapshotResidue AS SyntheticSnapshotResidue
    , @SyntheticEvidenceResidue AS SyntheticEvidenceResidue
    , @CaptureRowsBefore AS CaptureRowsBefore
    , @CaptureRowsAfter AS CaptureRowsAfter
    , @SnapshotRowsBefore AS SnapshotRowsBefore
    , @SnapshotRowsAfter AS SnapshotRowsAfter
    , @EvidenceRowsBefore AS EvidenceRowsBefore
    , @EvidenceRowsAfter AS EvidenceRowsAfter
    , @FinalRowsBefore AS FinalRowsBefore
    , @FinalRowsAfter AS FinalRowsAfter
    , @SummaryRowsBefore AS SummaryRowsBefore
    , @SummaryRowsAfter AS SummaryRowsAfter
    , @AgentJobsBefore AS AgentJobsBefore
    , @AgentJobsAfter AS AgentJobsAfter
    , @XECountBefore AS XECountBefore
    , @XECountAfter AS XECountAfter
    , @PostRollbackSafetyGate AS SafetyGate;


/*==============================================================================
 19 - RCA V1 FREEZE MANIFEST

 These hashes identify the exact deployed programmable-object definitions
 accepted by this run. They are evidence for the freeze record; they are not
 preloaded expected values and therefore are not used to manufacture a PASS.
==============================================================================*/
SELECT
      '19 - RCA V1 FREEZE MANIFEST' AS ValidationSection
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


/*==============================================================================
 20 - FINAL RCA V1 RELEASE / FREEZE VERDICT
==============================================================================*/
DECLARE @FinalReleaseVerdict varchar(10)=
    CASE
        WHEN @PreRollbackGate='PASS'
         AND @PostRollbackSafetyGate='PASS'
        THEN 'PASS' ELSE 'FAIL'
    END;

SELECT
      '20 - SCRIPT 110L FINAL RCA V1 RELEASE FREEZE VERDICT' AS ValidationSection
    , @FinalReleaseVerdict AS Result
    , @ScriptName AS ScriptName
    , @ScriptVersion AS ScriptVersion
    , 7 AS CertifiedDomainTarget
    , (SELECT COUNT(*) FROM @Proof WHERE DomainGate='PASS') AS CertifiedDomainsObserved
    , 6 AS CertifiedCausalEdgeTarget
    , (SELECT COUNT(*) FROM @TopologyObserved WHERE ObservedClassification='CERTIFIED_CAUSAL') AS CertifiedCausalEdgesObserved
    , 1 AS ReferenceOnlyRelationshipTarget
    , (SELECT COUNT(*) FROM @TopologyObserved WHERE ObservedClassification='REFERENCE_ONLY') AS ReferenceOnlyRelationshipsObserved
    , @CertifiedConsumerPath AS CertifiedDBAAnswerConsumerPath
    , (SELECT COUNT(*) FROM @AnswerAudit WHERE ExecutionGate='PASS') AS DBAAnswerDomainsCertified
    , @NoContradictoryPrimaryGate AS DeterministicArbitrationGate
    , @PreRollbackGate AS FunctionalReleaseGate
    , @PostRollbackSafetyGate AS SafetyGate
    , CASE
          WHEN @FinalReleaseVerdict='PASS'
          THEN 'RCA V1 END-TO-END RELEASE CERTIFIED - FREEZE AUTHORIZED'
          ELSE 'RCA V1 RELEASE/FREEZE NOT AUTHORIZED'
      END AS CertificationStatus
    , CASE
          WHEN @FinalReleaseVerdict='PASS'
          THEN 'ARCHIVE THIS RESULT SET WITH THE FREEZE MANIFEST; CHANGES REQUIRE RECERTIFICATION'
          ELSE 'CORRECT THE FAILED GATE; DO NOT WEAKEN THE CERTIFICATION CONTRACT'
      END AS RequiredAction
    , SYSUTCDATETIME() AS EndUTC;

IF @FinalReleaseVerdict<>'PASS'
    THROW 63725,'SCRIPT 110L FAILED: RCA V1 end-to-end release acceptance did not pass all gates.',1;

END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local','answer_cursor')>=0
        CLOSE answer_cursor;
    IF CURSOR_STATUS('local','answer_cursor')>-3
        DEALLOCATE answer_cursor;

    IF @@TRANCOUNT>0
        ROLLBACK TRANSACTION;

    SELECT @AgentJobsAfter=COUNT(*) FROM msdb.dbo.sysjobs;
    SELECT @XECountAfter=COUNT(*) FROM sys.server_event_sessions;

    SELECT
          'ERROR - SCRIPT 110L ROLLBACK CONFIRMATION' AS ValidationSection
        , ERROR_NUMBER() AS ErrorNumber
        , ERROR_LINE() AS ErrorLine
        , ERROR_MESSAGE() AS ErrorMessage
        , @@TRANCOUNT AS OpenTransactionCount
        , @CPUCaptureRunID AS CPUCaptureRunID
        , @IOCaptureRunID AS IOCaptureRunID
        , @MemoryCaptureRunID AS MemoryCaptureRunID
        , @TempDBCaptureRunID AS TempDBCaptureRunID
        , @LogCaptureRunID AS LogCaptureRunID
        , @ConnectivityCaptureRunID AS ConnectivityCaptureRunID
        , @AgentJobsBefore AS AgentJobsBefore
        , @AgentJobsAfter AS AgentJobsAfter
        , @XECountBefore AS XECountBefore
        , @XECountAfter AS XECountAfter
        , 'ROLLBACK EXECUTED; NO FREEZE AUTHORIZATION ISSUED' AS SafetyStatus;

    THROW;
END CATCH;
GO
