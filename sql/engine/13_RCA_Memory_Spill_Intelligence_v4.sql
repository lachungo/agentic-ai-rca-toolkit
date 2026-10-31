USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  13_RCA_Memory_Spill_Intelligence_v4.sql

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
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 68000,N'Invalid CaptureRunID.',1;

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
              WHEN pe.GrantedMemoryKB IS NOT NULL
               AND pe.MaxUsedMemoryKB IS NOT NULL
               AND pe.GrantedMemoryKB > 0
               AND pe.MaxUsedMemoryKB >= pe.GrantedMemoryKB
              THEN 'HIGH'
              ELSE 'MEDIUM'
          END
        , 'MEMORY_SPILL'
        , CONCAT
          (
              N'Runtime spill detected in ',COALESCE(o.PhysicalOp,N'(unknown)'),
              N' / ',COALESCE(o.LogicalOp,N'(unknown)'),
              N' at NodeId ',COALESCE(CONVERT(varchar(20),o.NodeID),'?'),N'. ',
              N'RequestedMemoryKB=',COALESCE(CONVERT(varchar(30),pe.RequestedMemoryKB),'NULL'),
              N'; GrantedMemoryKB=',COALESCE(CONVERT(varchar(30),pe.GrantedMemoryKB),'NULL'),
              N'; MaxUsedMemoryKB=',COALESCE(CONVERT(varchar(30),pe.MaxUsedMemoryKB),'NULL'),
              N'; ActualDOP=',COALESCE(CONVERT(varchar(20),pe.ActualDOP),'NULL'),N'.'
          )
        , N'Inspect the spilling Sort/Hash operator, requested/granted/max-used memory, cardinality estimates, concurrency, and tempdb impact. Determine whether the spill is primary or downstream of another cause.'
    FROM dbo.RCA_PlanOperator o
    JOIN dbo.RCA_PlanEvidence pe
      ON pe.PlanEvidenceID=o.PlanEvidenceID
     AND pe.CaptureRunID=o.CaptureRunID
    WHERE o.CaptureRunID=@CaptureRunID
      AND o.HasSpillWarning=1
      AND o.ExecutionEvidenceID IS NOT NULL;

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
        SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID
    )
        THROW 68010,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_MemorySpillEvidence
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_Recommendation
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseCategory='MEMORY_GRANT_SPILL';

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
                    CONCAT(COALESCE(o.PhysicalOp,N'?'),N'/',
                           COALESCE(o.LogicalOp,N'?'),N' Node ',
                           COALESCE(CONVERT(varchar(20),o.NodeID),'?'))),N'; ')
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
    Candidate AS
    (
        SELECT
              s.ExecutionEvidenceID AS ImpactedExecutionEvidenceID
            , s.SpillOperatorCount
            , s.HighSeveritySpillCount
            , so.SpillPhysicalOps
            , g.RepresentativePlanEvidenceID
            , g.RequestedMemoryKB
            , g.GrantedMemoryKB
            , g.MaxUsedMemoryKB
            , g.ActualDOP
            , GrantUtilizationPercent=
                CONVERT(decimal(19,4),100.0*g.MaxUsedMemoryKB/NULLIF(g.GrantedMemoryKB,0))
            , CardinalityMismatchCount=ISNULL(f.CardinalityMismatchCount,0)
            , HighSeverityCardinalityMismatchCount=ISNULL(f.HighSeverityCardinalityMismatchCount,0)
            , StatisticsRiskCount=ISNULL(f.StatisticsRiskCount,0)
        FROM SpillAgg s
        LEFT JOIN SpillOps so ON so.ExecutionEvidenceID=s.ExecutionEvidenceID
        LEFT JOIN GrantAgg g ON g.ExecutionEvidenceID=s.ExecutionEvidenceID
        LEFT JOIN FindingAgg f ON f.ExecutionEvidenceID=s.ExecutionEvidenceID
    ),
    Baselines AS
    (
        SELECT
              c.ImpactedExecutionEvidenceID
            , b.ExecutionEvidenceID AS BaselineExecutionEvidenceID
            , rn=ROW_NUMBER() OVER
              (
                  PARTITION BY c.ImpactedExecutionEvidenceID
                  ORDER BY ISNULL(b.LogicalReads,9223372036854775807),
                           ISNULL(b.CPUms,999999999999.999),
                           ISNULL(b.DurationMs,999999999999.999),
                           b.ExecutionEvidenceID
              )
        FROM Candidate c
        JOIN dbo.RCA_ExecutionEvidence i
          ON i.ExecutionEvidenceID=c.ImpactedExecutionEvidenceID
        JOIN dbo.RCA_ExecutionEvidence b
          ON b.CaptureRunID=@CaptureRunID
         AND b.ExecutionEvidenceID<>i.ExecutionEvidenceID
         AND ISNULL(b.ObjectName,N'')=ISNULL(i.ObjectName,N'')
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.RCA_PlanOperator bo
            WHERE bo.CaptureRunID=@CaptureRunID
              AND bo.ExecutionEvidenceID=b.ExecutionEvidenceID
              AND bo.HasSpillWarning=1
        )
    ),
    BestBaseline AS
    (
        SELECT ImpactedExecutionEvidenceID,BaselineExecutionEvidenceID
        FROM Baselines WHERE rn=1
    ),
    E AS
    (
        SELECT
              c.*
            , bb.BaselineExecutionEvidenceID
            , be.DurationMs AS BaselineDurationMs
            , ie.DurationMs AS ImpactedDurationMs
            , DurationRatio=CONVERT(decimal(19,4),ie.DurationMs/NULLIF(be.DurationMs,0))
            , be.CPUms AS BaselineCPUms
            , ie.CPUms AS ImpactedCPUms
            , CPURatio=CONVERT(decimal(19,4),ie.CPUms/NULLIF(be.CPUms,0))
            , be.LogicalReads AS BaselineLogicalReads
            , ie.LogicalReads AS ImpactedLogicalReads
            , LogicalReadRatio=CONVERT(decimal(19,4),1.0*ie.LogicalReads/NULLIF(be.LogicalReads,0))
            , be.Writes AS BaselineWrites
            , ie.Writes AS ImpactedWrites
            , WriteRatio=CONVERT(decimal(19,4),1.0*ie.Writes/NULLIF(be.Writes,0))
            , HasParameterCause=
                CASE WHEN EXISTS
                (
                    SELECT 1 FROM dbo.RCA_ParameterSensitivePlanEvidence p
                    WHERE p.CaptureRunID=@CaptureRunID
                      AND p.ImpactedExecutionEvidenceID=c.ImpactedExecutionEvidenceID
                      AND p.Confidence IN ('HIGH','MEDIUM')
                ) THEN 1 ELSE 0 END
            , HasStatisticsCause=
                CASE WHEN EXISTS
                (
                    SELECT 1 FROM dbo.RCA_StatisticsCardinalityEvidence s
                    WHERE s.CaptureRunID=@CaptureRunID
                      AND s.ImpactedExecutionEvidenceID=c.ImpactedExecutionEvidenceID
                      AND s.Confidence IN ('HIGH','MEDIUM')
                ) THEN 1 ELSE 0 END
        FROM Candidate c
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
                (CASE WHEN ISNULL(DurationRatio,0)>=2 THEN 1 ELSE 0 END)+
                (CASE WHEN ISNULL(CPURatio,0)>=2 THEN 1 ELSE 0 END)+
                (CASE WHEN ISNULL(LogicalReadRatio,0)>=2 THEN 1 ELSE 0 END)+
                (CASE WHEN ISNULL(WriteRatio,0)>=2 THEN 1 ELSE 0 END)
            , UpstreamCauseCategory=
                CASE
                    WHEN HasParameterCause=1 THEN 'PARAMETER_SENSITIVE_PLAN_REUSE'
                    WHEN HasStatisticsCause=1 THEN 'STATISTICS_CARDINALITY_REGRESSION'
                    WHEN HighSeverityCardinalityMismatchCount>=3 THEN 'CARDINALITY_REGRESSION'
                    ELSE NULL
                END
        FROM E e
    )
    INSERT dbo.RCA_MemorySpillEvidence
    (
          CaptureRunID,BaselineExecutionEvidenceID,ImpactedExecutionEvidenceID,
          RepresentativePlanEvidenceID,SpillOperatorCount,HighSeveritySpillCount,
          SpillPhysicalOps,RequestedMemoryKB,GrantedMemoryKB,MaxUsedMemoryKB,
          ActualDOP,GrantUtilizationPercent,CardinalityMismatchCount,
          HighSeverityCardinalityMismatchCount,StatisticsRiskCount,
          BaselineDurationMs,ImpactedDurationMs,DurationRatio,
          BaselineCPUms,ImpactedCPUms,CPURatio,
          BaselineLogicalReads,ImpactedLogicalReads,LogicalReadRatio,
          BaselineWrites,ImpactedWrites,WriteRatio,
          UpstreamCauseCategory,RootCauseRole,Confidence,EvidenceSummary
    )
    SELECT
          @CaptureRunID,s.BaselineExecutionEvidenceID,s.ImpactedExecutionEvidenceID,
          s.RepresentativePlanEvidenceID,s.SpillOperatorCount,s.HighSeveritySpillCount,
          s.SpillPhysicalOps,s.RequestedMemoryKB,s.GrantedMemoryKB,s.MaxUsedMemoryKB,
          s.ActualDOP,s.GrantUtilizationPercent,s.CardinalityMismatchCount,
          s.HighSeverityCardinalityMismatchCount,s.StatisticsRiskCount,
          s.BaselineDurationMs,s.ImpactedDurationMs,s.DurationRatio,
          s.BaselineCPUms,s.ImpactedCPUms,s.CPURatio,
          s.BaselineLogicalReads,s.ImpactedLogicalReads,s.LogicalReadRatio,
          s.BaselineWrites,s.ImpactedWrites,s.WriteRatio,
          s.UpstreamCauseCategory,
          CASE WHEN s.UpstreamCauseCategory IS NULL THEN 'PRIMARY' ELSE 'CONTRIBUTING' END,
          CASE
              WHEN s.UpstreamCauseCategory IS NULL AND s.RegressionSignals>=2 THEN 'HIGH'
              WHEN s.RegressionSignals>=1 OR s.BaselineExecutionEvidenceID IS NULL THEN 'MEDIUM'
              ELSE 'LOW'
          END,
          CONCAT
          (
              N'Execution ',s.ImpactedExecutionEvidenceID,N' contained ',s.SpillOperatorCount,
              N' spill warning(s): ',COALESCE(s.SpillPhysicalOps,N'(operator unavailable)'),N'. ',
              N'Requested=',COALESCE(CONVERT(varchar(30),s.RequestedMemoryKB),'NULL'),N' KB; ',
              N'Granted=',COALESCE(CONVERT(varchar(30),s.GrantedMemoryKB),'NULL'),N' KB; ',
              N'MaxUsed=',COALESCE(CONVERT(varchar(30),s.MaxUsedMemoryKB),'NULL'),N' KB; ',
              N'Grant utilization=',COALESCE(CONVERT(varchar(30),s.GrantUtilizationPercent),'NULL'),N'%. ',
              CASE WHEN s.BaselineExecutionEvidenceID IS NOT NULL THEN CONCAT
              (
                  N'Baseline execution ',s.BaselineExecutionEvidenceID,N': duration=',
                  COALESCE(CONVERT(varchar(30),s.DurationRatio),'NULL'),N'x; CPU=',
                  COALESCE(CONVERT(varchar(30),s.CPURatio),'NULL'),N'x; logical reads=',
                  COALESCE(CONVERT(varchar(30),s.LogicalReadRatio),'NULL'),N'x; writes=',
                  COALESCE(CONVERT(varchar(30),s.WriteRatio),'NULL'),N'x. '
              ) ELSE N'No non-spilling same-object baseline was available. ' END,
              N'High-severity cardinality mismatches=',s.HighSeverityCardinalityMismatchCount,
              N'; statistics-risk findings=',s.StatisticsRiskCount,N'. ',
              CASE WHEN s.UpstreamCauseCategory IS NULL
                   THEN N'No stronger upstream parameter/statistics cause was detected; spill classified PRIMARY.'
                   ELSE CONCAT(N'Spill classified CONTRIBUTING because stronger upstream evidence exists: ',s.UpstreamCauseCategory,N'.')
              END
          )
    FROM Scored s;

    INSERT dbo.RCA_Recommendation
    (
          CaptureRunID,ExecutionEvidenceID,Priority,Confidence,RootCauseCategory,
          RootCauseSummary,EvidenceSummary,WhyItMatters,RecommendedAction,
          EvidenceCount,HighSeverityFindingCount,MediumSeverityFindingCount
    )
    SELECT
          e.CaptureRunID,e.ImpactedExecutionEvidenceID,
          CASE WHEN e.RootCauseRole='PRIMARY' AND e.Confidence='HIGH' THEN 1 ELSE 2 END,
          e.Confidence,'MEMORY_GRANT_SPILL',
          CASE WHEN e.RootCauseRole='PRIMARY'
               THEN N'Runtime memory-grant/spill behavior materially contributed to the execution regression.'
               ELSE N'Runtime spill behavior was observed, but stronger upstream evidence indicates it is a contributing symptom.' END,
          e.EvidenceSummary,
          N'Spills move work that should ideally remain memory-resident into tempdb, adding I/O and elapsed time. The fix depends on whether the spill is primary or caused by bad estimates.',
          CASE WHEN e.RootCauseRole='PRIMARY'
               THEN N'Reproduce the execution and inspect the spilling operator, requested/granted/max-used memory, concurrency, tempdb activity, and plan shape. Test the least invasive change that removes the spill without over-granting memory.'
               ELSE N'Address the upstream parameter/cardinality/statistics cause first, then rerun the same workload and verify whether the spill disappears before changing memory behavior.' END,
          e.SpillOperatorCount+e.CardinalityMismatchCount+e.StatisticsRiskCount,
          e.HighSeveritySpillCount,
          CASE WHEN e.SpillOperatorCount>e.HighSeveritySpillCount
               THEN e.SpillOperatorCount-e.HighSeveritySpillCount ELSE 0 END
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
      MemorySpillFindingBuilder = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildMemorySpillFindings',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillEvidenceTable  = CASE WHEN OBJECT_ID(N'dbo.RCA_MemorySpillEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillEvidenceView   = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_MemorySpillEvidence',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillDetector       = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildMemorySpillEvidence',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , MemorySpillSynthesis      = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyMemorySpillSynthesis',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , AnalyzeWorkflow           = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , SpillIncidentView         = CASE WHEN OBJECT_ID(N'dbo.vw_RCA_MemorySpillIncidentEvidence',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO
