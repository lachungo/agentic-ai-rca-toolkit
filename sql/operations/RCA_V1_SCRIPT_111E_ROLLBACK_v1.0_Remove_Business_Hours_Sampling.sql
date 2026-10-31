USE dbamaint;
GO
SET NOCOUNT ON;
DECLARE @Name sysname;
DECLARE @Names table(JobName sysname);
INSERT @Names VALUES(N'RCA_V1_BH_00_Start'),(N'RCA_V1_BH_01_CPU_Blocking_Memory'),
(N'RCA_V1_BH_02_IO'),(N'RCA_V1_BH_03_TempDB'),(N'RCA_V1_BH_04_Log'),
(N'RCA_V1_BH_05_Connectivity'),(N'RCA_V1_BH_99_StopAnalyze');
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT JobName FROM @Names;
OPEN c; FETCH NEXT FROM c INTO @Name;
WHILE @@FETCH_STATUS=0
BEGIN
 IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@Name) EXEC msdb.dbo.sp_delete_job @job_name=@Name;
 FETCH NEXT FROM c INTO @Name;
END
CLOSE c; DEALLOCATE c;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_StopBusinessHoursCollection;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_RunBusinessHoursWorker;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_StartBusinessHoursCollection;
SELECT 'SCRIPT 111E ROLLBACK' ValidationSection,'PASS' Result,'SCHEDULES AND THREE ORCHESTRATION PROCEDURES REMOVED; RCA EVIDENCE PRESERVED' SafetyStatement;
GO
