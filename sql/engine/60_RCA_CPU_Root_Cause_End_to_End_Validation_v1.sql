USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  60_RCA_CPU_Root_Cause_End_to_End_Validation_v1.sql

  PURPOSE
  -------
  Validate that the RCA engine can distinguish a CPU-driven incident from the
  blocking scenario already proven by Captures 39/42.

  PRIMARY QUESTION
  ----------------
      Can the existing RCA evidence/ranking pipeline identify sustained CPU
      pressure as the supported primary cause, and can the canonical DBA-facing
      command explain it correctly?

  IMPORTANT
  ---------
  This script is a CONTROLLED CPU positive test.

  It does NOT:
      - change detector thresholds
      - change root-cause ranking logic
      - modify historical evidence
      - rebuild historical captures
      - change the blocking/transaction collector
      - alter dbo.usp_RCA_DBAAnswer

  EXPECTED OUTCOME
  ----------------
  Underlying RCA evidence should show:
      - repeated server samples
      - high SQL CPU and/or low system idle
      - runnable task pressure where applicable
      - CPU-heavy execution evidence
      - CPU scheduler evidence / final-cause ranking if existing logic supports it

  The canonical DBA answer is intentionally tested as-is. If the engine proves
  CPU but dbo.usp_RCA_DBAAnswer still says "ROOT CAUSE NOT CONFIRMED", that is
  a PRESENTATION-GENERALIZATION gap, not a reason to change CPU thresholds.

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

IF OBJECT_ID(N'RCA.dbo.usp_RCA_Run8_CPU',N'P') IS NULL
    SET @Missing += N' RCA.dbo.usp_RCA_Run8_CPU;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message=CONCAT(N'Script 60 prerequisites are missing:',@Missing);
    THROW 56000,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 60 PRE-FLIGHT'
    , StartProcedure='PASS'
    , StopProcedure='PASS'
    , Sampler='PASS'
    , ServerSnapshot='PASS'
    , ExecutionEvidence='PASS'
    , CPUWorkloadProcedure='PASS'
    , CanonicalDBAAnswer='PASS'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , HistoricalEvidenceModified='NO';
GO


/*==============================================================================
  1. CLEAN UP LEFTOVER CONTROL JOBS
==============================================================================*/
DECLARE @JobName sysname;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM msdb.dbo.sysjobs
WHERE name = N'RCA_C43_CPU_Sampler'
   OR name LIKE N'RCA_C43_CPU_Worker_%';

OPEN JobCleanup;
FETCH NEXT FROM JobCleanup INTO @JobName;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name=@JobName;
    FETCH NEXT FROM JobCleanup INTO @JobName;
END;

CLOSE JobCleanup;
DEALLOCATE JobCleanup;
GO


/*==============================================================================
  2. START FRESH CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint;

EXEC dbo.usp_RCA_Start
     @DatabaseName=N'RCA',
     @IncidentDescription=
         N'CPU positive control - sustained concurrent CPU workload for multi-domain RCA validation';

SELECT TOP (1)
    @CaptureRunID=CaptureRunID
FROM dbo.RCA_CaptureRun
WHERE CaptureStatus=N'RUNNING'
  AND TargetDatabase=N'RCA'
ORDER BY CaptureRunID DESC;

IF @CaptureRunID IS NULL
    THROW 56010,N'CPU validation capture start failed.',1;

EXEC sys.sp_set_session_context
     @key=N'RCA_CPU_Validation_RunID',
     @value=@CaptureRunID;

SELECT
      ValidationSection='1 - CPU CAPTURE STARTED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus='RUNNING'
    , TestScenario='SUSTAINED CONCURRENT CPU PRESSURE'
    , ExpectedDomain='CPU / SCHEDULER'
    , RootCauseLogicChanged='NO';
GO


/*==============================================================================
  3. CREATE SAMPLER JOB
==============================================================================*/
DECLARE
      @CaptureRunID bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'))
    , @SamplerCommand nvarchar(max);

IF @CaptureRunID IS NULL
    THROW 56011,N'CPU validation capture context is missing.',1;

SET @SamplerCommand=
      N'USE DBA; EXEC dbo.usp_RCA_RunSampler '
    + N'@CaptureRunID=' + CONVERT(nvarchar(30),@CaptureRunID)
    + N', @DurationMinutes=2, @SampleSeconds=5;';

EXEC msdb.dbo.sp_add_job
     @job_name=N'RCA_C43_CPU_Sampler',
     @enabled=1,
     @delete_level=0;

EXEC msdb.dbo.sp_add_jobstep
     @job_name=N'RCA_C43_CPU_Sampler',
     @step_name=N'Capture RCA CPU validation snapshots',
     @subsystem=N'TSQL',
     @database_name=N'DBA',
     @command=@SamplerCommand;

EXEC msdb.dbo.sp_add_jobserver
     @job_name=N'RCA_C43_CPU_Sampler';
GO


/*==============================================================================
  4. CREATE CPU WORKERS

  12 concurrent workers is intentionally substantial but lower than the prior
  24-worker CPU test used in this lab.

  If the host has very few CPUs, this should still create scheduler pressure.
  If the host has many CPUs, the RCA evidence will show whether the pressure was
  actually sufficient; we do not manufacture a CPU conclusion.
==============================================================================*/
DECLARE
      @i int=1
    , @JobName sysname
    , @Command nvarchar(max);

WHILE @i<=12
BEGIN
    SET @JobName=
        N'RCA_C43_CPU_Worker_'
        + RIGHT(N'00'+CONVERT(nvarchar(2),@i),2);

    SET @Command=
        N'USE RCA; SET NOCOUNT ON; '
      + N'EXEC dbo.usp_RCA_Run8_CPU @Loops=30;';

    EXEC msdb.dbo.sp_add_job
         @job_name=@JobName,
         @enabled=1,
         @delete_level=0;

    EXEC msdb.dbo.sp_add_jobstep
         @job_name=@JobName,
         @step_name=N'CPU Worker',
         @subsystem=N'TSQL',
         @database_name=N'RCA',
         @command=@Command;

    EXEC msdb.dbo.sp_add_jobserver
         @job_name=@JobName;

    SET @i+=1;
END;

SELECT
      ValidationSection='2 - CPU CONTROL JOBS CREATED'
    , SamplerJob=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM msdb.dbo.sysjobs
            WHERE name=N'RCA_C43_CPU_Sampler'
        ) THEN 'PASS' ELSE 'FAIL' END
    , CPUWorkerJobs=
        (
            SELECT COUNT(*)
            FROM msdb.dbo.sysjobs
            WHERE name LIKE N'RCA_C43_CPU_Worker_%'
        )
    , ExpectedWorkers=12;
GO


/*==============================================================================
  5. START SAMPLER, THEN CPU WORKERS
==============================================================================*/
DECLARE @i int=1,@JobName sysname;

EXEC msdb.dbo.sp_start_job @job_name=N'RCA_C43_CPU_Sampler';

WAITFOR DELAY '00:00:05';

WHILE @i<=12
BEGIN
    SET @JobName=
        N'RCA_C43_CPU_Worker_'
        + RIGHT(N'00'+CONVERT(nvarchar(2),@i),2);

    EXEC msdb.dbo.sp_start_job @job_name=@JobName;

    SET @i+=1;
END;

SELECT
      ValidationSection='3 - CPU WORKLOAD STARTED'
    , CaptureRunID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'))
    , Sampler='STARTED'
    , CPUWorkersStarted=12
    , Note='Allowing workload and sampler to overlap before stop/analyze.';

WAITFOR DELAY '00:01:10';
GO


/*==============================================================================
  6. STOP / ANALYZE CAPTURE
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

IF @CaptureRunID IS NULL
    THROW 56012,N'CPU validation capture context missing before stop.',1;

EXEC dbo.usp_RCA_Stop
     @CaptureRunID=@CaptureRunID;

SELECT
      ValidationSection='4 - CPU CAPTURE STOPPED'
    , CaptureRunID=@CaptureRunID
    , CaptureStatus=
        (
            SELECT CaptureStatus
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@CaptureRunID
        );
GO


/*==============================================================================
  7. SERVER-HEALTH EVIDENCE
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

SELECT
      ValidationSection='5 - CPU SERVER HEALTH'
    , CaptureRunID=@CaptureRunID
    , ServerSamples=COUNT(*)
    , FirstSampleUTC=MIN(CaptureTimeUTC)
    , LastSampleUTC=MAX(CaptureTimeUTC)
    , PeakSqlCpuPercent=MAX(SqlCpuPercent)
    , AvgSqlCpuPercent=CAST(AVG(CAST(SqlCpuPercent AS decimal(18,4))) AS decimal(18,4))
    , PeakOtherCpuPercent=MAX(OtherCpuPercent)
    , LowestSystemIdlePercent=MIN(SystemIdlePercent)
    , PeakRunnableTasks=MAX(RunnableTasks)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  8. TOP CPU EXECUTIONS
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

SELECT TOP (20)
      ValidationSection='6 - TOP CPU EXECUTIONS'
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
  9. CPU-SCHEDULER EVIDENCE, IF PRESENT
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          ValidationSection='7 - CPU SCHEDULER EVIDENCE'
        , *
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY 1;
END
ELSE
BEGIN
    SELECT
          ValidationSection='7 - CPU SCHEDULER EVIDENCE'
        , Result='RCA_CPUSchedulerEvidence table not present';
END;
GO


/*==============================================================================
  10. FINAL CAUSE RANKING
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

IF OBJECT_ID(N'dbo.RCA_FinalCauseRanking',N'U') IS NOT NULL
BEGIN
    SELECT
          ValidationSection='8 - FINAL CAUSE RANKING'
        , *
    FROM dbo.RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          CASE WHEN PrimaryRole='PRIMARY' THEN 1 ELSE 2 END,
          CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
END
ELSE
BEGIN
    SELECT
          ValidationSection='8 - FINAL CAUSE RANKING'
        , Result='RCA_FinalCauseRanking table not present';
END;
GO


/*==============================================================================
  11. BLOCKING NEGATIVE CHECK
  CPU control should not accidentally be explained as blocking.
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

SELECT
      ValidationSection='9 - BLOCKING NEGATIVE CHECK'
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
  12. CANONICAL DBA ANSWER - TEST AS-IS

  Important:
  Do NOT change it here. This result tells us whether the production-facing
  answer is already multi-domain or remains blocking-specific.
==============================================================================*/
DECLARE @CaptureRunID bigint=
    TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'));

EXEC dbo.usp_RCA_DBAAnswer
     @CaptureRunID=@CaptureRunID;
GO


/*==============================================================================
  13. ACCEPTANCE MATRIX
==============================================================================*/
DECLARE
      @CaptureRunID bigint=
          TRY_CONVERT(bigint,SESSION_CONTEXT(N'RCA_CPU_Validation_RunID'))
    , @Samples int=0
    , @PeakSqlCpu decimal(18,4)=0
    , @AvgSqlCpu decimal(18,4)=0
    , @LowestIdle decimal(18,4)=100
    , @PeakRunnable int=0
    , @HighCpuExecutions int=0
    , @BlockingRows int=0
    , @CPUEvidenceRows int=0
    , @CPUPrimaryRows int=0;

SELECT
      @Samples=COUNT(*)
    , @PeakSqlCpu=ISNULL(MAX(SqlCpuPercent),0)
    , @AvgSqlCpu=ISNULL(AVG(CAST(SqlCpuPercent AS decimal(18,4))),0)
    , @LowestIdle=ISNULL(MIN(SystemIdlePercent),100)
    , @PeakRunnable=ISNULL(MAX(RunnableTasks),0)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=@CaptureRunID;

SELECT @HighCpuExecutions=COUNT(*)
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=@CaptureRunID
  AND ISNULL(CPUms,0)>=500;

SELECT @BlockingRows=COUNT(*)
FROM dbo.RCA_BlockingEvidence
WHERE CaptureRunID=@CaptureRunID;

IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT @CPUEvidenceRows=COUNT(*)
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;

IF OBJECT_ID(N'dbo.RCA_FinalCauseRanking',N'U') IS NOT NULL
BEGIN
    SELECT @CPUPrimaryRows=COUNT(*)
    FROM dbo.RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
      AND PrimaryRole='PRIMARY'
      AND
      (
           CauseCategory LIKE '%CPU%'
        OR CauseCategory LIKE '%SCHEDUL%'
        OR CauseDisplayName LIKE '%CPU%'
        OR CauseDisplayName LIKE '%schedul%'
      );
END;

SELECT
      ValidationSection='10 - CPU END-TO-END ACCEPTANCE'
    , CaptureRunID=@CaptureRunID
    , ServerSamples=
        CASE WHEN @Samples>=3 THEN 'PASS' ELSE 'FAIL' END
    , PeakSqlCpuPercent=@PeakSqlCpu
    , AvgSqlCpuPercent=@AvgSqlCpu
    , LowestSystemIdlePercent=@LowestIdle
    , PeakRunnableTasks=@PeakRunnable
    , HighCpuExecutionCount=@HighCpuExecutions
    , CPUWorkloadObserved=
        CASE
          WHEN @HighCpuExecutions>0
            OR @PeakSqlCpu>=50
            OR @LowestIdle<=50
            OR @PeakRunnable>0
          THEN 'PASS'
          ELSE 'REVIEW'
        END
    , CPUSchedulerEvidenceRows=@CPUEvidenceRows
    , CPUPrimaryCauseRows=@CPUPrimaryRows
    , BlockingEvidenceRows=@BlockingRows
    , RootCauseEngineResult=
        CASE
          WHEN @CPUPrimaryRows>0
          THEN 'PASS - CPU PRIMARY CAUSE IDENTIFIED'
          WHEN @CPUEvidenceRows>0
          THEN 'PARTIAL - CPU EVIDENCE EXISTS BUT NOT PRIMARY'
          ELSE 'REVIEW - CPU CAUSE NOT ESTABLISHED'
        END
    , SafetyResult='PASS - NO THRESHOLDS OR ROOT-CAUSE LOGIC CHANGED';
GO


/*==============================================================================
  14. CLEANUP CONTROL JOBS
==============================================================================*/
DECLARE @JobName sysname;

DECLARE JobCleanup CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM msdb.dbo.sysjobs
WHERE name = N'RCA_C43_CPU_Sampler'
   OR name LIKE N'RCA_C43_CPU_Worker_%';

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
  15. SAFETY / NEXT STEP
==============================================================================*/
SELECT
      ValidationSection='11 - SCRIPT 60 SAFETY'
    , FreshCaptureCreated='YES'
    , ControlledCPUWorkloadStarted='YES'
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
        'Compare Sections 5-10. If CPU is correctly proven by the evidence/ranking layer but the DBA answer does not explain CPU, build a multi-domain presentation router rather than changing CPU thresholds.';
GO
