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
 IF NOT EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
  THROW 63100,N'CaptureRunID does not exist.',1;

 /* Result 1: one-screen incident summary */
 SELECT N'SQL RCA INCIDENT SUMMARY' ReportSection,
  CaptureRunID,TargetDatabase,CaptureReason,StartTimeUTC,EndTimeUTC,CaptureDurationSeconds,
  OverallConfidence,ConfidenceBasis,SynthesizedExecutions,
  PrimaryCause,MostImpactedExecutionEvidenceID,MostImpactedObject,MostImpactedParameters,
  CAST(DurationMs/1000.0 AS decimal(19,2)) DurationSeconds,
  CAST(CPUms/1000.0 AS decimal(19,2)) CPUSeconds,
  LogicalReads,Writes,TotalRows RowsAffected,PrimaryEvidence,
  ContributingFactor1,ContributingFactor2,RuledOutCause,RuledOutEvidence,
  Action1,Action2,Action3,ExecutiveSummary,
  PeakSqlCpuPercent,LowestBufferCacheHitRatio,LowestPLESeconds,
  LowestAvailablePhysicalMemoryMB,PeakMemoryGrantsPending,PeakRunnableTasks
 FROM dbo.vw_RCA_IncidentSummary WHERE CaptureRunID=@CaptureRunID;

 /* Result 2: narrow/heavy execution comparison */
 SELECT N'EXECUTION COMPARISON' ReportSection,ExecutionEvidenceID,EventTimeUTC,ObjectName,
  Confidence,CAST(DurationMs/1000.0 AS decimal(19,2)) DurationSeconds,
  CAST(CPUms/1000.0 AS decimal(19,2)) CPUSeconds,
  LogicalReads,PhysicalReads,Writes,TotalRows RowsAffected,LinkedActualPlans,
  Assessment,ParameterText
 FROM dbo.vw_RCA_ExecutionComparison
 WHERE CaptureRunID=@CaptureRunID
 ORDER BY DurationMs DESC,CPUms DESC;

 /* Result 3: proof / DBA drill-down */
 IF @IncludeTechnicalEvidence=1
 SELECT N'TECHNICAL RCA EVIDENCE' ReportSection,s.ExecutionEvidenceID,e.EventTimeUTC,
  e.SessionID,e.DatabaseName,e.HostName,e.ProgramName,e.LoginName,e.CPUms,e.DurationMs,
  e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows,e.ParameterText,s.Confidence,
  s.PrimaryCause,s.PrimaryEvidence,s.ContributingFactor1,s.ContributingEvidence1,
  s.ContributingFactor2,s.ContributingEvidence2,s.RuledOutCause,s.RuledOutEvidence,
  s.Action1,s.Action2,s.Action3,s.ExecutiveSummary
 FROM dbo.RCA_RootCauseSynthesis s
 JOIN dbo.RCA_ExecutionEvidence e ON e.ExecutionEvidenceID=s.ExecutionEvidenceID
 WHERE s.CaptureRunID=@CaptureRunID
 ORDER BY e.DurationMs DESC,e.CPUms DESC;
END;
GO

SELECT
 IncidentSummaryView=CASE WHEN OBJECT_ID(N'dbo.vw_RCA_IncidentSummary',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 ExecutionComparisonView=CASE WHEN OBJECT_ID(N'dbo.vw_RCA_ExecutionComparison',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
 IncidentReport=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ShowIncidentReport',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

-- TEST:
-- EXEC dbo.usp_RCA_ShowIncidentReport @CaptureRunID=3,@IncludeTechnicalEvidence=1;
-- Executive only:
-- EXEC dbo.usp_RCA_ShowIncidentReport @CaptureRunID=3,@IncludeTechnicalEvidence=0;
