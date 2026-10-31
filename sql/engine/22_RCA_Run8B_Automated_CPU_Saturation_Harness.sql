USE RCA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
22_RCA_Run8B_Automated_CPU_Saturation_Harness.sql

PURPOSE
-------
Repeatable Run 8B CPU/scheduler-pressure validation for CaptureRunID 16.

WHY THIS VERSION
----------------
The first Run 8 workload used four MAXDOP 4 requests. On a 20-scheduler lab
instance that produced CPU activity but not sustained runnable-queue pressure.

This harness:
- uses 24 independent SQL Agent workers,
- forces each workload request to MAXDOP 1,
- launches the workers nearly simultaneously,
- leaves the existing RCA collector/sampler unchanged,
- provides live proof queries,
- includes cleanup for the temporary SQL Agent jobs.

IMPORTANT
---------
This is a LAB validation harness. It intentionally creates CPU pressure.
Do not run on a production server.

CaptureRunID for this validation: 16
==============================================================================*/


/*==============================================================================
STEP 1 - ALTER ONLY THE RUN-8 TEST PROCEDURE

MAXDOP 1 is deliberate. We want many independent runnable workers rather than
a few parallel requests consuming multiple schedulers.
==============================================================================*/
USE RCA;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_Run8_CPU
    @Loops int = 30
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @i int = 1;

    WHILE @i <= @Loops
    BEGIN
        SELECT
              GroupID
            , Cnt        = COUNT_BIG(*)
            , SumAmount  = SUM(Amount)
            , AvgAmount  = AVG(Amount)
            , MaxSortKey = MAX(SortKey)
            , CheckValue =
                CHECKSUM_AGG
                (
                    CHECKSUM
                    (
                          SortKey
                        , Amount
                        , Payload
                    )
                )
        FROM dbo.RCA_Run8_CPU
        GROUP BY GroupID
        HAVING COUNT_BIG(*) > 50
        ORDER BY
              SUM(Amount) DESC
            , MAX(SortKey) DESC
        OPTION
        (
              RECOMPILE
            , MAXDOP 1
        );

        SET @i += 1;
    END;
END;
GO


/*==============================================================================
STEP 2 - PRE-FLIGHT

All checks should PASS before continuing.
==============================================================================*/
USE master;
GO

SELECT
      Run8Table =
        CASE WHEN OBJECT_ID(N'RCA.dbo.RCA_Run8_CPU',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , Run8Procedure =
        CASE WHEN OBJECT_ID(N'RCA.dbo.usp_RCA_Run8_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CaptureRun16 =
        CASE WHEN EXISTS
             (
                 SELECT 1
                 FROM DBA.dbo.RCA_CaptureRun
                 WHERE CaptureRunID = 16
             )
             THEN 'PASS' ELSE 'FAIL' END
    , SqlAgentXPs =
        CASE WHEN CONVERT(int,SERVERPROPERTY('IsIntegratedSecurityOnly')) IN (0,1)
                  AND EXISTS
                  (
                      SELECT 1
                      FROM sys.configurations
                      WHERE name = N'Agent XPs'
                        AND value_in_use = 1
                  )
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
STEP 3 - START THE EXISTING RCA SAMPLER IN A SEPARATE SSMS WINDOW

RUN THIS BLOCK IN WINDOW A AND LEAVE IT EXECUTING.
==============================================================================*/
/*
USE DBA;
GO

EXEC dbo.usp_RCA_RunSampler
     @CaptureRunID = 16,
     @DurationMinutes = 4,
     @SampleSeconds = 5;
GO
*/


/*==============================================================================
STEP 4 - CREATE 24 TEMPORARY SQL AGENT WORKER JOBS

Run this block once in the current window.
==============================================================================*/
USE msdb;
GO

DECLARE
      @i int = 1
    , @JobName sysname
    , @Command nvarchar(max);

WHILE @i <= 24
BEGIN
    SET @JobName =
        N'RCA_Run8B_CPU_' + RIGHT(N'00' + CONVERT(nvarchar(2),@i),2);

    IF EXISTS
    (
        SELECT 1
        FROM msdb.dbo.sysjobs
        WHERE name = @JobName
    )
    BEGIN
        EXEC msdb.dbo.sp_delete_job
             @job_name = @JobName,
             @delete_unused_schedule = 1;
    END;

    EXEC msdb.dbo.sp_add_job
         @job_name = @JobName,
         @enabled = 1,
         @description = N'TEMPORARY RCA Run 8B CPU saturation validation worker';

    SET @Command =
        N'USE RCA;
          SET NOCOUNT ON;
          EXEC dbo.usp_RCA_Run8_CPU @Loops = 30;';

    EXEC msdb.dbo.sp_add_jobstep
         @job_name = @JobName,
         @step_name = N'CPU Worker',
         @subsystem = N'TSQL',
         @database_name = N'RCA',
         @command = @Command,
         @retry_attempts = 0,
         @retry_interval = 0;

    EXEC msdb.dbo.sp_add_jobserver
         @job_name = @JobName;

    SET @i += 1;
END;

SELECT
      CreatedWorkerJobs = COUNT(*)
    , Validation =
        CASE WHEN COUNT(*) = 24 THEN 'PASS' ELSE 'FAIL' END
FROM msdb.dbo.sysjobs
WHERE name LIKE N'RCA_Run8B_CPU[_]%';
GO


/*==============================================================================
STEP 5 - LAUNCH ALL 24 WORKERS

Start this only AFTER the sampler for CaptureRunID 16 is running.
==============================================================================*/
USE msdb;
GO

DECLARE
      @i int = 1
    , @JobName sysname;

WHILE @i <= 24
BEGIN
    SET @JobName =
        N'RCA_Run8B_CPU_' + RIGHT(N'00' + CONVERT(nvarchar(2),@i),2);

    EXEC msdb.dbo.sp_start_job
         @job_name = @JobName;

    SET @i += 1;
END;

SELECT
      LaunchTime = SYSDATETIME()
    , WorkersRequested = 24
    , Run8B = 'STARTED';
GO


/*==============================================================================
STEP 6 - LIVE PROOF

Wait about 15-20 seconds after STEP 5, then run this block.
Run it more than once while the workers are active.
==============================================================================*/
USE DBA;
GO

SELECT TOP (30)
      CaptureTimeUTC
    , SqlCpuPercent
    , OtherCpuPercent
    , SystemIdlePercent
    , RunnableTasks
    , MemoryGrantsPending
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID = 16
ORDER BY CaptureTimeUTC DESC;
GO

SELECT
      TotalRunnableTasks =
          SUM(runnable_tasks_count)
    , MaxRunnableOnOneScheduler =
          MAX(runnable_tasks_count)
    , ActiveWorkers =
          SUM(active_workers_count)
    , CurrentTasks =
          SUM(current_tasks_count)
    , VisibleSchedulers =
          COUNT(*)
FROM sys.dm_os_schedulers
WHERE status = N'VISIBLE ONLINE';
GO

SELECT
      r.session_id
    , r.status
    , r.command
    , r.cpu_time
    , r.total_elapsed_time
    , r.logical_reads
    , r.reads
    , r.writes
    , r.wait_type
    , r.scheduler_id
    , DB_NAME(r.database_id) AS DatabaseName
    , s.host_name
    , s.program_name
    , s.login_name
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = r.session_id
WHERE DB_NAME(r.database_id) = N'RCA'
  AND r.session_id <> @@SPID
ORDER BY r.cpu_time DESC;
GO


/*==============================================================================
STEP 7 - RAW CPU RING BUFFER CROSS-CHECK

This source commonly refreshes at a coarser interval than the 5-second RCA
sampler. It is a cross-check, not the only acceptance criterion.
==============================================================================*/
DECLARE @ts_now bigint;

SELECT @ts_now = cpu_ticks / (cpu_ticks / ms_ticks)
FROM sys.dm_os_sys_info;

SELECT TOP (20)
      DATEADD(ms,-1 * (@ts_now - [timestamp]),GETDATE()) AS EventTime
    , SQLProcessUtilization
    , SystemIdle
    , 100 - SystemIdle - SQLProcessUtilization AS OtherProcessUtilization
FROM
(
    SELECT
          record.value('(./Record/@id)[1]','int') AS record_id
        , record.value(
              '(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]',
              'int'
          ) AS SystemIdle
        , record.value(
              '(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]',
              'int'
          ) AS SQLProcessUtilization
        , [timestamp]
    FROM
    (
        SELECT
              [timestamp]
            , CONVERT(xml,record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE N'%<SystemHealth>%'
    ) AS rb
) AS x
ORDER BY EventTime DESC;
GO


/*==============================================================================
STEP 8 - WORKER STATUS

Use this to determine whether the temporary workers are still running.
==============================================================================*/
USE msdb;
GO

SELECT
      j.name
    , StartExecutionDate = ja.start_execution_date
    , StopExecutionDate  = ja.stop_execution_date
    , JobState =
        CASE
            WHEN ja.start_execution_date IS NOT NULL
             AND ja.stop_execution_date IS NULL
                THEN 'RUNNING'
            WHEN ja.start_execution_date IS NOT NULL
             AND ja.stop_execution_date IS NOT NULL
                THEN 'FINISHED'
            ELSE 'NOT STARTED'
        END
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobactivity AS ja
  ON ja.job_id = j.job_id
 AND ja.session_id =
     (
         SELECT MAX(session_id)
         FROM msdb.dbo.syssessions
     )
WHERE j.name LIKE N'RCA_Run8B_CPU[_]%'
ORDER BY j.name;
GO


/*==============================================================================
STEP 9 - AFTER THE WORKLOAD AND SAMPLER FINISH

Do NOT run until we have reviewed the live proof.

Then the remaining RCA pipeline will be:

  1. StopCapture       (CaptureRunID 16)
  2. ImportXE          (CaptureRunID 16)
  3. AnalyzeCaptureRun (CaptureRunID 16)
  4. Build CPU/scheduler evidence
  5. Final output
  6. Run 8B acceptance test

We intentionally stop here so detector thresholds are not validated against
an unproven workload.
==============================================================================*/


/*==============================================================================
STEP 10 - CLEANUP TEMPORARY SQL AGENT JOBS

Run AFTER Run 8B is complete.

This removes only jobs named RCA_Run8B_CPU_01 through RCA_Run8B_CPU_24.
==============================================================================*/
/*
USE msdb;
GO

DECLARE
      @i int = 1
    , @JobName sysname;

WHILE @i <= 24
BEGIN
    SET @JobName =
        N'RCA_Run8B_CPU_' + RIGHT(N'00' + CONVERT(nvarchar(2),@i),2);

    IF EXISTS
    (
        SELECT 1
        FROM msdb.dbo.sysjobs
        WHERE name = @JobName
    )
    BEGIN
        EXEC msdb.dbo.sp_delete_job
             @job_name = @JobName,
             @delete_unused_schedule = 1;
    END;

    SET @i += 1;
END;

SELECT
      RemainingRun8BJobs = COUNT(*)
FROM msdb.dbo.sysjobs
WHERE name LIKE N'RCA_Run8B_CPU[_]%';
GO
*/
