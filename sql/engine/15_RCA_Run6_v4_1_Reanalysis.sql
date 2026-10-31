USE DBA;
GO

/*==============================================================================
  Run 6 - v4.1 reanalysis only
  No workload rerun. No XE reimport. Rebuilds Run 6 derived evidence from the
  already-imported CaptureRunID 6 data.
==============================================================================*/

EXEC dbo.usp_RCA_AnalyzeCaptureRun
     @CaptureRunID = 6,
     @Reparse = 0;
GO

SELECT
      MemorySpillEvidenceID
    , BaselineExecutionEvidenceID
    , ImpactedExecutionEvidenceID
    , SpillOperatorCount
    , HighSeveritySpillCount
    , RequestedMemoryKB
    , GrantedMemoryKB
    , MaxUsedMemoryKB
    , GrantUtilizationPercent
    , BaselineDurationMs
    , ImpactedDurationMs
    , DurationRatio
    , BaselineCPUms
    , ImpactedCPUms
    , CPURatio
    , BaselineLogicalReads
    , ImpactedLogicalReads
    , LogicalReadRatio
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
FROM dbo.vw_RCA_MemorySpillEvidence
WHERE CaptureRunID=6
ORDER BY
      CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END
    , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
    , ImpactedExecutionEvidenceID;
GO

SELECT
      ExecutionEvidenceID
    , Confidence
    , PrimaryCause
    , ContributingFactor1
    , ContributingFactor2
    , Action1
    , Action2
    , Action3
    , ExecutiveSummary
FROM dbo.RCA_RootCauseSynthesis
WHERE CaptureRunID=6
ORDER BY ExecutionEvidenceID;
GO

EXEC dbo.usp_RCA_ShowIncidentReport
     @CaptureRunID=6,
     @IncludeTechnicalEvidence=1;
GO
