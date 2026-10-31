USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  12_RCA_Multi_Cause_Intelligence_v3.sql

  PURPOSE
  -------
  Extend the RCA engine with independent parameter-sensitive-plan and statistics/cardinality-regression detectors using evidence already captured.
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
  5. STATISTICS / CARDINALITY REGRESSION INTELLIGENCE

  PURPOSE
  -------
  Detect cases where materially modified statistics used by the captured actual
  plan coincide with severe cardinality-estimation error and measurable execution
  regression.

  This detector is intentionally separate from parameter-sensitive-plan reuse.
  It does NOT require compiled/runtime parameter divergence.

  Thresholds are procedure parameters so the framework is not permanently tied
  to one absolute modification-count definition.
==============================================================================*/


/*==============================================================================
  5.1 EVIDENCE TABLE
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_StatisticsCardinalityEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_StatisticsCardinalityEvidence
    (
          StatisticsCardinalityEvidenceID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_StatisticsCardinalityEvidence PRIMARY KEY
        , CaptureRunID bigint NOT NULL
        , BaselineExecutionEvidenceID bigint NULL
        , ImpactedExecutionEvidenceID bigint NOT NULL
        , RepresentativePlanEvidenceID bigint NULL

        , DatabaseName nvarchar(256) NULL
        , SchemaName nvarchar(256) NULL
        , TableName nvarchar(512) NULL
        , StatisticsName nvarchar(512) NULL

        , LastUpdate datetime2(7) NULL
        , ModificationCount bigint NULL
        , SamplingPercent decimal(19,6) NULL
        , StatsAgeHours decimal(19,3) NULL

        , CardinalityMismatchCount int NOT NULL
        , HighSeverityCardinalityMismatchCount int NOT NULL
        , LargeScanCount int NOT NULL
        , StatisticsRiskCount int NOT NULL
        , WorstEstimateActualRatio decimal(38,6) NULL

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

        , Confidence varchar(20) NOT NULL
        , EvidenceSummary nvarchar(max) NOT NULL
        , CreatedTimeUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_SCE_Created DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_RCA_SCE_Run_Execution
        ON dbo.RCA_StatisticsCardinalityEvidence
           (CaptureRunID,ImpactedExecutionEvidenceID);

    CREATE INDEX IX_RCA_SCE_Run_Confidence
        ON dbo.RCA_StatisticsCardinalityEvidence
           (CaptureRunID,Confidence,ImpactedExecutionEvidenceID);
END;
GO


/*==============================================================================
  5.2 READABLE VIEW
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_StatisticsCardinalityEvidence
AS
SELECT
      e.StatisticsCardinalityEvidenceID
    , e.CaptureRunID
    , e.BaselineExecutionEvidenceID
    , e.ImpactedExecutionEvidenceID
    , e.RepresentativePlanEvidenceID
    , e.DatabaseName
    , e.SchemaName
    , e.TableName
    , e.StatisticsName
    , e.LastUpdate
    , e.ModificationCount
    , e.SamplingPercent
    , e.StatsAgeHours
    , e.CardinalityMismatchCount
    , e.HighSeverityCardinalityMismatchCount
    , e.LargeScanCount
    , e.StatisticsRiskCount
    , e.WorstEstimateActualRatio
    , e.BaselineDurationMs
    , e.ImpactedDurationMs
    , e.DurationRatio
    , e.BaselineCPUms
    , e.ImpactedCPUms
    , e.CPURatio
    , e.BaselineLogicalReads
    , e.ImpactedLogicalReads
    , e.LogicalReadRatio
    , e.BaselineRows
    , e.ImpactedRows
    , e.RowRatio
    , e.Confidence
    , e.EvidenceSummary
    , e.CreatedTimeUTC
FROM dbo.RCA_StatisticsCardinalityEvidence e;
GO


/*==============================================================================
  5.3 DETECTOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildStatisticsCardinalityEvidence
      @CaptureRunID bigint
    , @MaterialModificationCount bigint = 1000
    , @HighModificationCount bigint = 100000
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
        THROW 67000,N'Invalid CaptureRunID.',1;

    IF @MaterialModificationCount < 0 OR @HighModificationCount < @MaterialModificationCount
        THROW 67001,N'Invalid statistics modification thresholds.',1;

    DELETE FROM dbo.RCA_StatisticsCardinalityEvidence
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_Recommendation
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseCategory='STATISTICS_CARDINALITY_REGRESSION';

    ;WITH PersistentStats AS
    (
        SELECT
              ps.CaptureRunID
            , ps.ExecutionEvidenceID
            , ps.PlanEvidenceID
            , ps.DatabaseName
            , ps.SchemaName
            , ps.TableName
            , ps.StatisticsName
            , ps.LastUpdate
            , ps.ModificationCount
            , ps.SamplingPercent
            , ps.StatsAgeHours
        FROM dbo.RCA_PlanStatistics ps
        WHERE ps.CaptureRunID=@CaptureRunID
          AND ps.ExecutionEvidenceID IS NOT NULL
          AND ISNULL(ps.ModificationCount,0)>=@MaterialModificationCount
          AND ISNULL(ps.DatabaseName,N'') NOT LIKE N'%tempdb%'
          AND ISNULL(ps.TableName,N'') NOT LIKE N'%#%'
    ),
    FindingAgg AS
    (
        SELECT
              f.ExecutionEvidenceID
            , CardinalityMismatchCount =
                SUM(CASE WHEN f.FindingType='CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
            , HighSeverityCardinalityMismatchCount =
                SUM(CASE WHEN f.FindingType='CARDINALITY_MISMATCH'
                              AND f.Severity='HIGH' THEN 1 ELSE 0 END)
            , LargeScanCount =
                SUM(CASE WHEN f.FindingType='LARGE_SCAN' THEN 1 ELSE 0 END)
            , StatisticsRiskCount =
                SUM(CASE WHEN f.FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding f
        WHERE f.CaptureRunID=@CaptureRunID
          AND f.ExecutionEvidenceID IS NOT NULL
        GROUP BY f.ExecutionEvidenceID
    ),
    OperatorAgg AS
    (
        SELECT
              p.LinkedExecutionEvidenceID AS ExecutionEvidenceID
            , WorstEstimateActualRatio =
                MAX(CONVERT(decimal(38,6),o.EstimateActualRatio))
        FROM dbo.RCA_PlanOperator o
        JOIN dbo.RCA_PlanEvidence p
          ON p.PlanEvidenceID=o.PlanEvidenceID
         AND p.CaptureRunID=o.CaptureRunID
        WHERE o.CaptureRunID=@CaptureRunID
          AND p.LinkedExecutionEvidenceID IS NOT NULL
          AND o.EstimateActualRatio IS NOT NULL
        GROUP BY p.LinkedExecutionEvidenceID
    ),
    CandidateStats AS
    (
        SELECT
              ps.*
            , ISNULL(f.CardinalityMismatchCount,0) AS CardinalityMismatchCount
            , ISNULL(f.HighSeverityCardinalityMismatchCount,0) AS HighSeverityCardinalityMismatchCount
            , ISNULL(f.LargeScanCount,0) AS LargeScanCount
            , ISNULL(f.StatisticsRiskCount,0) AS StatisticsRiskCount
            , oa.WorstEstimateActualRatio
            , rn =
                ROW_NUMBER() OVER
                (
                    PARTITION BY ps.ExecutionEvidenceID
                    ORDER BY
                        ISNULL(ps.ModificationCount,0) DESC,
                        ISNULL(oa.WorstEstimateActualRatio,0) DESC,
                        ps.PlanEvidenceID
                )
        FROM PersistentStats ps
        LEFT JOIN FindingAgg f
          ON f.ExecutionEvidenceID=ps.ExecutionEvidenceID
        LEFT JOIN OperatorAgg oa
          ON oa.ExecutionEvidenceID=ps.ExecutionEvidenceID
        WHERE ISNULL(f.HighSeverityCardinalityMismatchCount,0)>0
          AND ISNULL(f.StatisticsRiskCount,0)>0
    ),
    StrongestStat AS
    (
        SELECT *
        FROM CandidateStats
        WHERE rn=1
    ),
    BaselineCandidates AS
    (
        SELECT
              s.ExecutionEvidenceID AS ImpactedExecutionEvidenceID
            , bps.ExecutionEvidenceID AS BaselineExecutionEvidenceID
            , ROW_NUMBER() OVER
              (
                  PARTITION BY s.ExecutionEvidenceID
                  ORDER BY
                      ISNULL(be.LogicalReads,9223372036854775807),
                      ISNULL(be.CPUms,999999999999.999),
                      ISNULL(be.DurationMs,999999999999.999),
                      bps.ExecutionEvidenceID
              ) AS rn
        FROM StrongestStat s
        JOIN dbo.RCA_PlanStatistics bps
          ON bps.CaptureRunID=@CaptureRunID
         AND bps.ExecutionEvidenceID<>s.ExecutionEvidenceID
         AND ISNULL(bps.DatabaseName,N'')=ISNULL(s.DatabaseName,N'')
         AND ISNULL(bps.SchemaName,N'')=ISNULL(s.SchemaName,N'')
         AND ISNULL(bps.TableName,N'')=ISNULL(s.TableName,N'')
         AND ISNULL(bps.StatisticsName,N'')=ISNULL(s.StatisticsName,N'')
        JOIN dbo.RCA_ExecutionEvidence be
          ON be.ExecutionEvidenceID=bps.ExecutionEvidenceID
    ),
    BestBaseline AS
    (
        SELECT ImpactedExecutionEvidenceID,BaselineExecutionEvidenceID
        FROM BaselineCandidates
        WHERE rn=1
    ),
    Evidence AS
    (
        SELECT
              s.*
            , bb.BaselineExecutionEvidenceID
            , ie.DurationMs AS ImpactedDurationMs
            , ie.CPUms AS ImpactedCPUms
            , ie.LogicalReads AS ImpactedLogicalReads
            , ie.TotalRows AS ImpactedRows
            , be.DurationMs AS BaselineDurationMs
            , be.CPUms AS BaselineCPUms
            , be.LogicalReads AS BaselineLogicalReads
            , be.TotalRows AS BaselineRows
            , DurationRatio =
                CONVERT(decimal(19,4),ie.DurationMs/NULLIF(be.DurationMs,0))
            , CPURatio =
                CONVERT(decimal(19,4),ie.CPUms/NULLIF(be.CPUms,0))
            , LogicalReadRatio =
                CONVERT(decimal(19,4),1.0*ie.LogicalReads/NULLIF(be.LogicalReads,0))
            , RowRatio =
                CONVERT(decimal(19,4),1.0*ie.TotalRows/NULLIF(be.TotalRows,0))
        FROM StrongestStat s
        JOIN dbo.RCA_ExecutionEvidence ie
          ON ie.ExecutionEvidenceID=s.ExecutionEvidenceID
        LEFT JOIN BestBaseline bb
          ON bb.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
        LEFT JOIN dbo.RCA_ExecutionEvidence be
          ON be.ExecutionEvidenceID=bb.BaselineExecutionEvidenceID
    ),
    Scored AS
    (
        SELECT
              e.*
            , RegressionSignals =
                (CASE WHEN ISNULL(e.DurationRatio,0)>=2 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.CPURatio,0)>=2 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.LogicalReadRatio,0)>=2 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.RowRatio,0)>=2 THEN 1 ELSE 0 END)
        FROM Evidence e
    )
    INSERT dbo.RCA_StatisticsCardinalityEvidence
    (
          CaptureRunID
        , BaselineExecutionEvidenceID
        , ImpactedExecutionEvidenceID
        , RepresentativePlanEvidenceID
        , DatabaseName
        , SchemaName
        , TableName
        , StatisticsName
        , LastUpdate
        , ModificationCount
        , SamplingPercent
        , StatsAgeHours
        , CardinalityMismatchCount
        , HighSeverityCardinalityMismatchCount
        , LargeScanCount
        , StatisticsRiskCount
        , WorstEstimateActualRatio
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
        , Confidence
        , EvidenceSummary
    )
    SELECT
          @CaptureRunID
        , e.BaselineExecutionEvidenceID
        , e.ExecutionEvidenceID
        , e.PlanEvidenceID
        , e.DatabaseName
        , e.SchemaName
        , e.TableName
        , e.StatisticsName
        , e.LastUpdate
        , e.ModificationCount
        , e.SamplingPercent
        , e.StatsAgeHours
        , e.CardinalityMismatchCount
        , e.HighSeverityCardinalityMismatchCount
        , e.LargeScanCount
        , e.StatisticsRiskCount
        , e.WorstEstimateActualRatio
        , e.BaselineDurationMs
        , e.ImpactedDurationMs
        , e.DurationRatio
        , e.BaselineCPUms
        , e.ImpactedCPUms
        , e.CPURatio
        , e.BaselineLogicalReads
        , e.ImpactedLogicalReads
        , e.LogicalReadRatio
        , e.BaselineRows
        , e.ImpactedRows
        , e.RowRatio
        , CASE
              WHEN ISNULL(e.ModificationCount,0)>=@HighModificationCount
               AND e.HighSeverityCardinalityMismatchCount>0
               AND e.StatisticsRiskCount>0
               AND e.RegressionSignals>=2
              THEN 'HIGH'
              WHEN ISNULL(e.ModificationCount,0)>=@MaterialModificationCount
               AND e.HighSeverityCardinalityMismatchCount>0
               AND e.StatisticsRiskCount>0
              THEN 'MEDIUM'
              ELSE 'LOW'
          END
        , CONCAT
          (
              N'Statistics ',COALESCE(e.StatisticsName,N'(unknown)'),
              N' on ',COALESCE(e.DatabaseName,N''),N'.',
              COALESCE(e.SchemaName,N''),N'.',COALESCE(e.TableName,N''),
              N' had ',FORMAT(ISNULL(e.ModificationCount,0),'N0'),
              N' modification(s) since the captured last update ',
              COALESCE(CONVERT(nvarchar(30),e.LastUpdate,121),N'(unknown)'),N'. ',
              N'Sampling=',COALESCE(CONVERT(varchar(30),e.SamplingPercent),N'NULL'),N'%. ',
              N'High-severity cardinality mismatches=',e.HighSeverityCardinalityMismatchCount,
              N'; statistics-risk findings=',e.StatisticsRiskCount,
              N'; large-scan findings=',e.LargeScanCount,
              N'; worst captured estimate/actual ratio=',
              COALESCE(CONVERT(varchar(40),e.WorstEstimateActualRatio),N'NULL'),N'. ',
              CASE WHEN e.BaselineExecutionEvidenceID IS NOT NULL
                   THEN CONCAT
                        (
                            N'Baseline execution ',e.BaselineExecutionEvidenceID,
                            N' comparison: duration ratio=',
                            COALESCE(CONVERT(varchar(30),e.DurationRatio),N'NULL'),N'x; CPU ratio=',
                            COALESCE(CONVERT(varchar(30),e.CPURatio),N'NULL'),N'x; logical-read ratio=',
                            COALESCE(CONVERT(varchar(30),e.LogicalReadRatio),N'NULL'),N'x; row ratio=',
                            COALESCE(CONVERT(varchar(30),e.RowRatio),N'NULL'),N'x.'
                        )
                   ELSE N'No lower-cost same-statistic baseline execution was available in this capture.'
              END
          )
    FROM Scored e
    WHERE
        (
            e.RegressionSignals>=2
            OR e.BaselineExecutionEvidenceID IS NULL
        );

    /* Convert HIGH/MEDIUM detector evidence into standard Recommendation rows. */
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
          e.CaptureRunID
        , e.ImpactedExecutionEvidenceID
        , CASE WHEN e.Confidence='HIGH' THEN 1 ELSE 2 END
        , e.Confidence
        , 'STATISTICS_CARDINALITY_REGRESSION'
        , N'Materially modified statistics used by the captured actual plan coincide with severe cardinality-estimation error and measurable execution regression.'
        , e.EvidenceSummary
        , N'When optimizer statistics no longer represent the current data distribution, cardinality estimates can be wrong by orders of magnitude. That can drive inappropriate access paths, join choices, memory grants, parallelism decisions, and excessive reads.'
        , N'Validate the affected statistic and histogram against the current data distribution. Test a targeted statistics refresh for the specific object/statistic in a controlled environment, then re-run the identical workload and compare estimates, actual rows, plan shape, CPU, duration, reads, memory grants, and QueryPlanHash. Avoid blanket statistics maintenance until the affected statistics are proven.'
        , e.CardinalityMismatchCount + e.StatisticsRiskCount + e.LargeScanCount
        , e.HighSeverityCardinalityMismatchCount
        , CASE WHEN e.StatisticsRiskCount>0 THEN e.StatisticsRiskCount ELSE 0 END
    FROM dbo.RCA_StatisticsCardinalityEvidence e
    WHERE e.CaptureRunID=@CaptureRunID
      AND e.Confidence IN ('HIGH','MEDIUM');

    SELECT
          CaptureRunID=@CaptureRunID
        , DetectedCases=COUNT(*)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_StatisticsCardinalityEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
  5.4 APPLY STATISTICS DETECTOR TO SYNTHESIS

  Parameter-sensitive evidence is intentionally allowed to override this later
  in the unified workflow when both are present for the same execution.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ApplyStatisticsCardinalitySynthesis
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH RankedEvidence AS
    (
        SELECT
              e.*
            , rn=ROW_NUMBER() OVER
              (
                  PARTITION BY e.ImpactedExecutionEvidenceID
                  ORDER BY
                      CASE e.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                      e.HighSeverityCardinalityMismatchCount DESC,
                      ISNULL(e.ModificationCount,0) DESC,
                      e.StatisticsCardinalityEvidenceID
              )
        FROM dbo.RCA_StatisticsCardinalityEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
          AND e.Confidence IN ('HIGH','MEDIUM')
    )
    UPDATE s
       SET PrimaryCause =
             N'Materially modified statistics contributed to a severe cardinality-estimation regression, driving inefficient plan behavior and excessive work.'
         , PrimaryEvidence =
             CONCAT(e.EvidenceSummary,N' ',s.PrimaryEvidence)
         , Action1 =
             N'Validate the affected statistic and histogram against the current data distribution, modification count, skew, and predicate values.'
         , Action2 =
             N'In controlled testing, refresh only the affected statistic/object and re-run the identical workload. Compare estimated versus actual rows and the resulting access paths before considering broader maintenance.'
         , Action3 =
             N'Compare duration, CPU, logical reads, rows, memory grants, DOP, QueryPlanHash, and operator estimates against this captured baseline after the targeted change.'
         , Confidence =
             CASE WHEN e.Confidence='HIGH' THEN 'HIGH' ELSE s.Confidence END
         , ExecutiveSummary =
             CONCAT
             (
                 N'Probable root cause: statistics/cardinality regression. ',
                 N'The captured plan used statistic ',COALESCE(e.StatisticsName,N'(unknown)'),
                 N' on ',COALESCE(e.TableName,N'(unknown table)'),
                 N' after ',FORMAT(ISNULL(e.ModificationCount,0),'N0'),
                 N' modification(s) had accumulated since its captured last update. ',
                 N'The affected execution contained ',
                 e.HighSeverityCardinalityMismatchCount,
                 N' high-severity cardinality mismatch finding(s)',
                 CASE WHEN e.WorstEstimateActualRatio IS NOT NULL
                      THEN CONCAT(N', with a worst captured estimate/actual ratio of ',
                                  CONVERT(varchar(40),e.WorstEstimateActualRatio),N'x')
                      ELSE N''
                 END,
                 N'. ',
                 CASE WHEN e.BaselineExecutionEvidenceID IS NOT NULL
                      THEN CONCAT
                           (
                               N'Compared with baseline execution ',e.BaselineExecutionEvidenceID,
                               N', logical reads changed by ',
                               COALESCE(CONVERT(varchar(30),e.LogicalReadRatio),N'?'),N'x, CPU by ',
                               COALESCE(CONVERT(varchar(30),e.CPURatio),N'?'),N'x, and duration by ',
                               COALESCE(CONVERT(varchar(30),e.DurationRatio),N'?'),N'x. '
                           )
                      ELSE N''
                 END,
                 CASE WHEN s.RuledOutCause IS NOT NULL
                      THEN CONCAT(s.RuledOutCause,N' ')
                      ELSE N''
                 END,
                 N'Next action: validate the affected histogram/statistic, test a targeted refresh, and re-run the identical workload before applying broader changes.'
             )
    FROM dbo.RCA_RootCauseSynthesis s
    JOIN RankedEvidence e
      ON e.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
     AND e.rn=1
    WHERE s.CaptureRunID=@CaptureRunID
      AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.RCA_ParameterSensitivePlanEvidence p
              WHERE p.CaptureRunID=s.CaptureRunID
                AND p.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
                AND p.Confidence IN ('HIGH','MEDIUM')
          );

    SELECT
          CaptureRunID=@CaptureRunID
        , StatisticsSynthesesUpdated=@@ROWCOUNT;
END;
GO


/*==============================================================================
  6. UNIFIED ANALYSIS WORKFLOW
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

    /* Atomic recommendations first. */
    EXEC dbo.usp_RCA_BuildRecommendations
         @CaptureRunID=@CaptureRunID;

    /* Independent causal detectors. */
    EXEC dbo.usp_RCA_BuildParameterSensitivePlanEvidence
         @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_BuildStatisticsCardinalityEvidence
         @CaptureRunID=@CaptureRunID;

    /* Generic synthesis consumes all recommendation rows. */
    EXEC dbo.usp_RCA_BuildRootCauseSynthesis
         @CaptureRunID=@CaptureRunID;

    /*
      Apply more specific causal evidence after generic synthesis.
      Statistics is applied first. Parameter-sensitive plan evidence is
      intentionally last because confirmed plan reuse is the more specific
      explanation when both detectors fire for the same execution.
    */
    EXEC dbo.usp_RCA_ApplyStatisticsCardinalitySynthesis
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
       RESULT 3B - STATISTICS / CARDINALITY REGRESSION EVIDENCE

       Surfaces only first-class detector evidence.  Raw statistics and every
       actual plan remain available elsewhere in the repository/report.
     ======================================================================*/
     SELECT
         N'3B - STATISTICS / CARDINALITY EVIDENCE' AS ReportSection,
         sc.ImpactedExecutionEvidenceID AS ExecutionEvidenceID,
         sc.BaselineExecutionEvidenceID,
         sc.RepresentativePlanEvidenceID,
         sc.DatabaseName,
         sc.SchemaName,
         sc.TableName,
         sc.StatisticsName,
         sc.LastUpdate,
         sc.ModificationCount,
         sc.SamplingPercent,
         sc.StatsAgeHours,
         sc.CardinalityMismatchCount,
         sc.HighSeverityCardinalityMismatchCount,
         sc.LargeScanCount,
         sc.StatisticsRiskCount,
         sc.WorstEstimateActualRatio,
         sc.BaselineDurationMs,
         sc.ImpactedDurationMs,
         sc.DurationRatio,
         sc.BaselineCPUms,
         sc.ImpactedCPUms,
         sc.CPURatio,
         sc.BaselineLogicalReads,
         sc.ImpactedLogicalReads,
         sc.LogicalReadRatio,
         sc.BaselineRows,
         sc.ImpactedRows,
         sc.RowRatio,
         sc.Confidence,
         sc.EvidenceSummary
     FROM dbo.RCA_StatisticsCardinalityEvidence sc
     WHERE sc.CaptureRunID=@CaptureRunID
     ORDER BY
         CASE sc.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
         sc.LogicalReadRatio DESC,
         sc.CPURatio DESC,
         sc.ModificationCount DESC;



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
  7. INSTALL VALIDATION
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
    , StatisticsEvidenceTable =
          CASE WHEN OBJECT_ID(N'dbo.RCA_StatisticsCardinalityEvidence',N'U') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , StatisticsEvidenceView =
          CASE WHEN OBJECT_ID(N'dbo.vw_RCA_StatisticsCardinalityEvidence',N'V') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , StatisticsDetector =
          CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildStatisticsCardinalityEvidence',N'P') IS NOT NULL
               THEN 'PASS' ELSE 'FAIL' END
    , StatisticsSynthesis =
          CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyStatisticsCardinalitySynthesis',N'P') IS NOT NULL
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
