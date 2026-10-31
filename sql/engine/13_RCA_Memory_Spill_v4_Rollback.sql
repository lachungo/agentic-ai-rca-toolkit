USE DBA;
GO
/* Removes only the new memory-spill evidence objects. */
DROP VIEW IF EXISTS dbo.vw_RCA_MemorySpillIncidentEvidence;
DROP VIEW IF EXISTS dbo.vw_RCA_MemorySpillEvidence;
GO
DROP PROCEDURE IF EXISTS dbo.usp_RCA_ApplyMemorySpillSynthesis;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_BuildMemorySpillEvidence;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_BuildMemorySpillFindings;
GO
DROP TABLE IF EXISTS dbo.RCA_MemorySpillEvidence;
GO
PRINT 'Memory-spill v4 objects removed.';
PRINT 'Rerun 12_RCA_Multi_Cause_Intelligence_v3.sql to restore the v3 AnalyzeCaptureRun orchestration.';
GO
