USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  10_RCA_Parameter_Sensitive_Plan_Intelligence.sql

  PURPOSE
  -------
  Detect harmful parameter-sensitive plan reuse using evidence already captured.
  Includes integrated report-polish fixes: paired representative hashes, useful object names,
  and high-signal actual-plan analysis (no post-install patch required).

  HIGH-confidence evidence requires:
      1. Compiled parameter value differs from runtime value.
      2. A baseline execution exists where runtime = compiled value.
      3. Baseline and impacted execution share QueryHash + QueryPlanHash pairs.
      4. Impacted execution shows material resource regression.
      5. Cardinality evidence is retained as supporting proof.

  This is deliberately stricter than saying "parameter sniffing" whenever
  compiled and runtime values differ.

  DOES NOT CHANGE
  ---------------
  - Extended Events
  - raw XE evidence
  - plan correlation
  - existing capture tables
==============================================================================*/


/*==============================================================================
  1. EVIDENCE TABLE
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_ParameterSensitivePlanEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_ParameterSensitivePlanEvidence
    (
          ParameterSensitiveEvidenceID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_ParameterSensitivePlanEvidence PRIMARY KEY
        , CaptureRunID bigint NOT NULL
        , BaselineExecutionEvidenceID bigint NOT NULL
        , ImpactedExecutionEvidenceID bigint NOT NULL

        , ParameterName nvarchar(256) NOT NULL
        , CompiledValue nvarchar(1000) NULL
        , BaselineRuntimeValue nvarchar(1000) NULL
        , ImpactedRuntimeValue nvarchar(1000) NULL

        , SharedStatementPlanCount int NOT NULL
        , RepresentativeQueryHash varbinary(8) NULL
        , RepresentativeQueryPlanHash varbinary(8) NULL

        , BaselineDurationMs decimal(19,3) NULL
        , ImpactedDurationMs decimal(19,3) NULL
        , DurationRatio decimal(19,4) NULL

        , BaselineCPUms decimal(19,3) NULL
        , ImpactedCPUms decimal(19,3) NULL
        , CPURatio decimal(19,4) NULL

        , BaselineLogicalReads bigint NULL
        , ImpactedLogicalReads bigint NULL
        , LogicalReadRatio decimal(19,4) NULL

        , BaselineRows bigint NULL
        , ImpactedRows bigint NULL
        , RowRatio decimal(19,4) NULL

        , CardinalityMismatchCount int NOT NULL
        , HighSeverityCardinalityMismatchCount int NOT NULL

        , Confidence varchar(20) NOT NULL
        , EvidenceSummary nvarchar(max) NOT NULL
        , CreatedTimeUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_PSPE_Created DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_RCA_PSPE_Run_Execution_Parameter
        ON dbo.RCA_ParameterSensitivePlanEvidence
           (CaptureRunID,ImpactedExecutionEvidenceID,ParameterName);

    CREATE INDEX IX_RCA_PSPE_Run_Confidence
        ON dbo.RCA_ParameterSensitivePlanEvidence
           (CaptureRunID,Confidence,ImpactedExecutionEvidenceID);
END;
GO


/*==============================================================================
  2. READABLE VIEW
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_ParameterSensitivePlanEvidence
AS
SELECT
      p.ParameterSensitiveEvidenceID
    , p.CaptureRunID
    , p.BaselineExecutionEvidenceID
    , p.ImpactedExecutionEvidenceID
    , p.ParameterName
    , p.CompiledValue
    , p.BaselineRuntimeValue
    , p.ImpactedRuntimeValue
    , p.SharedStatementPlanCount
    , CONVERT(varchar(34),p.RepresentativeQueryHash,1) AS RepresentativeQueryHash
    , CONVERT(varchar(34),p.RepresentativeQueryPlanHash,1) AS RepresentativeQueryPlanHash
    , p.BaselineDurationMs
    , p.ImpactedDurationMs
    , p.DurationRatio
    , p.BaselineCPUms
    , p.ImpactedCPUms
    , p.CPURatio
    , p.BaselineLogicalReads
    , p.ImpactedLogicalReads
    , p.LogicalReadRatio
    , p.BaselineRows
    , p.ImpactedRows
    , p.RowRatio
    , p.CardinalityMismatchCount
    , p.HighSeverityCardinalityMismatchCount
    , p.Confidence
    , p.EvidenceSummary
FROM dbo.RCA_ParameterSensitivePlanEvidence p;
GO


/*==============================================================================
  3. DETECTOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildParameterSensitivePlanEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 66000,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_ParameterSensitivePlanEvidence
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_Recommendation
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseCategory='PARAMETER_SENSITIVE_PLAN_REUSE';

    ;WITH ParamValues AS
    (
        SELECT DISTINCT
              rp.ExecutionEvidenceID
            , rp.ParameterName
            , rp.ParameterCompiledValue
            , rp.ParameterRuntimeValue
        FROM dbo.RCA_RuntimeParameter rp
        WHERE rp.CaptureRunID=@CaptureRunID
          AND rp.ExecutionEvidenceID IS NOT NULL
          AND rp.ParameterName IS NOT NULL
    ),
    Impacted AS
    (
        SELECT *
        FROM ParamValues
        WHERE ISNULL(ParameterCompiledValue,N'') <>
              ISNULL(ParameterRuntimeValue,N'')
          AND ParameterCompiledValue IS NOT NULL
          AND ParameterRuntimeValue IS NOT NULL
    ),
    Baseline AS
    (
        SELECT *
        FROM ParamValues
        WHERE ISNULL(ParameterCompiledValue,N'') =
              ISNULL(ParameterRuntimeValue,N'')
          AND ParameterCompiledValue IS NOT NULL
    ),
    CandidatePairs AS
    (
        SELECT
              i.ExecutionEvidenceID AS ImpactedExecutionEvidenceID
            , b.ExecutionEvidenceID AS BaselineExecutionEvidenceID
            , i.ParameterName
            , i.ParameterCompiledValue AS CompiledValue
            , b.ParameterRuntimeValue AS BaselineRuntimeValue
            , i.ParameterRuntimeValue AS ImpactedRuntimeValue
        FROM Impacted i
        JOIN Baseline b
          ON b.ParameterName=i.ParameterName
         AND ISNULL(b.ParameterCompiledValue,N'') =
             ISNULL(i.ParameterCompiledValue,N'')
         AND b.ExecutionEvidenceID<>i.ExecutionEvidenceID
    ),
    SharedPlanPairs AS
    (
        SELECT DISTINCT
              c.ImpactedExecutionEvidenceID
            , c.BaselineExecutionEvidenceID
            , c.ParameterName
            , c.CompiledValue
            , c.BaselineRuntimeValue
            , c.ImpactedRuntimeValue
            , ip.QueryHash
            , ip.QueryPlanHash
        FROM CandidatePairs c
        JOIN
        (
            SELECT DISTINCT
                  LinkedExecutionEvidenceID
                , QueryHash
                , QueryPlanHash
            FROM dbo.RCA_PlanEvidence
            WHERE CaptureRunID=@CaptureRunID
              AND QueryHash IS NOT NULL
              AND QueryPlanHash IS NOT NULL
        ) ip
          ON ip.LinkedExecutionEvidenceID=c.ImpactedExecutionEvidenceID
        JOIN
        (
            SELECT DISTINCT
                  LinkedExecutionEvidenceID
                , QueryHash
                , QueryPlanHash
            FROM dbo.RCA_PlanEvidence
            WHERE CaptureRunID=@CaptureRunID
              AND QueryHash IS NOT NULL
              AND QueryPlanHash IS NOT NULL
        ) bp
          ON bp.LinkedExecutionEvidenceID=c.BaselineExecutionEvidenceID
         AND bp.QueryHash=ip.QueryHash
         AND bp.QueryPlanHash=ip.QueryPlanHash
    ),
    SharedPlansRanked AS
    (
        SELECT
              spp.*
            , COUNT(*) OVER
              (
                  PARTITION BY
                      spp.ImpactedExecutionEvidenceID,
                      spp.BaselineExecutionEvidenceID,
                      spp.ParameterName,
                      spp.CompiledValue,
                      spp.BaselineRuntimeValue,
                      spp.ImpactedRuntimeValue
              ) AS SharedStatementPlanCount
            , ROW_NUMBER() OVER
              (
                  PARTITION BY
                      spp.ImpactedExecutionEvidenceID,
                      spp.BaselineExecutionEvidenceID,
                      spp.ParameterName,
                      spp.CompiledValue,
                      spp.BaselineRuntimeValue,
                      spp.ImpactedRuntimeValue
                  ORDER BY spp.QueryHash,spp.QueryPlanHash
              ) AS RepresentativeRN
        FROM SharedPlanPairs spp
    ),
    SharedPlans AS
    (
        SELECT
              ImpactedExecutionEvidenceID
            , BaselineExecutionEvidenceID
            , ParameterName
            , CompiledValue
            , BaselineRuntimeValue
            , ImpactedRuntimeValue
            , SharedStatementPlanCount
            , QueryHash AS RepresentativeQueryHash
            , QueryPlanHash AS RepresentativeQueryPlanHash
        FROM SharedPlansRanked
        WHERE RepresentativeRN=1
    ),
    Evidence AS
    (
        SELECT
              sp.*
            , be.DurationMs AS BaselineDurationMs
            , ie.DurationMs AS ImpactedDurationMs
            , CAST(ie.DurationMs / NULLIF(be.DurationMs,0) AS decimal(19,4)) AS DurationRatio
            , be.CPUms AS BaselineCPUms
            , ie.CPUms AS ImpactedCPUms
            , CAST(ie.CPUms / NULLIF(be.CPUms,0) AS decimal(19,4)) AS CPURatio
            , be.LogicalReads AS BaselineLogicalReads
            , ie.LogicalReads AS ImpactedLogicalReads
            , CAST(1.0*ie.LogicalReads / NULLIF(be.LogicalReads,0) AS decimal(19,4)) AS LogicalReadRatio
            , be.TotalRows AS BaselineRows
            , ie.TotalRows AS ImpactedRows
            , CAST(1.0*ie.TotalRows / NULLIF(be.TotalRows,0) AS decimal(19,4)) AS RowRatio
            , CardinalityMismatchCount =
                (
                    SELECT COUNT(*)
                    FROM dbo.RCA_PlanFinding f
                    WHERE f.CaptureRunID=@CaptureRunID
                      AND f.ExecutionEvidenceID=sp.ImpactedExecutionEvidenceID
                      AND f.FindingType='CARDINALITY_MISMATCH'
                )
            , HighSeverityCardinalityMismatchCount =
                (
                    SELECT COUNT(*)
                    FROM dbo.RCA_PlanFinding f
                    WHERE f.CaptureRunID=@CaptureRunID
                      AND f.ExecutionEvidenceID=sp.ImpactedExecutionEvidenceID
                      AND f.FindingType='CARDINALITY_MISMATCH'
                      AND f.Severity='HIGH'
                )
        FROM SharedPlans sp
        JOIN dbo.RCA_ExecutionEvidence ie
          ON ie.ExecutionEvidenceID=sp.ImpactedExecutionEvidenceID
        JOIN dbo.RCA_ExecutionEvidence be
          ON be.ExecutionEvidenceID=sp.BaselineExecutionEvidenceID
    ),
    Ranked AS
    (
        SELECT
              e.*
            , RegressionSignals =
                (CASE WHEN ISNULL(e.DurationRatio,0)>=2 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.CPURatio,0)>=2 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.LogicalReadRatio,0)>=2 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.RowRatio,0)>=2 THEN 1 ELSE 0 END)
            , rn =
                ROW_NUMBER() OVER
                (
                    PARTITION BY e.ImpactedExecutionEvidenceID,e.ParameterName
                    ORDER BY
                        e.SharedStatementPlanCount DESC,
                        e.BaselineLogicalReads ASC,
                        e.BaselineCPUms ASC
                )
        FROM Evidence e
    )
    INSERT dbo.RCA_ParameterSensitivePlanEvidence
    (
          CaptureRunID
        , BaselineExecutionEvidenceID
        , ImpactedExecutionEvidenceID
        , ParameterName
        , CompiledValue
        , BaselineRuntimeValue
        , ImpactedRuntimeValue
        , SharedStatementPlanCount
        , RepresentativeQueryHash
        , RepresentativeQueryPlanHash
        , BaselineDurationMs
        , ImpactedDurationMs
        , DurationRatio
        , BaselineCPUms
        , ImpactedCPUms
        , CPURatio
        , BaselineLogicalReads
        , ImpactedLogicalReads
        , LogicalReadRatio
        , BaselineRows
        , ImpactedRows
        , RowRatio
        , CardinalityMismatchCount
        , HighSeverityCardinalityMismatchCount
        , Confidence
        , EvidenceSummary
    )
    SELECT
          @CaptureRunID
        , r.BaselineExecutionEvidenceID
        , r.ImpactedExecutionEvidenceID
        , r.ParameterName
        , LEFT(r.CompiledValue,1000)
        , LEFT(r.BaselineRuntimeValue,1000)
        , LEFT(r.ImpactedRuntimeValue,1000)
        , r.SharedStatementPlanCount
        , r.RepresentativeQueryHash
        , r.RepresentativeQueryPlanHash
        , r.BaselineDurationMs
        , r.ImpactedDurationMs
        , r.DurationRatio
        , r.BaselineCPUms
        , r.ImpactedCPUms
        , r.CPURatio
        , r.BaselineLogicalReads
        , r.ImpactedLogicalReads
        , r.LogicalReadRatio
        , r.BaselineRows
        , r.ImpactedRows
        , r.RowRatio
        , r.CardinalityMismatchCount
        , r.HighSeverityCardinalityMismatchCount
        , CASE
              WHEN r.SharedStatementPlanCount>=1
               AND r.RegressionSignals>=3
               AND r.HighSeverityCardinalityMismatchCount>0
              THEN 'HIGH'
              WHEN r.SharedStatementPlanCount>=1
               AND r.RegressionSignals>=2
              THEN 'MEDIUM'
              ELSE 'LOW'
          END
        , CONCAT
          (
              N'Parameter ',r.ParameterName,
              N' was compiled as ',COALESCE(r.CompiledValue,N'(NULL)'),
              N' but executed as ',COALESCE(r.ImpactedRuntimeValue,N'(NULL)'),
              N'. Baseline execution ',r.BaselineExecutionEvidenceID,
              N' used runtime value ',COALESCE(r.BaselineRuntimeValue,N'(NULL)'),
              N'. The executions shared ',r.SharedStatementPlanCount,
              N' statement QueryHash/QueryPlanHash pair(s). ',
              N'Duration ratio=',COALESCE(CONVERT(varchar(30),r.DurationRatio),'NULL'),
              N'x; CPU ratio=',COALESCE(CONVERT(varchar(30),r.CPURatio),'NULL'),
              N'x; logical-read ratio=',COALESCE(CONVERT(varchar(30),r.LogicalReadRatio),'NULL'),
              N'x; row ratio=',COALESCE(CONVERT(varchar(30),r.RowRatio),'NULL'),
              N'x. High-severity cardinality mismatches=',
              r.HighSeverityCardinalityMismatchCount,N'.'
          )
    FROM Ranked r
    WHERE r.rn=1
      AND r.SharedStatementPlanCount>=1
      AND r.RegressionSignals>=2;


    /* Convert HIGH/MEDIUM detector evidence into normal Recommendation rows. */
    INSERT dbo.RCA_Recommendation
    (
          CaptureRunID
        , ExecutionEvidenceID
        , Priority
        , Confidence
        , RootCauseCategory
        , RootCauseSummary
        , EvidenceSummary
        , WhyItMatters
        , RecommendedAction
        , EvidenceCount
        , HighSeverityFindingCount
        , MediumSeverityFindingCount
    )
    SELECT
          p.CaptureRunID
        , p.ImpactedExecutionEvidenceID
        , CASE WHEN p.Confidence='HIGH' THEN 1 ELSE 2 END
        , p.Confidence
        , 'PARAMETER_SENSITIVE_PLAN_REUSE'
        , N'Parameter-sensitive plan reuse is strongly supported by compiled/runtime parameter divergence, shared statement plan hashes, and material execution regression.'
        , p.EvidenceSummary
        , N'The same statement plan shape was reused for materially different runtime parameter values. The impacted execution processed substantially more work than the baseline and also exhibited cardinality-estimation problems.'
        , N'Validate whether the impacted parameter pattern is expected. In controlled testing, compare plan strategies appropriate to the different parameter distributions, then re-run the identical parameter sets and compare CPU, duration, reads, rows, estimates, plan hashes, and memory grants. Do not apply a blanket recompile or hint without measuring both parameter patterns.'
        , p.SharedStatementPlanCount
        , p.HighSeverityCardinalityMismatchCount
        , 0
    FROM dbo.RCA_ParameterSensitivePlanEvidence p
    WHERE p.CaptureRunID=@CaptureRunID
      AND p.Confidence IN ('HIGH','MEDIUM');


    SELECT
          CaptureRunID=@CaptureRunID
        , DetectedCases=COUNT(*)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_ParameterSensitivePlanEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
  4. APPLY DETECTOR TO SYNTHESIS
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ApplyParameterSensitiveSynthesis
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE s
       SET PrimaryCause =
             N'Parameter-sensitive plan reuse contributed materially to the regression: the execution reused statement plan hashes while runtime parameter values differed from the values captured at compilation.'
         , PrimaryEvidence =
             CONCAT(p.EvidenceSummary,N' ',s.PrimaryEvidence)
         , Action1 =
             N'Confirm the affected parameter pattern and reproduce both the baseline and impacted values in controlled testing.'
         , Action2 =
             N'Compare alternative plan strategies for the distinct parameter distributions; use the least invasive production-safe option supported by measured results.'
         , Action3 =
             N'Re-run the identical parameters and verify duration, CPU, logical reads, cardinality estimates, QueryPlanHash, memory grant, and access paths against this baseline.'
         , Confidence =
             CASE WHEN p.Confidence='HIGH' THEN 'HIGH' ELSE s.Confidence END
         , ExecutiveSummary =
             CONCAT
             (
                 N'Probable root cause: parameter-sensitive plan reuse. ',
                 p.ParameterName,N' was compiled as ',p.CompiledValue,
                 N' but executed as ',p.ImpactedRuntimeValue,
                 N' while ',p.SharedStatementPlanCount,
                 N' statement plan hash pair(s) were shared with baseline execution ',
                 p.BaselineExecutionEvidenceID,N'. ',
                 N'Logical reads increased ',
                 COALESCE(CONVERT(varchar(30),p.LogicalReadRatio),N'?'),N'x, CPU ',
                 COALESCE(CONVERT(varchar(30),p.CPURatio),N'?'),N'x, and duration ',
                 COALESCE(CONVERT(varchar(30),p.DurationRatio),N'?'),N'x. ',
                 N'The captured plans also contained ',
                 p.HighSeverityCardinalityMismatchCount,
                 N' high-severity cardinality mismatch finding(s). ',
                 CASE
                     WHEN s.RuledOutCause IS NOT NULL
                     THEN CONCAT(s.RuledOutCause,N' ')
                     ELSE N''
                 END,
                 N'Next action: test the distinct parameter distributions with measured plan alternatives and re-validate the identical runtime values.'
             )
    FROM dbo.RCA_RootCauseSynthesis s
    JOIN dbo.RCA_ParameterSensitivePlanEvidence p
      ON p.CaptureRunID=s.CaptureRunID
     AND p.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
    WHERE s.CaptureRunID=@CaptureRunID
      AND p.Confidence IN ('HIGH','MEDIUM');

    SELECT
          CaptureRunID=@CaptureRunID
        , SynthesesUpdated=@@ROWCOUNT;
END;
GO


/*==============================================================================
  5. UNIFIED ANALYSIS WORKFLOW
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_AnalyzeCaptureRun
      @CaptureRunID bigint
    , @Reparse bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reparse=1
        EXEC dbo.usp_RCA_ParseCaptureRun
             @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_BuildRecommendations
         @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_BuildParameterSensitivePlanEvidence
         @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_BuildRootCauseSynthesis
         @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_ApplyParameterSensitiveSynthesis
         @CaptureRunID=@CaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowIncidentReport
 @CaptureRunID bigint,
 @IncludeTechnicalEvidence bit=1
AS
BEGIN
 SET NOCOUNT ON;

 IF NOT EXISTS
 (
     SELECT 1
     FROM dbo.RCA_CaptureRun
     WHERE CaptureRunID=@CaptureRunID
 )
     THROW 63100,N'CaptureRunID does not exist.',1;

 /*==========================================================================
   RESULT 1 - INCIDENT SUMMARY
   Management-friendly: what happened, why, what was ruled out, what next.
 ==========================================================================*/
 SELECT
     N'1 - INCIDENT SUMMARY' AS ReportSection,
     CaptureRunID,
     TargetDatabase,
     CaptureReason,
     StartTimeUTC,
     EndTimeUTC,
     CaptureDurationSeconds,
     OverallConfidence,
     ConfidenceBasis,
     SynthesizedExecutions,
     PrimaryCause,
     MostImpactedExecutionEvidenceID,
     MostImpactedObject,
     CAST(DurationMs/1000.0 AS decimal(19,2)) AS DurationSeconds,
     CAST(CPUms/1000.0 AS decimal(19,2)) AS CPUSeconds,
     LogicalReads,
     Writes,
     TotalRows AS RowsAffected,
     ContributingFactor1,
     ContributingFactor2,
     RuledOutCause,
     RuledOutEvidence,
     Action1,
     Action2,
     Action3,
     ExecutiveSummary,
     PeakSqlCpuPercent,
     LowestBufferCacheHitRatio,
     LowestPLESeconds,
     LowestAvailablePhysicalMemoryMB,
     PeakMemoryGrantsPending,
     PeakRunnableTasks
 FROM dbo.vw_RCA_IncidentSummary
 WHERE CaptureRunID=@CaptureRunID;


 /*==========================================================================
   RESULT 2 - EXECUTION COMPARISON
   Shows the executions side-by-side by cost. ParameterText remains available
   here for quick context; Result 3 presents parsed runtime parameters.
 ==========================================================================*/
 SELECT
     N'2 - EXECUTION COMPARISON' AS ReportSection,
     ExecutionEvidenceID,
     EventTimeUTC,
     ObjectName,
     Confidence,
     CAST(DurationMs/1000.0 AS decimal(19,2)) AS DurationSeconds,
     CAST(CPUms/1000.0 AS decimal(19,2)) AS CPUSeconds,
     LogicalReads,
     PhysicalReads,
     Writes,
     TotalRows AS RowsAffected,
     LinkedActualPlans,
     Assessment,
     ParameterText
 FROM dbo.vw_RCA_ExecutionComparison
 WHERE CaptureRunID=@CaptureRunID
 ORDER BY DurationMs DESC,CPUms DESC,LogicalReads DESC;


 IF @IncludeTechnicalEvidence=1
 BEGIN
     /*======================================================================
       RESULT 3 - PARAMETER-SENSITIVE PLAN EVIDENCE
       This is intentionally concise.  It surfaces only cases where:
         - a runtime parameter differs from its compiled value,
         - the impacted execution shares statement plan hashes with a baseline,
         - and the impacted execution materially regressed.
     ======================================================================*/
     SELECT
         N'3 - PARAMETER-SENSITIVE PLAN EVIDENCE' AS ReportSection,
         ps.ImpactedExecutionEvidenceID AS ExecutionEvidenceID,
         ps.BaselineExecutionEvidenceID,
         ps.ParameterName,
         ps.CompiledValue,
         ps.BaselineRuntimeValue,
         ps.ImpactedRuntimeValue,
         ps.SharedStatementPlanCount,
         CONVERT(varchar(34),ps.RepresentativeQueryHash,1) AS RepresentativeQueryHash,
         CONVERT(varchar(34),ps.RepresentativeQueryPlanHash,1) AS RepresentativeQueryPlanHash,
         ps.BaselineDurationMs,
         ps.ImpactedDurationMs,
         ps.DurationRatio,
         ps.BaselineCPUms,
         ps.ImpactedCPUms,
         ps.CPURatio,
         ps.BaselineLogicalReads,
         ps.ImpactedLogicalReads,
         ps.LogicalReadRatio,
         ps.BaselineRows,
         ps.ImpactedRows,
         ps.RowRatio,
         ps.CardinalityMismatchCount,
         ps.HighSeverityCardinalityMismatchCount,
         ps.Confidence,
         ps.EvidenceSummary
     FROM dbo.RCA_ParameterSensitivePlanEvidence ps
     WHERE ps.CaptureRunID=@CaptureRunID
     ORDER BY
         CASE ps.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
         ps.LogicalReadRatio DESC,
         ps.CPURatio DESC;


     /*======================================================================
       RESULT 4 - RUNTIME PARAMETERS
       One row per execution/parameter/value. Duplicate parameter evidence
       from multiple statement-level plans is collapsed.
     ======================================================================*/
     ;WITH P AS
     (
         SELECT
             rp.ExecutionEvidenceID,
             rp.ParameterName,
             rp.ParameterDataType,
             rp.ParameterCompiledValue,
             rp.ParameterRuntimeValue,
             rp.EvidenceSource,
             ROW_NUMBER() OVER
             (
                 PARTITION BY
                     rp.ExecutionEvidenceID,
                     rp.ParameterName,
                     COALESCE(rp.ParameterRuntimeValue,N''),
                     COALESCE(rp.ParameterCompiledValue,N'')
                 ORDER BY rp.PlanEvidenceID,rp.RuntimeParameterID
             ) AS rn
         FROM dbo.RCA_RuntimeParameter rp
         WHERE rp.CaptureRunID=@CaptureRunID
           AND rp.ExecutionEvidenceID IS NOT NULL
     )
     SELECT
         N'4 - RUNTIME PARAMETERS' AS ReportSection,
         p.ExecutionEvidenceID,
         e.EventTimeUTC,
         CASE
              WHEN e.ObjectName IS NOT NULL AND e.ObjectName<>N'Ad hoc / batch execution' THEN e.ObjectName
              WHEN e.ParameterText LIKE N'%usp_RCA_PerformanceQuery%' THEN N'dbo.usp_RCA_PerformanceQuery'
              ELSE COALESCE(e.ObjectName,N'Ad hoc / batch execution')
          END AS ObjectName,
         p.ParameterName,
         p.ParameterDataType,
         p.ParameterCompiledValue AS CompiledValue,
         p.ParameterRuntimeValue AS RuntimeValue,
         CASE
             WHEN ISNULL(p.ParameterCompiledValue,N'') <>
                  ISNULL(p.ParameterRuntimeValue,N'')
             THEN 'YES' ELSE 'NO'
         END AS RuntimeDiffersFromCompiled,
         p.EvidenceSource
     FROM P p
     JOIN dbo.RCA_ExecutionEvidence e
       ON e.ExecutionEvidenceID=p.ExecutionEvidenceID
     WHERE p.rn=1
     ORDER BY e.DurationMs DESC,p.ExecutionEvidenceID,p.ParameterName;


     /*======================================================================
       RESULT 5 - ACTUAL PLAN ANALYSIS
       Only actionable/high-signal operators are surfaced.
       Full actual plans remain available in Result 6.
     ======================================================================*/
     ;WITH PlanAnalysis AS
     (
         SELECT
               p.LinkedExecutionEvidenceID AS ExecutionEvidenceID
             , o.PlanEvidenceID
             , o.NodeID
             , o.PhysicalOp
             , o.LogicalOp
             , o.EstimateRows
             , o.ActualRows
             , o.ActualRowsRead
             , o.ActualExecutions
             , o.EstimateActualRatio
             , o.EstimatedSubtreeCost
             , o.Parallel
             , o.DatabaseName
             , o.SchemaName
             , o.TableName
             , o.IndexName
             , o.IndexKind
             , o.Storage
             , o.HasSpillWarning
             , o.HasImplicitConversion
             , FindingPriority =
                 CASE
                     WHEN o.HasSpillWarning=1 THEN 1
                     WHEN o.EstimateActualRatio>=100
                       OR (o.EstimateActualRatio>0 AND o.EstimateActualRatio<=0.01) THEN 2
                     WHEN o.EstimateActualRatio>=10
                       OR (o.EstimateActualRatio>0 AND o.EstimateActualRatio<=0.10) THEN 3
                     WHEN o.HasImplicitConversion=1
                      AND (o.PhysicalOp LIKE '%Scan%' OR o.PhysicalOp LIKE '%Seek%') THEN 4
                     WHEN o.PhysicalOp LIKE '%Scan%' AND ISNULL(o.ActualRowsRead,0)>=100000 THEN 5
                     ELSE 99
                 END
             , OperatorAssessment =
                 CASE
                     WHEN o.HasSpillWarning=1 THEN 'HIGH - SPILL'
                     WHEN o.EstimateActualRatio>=100
                       OR (o.EstimateActualRatio>0 AND o.EstimateActualRatio<=0.01)
                         THEN 'HIGH - CARDINALITY MISMATCH'
                     WHEN o.EstimateActualRatio>=10
                       OR (o.EstimateActualRatio>0 AND o.EstimateActualRatio<=0.10)
                         THEN 'MEDIUM - CARDINALITY MISMATCH'
                     WHEN o.HasImplicitConversion=1
                      AND (o.PhysicalOp LIKE '%Scan%' OR o.PhysicalOp LIKE '%Seek%')
                         THEN 'REVIEW - IMPLICIT CONVERSION'
                     WHEN o.PhysicalOp LIKE '%Scan%' AND ISNULL(o.ActualRowsRead,0)>=100000
                         THEN 'REVIEW - LARGE SCAN'
                     ELSE 'INFO'
                 END
         FROM dbo.RCA_PlanOperator o
         JOIN dbo.RCA_PlanEvidence p
           ON p.PlanEvidenceID=o.PlanEvidenceID
          AND p.CaptureRunID=o.CaptureRunID
         WHERE o.CaptureRunID=@CaptureRunID
           AND p.LinkedExecutionEvidenceID IS NOT NULL
     ),
     RankedPlanAnalysis AS
     (
         SELECT
               pa.*
             , ROW_NUMBER() OVER
               (
                   PARTITION BY
                       pa.ExecutionEvidenceID,pa.PlanEvidenceID,pa.OperatorAssessment,
                       ISNULL(pa.DatabaseName,N''),ISNULL(pa.SchemaName,N''),
                       ISNULL(pa.TableName,N''),ISNULL(pa.IndexName,N'')
                   ORDER BY
                       pa.FindingPriority,
                       ISNULL(pa.ActualRowsRead,pa.ActualRows) DESC,
                       pa.EstimatedSubtreeCost DESC,
                       pa.NodeID
               ) AS FindingRN
         FROM PlanAnalysis pa
         WHERE pa.FindingPriority<99
     )
     SELECT TOP (50)
           N'5 - ACTUAL PLAN ANALYSIS' AS ReportSection
         , ExecutionEvidenceID
         , PlanEvidenceID
         , NodeID
         , PhysicalOp
         , LogicalOp
         , EstimateRows
         , ActualRows
         , ActualRowsRead
         , ActualExecutions
         , EstimateActualRatio
         , EstimatedSubtreeCost
         , Parallel
         , DatabaseName
         , SchemaName
         , TableName
         , IndexName
         , IndexKind
         , Storage
         , HasSpillWarning
         , HasImplicitConversion
         , OperatorAssessment
     FROM RankedPlanAnalysis
     WHERE FindingRN=1
     ORDER BY
           FindingPriority
         , ISNULL(ActualRowsRead,ActualRows) DESC
         , EstimatedSubtreeCost DESC;


     /*======================================================================
       RESULT 6 - CAPTURED ACTUAL EXECUTION PLANS
       ActualExecutionPlanXML remains XML so SSMS exposes the captured plan
       evidence for DBA inspection.
     ======================================================================*/
     SELECT
         N'6 - CAPTURED ACTUAL PLANS' AS ReportSection,
         p.LinkedExecutionEvidenceID AS ExecutionEvidenceID,
         p.PlanEvidenceID,
         p.EventTimeUTC,
         p.DatabaseName,
         p.SessionID,
         CASE
              WHEN e.ObjectName IS NOT NULL AND e.ObjectName<>N'Ad hoc / batch execution' THEN e.ObjectName
              WHEN e.ParameterText LIKE N'%usp_RCA_PerformanceQuery%' THEN N'dbo.usp_RCA_PerformanceQuery'
              ELSE COALESCE(e.ObjectName,N'Ad hoc / batch execution')
          END AS ObjectName,
         e.ParameterText,
         p.RequestedMemoryKB,
         p.GrantedMemoryKB,
         p.MaxUsedMemoryKB,
         p.ActualDOP,
         p.QueryHash,
         p.QueryPlanHash,
         p.PlanHandle,
         p.SQLText,
         p.ActualExecutionPlanXML
     FROM dbo.RCA_PlanEvidence p
     LEFT JOIN dbo.RCA_ExecutionEvidence e
       ON e.ExecutionEvidenceID=p.LinkedExecutionEvidenceID
     WHERE p.CaptureRunID=@CaptureRunID
       AND p.ActualExecutionPlanXML IS NOT NULL
     ORDER BY
         e.DurationMs DESC,
         p.LinkedExecutionEvidenceID,
         p.EventTimeUTC,
         p.PlanEvidenceID;
 END;
END;
GO


/*==============================================================================
  6. INSTALL VALIDATION
==============================================================================*/
SELECT
      EvidenceTable =
          CASE WHEN OBJECT_ID(N'dbo.RCA_ParameterSensitivePlanEvidence',N'U') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , EvidenceView =
          CASE WHEN OBJECT_ID(N'dbo.vw_RCA_ParameterSensitivePlanEvidence',N'V') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , Detector =
          CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildParameterSensitivePlanEvidence',N'P') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , SynthesisPatch =
          CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyParameterSensitiveSynthesis',N'P') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , AnalyzeWorkflow =
          CASE WHEN OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , IncidentReport =
          CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ShowIncidentReport',N'P') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
  RUN 3 TEST
==============================================================================*/
/*
USE DBA;
GO

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID=3,
     @Reparse=0;
GO

SELECT *
FROM dbo.vw_RCA_ParameterSensitivePlanEvidence
WHERE CaptureRunID=3
ORDER BY LogicalReadRatio DESC,CPURatio DESC;
GO

EXEC dbo.usp_RCA_ShowIncidentReport
     @CaptureRunID=3,
     @IncludeTechnicalEvidence=1;
GO
*/
