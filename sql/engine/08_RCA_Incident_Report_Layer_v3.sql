USE DBA;
GO
/*
08_RCA_Incident_Report_Layer.sql
Presentation only. Does not alter capture/parser/correlation/synthesis logic.
*/
CREATE OR ALTER VIEW dbo.vw_RCA_IncidentSummary
AS
WITH SA AS
(
 SELECT CaptureRunID,
        MAX(SqlCpuPercent) PeakSqlCpuPercent,
        MIN(BufferCacheHitRatio) LowestBufferCacheHitRatio,
        MIN(PageLifeExpectancySeconds) LowestPLESeconds,
        MIN(AvailablePhysicalMemoryMB) LowestAvailablePhysicalMemoryMB,
        MAX(MemoryGrantsPending) PeakMemoryGrantsPending,
        MAX(RunnableTasks) PeakRunnableTasks
 FROM dbo.RCA_ServerSnapshot GROUP BY CaptureRunID
),
W AS
(
 SELECT *
 FROM
 (
  SELECT s.CaptureRunID,s.ExecutionEvidenceID,s.Confidence,s.PrimaryCause,
         s.PrimaryEvidence,s.ContributingFactor1,s.ContributingFactor2,
         s.RuledOutCause,s.RuledOutEvidence,s.Action1,s.Action2,s.Action3,
         s.ExecutiveSummary,e.ObjectName,e.ParameterText,e.CPUms,e.DurationMs,
         e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows,
         ROW_NUMBER() OVER(PARTITION BY s.CaptureRunID
                           ORDER BY e.DurationMs DESC,e.CPUms DESC,e.LogicalReads DESC) rn
  FROM dbo.RCA_RootCauseSynthesis s
  JOIN dbo.RCA_ExecutionEvidence e
    ON e.ExecutionEvidenceID=s.ExecutionEvidenceID
 ) q WHERE rn=1
),
CA AS
(
 SELECT CaptureRunID,COUNT(*) SynthesizedExecutions,
        SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END) HighConfidence
 FROM dbo.RCA_RootCauseSynthesis GROUP BY CaptureRunID
)
SELECT r.CaptureRunID,r.TargetDatabase,r.CaptureReason,r.StartTimeUTC,r.EndTimeUTC,
 CAST(DATEDIFF_BIG(millisecond,r.StartTimeUTC,r.EndTimeUTC)/1000.0 AS decimal(19,1)) CaptureDurationSeconds,
 CASE WHEN ca.SynthesizedExecutions>0 AND ca.SynthesizedExecutions=ca.HighConfidence
      THEN 'HIGH' WHEN ca.HighConfidence>0 THEN 'MIXED' ELSE 'LOW' END OverallConfidence,
 ca.SynthesizedExecutions,
 w.ExecutionEvidenceID MostImpactedExecutionEvidenceID,
 COALESCE(w.ObjectName,N'Ad hoc / batch execution') MostImpactedObject,
 w.ParameterText MostImpactedParameters,w.DurationMs,w.CPUms,w.LogicalReads,w.Writes,w.TotalRows,
 w.PrimaryCause,w.PrimaryEvidence,w.ContributingFactor1,w.ContributingFactor2,
 w.RuledOutCause,w.RuledOutEvidence,w.Action1,w.Action2,w.Action3,w.ExecutiveSummary,
 sa.PeakSqlCpuPercent,sa.LowestBufferCacheHitRatio,sa.LowestPLESeconds,
 sa.LowestAvailablePhysicalMemoryMB,sa.PeakMemoryGrantsPending,sa.PeakRunnableTasks,
 CASE
  WHEN w.ExecutionEvidenceID IS NULL THEN N'LOW - no synthesized execution evidence is available.'
  WHEN w.Confidence='HIGH'
   AND EXISTS(SELECT 1 FROM dbo.RCA_PlanEvidence p
              WHERE p.CaptureRunID=r.CaptureRunID
                AND p.LinkedExecutionEvidenceID=w.ExecutionEvidenceID
                AND p.ActualExecutionPlanXML IS NOT NULL)
   AND NULLIF(LTRIM(RTRIM(w.ParameterText)),N'') IS NOT NULL
   THEN N'HIGH - supported by runtime parameters, execution metrics, linked actual execution plan, and server-state evidence.'
  WHEN w.Confidence='HIGH'
   THEN N'HIGH - supported by correlated execution and server-state evidence; review linked plan evidence for completeness.'
  ELSE CONCAT(w.Confidence,N' - review technical evidence before treating the conclusion as definitive.')
 END ConfidenceBasis
FROM dbo.RCA_CaptureRun r
LEFT JOIN CA ca ON ca.CaptureRunID=r.CaptureRunID
LEFT JOIN W w ON w.CaptureRunID=r.CaptureRunID
LEFT JOIN SA sa ON sa.CaptureRunID=r.CaptureRunID;
GO

CREATE OR ALTER VIEW dbo.vw_RCA_ExecutionComparison
AS
SELECT s.CaptureRunID,e.ExecutionEvidenceID,e.EventTimeUTC,
 COALESCE(e.ObjectName,N'Ad hoc / batch execution') ObjectName,
 e.ParameterText,s.Confidence,e.DurationMs,e.CPUms,e.LogicalReads,e.PhysicalReads,
 e.Writes,e.TotalRows,s.PrimaryCause Assessment,
 (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence p
  WHERE p.CaptureRunID=s.CaptureRunID
    AND p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID) LinkedActualPlans
FROM dbo.RCA_RootCauseSynthesis s
JOIN dbo.RCA_ExecutionEvidence e ON e.ExecutionEvidenceID=s.ExecutionEvidenceID;
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
       RESULT 3 - RUNTIME PARAMETERS
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
         N'3 - RUNTIME PARAMETERS' AS ReportSection,
         p.ExecutionEvidenceID,
         e.EventTimeUTC,
         COALESCE(e.ObjectName,N'Ad hoc / batch execution') AS ObjectName,
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
       RESULT 4 - ACTUAL PLAN ANALYSIS
       Parsed operator evidence from the captured actual plans.
       Worst/high-signal operators are sorted first.
     ======================================================================*/
     SELECT
         N'4 - ACTUAL PLAN ANALYSIS' AS ReportSection,
         p.LinkedExecutionEvidenceID AS ExecutionEvidenceID,
         o.PlanEvidenceID,
         o.NodeID,
         o.PhysicalOp,
         o.LogicalOp,
         o.EstimateRows,
         o.ActualRows,
         o.ActualRowsRead,
         o.ActualExecutions,
         o.EstimateActualRatio,
         o.EstimatedSubtreeCost,
         o.Parallel,
         o.DatabaseName,
         o.SchemaName,
         o.TableName,
         o.IndexName,
         o.IndexKind,
         o.Storage,
         o.HasSpillWarning,
         o.HasImplicitConversion,
         CASE
             WHEN o.HasSpillWarning=1 THEN 'HIGH - SPILL'
             WHEN o.HasImplicitConversion=1 THEN 'HIGH - IMPLICIT CONVERSION'
             WHEN o.EstimateActualRatio >= 100
               OR (o.EstimateActualRatio > 0 AND o.EstimateActualRatio <= 0.01)
                 THEN 'HIGH - CARDINALITY MISMATCH'
             WHEN o.EstimateActualRatio >= 10
               OR (o.EstimateActualRatio > 0 AND o.EstimateActualRatio <= 0.10)
                 THEN 'MEDIUM - CARDINALITY MISMATCH'
             WHEN o.PhysicalOp LIKE '%Scan%' AND ISNULL(o.ActualRowsRead,0)>=100000
                 THEN 'REVIEW - LARGE SCAN'
             ELSE 'INFO'
         END AS OperatorAssessment
     FROM dbo.RCA_PlanOperator o
     JOIN dbo.RCA_PlanEvidence p
       ON p.PlanEvidenceID=o.PlanEvidenceID
      AND p.CaptureRunID=o.CaptureRunID
     WHERE o.CaptureRunID=@CaptureRunID
       AND p.LinkedExecutionEvidenceID IS NOT NULL
     ORDER BY
         CASE
             WHEN o.HasSpillWarning=1 THEN 1
             WHEN o.HasImplicitConversion=1 THEN 2
             WHEN o.EstimateActualRatio >= 100
               OR (o.EstimateActualRatio > 0 AND o.EstimateActualRatio <= 0.01) THEN 3
             WHEN o.EstimateActualRatio >= 10
               OR (o.EstimateActualRatio > 0 AND o.EstimateActualRatio <= 0.10) THEN 4
             WHEN o.PhysicalOp LIKE '%Scan%' AND ISNULL(o.ActualRowsRead,0)>=100000 THEN 5
             ELSE 6
         END,
         ISNULL(o.ActualRowsRead,o.ActualRows) DESC,
         p.LinkedExecutionEvidenceID,
         o.PlanEvidenceID,
         o.NodeID;


     /*======================================================================
       RESULT 5 - CAPTURED ACTUAL EXECUTION PLANS
       ActualExecutionPlanXML remains XML so SSMS exposes the captured plan
       evidence for DBA inspection.
     ======================================================================*/
     SELECT
         N'5 - CAPTURED ACTUAL PLANS' AS ReportSection,
         p.LinkedExecutionEvidenceID AS ExecutionEvidenceID,
         p.PlanEvidenceID,
         p.EventTimeUTC,
         p.DatabaseName,
         p.SessionID,
         COALESCE(e.ObjectName,N'Ad hoc / batch execution') AS ObjectName,
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

SELECT
 IncidentSummaryView=CASE WHEN OBJECT_ID(N'dbo.vw_RCA_IncidentSummary',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 ExecutionComparisonView=CASE WHEN OBJECT_ID(N'dbo.vw_RCA_ExecutionComparison',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 IncidentReport=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ShowIncidentReport',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

-- TEST - full five-result incident report:
-- EXEC dbo.usp_RCA_ShowIncidentReport @CaptureRunID=3,@IncludeTechnicalEvidence=1;
--
-- Result 1 = Incident Summary
-- Result 2 = Execution Comparison
-- Result 3 = Runtime Parameters
-- Result 4 = Actual Plan Analysis
-- Result 5 = Captured Actual Execution Plans
--
-- Executive-only:
-- EXEC dbo.usp_RCA_ShowIncidentReport @CaptureRunID=3,@IncludeTechnicalEvidence=0;
