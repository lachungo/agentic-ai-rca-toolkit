USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  62_RCA_CPU_Positive_Control_v2.sql

  PURPOSE
  -------
  Create a stronger, calibrated CPU positive control after Capture 43 proved
  insufficient:

      Peak SQL CPU       = 37%
      Average SQL CPU    = 8.26%
      Lowest system idle = 52%
      CPU primary cause  = not established

  Capture 44 deliberately creates sustained CPU-bound work using more concurrent
  single-threaded workers than visible online SQL schedulers.

  DESIGN
  ------
  - Fresh Capture 44
  - Worker count = visible online schedulers + 8
  - Minimum workers = 16
  - Maximum workers = 32
  - Each worker runs CPU-heavy CHECKSUM aggregation repeatedly for ~60 seconds
  - MAXDOP 1 per worker so concurrency, not one parallel query, drives pressure
  - RCA sampler runs concurrently for 2 minutes
  - Existing RCA thresholds / ranking / presentation remain unchanged

  SAFETY
  ------
  This is a LAB stress test. It is intentionally CPU intensive.
  Run only on the RCA lab SQL instance.

  This script does NOT:
      - change detector thresholds
      - change root-cause domains
      - change root-cause ranking logic
      - modify historical captures
      - modify blocking / transaction collectors
      - modify dbo.usp_RCA_DBAAnswer

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max)=N'';
DECLARE @Message nvarchar(2048);

IF DB_ID(N'RCA') IS NULL
    SET @Missing += N' database RCA;';

IF OBJECT_ID(N'dbo.usp_RCA_Start',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_Start;';

IF OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_Stop;';

IF OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_RunSampler;';

IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ServerSnapshot;';

IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_ExecutionEvidence;';

IF OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_DBAAnswer;';

IF OBJECT_ID(N'RCA.dbo.RCA_Run8_CPU',N'U') IS NULL
    SET @Missing += N' RCA.dbo.RCA_Run8_CPU;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message=CONCAT(N'Script 62 prerequisites are missing:',@Missing);
    THROW 56200,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 62 PRE-FLIGHT'
    , StartProcedure='PASS'
    , StopProcedure='PASS'
    , Sampler='PASS'
    , ServerSnapshot='PASS'
    , ExecutionEvidence='PASS'
    , CPUSourceTable='PASS'
    , CanonicalDBAAnswer='PASS'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , HistoricalEvidenceModified='NO';
GO


/*==============================================================================
  1. CREATE CALIBRATED CPU WORKER PROCEDURE IN RCA

  Each worker repeatedly scans RCA_Run8_CPU and computes CPU-heavy checksums.
  The query is intentionally MAXDOP 1 so each worker consumes roughly one
  scheduler at a time and overall pressure comes from concurrency.

  No data is modified.
==============================================================================*/
USE RCA;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_CPU_PositiveControlWorker
      @DurationSeconds int = 60
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationSeconds NOT BETWEEN 15 AND 180
        THROW 56210,N'@DurationSeconds must be between 15 and 180.',1;

    DECLARE
          @StopAt datetime2(3)=DATEADD(second,@DurationSeconds,SYSUTCDATETIME())
        , @Iteration int=0
        , @Checksum int
        , @Rows bigint
        , @StartUTC datetime2(3)=SYSUTCDATETIME();

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        /*
          Force a real table scan and CPU work over the existing ~2M-row lab
          table. MAXDOP 1 keeps each worker single-threaded and makes worker
          concurrency visible as scheduler pressure.
        */
        SELECT
              @Checksum = CHECKSUM_AGG
              (
                  BINARY_CHECKSUM
                  (
                        SortKey
                      , Amount
                      , Payload
                  )
              )
            , @Rows = COUNT_BIG(*)
        FROM dbo.RCA_Run8_CPU
        OPTION (MAXDOP 1, RECOMPILE);

        /*
          Add a second CPU-bound pass using arithmetic/hash expressions.
          The result is assigned to a variable so SSMS/Agent output stays small.
        */
        SELECT
            @Checksum = ISNULL(@Checksum,0)
                      ^ ISNULL
                        (
                            CHECKSUM_AGG
                            (
                                CHECKSUM
                                (
                                      GroupID
                                    , SortKey * 31
                                    , CONVERT(bigint,Amount * 100)
                                )
                            ),
                            0
                        )
        FROM dbo.RCA_Run8_CPU
        WHERE GroupID >= 0
        OPTION (MAXDOP 1, RECOMPILE);

        SET @Iteration += 1;
    END;

    SELECT
          WorkerStartUTC=@StartUTC
        , WorkerEndUTC=SYSUTCDATETIME()
        , DurationSeconds=@DurationSeconds
        , IterationsCompleted=@Iteration
        , LastChecksum=@Checksum
        , LastRowCount=@Rows;
END;
GO


/*==============================================================================
  2. CALCULATE WORKER COUNT FROM ONLINE SCHEDULERS
==============================================================================*/
USE DBA;
GO

DECLARE
      @OnlineSchedulers int
    , @WorkerCount int;

SELECT @OnlineSchedulers=
    COUNT(*)
FROM sys.dm_os_schedulers
WHERE scheduler_id < 255
  AND status = N'VISIBLE ONLINE';

SET @WorkerCount=@OnlineSchedulers+8;

IF @WorkerCount<16 SET @WorkerCount=16;
IF @WorkerCount>32 SET @WorkerCount=32;

EXEC sys.sp_set_session_context
     @key=N'RCA_C44_WorkerCount',
     @value=@WorkerCount;

SELECT
      ValidationSection='1 - CPU CALIBRATION TARGET'
    , OnlineVisibleSchedulers=@OnlineSchedulers
    , WorkerCount=@WorkerCount
    , WorkersAboveSchedulers=@WorkerCount-@OnlineSchedulers
    , WorkerDurationSeconds=60
    , SampleDurationMinutes=2
    , SampleIntervalSeconds=5
    , TestIntent='SUSTAIN SQL CPU PRESSURE ACROSS MULTIPLE SERVER SAMPLES';
GO


/*==============================================================================
  3. CLEAN UP LEFTOVER CAPTURE 44 CONTROL JOBS
==============================================================================*/
DECLARE @JobName sysname;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM msdb.dbo.sysjobs
WHERE name=N'RCA_C44_CPU_Sampler'
   OR name LIKE N'RCA_C44_CPU_Worker_%';

OPEN JobCleanup;
FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS=0
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
    FETCH NEXT FROM JobCleanup INTO @JobName;
END;

CLOSE JobCleanup;
DEALLOCATE JobCleanup;
GO


/*==============================================================================
  4. START FRESH CAPTURE 44
==============================================================================*/
DECLARE @CaptureRunID bigint;

EXEC dbo.usp_RCA_Start
     @DatabaseName=N'RCA',
     @IncidentDescription=
         N'Capture 44 - calibrated CPU positive control - scheduler saturation validation';

SELECT TOP (1)
    @CaptureRunID=CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE CaptureStatus=N'RUNNING'
  AND TargetDatabase=N'RCA'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
    THROW 56220,N'Capture 44 start failed.',1;

EXEC sys.sp_set_session_context
     @key=N'RCA_C44_RunID',
     @value=@CaptureRunID;

SELECT
      ValidationSection='2 - CAPTURE 44 STARTED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus='RUNNING'
    , TestScenario='CALIBRATED CPU POSITIVE CONTROL'
    , ExpectedDomain='CPU / SCHEDULER'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO';
GO


/*==============================================================================
  5. CREATE SAMPLER JOB
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'))
    , @SamplerCommand nvarchar(max);

IF @CaptureRunID IS NULL
    THROW 56221,N'Capture 44 context missing before job creation.',1;

SET @SamplerCommand=
      N'USE DBA; EXEC dbo.usp_RCA_RunSampler '
    + N'@CaptureRunID=' + CONVERT(nvarchar(30),@CaptureRunID)
    + N', @DurationMinutes=2, @SampleSeconds=5;';

EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C44_CPU_Sampler',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C44_CPU_Sampler',
     @step_name=N'Capture RCA CPU positive-control snapshots',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C44_CPU_Sampler';
GO


/*==============================================================================
  6. CREATE CALIBRATED CPU WORKER JOBS
==============================================================================*/
DECLARE
      @WorkerCount int=TRY_CONVERT(int,SESSION_CONTEXT(N'RCA_C44_WorkerCount'))
    , @i int=1
    , @JobName sysname
    , @Command nvarchar(max);

IF @WorkerCount IS NULL
    THROW 56222,N'Capture 44 worker-count context is missing.',1;

WHILE @i<=@WorkerCount
BEGIN
    SET @JobName=
        N'RCA_C44_CPU_Worker_'
        + RIGHT(N'00'+CONVERT(nvarchar(2),@i),2);

    SET @Command=
        N'USE RCA; SET NOCOUNT ON; '
      + N'EXEC dbo.usp_RCA_CPU_PositiveControlWorker @DurationSeconds=60;';

    EXEC msdb.dbo.sp_add_job
         @job_name=@JobName,
         @enabled=1,
         @delete_level=0;

    EXEC msdb.dbo.sp_add_jobstep
         @job_name=@JobName,
         @step_name=N'CPU Positive Control Worker',
         @subsystem=N'TSQL',
         @database_name=N'RCA',
         @command=@Command;

    EXEC msdb.dbo.sp_add_jobserver
         @job_name=@JobName;

    SET @i+=1;
END;

SELECT
      ValidationSection='3 - CPU JOBS CREATED'
    , SamplerJob=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM msdb.dbo.sysjobs
            WHERE name=N'RCA_C44_CPU_Sampler'
        ) THEN 'PASS' ELSE 'FAIL' END
    , CPUWorkerJobs=
        (
            SELECT COUNT(*)
            FROM msdb.dbo.sysjobs
            WHERE name LIKE N'RCA_C44_CPU_Worker_%'
        )
    , ExpectedWorkerJobs=@WorkerCount;
GO


/*==============================================================================
  7. START SAMPLER THEN ALL WORKERS
==============================================================================*/
DECLARE
      @WorkerCount int=TRY_CONVERT(int,SESSION_CONTEXT(N'RCA_C44_WorkerCount'))
    , @i int=1
    , @JobName sysname;

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C44_CPU_Sampler';

WAITFOR DELAY '00:00:05';

WHILE @i<=@WorkerCount
BEGIN
    SET @JobName=
        N'RCA_C44_CPU_Worker_'
        + RIGHT(N'00'+CONVERT(nvarchar(2),@i),2);

    EXEC msdb.dbo.sp_start_job @job_name=@JobName;

    SET @i+=1;
END;

SELECT
      ValidationSection='4 - CALIBRATED CPU WORKLOAD STARTED'
    , CaptureRunID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'))
    , Sampler='STARTED'
    , CPUWorkersStarted=@WorkerCount
    , WorkerDurationSeconds=60;

WAITFOR DELAY '00:01:15';
GO


/*==============================================================================
  8. LIVE CPU CHECK BEFORE STOP
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

SELECT
      ValidationSection='5 - LIVE CPU CHECK'
    , CaptureRunID=@CaptureRunID
    , ServerSamples=COUNT(*)
    , PeakSqlCpuPercent=MAX(SqlCpuPercent)
    , AvgSqlCpuPercent=
        CAST(AVG(CAST(SqlCpuPercent AS decimal(18,4))) AS decimal(18,4))
    , LowestSystemIdlePercent=MIN(SystemIdlePercent)
    , PeakRunnableTasks=MAX(RunnableTasks)
    , SamplesSqlCpuAtOrAbove50=
        SUM(CASE WHEN SqlCpuPercent>=50 THEN 1 ELSE 0 END)
    , SamplesSqlCpuAtOrAbove70=
        SUM(CASE WHEN SqlCpuPercent>=70 THEN 1 ELSE 0 END)
    , SamplesIdleAtOrBelow30=
        SUM(CASE WHEN SystemIdlePercent<=30 THEN 1 ELSE 0 END)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  9. STOP / ANALYZE CAPTURE 44
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

IF @CaptureRunID IS NULL
    THROW 56223,N'Capture 44 context missing before stop.',1;

EXEC dbo.usp_RCA_Stop
     @CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='6 - CAPTURE 44 STOPPED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus=
        (
            SELECT CaptureStatus
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@CaptureRunID
        );
GO


/*==============================================================================
  10. SERVER-HEALTH EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

SELECT
      ValidationSection='7 - CPU SERVER HEALTH'
    , CaptureRunID=@CaptureRunID
    , ServerSamples=COUNT(*)
    , FirstSampleUTC=MIN(CaptureTimeUTC)
    , LastSampleUTC=MAX(CaptureTimeUTC)
    , PeakSqlCpuPercent=MAX(SqlCpuPercent)
    , AvgSqlCpuPercent=
        CAST(AVG(CAST(SqlCpuPercent AS decimal(18,4))) AS decimal(18,4))
    , PeakOtherCpuPercent=MAX(OtherCpuPercent)
    , LowestSystemIdlePercent=MIN(SystemIdlePercent)
    , PeakRunnableTasks=MAX(RunnableTasks)
    , AvgRunnableTasks=
        CAST(AVG(CAST(RunnableTasks AS decimal(18,4))) AS decimal(18,4))
    , SamplesSqlCpuAtOrAbove50=
        SUM(CASE WHEN SqlCpuPercent>=50 THEN 1 ELSE 0 END)
    , SamplesSqlCpuAtOrAbove70=
        SUM(CASE WHEN SqlCpuPercent>=70 THEN 1 ELSE 0 END)
    , SamplesSqlCpuAtOrAbove80=
        SUM(CASE WHEN SqlCpuPercent>=80 THEN 1 ELSE 0 END)
    , SamplesIdleAtOrBelow30=
        SUM(CASE WHEN SystemIdlePercent<=30 THEN 1 ELSE 0 END)
    , SamplesRunnableAbove0=
        SUM(CASE WHEN RunnableTasks>0 THEN 1 ELSE 0 END)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  11. CPU SAMPLE TIMELINE
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

SELECT
      ValidationSection='8 - CPU SAMPLE TIMELINE'
    , CaptureTimeUTC
    , SqlCpuPercent
    , OtherCpuPercent
    , SystemIdlePercent
    , RunnableTasks
    , BufferCacheHitRatio
    , PageLifeExpectancySeconds
    , AvailablePhysicalMemoryMB
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID
ORDER BY CaptureTimeUTC;
GO


/*==============================================================================
  12. TOP CPU EXECUTIONS
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

SELECT TOP (40)
      ValidationSection='9 - TOP CPU EXECUTIONS'
    , ExecutionEvidenceID
    , EventTimeUTC
    , DatabaseName
    , SessionID
    , ObjectName
    , HostName
    , ProgramName
    , LoginName
    , CPUms
    , DurationMs
    , LogicalReads
    , PhysicalReads
    , Writes
    , TotalRows
    , SubmittedCommand
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=@CaptureRunID
ORDER BY
      ISNULL(CPUms,0) DESC,
      ISNULL(DurationMs,0) DESC,
      ExecutionEvidenceID;
GO


/*==============================================================================
  13. CPU SCHEDULER EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          ValidationSection='10 - CPU SCHEDULER EVIDENCE'
        , *
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;
END
ELSE
BEGIN
    SELECT
          ValidationSection='10 - CPU SCHEDULER EVIDENCE'
        , Result='RCA_CPUSchedulerEvidence table not present';
END;
GO


/*==============================================================================
  14. EXISTING RCA CPU BUILDER - READ CURRENT OUTPUT ONLY
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

IF OBJECT_ID(N'dbo.vw_RCA_CPUSchedulerEvidence',N'V') IS NOT NULL
BEGIN
    SELECT
          ValidationSection='11 - CPU SCHEDULER VIEW'
        , *
    FROM dbo.vw_RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
  15. BLOCKING NEGATIVE CONTROL
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

SELECT
      ValidationSection='12 - BLOCKING NEGATIVE CHECK'
    , CaptureRunID=@CaptureRunID
    , BlockingEvidenceRows=COUNT(*)
    , Interpretation=
        CASE WHEN COUNT(*)=0
             THEN 'PASS - CPU TEST DID NOT CREATE BLOCKING ROOT-CAUSE EVIDENCE'
             ELSE 'REVIEW - BLOCKING ALSO OCCURRED DURING CPU TEST'
        END
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  16. CANONICAL DBA ANSWER AS-IS
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'));

EXEC dbo.usp_RCA_DBAAnswer
     @CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  17. CAPTURE 44 ACCEPTANCE

  This evaluates whether the STIMULUS was strong enough and whether the existing
  RCA CPU evidence layer recognized it. It does not alter thresholds.
==============================================================================*/
DECLARE
      @CaptureRunID bigint=
          TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_C44_RunID'))
    , @Samples int=0
    , @PeakSqlCpu decimal(18,4)=0
    , @AvgSqlCpu decimal(18,4)=0
    , @LowestIdle decimal(18,4)=100
    , @PeakRunnable int=0
    , @HighSamples int=0
    , @VeryHighSamples int=0
    , @HighCpuExecutions int=0
    , @CPUEvidenceRows int=0
    , @BlockingRows int=0;

SELECT
      @Samples=COUNT(*)
    , @PeakSqlCpu=ISNULL(MAX(SqlCpuPercent),0)
    , @AvgSqlCpu=ISNULL(AVG(CAST(SqlCpuPercent AS decimal(18,4))),0)
    , @LowestIdle=ISNULL(MIN(SystemIdlePercent),100)
    , @PeakRunnable=ISNULL(MAX(RunnableTasks),0)
    , @HighSamples=
        ISNULL(SUM(CASE WHEN SqlCpuPercent>=70 THEN 1 ELSE 0 END),0)
    , @VeryHighSamples=
        ISNULL(SUM(CASE WHEN SqlCpuPercent>=80 THEN 1 ELSE 0 END),0)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;

SELECT @HighCpuExecutions=COUNT(*)
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=@CaptureRunID
  AND ISNULL(CPUms,0)>=500;

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT @CPUEvidenceRows=COUNT(*)
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;

SELECT @BlockingRows=COUNT(*)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='13 - CAPTURE 44 CPU ACCEPTANCE'
    , CaptureRunID=@CaptureRunID
    , ServerSamples=@Samples
    , PeakSqlCpuPercent=@PeakSqlCpu
    , AvgSqlCpuPercent=@AvgSqlCpu
    , LowestSystemIdlePercent=@LowestIdle
    , PeakRunnableTasks=@PeakRunnable
    , SamplesSqlCpu70Plus=@HighSamples
    , SamplesSqlCpu80Plus=@VeryHighSamples
    , HighCpuExecutionCount=@HighCpuExecutions
    , CPUSchedulerEvidenceRows=@CPUEvidenceRows
    , BlockingEvidenceRows=@BlockingRows

    , PositiveControlStrength=
        CASE
          WHEN @PeakSqlCpu>=80
           AND @HighSamples>=3
           AND @LowestIdle<=20
          THEN 'PASS - STRONG CPU POSITIVE CONTROL'
          WHEN @PeakSqlCpu>=70
            OR @AvgSqlCpu>=50
            OR @LowestIdle<=30
          THEN 'PARTIAL - MATERIAL CPU PRESSURE'
          ELSE 'FAIL - CPU STIMULUS STILL TOO WEAK'
        END

    , ExistingRCARecognition=
        CASE
          WHEN @CPUEvidenceRows>0
          THEN 'PASS - CPU SCHEDULER EVIDENCE CREATED'
          ELSE 'REVIEW - CPU SCHEDULER EVIDENCE NOT CREATED'
        END

    , OverallInterpretation=
        CASE
          WHEN @PeakSqlCpu>=80
           AND @HighSamples>=3
           AND @LowestIdle<=20
           AND @CPUEvidenceRows>0
          THEN 'PASS - STRONG CPU INCIDENT AND RCA CPU EVIDENCE BOTH PROVEN'

          WHEN @PeakSqlCpu>=80
           AND @HighSamples>=3
           AND @LowestIdle<=20
           AND @CPUEvidenceRows=0
          THEN 'CPU INCIDENT PROVEN; RCA CPU DETECTOR/EVIDENCE BUILDER REQUIRES INVESTIGATION'

          WHEN @PeakSqlCpu<70
           AND @AvgSqlCpu<40
          THEN 'CPU POSITIVE CONTROL STILL INSUFFICIENT; DO NOT CHANGE RCA THRESHOLDS'

          ELSE 'REVIEW CAPTURE 44 CPU TIMELINE AND RCA CPU EVIDENCE'
        END;
GO


/*==============================================================================
  18. RETAIN JOB HISTORY BEFORE CLEANUP
==============================================================================*/
SELECT
      ValidationSection='14 - CPU WORKER JOB HISTORY'
    , j.name AS JobName
    , h.step_id
    , h.step_name
    , h.run_status
    , h.run_date
    , h.run_time
    , h.run_duration
    , h.message
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobhistory AS h
  ON h.job_id=j.job_id
WHERE j.name=N'RCA_C44_CPU_Sampler'
   OR j.name LIKE N'RCA_C44_CPU_Worker_%'
ORDER BY j.name,h.instance_id;
GO


/*==============================================================================
  19. CLEANUP CONTROL JOBS
==============================================================================*/
DECLARE @JobName sysname;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM msdb.dbo.sysjobs
WHERE name=N'RCA_C44_CPU_Sampler'
   OR name LIKE N'RCA_C44_CPU_Worker_%';

OPEN JobCleanup;
FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS=0
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
    FETCH NEXT FROM JobCleanup INTO @JobName;
END;

CLOSE JobCleanup;
DEALLOCATE JobCleanup;
GO


/*==============================================================================
  20. SAFETY / NEXT STEP
==============================================================================*/
SELECT
      ValidationSection='15 - SCRIPT 62 SAFETY'
    , FreshCaptureCreated='YES'
    , CalibratedCPUWorkloadCreated='YES'
    , CPUWorkloadProcedureAdded='YES'
    , HistoricalEvidenceModified='NO'
    , BlockingCollectorChanged='NO'
    , TransactionCollectorChanged='NO'
    , FindingsRebuiltByScript='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , ControlledJobsRemoved='YES'
    , NextStep=
        'Review Sections 7-14. If Capture 44 proves sustained CPU pressure but no CPU scheduler evidence is created, investigate the existing CPU evidence builder without weakening thresholds.';
GO
