USE dbamaint;
GO
/*=============================================================================
 RCA V1 - SCRIPT 111E v1.0
 Deploy one-database business-hours sampling for RCA.

 Local schedule: 08:00 start, 08:02 parallel samplers, 17:00 stop/analyze.
 Sample interval: 60 seconds. Worker duration: 535 minutes (through 16:57).
 No certified detector, evidence builder, arbitration view, or DBA answer is changed.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT<>0 THROW 63910,'SCRIPT 111E ABORTED: use a new query window.',1;

DECLARE @Required table(ObjectName sysname,ObjectType char(2));
INSERT @Required VALUES
(N'dbo.usp_RCA_StartCapture',N'P'),(N'dbo.usp_RCA_Stop',N'P'),
(N'dbo.usp_RCA_RunSampler',N'P'),(N'dbo.usp_RCA_RunIOSampler',N'P'),
(N'dbo.usp_RCA_RunTempDBSampler',N'P'),(N'dbo.usp_RCA_RunLogSampler',N'P'),
(N'dbo.usp_RCA_RunConnectivitySampler',N'P'),(N'dbo.RCA_CaptureRun',N'U');
IF DB_ID(N'RCA') IS NULL OR EXISTS(SELECT 1 FROM @Required WHERE OBJECT_ID(ObjectName,ObjectType) IS NULL)
 THROW 63911,'SCRIPT 111E ABORTED: RCA or a required certified collection object is absent.',1;

SELECT '0 - SCRIPT 111E PREFLIGHT' ValidationSection,@@SERVERNAME ServerName,DB_NAME() RepositoryDatabase,
 CURRENT_TIMEZONE() SQLServerTimeZone,N'RCA' ActiveDatabase,'08:00-17:00 LOCAL' CollectionWindow,
 60 SampleSeconds,535 WorkerDurationMinutes,'PASS' PreflightGate;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_StartBusinessHoursCollection
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @CaptureRunID bigint,@Reason nvarchar(2000)=N'RCA V1 BUSINESS HOURS COLLECTOR | DB=RCA | '+CONVERT(nvarchar(10),CONVERT(date,SYSDATETIME()),120);
 IF CONVERT(time(0),SYSDATETIME())<'08:00' OR CONVERT(time(0),SYSDATETIME())>='17:00' RETURN;
 IF EXISTS(SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureStatus IN ('RUNNING','CAPTURING')) RETURN;
 EXEC dbo.usp_RCA_StartCapture @CaptureReason=@Reason,@CaptureRunID=@CaptureRunID OUTPUT;
 UPDATE dbo.RCA_CaptureRun SET TargetDatabase=N'RCA'
 WHERE CaptureRunID=@CaptureRunID AND CaptureStatus IN ('RUNNING','CAPTURING');
 IF @@ROWCOUNT<>1 THROW 63912,'Business-hours capture could not be assigned to RCA.',1;
 SELECT @CaptureRunID CaptureRunID,N'RCA' TargetDatabase,'STARTED' CollectionState;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_RunBusinessHoursWorker
 @SamplerName sysname
AS
BEGIN
 SET NOCOUNT ON;
 IF @SamplerName NOT IN (N'usp_RCA_RunSampler',N'usp_RCA_RunIOSampler',N'usp_RCA_RunTempDBSampler',N'usp_RCA_RunLogSampler',N'usp_RCA_RunConnectivitySampler')
  THROW 63913,'Unsupported RCA sampler.',1;
 DECLARE @CaptureRunID bigint,@Attempts int=0,@SQL nvarchar(max);
 WHILE @CaptureRunID IS NULL AND @Attempts<30
 BEGIN
  SELECT TOP(1) @CaptureRunID=CaptureRunID FROM dbo.RCA_CaptureRun
  WHERE TargetDatabase=N'RCA' AND CaptureStatus IN ('RUNNING','CAPTURING')
    AND CaptureReason LIKE N'RCA V1 BUSINESS HOURS COLLECTOR%'
  ORDER BY CaptureRunID DESC;
  IF @CaptureRunID IS NULL BEGIN WAITFOR DELAY '00:00:10'; SET @Attempts+=1; END;
 END;
 IF @CaptureRunID IS NULL THROW 63914,'No active RCA business-hours capture was found.',1;
 SET @SQL=N'EXEC dbo.'+QUOTENAME(@SamplerName)+N' @CaptureRunID=@p1,@DurationMinutes=535,@SampleSeconds=60;';
 EXEC sys.sp_executesql @SQL,N'@p1 bigint',@p1=@CaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_StopBusinessHoursCollection
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @CaptureRunID bigint;
 SELECT TOP(1) @CaptureRunID=CaptureRunID FROM dbo.RCA_CaptureRun
 WHERE TargetDatabase=N'RCA' AND CaptureStatus IN ('RUNNING','CAPTURING')
   AND CaptureReason LIKE N'RCA V1 BUSINESS HOURS COLLECTOR%'
 ORDER BY CaptureRunID DESC;
 IF @CaptureRunID IS NOT NULL EXEC dbo.usp_RCA_Stop @CaptureRunID=@CaptureRunID;
 SELECT @CaptureRunID CaptureRunID,CASE WHEN @CaptureRunID IS NULL THEN 'NO ACTIVE COLLECTOR' ELSE 'STOPPED AND ANALYZED' END CollectionState;
END;
GO

DECLARE @Names table(JobName sysname);
INSERT @Names VALUES(N'RCA_V1_BH_00_Start'),(N'RCA_V1_BH_01_CPU_Blocking_Memory'),
(N'RCA_V1_BH_02_IO'),(N'RCA_V1_BH_03_TempDB'),(N'RCA_V1_BH_04_Log'),
(N'RCA_V1_BH_05_Connectivity'),(N'RCA_V1_BH_99_StopAnalyze');
DECLARE @Name sysname;
DECLARE cleanup CURSOR LOCAL FAST_FORWARD FOR SELECT JobName FROM @Names;
OPEN cleanup; FETCH NEXT FROM cleanup INTO @Name;
WHILE @@FETCH_STATUS=0
BEGIN
 IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@Name) EXEC msdb.dbo.sp_delete_job @job_name=@Name;
 FETCH NEXT FROM cleanup INTO @Name;
END
CLOSE cleanup; DEALLOCATE cleanup;

DECLARE @Owner sysname=SUSER_SNAME(0),@JobID uniqueidentifier,@Command nvarchar(max),@StartTime int;
DECLARE @Jobs table(JobOrder int,JobName sysname,Command nvarchar(max),StartTime int);
INSERT @Jobs VALUES
(0,N'RCA_V1_BH_00_Start',N'EXEC dbo.usp_RCA_StartBusinessHoursCollection;',080000),
(1,N'RCA_V1_BH_01_CPU_Blocking_Memory',N'EXEC dbo.usp_RCA_RunBusinessHoursWorker @SamplerName=N''usp_RCA_RunSampler'';',080200),
(2,N'RCA_V1_BH_02_IO',N'EXEC dbo.usp_RCA_RunBusinessHoursWorker @SamplerName=N''usp_RCA_RunIOSampler'';',080200),
(3,N'RCA_V1_BH_03_TempDB',N'EXEC dbo.usp_RCA_RunBusinessHoursWorker @SamplerName=N''usp_RCA_RunTempDBSampler'';',080200),
(4,N'RCA_V1_BH_04_Log',N'EXEC dbo.usp_RCA_RunBusinessHoursWorker @SamplerName=N''usp_RCA_RunLogSampler'';',080200),
(5,N'RCA_V1_BH_05_Connectivity',N'EXEC dbo.usp_RCA_RunBusinessHoursWorker @SamplerName=N''usp_RCA_RunConnectivitySampler'';',080200),
(99,N'RCA_V1_BH_99_StopAnalyze',N'EXEC dbo.usp_RCA_StopBusinessHoursCollection;',170000);
DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR SELECT JobName,Command,StartTime FROM @Jobs ORDER BY JobOrder;
OPEN jobs; FETCH NEXT FROM jobs INTO @Name,@Command,@StartTime;
WHILE @@FETCH_STATUS=0
BEGIN
 SET @JobID=NULL;
 EXEC msdb.dbo.sp_add_job @job_name=@Name,@enabled=1,@owner_login_name=@Owner,
  @description=N'RCA V1 business-hours seven-domain collection',@job_id=@JobID OUTPUT;
 EXEC msdb.dbo.sp_add_jobstep @job_id=@JobID,@step_name=N'RCA V1 collection step',@subsystem=N'TSQL',
  @database_name=N'dbamaint',@command=@Command,@retry_attempts=2,@retry_interval=1;
 EXEC msdb.dbo.sp_add_jobschedule @job_id=@JobID,@name=@Name,@freq_type=4,@freq_interval=1,
  @freq_subday_type=1,@active_start_time=@StartTime;
 EXEC msdb.dbo.sp_add_jobserver @job_id=@JobID;
 FETCH NEXT FROM jobs INTO @Name,@Command,@StartTime;
END
CLOSE jobs; DEALLOCATE jobs;

SELECT '1 - SCRIPT 111E DEPLOYED JOBS' ValidationSection,j.name JobName,j.enabled,
 s.step_name,s.database_name,s.command,sch.active_start_time
FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id=j.job_id
JOIN msdb.dbo.sysjobschedules js ON js.job_id=j.job_id
JOIN msdb.dbo.sysschedules sch ON sch.schedule_id=js.schedule_id
WHERE j.name LIKE N'RCA_V1_BH[_]%'
ORDER BY sch.active_start_time,j.name;

SELECT '2 - SCRIPT 111E FINAL VERDICT' ValidationSection,'PASS' Result,N'RCA' ActiveDatabase,
 7 CertifiedDomainTarget,5 ParallelSamplerJobs,'08:00-17:00 SQL SERVER LOCAL TIME' Schedule,
 'NO CERTIFIED DETECTOR OR ARBITRATION OBJECT MODIFIED' SafetyStatement;
GO
