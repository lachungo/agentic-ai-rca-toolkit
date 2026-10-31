USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  13_RCA_Memory_Spill_Intelligence_v4_1.sql

  PURPOSE
  -------
  Add a first-class MEMORY_GRANT_SPILL detector without changing the collector,
  XE session, existing Run 3 parameter-sensitive detector, or Run 5 statistics /
  cardinality detector.

  ARCHITECTURE
  ------------
  Actual ShowPlan -> RCA_PlanOperator.HasSpillWarning
                  -> MEMORY_SPILL atomic finding
                  -> RCA_MemorySpillEvidence
                  -> RCA_Recommendation
                  -> Root-cause synthesis / incident report

  IMPORTANT
  ---------
  A spill proves that a runtime spill occurred. It does not by itself prove why.
  If stronger parameter-sensitive or statistics/cardinality evidence exists for
  the same execution, this detector classifies the spill as CONTRIBUTING rather
  than PRIMARY.
==============================================================================*/

/*==============================================================================
  1. EVIDENCE TABLE
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_MemorySpillEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_MemorySpillEvidence
    (
          MemorySpillEvidenceID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_MemorySpillEvidence PRIMARY KEY
        , CaptureRunID bigint NOT NULL
        , BaselineExecutionEvidenceID bigint NULL
        , ImpactedExecutionEvidenceID bigint NOT NULL
        , RepresentativePlanEvidenceID bigint NULL
        , SpillOperatorCount int NOT NULL
        , HighSeveritySpillCount int NOT NULL
        , SpillPhysicalOps nvarchar(2000) NULL
        , RequestedMemoryKB bigint NULL
        , GrantedMemoryKB bigint NULL
        , MaxUsedMemoryKB bigint NULL
        , ActualDOP int NULL
        , GrantUtilizationPercent decimal(19,4) NULL
        , CardinalityMismatchCount int NOT NULL
        , HighSeverityCardinalityMismatchCount int NOT NULL
        , StatisticsRiskCount int NOT NULL
        , BaselineDurationMs decimal(19,3) NULL
        , ImpactedDurationMs decimal(19,3) NULL
        , DurationRatio decimal(19,4) NULL
        , BaselineCPUms decimal(19,3) NULL
        , ImpactedCPUms decimal(19,3) NULL
        , CPURatio decimal(19,4) NULL
        , BaselineLogicalReads bigint NULL
        , ImpactedLogicalReads bigint NULL
        , LogicalReadRatio decimal(19,4) NULL
        , BaselineWrites bigint NULL
        , ImpactedWrites bigint NULL
        , WriteRatio decimal(19,4) NULL
        , UpstreamCauseCategory varchar(80) NULL
        , RootCauseRole varchar(20) NOT NULL
        , Confidence varchar(20) NOT NULL
        , EvidenceSummary nvarchar(max) NOT NULL
        , CreatedTimeUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_MemorySpillEvidence_Created
            DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_RCA_MemorySpillEvidence_RunExec
        ON dbo.RCA_MemorySpillEvidence
           (CaptureRunID,ImpactedExecutionEvidenceID);

    CREATE INDEX IX_RCA_MemorySpillEvidence_RunConfidence
        ON dbo.RCA_MemorySpillEvidence
           (CaptureRunID,RootCauseRole,Confidence);
END;
GO

CREATE OR ALTER VIEW dbo.vw_RCA_MemorySpillEvidence
AS
SELECT *
FROM dbo.RCA_MemorySpillEvidence;
GO

/*==============================================================================
  2. ATOMIC MEMORY_SPILL FINDINGS
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildMemorySpillFindings
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
        THROW 68100,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID
      AND FindingType='MEMORY_SPILL';

    INSERT dbo.RCA_PlanFinding
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , Severity
        , FindingType
        , FindingText
        , RecommendedAction
    )
    SELECT
          o.CaptureRunID
        , o.PlanEvidenceID
        , o.ExecutionEvidenceID
        , CASE
              WHEN o.HasSpillWarning=1
               AND
               (
                   COALESCE(o.PhysicalOp,N'') IN
                       (N'Sort',N'Hash Match')
                   OR COALESCE(o.LogicalOp,N'') IN
                       (N'Sort',N'Aggregate',N'Hash Match')
               )
               AND
               (
                   pe.GrantedMemoryKB IS NULL
                   OR pe.MaxUsedMemoryKB IS NULL
                   OR pe.GrantedMemoryKB=0
                   OR 100.0*pe.MaxUsedMemoryKB/NULLIF(pe.GrantedMemoryKB,0) >= 85.0
               )
              THEN 'HIGH'
              ELSE 'MEDIUM'
          END
        , 'MEMORY_SPILL'
        , CONCAT
          (
              N'Runtime spill detected in ',
              COALESCE(o.PhysicalOp,N'(unknown operator)'),
              N' / ',COALESCE(o.LogicalOp,N'(unknown logical operator)'),
              N' at NodeId ',COALESCE(CONVERT(varchar(20),o.NodeID),'?'),
              N'. Requested memory=',COALESCE(CONVERT(varchar(30),pe.RequestedMemoryKB),'NULL'),
              N' KB; granted=',COALESCE(CONVERT(varchar(30),pe.GrantedMemoryKB),'NULL'),
              N' KB; max used=',COALESCE(CONVERT(varchar(30),pe.MaxUsedMemoryKB),'NULL'),
              N' KB; DOP=',COALESCE(CONVERT(varchar(20),pe.ActualDOP),'NULL'),
              N'. Estimate/actual ratio=',COALESCE(CONVERT(varchar(40),o.EstimateActualRatio),'NULL'),
              N'.'
          )
        , N'Inspect the spilling operator, memory grant, cardinality estimates, and tempdb impact. A runtime spill is hard evidence of a spill event, but root-cause classification must still evaluate whether an upstream parameter/statistics detector explains the grant problem.'
    FROM dbo.RCA_PlanOperator o
    JOIN dbo.RCA_PlanEvidence pe
      ON pe.PlanEvidenceID=o.PlanEvidenceID
     AND pe.CaptureRunID=o.CaptureRunID
    WHERE o.CaptureRunID=@CaptureRunID
      AND o.HasSpillWarning=1;

    SELECT
          CaptureRunID=@CaptureRunID
        , MemorySpillFindings=COUNT(*)
        , HighSeverity=SUM(CASE WHEN Severity='HIGH' THEN 1 ELSE 0 END)
        , MediumSeverity=SUM(CASE WHEN Severity='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID
      AND FindingType='MEMORY_SPILL';
END;
GO

/*==============================================================================
  3. MEMORY SPILL DETECTOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildMemorySpillEvidence
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
        THROW 68110,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_MemorySpillEvidence
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_Recommendation
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseCategory='MEMORY_GRANT_SPILL';

    /*----------------------------------------------------------------------
      1. Aggregate spill evidence per impacted execution.
    ----------------------------------------------------------------------*/
    ;WITH SpillAgg AS
    (
        SELECT
              f.ExecutionEvidenceID
            , SpillOperatorCount=COUNT(*)
            , HighSeveritySpillCount=
                SUM(CASE WHEN f.Severity='HIGH' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding f
        WHERE f.CaptureRunID=@CaptureRunID
          AND f.FindingType='MEMORY_SPILL'
          AND f.ExecutionEvidenceID IS NOT NULL
        GROUP BY f.ExecutionEvidenceID
    ),
    SpillOps AS
    (
        SELECT
              o.ExecutionEvidenceID
            , SpillPhysicalOps=
                STRING_AGG(CONVERT(nvarchar(max),
                    CONCAT(COALESCE(o.PhysicalOp,N'?'),N'/',COALESCE(o.LogicalOp,N'?'),
                           N' Node ',COALESCE(CONVERT(varchar(20),o.NodeID),'?'))),N'; ')
        FROM dbo.RCA_PlanOperator o
        WHERE o.CaptureRunID=@CaptureRunID
          AND o.HasSpillWarning=1
          AND o.ExecutionEvidenceID IS NOT NULL
        GROUP BY o.ExecutionEvidenceID
    ),
    GrantAgg AS
    (
        SELECT
              pe.LinkedExecutionEvidenceID AS ExecutionEvidenceID
            , RepresentativePlanEvidenceID=MAX(pe.PlanEvidenceID)
            , RequestedMemoryKB=MAX(pe.RequestedMemoryKB)
            , GrantedMemoryKB=MAX(pe.GrantedMemoryKB)
            , MaxUsedMemoryKB=MAX(pe.MaxUsedMemoryKB)
            , ActualDOP=MAX(pe.ActualDOP)
        FROM dbo.RCA_PlanEvidence pe
        WHERE pe.CaptureRunID=@CaptureRunID
          AND pe.LinkedExecutionEvidenceID IS NOT NULL
        GROUP BY pe.LinkedExecutionEvidenceID
    ),
    FindingAgg AS
    (
        SELECT
              f.ExecutionEvidenceID
            , CardinalityMismatchCount=
                SUM(CASE WHEN f.FindingType='CARDINALITY_MISMATCH' THEN 1 ELSE 0 END)
            , HighSeverityCardinalityMismatchCount=
                SUM(CASE WHEN f.FindingType='CARDINALITY_MISMATCH'
                              AND f.Severity='HIGH' THEN 1 ELSE 0 END)
            , StatisticsRiskCount=
                SUM(CASE WHEN f.FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding f
        WHERE f.CaptureRunID=@CaptureRunID
          AND f.ExecutionEvidenceID IS NOT NULL
        GROUP BY f.ExecutionEvidenceID
    ),
    /*----------------------------------------------------------------------
      2. Normalize command text and derive execution identity.

         Key rule:
         - Generic ObjectName values such as NULL / "Ad hoc / batch execution"
           are never enough to establish a baseline relationship.
         - Prefer identical QueryHash when present.
         - Otherwise fall back to the same recognizable workload/procedure
           signature derived from SubmittedCommand / ParameterText.
    ----------------------------------------------------------------------*/
    ExecIdentity AS
    (
        SELECT
              e.ExecutionEvidenceID
            , e.EventTimeUTC
            , e.ObjectName
            , e.QueryHash
            , e.QueryPlanHash
            , e.CPUms
            , e.DurationMs
            , e.LogicalReads
            , e.Writes
            , e.TotalRows
            , CommandText=
                COALESCE(NULLIF(e.SubmittedCommand,N''),NULLIF(e.ParameterText,N''),N'')
            , WorkloadSignature=
                CASE
                    WHEN COALESCE(e.SubmittedCommand,e.ParameterText,N'')
                         LIKE N'%usp_RCA_Run6_MemorySpill%'
                    THEN N'usp_RCA_Run6_MemorySpill'
                    WHEN e.ObjectName IS NOT NULL
                     AND e.ObjectName NOT IN
                         (N'Ad hoc / batch execution',N'sp_executesql')
                    THEN e.ObjectName
                    ELSE NULL
                END
            , IsLikelyMultiExecutionBatch=
                CASE
                    WHEN
                    (
                        LEN(COALESCE(e.SubmittedCommand,e.ParameterText,N'')) -
                        LEN(REPLACE(COALESCE(e.SubmittedCommand,e.ParameterText,N''),
                                    N'usp_RCA_Run6_MemorySpill',N''))
                    ) / NULLIF(LEN(N'usp_RCA_Run6_MemorySpill'),0) > 1
                    THEN 1 ELSE 0
                END
            , IsExplicitBaseline=
                CASE WHEN COALESCE(e.SubmittedCommand,e.ParameterText,N'')
                           LIKE N'%BASELINE%'
                          AND COALESCE(e.SubmittedCommand,e.ParameterText,N'')
                           LIKE N'%@MaxGrantPercent%NULL%'
                     THEN 1 ELSE 0 END
            , IsExplicitImpacted=
                CASE WHEN COALESCE(e.SubmittedCommand,e.ParameterText,N'')
                           LIKE N'%IMPACTED%'
                          AND COALESCE(e.SubmittedCommand,e.ParameterText,N'')
                           LIKE N'%@MaxGrantPercent%=%1%'
                     THEN 1 ELSE 0 END
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
    ),
    Candidates AS
    (
        SELECT
              sa.ExecutionEvidenceID AS ImpactedExecutionEvidenceID
            , sa.SpillOperatorCount
            , sa.HighSeveritySpillCount
            , so.SpillPhysicalOps
            , ga.RepresentativePlanEvidenceID
            , ga.RequestedMemoryKB
            , ga.GrantedMemoryKB
            , ga.MaxUsedMemoryKB
            , ga.ActualDOP
            , GrantUtilizationPercent=
                CONVERT(decimal(19,4),
                    100.0*ga.MaxUsedMemoryKB/NULLIF(ga.GrantedMemoryKB,0))
            , CardinalityMismatchCount=
                ISNULL(fa.CardinalityMismatchCount,0)
            , HighSeverityCardinalityMismatchCount=
                ISNULL(fa.HighSeverityCardinalityMismatchCount,0)
            , StatisticsRiskCount=
                ISNULL(fa.StatisticsRiskCount,0)
            , ei.EventTimeUTC
            , ei.QueryHash
            , ei.QueryPlanHash
            , ei.WorkloadSignature
            , ei.IsLikelyMultiExecutionBatch
            , ei.IsExplicitImpacted
        FROM SpillAgg sa
        JOIN ExecIdentity ei
          ON ei.ExecutionEvidenceID=sa.ExecutionEvidenceID
        LEFT JOIN SpillOps so
          ON so.ExecutionEvidenceID=sa.ExecutionEvidenceID
        LEFT JOIN GrantAgg ga
          ON ga.ExecutionEvidenceID=sa.ExecutionEvidenceID
        LEFT JOIN FindingAgg fa
          ON fa.ExecutionEvidenceID=sa.ExecutionEvidenceID
    ),
    /*----------------------------------------------------------------------
      3. Baseline correlation.

         Ranking:
         A. Same QueryHash if available.
         B. Else same workload/procedure signature.
         C. Baseline must be earlier than impacted.
         D. Baseline must not itself contain a spill.
         E. Reject likely multi-execution batches.
         F. Prefer explicitly marked baseline, then closest earlier execution.
    ----------------------------------------------------------------------*/
    BaselineCandidates AS
    (
        SELECT
              c.ImpactedExecutionEvidenceID
            , b.ExecutionEvidenceID AS BaselineExecutionEvidenceID
            , rn=ROW_NUMBER() OVER
              (
                  PARTITION BY c.ImpactedExecutionEvidenceID
                  ORDER BY
                      CASE
                          WHEN c.QueryHash IS NOT NULL
                           AND b.QueryHash=c.QueryHash
                          THEN 1
                          WHEN c.WorkloadSignature IS NOT NULL
                           AND b.WorkloadSignature=c.WorkloadSignature
                          THEN 2
                          ELSE 9
                      END,
                      CASE WHEN b.IsExplicitBaseline=1 THEN 1 ELSE 2 END,
                      DATEDIFF_BIG(millisecond,b.EventTimeUTC,c.EventTimeUTC),
                      b.ExecutionEvidenceID DESC
              )
        FROM Candidates c
        JOIN ExecIdentity b
          ON b.EventTimeUTC < c.EventTimeUTC
         AND b.ExecutionEvidenceID<>c.ImpactedExecutionEvidenceID
         AND b.IsLikelyMultiExecutionBatch=0
         AND
         (
             (c.QueryHash IS NOT NULL AND b.QueryHash=c.QueryHash)
             OR
             (c.WorkloadSignature IS NOT NULL
              AND b.WorkloadSignature=c.WorkloadSignature)
         )
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.RCA_PlanOperator bo
            WHERE bo.CaptureRunID=@CaptureRunID
              AND bo.ExecutionEvidenceID=b.ExecutionEvidenceID
              AND bo.HasSpillWarning=1
        )
          AND
          (
              b.IsExplicitBaseline=1
              OR c.WorkloadSignature IS NOT NULL
          )
    ),
    BestBaseline AS
    (
        SELECT
              ImpactedExecutionEvidenceID
            , BaselineExecutionEvidenceID
        FROM BaselineCandidates
        WHERE rn=1
    ),
    Evidence AS
    (
        SELECT
              c.*
            , bb.BaselineExecutionEvidenceID
            , ie.DurationMs AS ImpactedDurationMs
            , ie.CPUms AS ImpactedCPUms
            , ie.LogicalReads AS ImpactedLogicalReads
            , ie.Writes AS ImpactedWrites
            , be.DurationMs AS BaselineDurationMs
            , be.CPUms AS BaselineCPUms
            , be.LogicalReads AS BaselineLogicalReads
            , be.Writes AS BaselineWrites
            , DurationRatio=
                CONVERT(decimal(19,4),ie.DurationMs/NULLIF(be.DurationMs,0))
            , CPURatio=
                CONVERT(decimal(19,4),ie.CPUms/NULLIF(be.CPUms,0))
            , LogicalReadRatio=
                CONVERT(decimal(19,4),1.0*ie.LogicalReads/NULLIF(be.LogicalReads,0))
            , WriteRatio=
                CONVERT(decimal(19,4),1.0*ie.Writes/NULLIF(be.Writes,0))
            , HasStatisticsCause=
                CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_StatisticsCardinalityEvidence sc
                    WHERE sc.CaptureRunID=@CaptureRunID
                      AND sc.ImpactedExecutionEvidenceID=c.ImpactedExecutionEvidenceID
                      AND sc.Confidence IN ('HIGH','MEDIUM')
                )
                THEN 1 ELSE 0 END
            , HasParameterCause=
                CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_ParameterSensitivePlanEvidence ps
                    WHERE ps.CaptureRunID=@CaptureRunID
                      AND ps.ImpactedExecutionEvidenceID=c.ImpactedExecutionEvidenceID
                      AND ps.Confidence IN ('HIGH','MEDIUM')
                )
                THEN 1 ELSE 0 END
        FROM Candidates c
        JOIN dbo.RCA_ExecutionEvidence ie
          ON ie.ExecutionEvidenceID=c.ImpactedExecutionEvidenceID
        LEFT JOIN BestBaseline bb
          ON bb.ImpactedExecutionEvidenceID=c.ImpactedExecutionEvidenceID
        LEFT JOIN dbo.RCA_ExecutionEvidence be
          ON be.ExecutionEvidenceID=bb.BaselineExecutionEvidenceID
    ),
    Scored AS
    (
        SELECT
              e.*
            , RegressionSignals=
                (CASE WHEN ISNULL(e.DurationRatio,0)>=2.0 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.CPURatio,0)>=1.5 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.LogicalReadRatio,0)>=1.5 THEN 1 ELSE 0 END) +
                (CASE WHEN ISNULL(e.WriteRatio,0)>=2.0 THEN 1 ELSE 0 END)
            , UpstreamCauseCategory=
                CASE
                    WHEN e.HasParameterCause=1
                    THEN 'PARAMETER_SENSITIVE_PLAN_REUSE'
                    WHEN e.HasStatisticsCause=1
                    THEN 'STATISTICS_CARDINALITY_REGRESSION'
                    ELSE NULL
                END
        FROM Evidence e
    )
    INSERT dbo.RCA_MemorySpillEvidence
    (
          CaptureRunID
        , BaselineExecutionEvidenceID
        , ImpactedExecutionEvidenceID
        , RepresentativePlanEvidenceID
        , SpillOperatorCount
        , HighSeveritySpillCount
        , SpillPhysicalOps
        , RequestedMemoryKB
        , GrantedMemoryKB
        , MaxUsedMemoryKB
        , ActualDOP
        , GrantUtilizationPercent
        , CardinalityMismatchCount
        , HighSeverityCardinalityMismatchCount
        , StatisticsRiskCount
        , BaselineDurationMs
        , ImpactedDurationMs
        , DurationRatio
        , BaselineCPUms
        , ImpactedCPUms
        , CPURatio
        , BaselineLogicalReads
        , ImpactedLogicalReads
        , LogicalReadRatio
        , BaselineWrites
        , ImpactedWrites
        , WriteRatio
        , UpstreamCauseCategory
        , RootCauseRole
        , Confidence
        , EvidenceSummary
    )
    SELECT
          @CaptureRunID
        , s.BaselineExecutionEvidenceID
        , s.ImpactedExecutionEvidenceID
        , s.RepresentativePlanEvidenceID
        , s.SpillOperatorCount
        , s.HighSeveritySpillCount
        , s.SpillPhysicalOps
        , s.RequestedMemoryKB
        , s.GrantedMemoryKB
        , s.MaxUsedMemoryKB
        , s.ActualDOP
        , s.GrantUtilizationPercent
        , s.CardinalityMismatchCount
        , s.HighSeverityCardinalityMismatchCount
        , s.StatisticsRiskCount
        , s.BaselineDurationMs
        , s.ImpactedDurationMs
        , s.DurationRatio
        , s.BaselineCPUms
        , s.ImpactedCPUms
        , s.CPURatio
        , s.BaselineLogicalReads
        , s.ImpactedLogicalReads
        , s.LogicalReadRatio
        , s.BaselineWrites
        , s.ImpactedWrites
        , s.WriteRatio
        , s.UpstreamCauseCategory
        , CASE
              WHEN s.UpstreamCauseCategory IS NOT NULL
              THEN 'CONTRIBUTING'
              ELSE 'PRIMARY'
          END
        , CASE
              WHEN s.UpstreamCauseCategory IS NULL
               AND s.BaselineExecutionEvidenceID IS NOT NULL
               AND s.SpillOperatorCount>0
               AND s.RegressionSignals>=1
              THEN 'HIGH'
              WHEN s.SpillOperatorCount>0
              THEN 'MEDIUM'
              ELSE 'LOW'
          END
        , CONCAT
          (
              N'Execution ',s.ImpactedExecutionEvidenceID,
              N' contained ',s.SpillOperatorCount,N' runtime spill warning(s): ',
              COALESCE(s.SpillPhysicalOps,N'operator details unavailable'),N'. ',
              N'Requested=',COALESCE(CONVERT(varchar(30),s.RequestedMemoryKB),'NULL'),
              N' KB; granted=',COALESCE(CONVERT(varchar(30),s.GrantedMemoryKB),'NULL'),
              N' KB; max used=',COALESCE(CONVERT(varchar(30),s.MaxUsedMemoryKB),'NULL'),
              N' KB; grant utilization=',COALESCE(CONVERT(varchar(30),s.GrantUtilizationPercent),'NULL'),
              N'%; DOP=',COALESCE(CONVERT(varchar(20),s.ActualDOP),'NULL'),N'. ',
              CASE WHEN s.BaselineExecutionEvidenceID IS NOT NULL
                   THEN CONCAT
                   (
                       N'Comparable baseline execution ',
                       s.BaselineExecutionEvidenceID,
                       N': duration=',COALESCE(CONVERT(varchar(30),s.DurationRatio),'NULL'),
                       N'x; CPU=',COALESCE(CONVERT(varchar(30),s.CPURatio),'NULL'),
                       N'x; logical reads=',COALESCE(CONVERT(varchar(30),s.LogicalReadRatio),'NULL'),
                       N'x; writes=',COALESCE(CONVERT(varchar(30),s.WriteRatio),'NULL'),
                       N'x. '
                   )
                   ELSE N'No credible non-spilling baseline execution was found. '
              END,
              N'High-severity cardinality mismatches=',
              s.HighSeverityCardinalityMismatchCount,
              N'; statistics-risk findings=',s.StatisticsRiskCount,N'. ',
              CASE WHEN s.UpstreamCauseCategory IS NOT NULL
                   THEN CONCAT
                   (
                       N'Spill classified CONTRIBUTING because a dedicated upstream detector established ',
                       s.UpstreamCauseCategory,N'.'
                   )
                   ELSE N'No dedicated upstream parameter-sensitive/statistics-cardinality cause was established; spill classified PRIMARY.'
              END
          )
    FROM Scored s
    WHERE s.SpillOperatorCount>0;

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
        , CASE
              WHEN e.RootCauseRole='PRIMARY' AND e.Confidence='HIGH' THEN 1
              WHEN e.RootCauseRole='PRIMARY' THEN 2
              ELSE 3
          END
        , e.Confidence
        , 'MEMORY_GRANT_SPILL'
        , CASE
              WHEN e.RootCauseRole='PRIMARY'
              THEN N'Runtime memory-grant/spill behavior materially contributed to the execution regression.'
              ELSE N'Runtime spill behavior was observed, but a dedicated upstream detector established a stronger primary cause.'
          END
        , e.EvidenceSummary
        , N'Runtime spills move work from memory to tempdb work areas and can materially increase elapsed time. A spill is treated as primary only when a credible comparable baseline exists and no stronger upstream causal detector has fired.'
        , CASE
              WHEN e.RootCauseRole='PRIMARY'
              THEN N'Reproduce the same execution and inspect the spilling Sort/Hash operators, requested/granted/max-used memory, concurrency, and tempdb activity. Test the least invasive measured change that removes the spill without excessive memory grants.'
              ELSE N'Address the dedicated upstream cause first, then rerun the identical workload and verify whether the spill disappears before changing query/server memory behavior.'
          END
        , e.SpillOperatorCount + e.CardinalityMismatchCount + e.StatisticsRiskCount
        , e.HighSeveritySpillCount
        , CASE
              WHEN e.SpillOperatorCount-e.HighSeveritySpillCount>0
              THEN e.SpillOperatorCount-e.HighSeveritySpillCount
              ELSE 0
          END
    FROM dbo.RCA_MemorySpillEvidence e
    WHERE e.CaptureRunID=@CaptureRunID
      AND e.Confidence IN ('HIGH','MEDIUM');

    SELECT
          CaptureRunID=@CaptureRunID
        , DetectedCases=COUNT(*)
        , PrimaryCases=SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , ContributingCases=SUM(CASE WHEN RootCauseRole='CONTRIBUTING' THEN 1 ELSE 0 END)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_MemorySpillEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO

/*==============================================================================
  4. SYNTHESIS APPLICATION
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ApplyMemorySpillSynthesis
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH E AS
    (
        SELECT e.*,
               rn=ROW_NUMBER() OVER
                  (PARTITION BY ImpactedExecutionEvidenceID
                   ORDER BY CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END,
                            CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                            MemorySpillEvidenceID)
        FROM dbo.RCA_MemorySpillEvidence e
        WHERE CaptureRunID=@CaptureRunID
          AND Confidence IN ('HIGH','MEDIUM')
    )
    UPDATE s
       SET PrimaryCause=
             CASE WHEN e.RootCauseRole='PRIMARY'
                  THEN N'Runtime memory-grant/spill behavior materially contributed to the regression, with captured operators spilling during execution.'
                  ELSE s.PrimaryCause END,
           PrimaryEvidence=
             CASE WHEN e.RootCauseRole='PRIMARY'
                  THEN CONCAT(e.EvidenceSummary,N' ',s.PrimaryEvidence)
                  ELSE s.PrimaryEvidence END,
           ContributingFactor2=
             CASE WHEN e.RootCauseRole='CONTRIBUTING'
                  THEN N'Runtime memory spill increased execution cost downstream of the stronger upstream cause.'
                  ELSE s.ContributingFactor2 END,
           ContributingEvidence2=
             CASE WHEN e.RootCauseRole='CONTRIBUTING' THEN e.EvidenceSummary
                  ELSE s.ContributingEvidence2 END,
           Action1=
             CASE WHEN e.RootCauseRole='PRIMARY'
                  THEN N'Inspect the spilling Sort/Hash operator and the captured requested, granted, and maximum-used memory for this exact execution.'
                  ELSE s.Action1 END,
           Action2=
             CASE WHEN e.RootCauseRole='PRIMARY'
                  THEN N'Reproduce the identical workload while measuring tempdb and memory-grant behavior. Test the least invasive change that eliminates the spill without excessive grants.'
                  ELSE s.Action2 END,
           Action3=
             CASE WHEN e.RootCauseRole='PRIMARY'
                  THEN N'Re-run the same execution and compare spill warnings, duration, CPU, logical reads, writes, memory grant, DOP, plan hash, and operator behavior.'
                  ELSE s.Action3 END,
           Confidence=
             CASE WHEN e.RootCauseRole='PRIMARY' AND e.Confidence='HIGH' THEN 'HIGH'
                  ELSE s.Confidence END,
           ExecutiveSummary=
             CASE WHEN e.RootCauseRole='PRIMARY'
                  THEN CONCAT(N'Probable root cause: memory grant / spill regression. ',e.EvidenceSummary,
                              N' Next action: validate the spilling operator and memory grant, then remove the spill using the least invasive measured change.')
                  ELSE s.ExecutiveSummary END
    FROM dbo.RCA_RootCauseSynthesis s
    JOIN E e
      ON e.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
     AND e.rn=1
    WHERE s.CaptureRunID=@CaptureRunID
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.RCA_ParameterSensitivePlanEvidence p
          WHERE p.CaptureRunID=s.CaptureRunID
            AND p.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
            AND p.Confidence IN ('HIGH','MEDIUM')
      )
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.RCA_StatisticsCardinalityEvidence st
          WHERE st.CaptureRunID=s.CaptureRunID
            AND st.ImpactedExecutionEvidenceID=s.ExecutionEvidenceID
            AND st.Confidence IN ('HIGH','MEDIUM')
      );

    SELECT CaptureRunID=@CaptureRunID,MemorySpillSynthesesUpdated=@@ROWCOUNT;
END;
GO

/*==============================================================================
  5. UPDATE UNIFIED ANALYSIS WORKFLOW
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_AnalyzeCaptureRun
      @CaptureRunID bigint
    , @Reparse bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reparse=1
        EXEC dbo.usp_RCA_ParseCaptureRun @CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_BuildRecommendations @CaptureRunID=@CaptureRunID;

    /* Atomic spill finding comes from already-parsed actual-plan operators. */
    EXEC dbo.usp_RCA_BuildMemorySpillFindings @CaptureRunID=@CaptureRunID;

    /* Independent causal detectors. */
    EXEC dbo.usp_RCA_BuildParameterSensitivePlanEvidence @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_BuildStatisticsCardinalityEvidence @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_BuildMemorySpillEvidence @CaptureRunID=@CaptureRunID;

    /* Generic synthesis consumes standard recommendation rows. */
    EXEC dbo.usp_RCA_BuildRootCauseSynthesis @CaptureRunID=@CaptureRunID;

    /* Specific causal overlays. Stronger upstream causes retain precedence. */
    EXEC dbo.usp_RCA_ApplyMemorySpillSynthesis @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_ApplyStatisticsCardinalitySynthesis @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_ApplyParameterSensitiveSynthesis @CaptureRunID=@CaptureRunID;
END;
GO

/*==============================================================================
  6. REPORT HELPER VIEW
  Keep the existing incident report untouched for now. This view provides the
  new 3C evidence section cleanly while Run 6 is being validated.
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_MemorySpillIncidentEvidence
AS
SELECT
      N'3C - MEMORY GRANT / SPILL EVIDENCE' AS ReportSection
    , CaptureRunID
    , ImpactedExecutionEvidenceID AS ExecutionEvidenceID
    , BaselineExecutionEvidenceID
    , RepresentativePlanEvidenceID
    , SpillOperatorCount
    , HighSeveritySpillCount
    , SpillPhysicalOps
    , RequestedMemoryKB
    , GrantedMemoryKB
    , MaxUsedMemoryKB
    , ActualDOP
    , GrantUtilizationPercent
    , CardinalityMismatchCount
    , HighSeverityCardinalityMismatchCount
    , StatisticsRiskCount
    , BaselineDurationMs
    , ImpactedDurationMs
    , DurationRatio
    , BaselineCPUms
    , ImpactedCPUms
    , CPURatio
    , BaselineLogicalReads
    , ImpactedLogicalReads
    , LogicalReadRatio
    , BaselineWrites
    , ImpactedWrites
    , WriteRatio
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
FROM dbo.RCA_MemorySpillEvidence;
GO

/*==============================================================================
  7. INSTALL VALIDATION
==============================================================================*/
SELECT
      MemorySpillVersion='v4.1'
    , MemorySpillFindingBuilder = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildMemorySpillFindings',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillEvidenceTable  = CASE WHEN OBJECT_ID(N'dbo.RCA_MemorySpillEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillEvidenceView   = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_MemorySpillEvidence',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillDetector       = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildMemorySpillEvidence',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillSynthesis      = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyMemorySpillSynthesis',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , AnalyzeWorkflow           = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , SpillIncidentView         = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_MemorySpillIncidentEvidence',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO
