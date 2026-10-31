USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  61_RCA_CPU_Workload_Calibration_v1.sql

  PURPOSE
  -------
  Diagnose why Capture 43 did not create sustained CPU pressure before designing
  another CPU positive-control capture.

  THIS SCRIPT IS READ-ONLY / DIAGNOSTIC.
  It does NOT:
      - start a capture
      - start CPU workers
      - alter dbo.usp_RCA_Run8_CPU
      - alter SQL Agent jobs
      - rebuild RCA findings
      - change detector thresholds
      - change root-cause logic
      - modify historical evidence

  PRIMARY QUESTIONS
  -----------------
  1. What exactly does dbo.usp_RCA_Run8_CPU do?
  2. How many logical schedulers / online schedulers does SQL Server have?
  3. Did the 12 worker jobs really overlap?
  4. How long did the CPU workers actually execute?
  5. What did Capture 43 server CPU look like sample-by-sample?
  6. Did captured executions show meaningful CPU consumption?
  7. Was the CPU workload too short, too light, or insufficiently concurrent?
  8. What should the next controlled CPU test change WITHOUT changing RCA
     thresholds?

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
SELECT
      ValidationSection='0 - SCRIPT 61 PRE-FLIGHT'
    , Capture43Exists=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=43
        ) THEN 'PASS' ELSE 'FAIL' END
    , CPUWorkloadProcedure=
        CASE WHEN OBJECT_ID(N'RCA.dbo.usp_RCA_Run8_CPU',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ServerSnapshot=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ExecutionEvidence=
        CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyDiagnostic='YES'
    , HistoricalEvidenceModified='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=43
)
    THROW 56100,N'Capture 43 does not exist.',1;

IF OBJECT_ID(N'RCA.dbo.usp_RCA_Run8_CPU',N'P') IS NULL
    THROW 56101,N'RCA.dbo.usp_RCA_Run8_CPU does not exist.',1;
GO


/*==============================================================================
  1. CAPTURE 43 CONTEXT
==============================================================================*/
SELECT
      DiagnosticSection='1 - CAPTURE 43 CONTEXT'
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
    , CaptureDurationSeconds=
        DATEDIFF(second,StartTimeUTC,EndTimeUTC)
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=43;
GO


/*==============================================================================
  2. CPU WORKLOAD PROCEDURE DEFINITION
==============================================================================*/
SELECT
      DiagnosticSection='2 - CPU WORKLOAD PROCEDURE'
    , ProcedureName=N'RCA.dbo.usp_RCA_Run8_CPU'
    , ProcedureDefinition=
        OBJECT_DEFINITION(OBJECT_ID(N'RCA.dbo.usp_RCA_Run8_CPU'));
GO


/*==============================================================================
  3. SQL SERVER CPU / SCHEDULER CAPACITY
==============================================================================*/
SELECT
      DiagnosticSection='3 - SERVER CPU CAPACITY'
    , cpu_count
    , hyperthread_ratio
    , scheduler_count
    , physical_memory_kb
    , committed_kb
    , committed_target_kb
    , max_workers_count
FROM sys.dm_os_sys_info;
GO


SELECT
      DiagnosticSection='3A - ONLINE SCHEDULERS'
    , TotalVisibleSchedulers=COUNT(*)
    , OnlineVisibleSchedulers=
        SUM(CASE WHEN status='VISIBLE ONLINE' THEN 1 ELSE 0 END)
    , HiddenSchedulers=
        SUM(CASE WHEN is_online=1 AND status<>'VISIBLE ONLINE' THEN 1 ELSE 0 END)
FROM sys.dm_os_schedulers
WHERE scheduler_id<255;
GO


/*==============================================================================
  4. CAPTURE 43 SERVER CPU SAMPLE-BY-SAMPLE
==============================================================================*/
SELECT
      DiagnosticSection='4 - CPU SAMPLE TIMELINE'
    , CaptureTimeUTC
    , SqlCpuPercent
    , OtherCpuPercent
    , SystemIdlePercent
    , RunnableTasks
    , BufferCacheHitRatio
    , PageLifeExpectancySeconds
    , AvailablePhysicalMemoryMB
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=43
ORDER BY CaptureTimeUTC;
GO


/*==============================================================================
  5. CAPTURE 43 CPU SUMMARY
==============================================================================*/
SELECT
      DiagnosticSection='5 - CPU SUMMARY'
    , ServerSamples=COUNT(*)
    , PeakSqlCpuPercent=MAX(SqlCpuPercent)
    , AvgSqlCpuPercent=
        CAST(AVG(CAST(SqlCpuPercent AS decimal(18,4))) AS decimal(18,4))
    , MedianApproxSqlCpuPercent=
        (
            SELECT TOP (1)
                PERCENTILE_CONT(0.5)
                WITHIN GROUP (ORDER BY CAST(SqlCpuPercent AS float))
                OVER ()
            FROM dbo.RCA_ServerSnapshot
            WHERE CaptureRunID=43
        )
    , PeakOtherCpuPercent=MAX(OtherCpuPercent)
    , LowestSystemIdlePercent=MIN(SystemIdlePercent)
    , PeakRunnableTasks=MAX(RunnableTasks)
    , SamplesSqlCpuAtOrAbove50=
        SUM(CASE WHEN SqlCpuPercent>=50 THEN 1 ELSE 0 END)
    , SamplesSqlCpuAtOrAbove70=
        SUM(CASE WHEN SqlCpuPercent>=70 THEN 1 ELSE 0 END)
    , SamplesIdleAtOrBelow30=
        SUM(CASE WHEN SystemIdlePercent<=30 THEN 1 ELSE 0 END)
    , SamplesRunnableAbove0=
        SUM(CASE WHEN RunnableTasks>0 THEN 1 ELSE 0 END)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=43;
GO


/*==============================================================================
  6. EXECUTION EVIDENCE SUMMARY
==============================================================================*/
SELECT
      DiagnosticSection='6 - EXECUTION EVIDENCE SUMMARY'
    , ExecutionRows=COUNT(*)
    , RowsWithCPU=
        SUM(CASE WHEN ISNULL(CPUms,0)>0 THEN 1 ELSE 0 END)
    , RowsCPU500msOrMore=
        SUM(CASE WHEN ISNULL(CPUms,0)>=500 THEN 1 ELSE 0 END)
    , RowsCPU1000msOrMore=
        SUM(CASE WHEN ISNULL(CPUms,0)>=1000 THEN 1 ELSE 0 END)
    , MaxCPUms=MAX(CPUms)
    , AvgCPUms=
        CAST(AVG(CAST(ISNULL(CPUms,0) AS decimal(18,4))) AS decimal(18,4))
    , MaxDurationMs=MAX(DurationMs)
    , MaxLogicalReads=MAX(LogicalReads)
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=43;
GO


/*==============================================================================
  7. TOP CAPTURED EXECUTIONS BY CPU / DURATION
==============================================================================*/
SELECT TOP (30)
      DiagnosticSection='7 - TOP EXECUTIONS'
    , ExecutionEvidenceID
    , EventTimeUTC
    , SessionID
    , DatabaseName
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
WHERE CaptureRunID=43
ORDER BY
      ISNULL(CPUms,0) DESC,
      ISNULL(DurationMs,0) DESC,
      ExecutionEvidenceID;
GO


/*==============================================================================
  8. SQL AGENT HISTORY FOR CPU CONTROL JOBS
==============================================================================*/
SELECT
      DiagnosticSection='8 - CPU WORKER JOB HISTORY'
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
WHERE j.name LIKE N'RCA_C43_CPU_Worker_%'
   OR j.name=N'RCA_C43_CPU_Sampler'
ORDER BY
      j.name,
      h.instance_id;
GO


/*==============================================================================
  9. JOB STEP COMMANDS
  If Script 60 cleanup already removed the jobs, this section may be empty.
==============================================================================*/
SELECT
      DiagnosticSection='9 - CPU JOB STEP COMMANDS'
    , JobName=j.name
    , s.step_id
    , s.step_name
    , s.database_name
    , s.command
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s
  ON s.job_id=j.job_id
WHERE j.name LIKE N'RCA_C43_CPU_Worker_%'
   OR j.name=N'RCA_C43_CPU_Sampler'
ORDER BY j.name,s.step_id;
GO


/*==============================================================================
  10. XE / RAW EVENT TIMELINE FOR THE CPU PROCEDURE
  Look for whether the CPU procedure actually emitted completed calls and
  whether they overlapped substantially.
==============================================================================*/
SELECT
      DiagnosticSection='10 - CPU WORKLOAD EXECUTION TIMELINE'
    , ExecutionEvidenceID
    , EventTimeUTC
    , SessionID
    , ProgramName
    , LoginName
    , CPUms
    , DurationMs
    , SubmittedCommand
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=43
  AND
  (
       SubmittedCommand LIKE N'%usp_RCA_Run8_CPU%'
    OR ObjectName LIKE N'%usp_RCA_Run8_CPU%'
    OR ProgramName LIKE N'%RCA_C43_CPU_Worker%'
  )
ORDER BY EventTimeUTC,SessionID,ExecutionEvidenceID;
GO


/*==============================================================================
  11. SCHEDULER EVIDENCE TABLE / BUILDER EXISTENCE
==============================================================================*/
SELECT
      DiagnosticSection='11 - CPU RCA COMPONENT INVENTORY'
    , ObjectName=o.name
    , ObjectType=o.type_desc
FROM sys.objects AS o
WHERE o.name LIKE N'%CPU%'
   OR o.name LIKE N'%Scheduler%'
ORDER BY o.type_desc,o.name;
GO


/*==============================================================================
  12. CPU SCHEDULER EVIDENCE FOR CAPTURE 43
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence',N'U') IS NOT NULL
BEGIN
    SELECT
          DiagnosticSection='12 - CAPTURE 43 CPU SCHEDULER EVIDENCE'
        , *
    FROM dbo.RCA_CPUSchedulerEvidence
    WHERE CaptureRunID=43;
END
ELSE
BEGIN
    SELECT
          DiagnosticSection='12 - CAPTURE 43 CPU SCHEDULER EVIDENCE'
        , Result='RCA_CPUSchedulerEvidence table not present';
END;
GO


/*==============================================================================
  13. FINAL CPU CALIBRATION ASSESSMENT

  NOTE:
  This is NOT a root-cause detector. It only classifies whether the TEST
  generated a strong enough CPU stimulus to be a useful positive control.
==============================================================================*/
DECLARE
      @Samples int=0
    , @PeakSqlCpu decimal(18,4)=0
    , @AvgSqlCpu decimal(18,4)=0
    , @LowestIdle decimal(18,4)=100
    , @PeakRunnable int=0
    , @CpuExecRows int=0
    , @MaxCpuMs decimal(18,4)=0;

SELECT
      @Samples=COUNT(*)
    , @PeakSqlCpu=ISNULL(MAX(SqlCpuPercent),0)
    , @AvgSqlCpu=ISNULL(AVG(CAST(SqlCpuPercent AS decimal(18,4))),0)
    , @LowestIdle=ISNULL(MIN(SystemIdlePercent),100)
    , @PeakRunnable=ISNULL(MAX(RunnableTasks),0)
FROM dbo.RCA_ServerSnapshot
WHERE CaptureRunID=43;

SELECT
      @CpuExecRows=
        SUM(CASE WHEN ISNULL(CPUms,0)>=500 THEN 1 ELSE 0 END)
    , @MaxCpuMs=ISNULL(MAX(CPUms),0)
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=43;

SET @CpuExecRows=ISNULL(@CpuExecRows,0);

SELECT
      ValidationSection='13 - CPU WORKLOAD CALIBRATION'
    , ServerSamples=@Samples
    , PeakSqlCpuPercent=@PeakSqlCpu
    , AvgSqlCpuPercent=@AvgSqlCpu
    , LowestSystemIdlePercent=@LowestIdle
    , PeakRunnableTasks=@PeakRunnable
    , CapturedExecutionsCPU500msOrMore=@CpuExecRows
    , MaxCapturedExecutionCPUms=@MaxCpuMs

    , WorkloadStrength=
        CASE
          WHEN @PeakSqlCpu>=80
           AND @AvgSqlCpu>=60
           AND @LowestIdle<=20
          THEN 'STRONG CPU POSITIVE CONTROL'

          WHEN @PeakSqlCpu>=60
            OR @AvgSqlCpu>=40
            OR @LowestIdle<=35
          THEN 'MODERATE CPU PRESSURE - MAY NEED STRONGER/LOADER TEST'

          ELSE 'INSUFFICIENT CPU PRESSURE FOR POSITIVE CONTROL'
        END

    , Capture43Conclusion=
        CASE
          WHEN @PeakSqlCpu<50
           AND @AvgSqlCpu<20
           AND @LowestIdle>40
          THEN
              'Capture 43 did not create sustained CPU saturation. RCA was correct not to claim CPU root cause.'
          ELSE
              'Capture 43 created some CPU pressure; review timeline and scheduler evidence before designing next test.'
        END

    , NextTestRecommendation=
        CASE
          WHEN @PeakSqlCpu<50
           AND @AvgSqlCpu<20
          THEN
              'Increase workload intensity and overlap, not RCA thresholds. First inspect usp_RCA_Run8_CPU definition and worker duration.'
          WHEN @CpuExecRows=0
          THEN
              'Captured execution CPU attribution is weak. Ensure the next workload produces long-running CPU-bound statements visible to XE.'
          ELSE
              'Pressure is measurable. Calibrate next worker count/duration to sustain high SQL CPU across multiple samples.'
        END;
GO


/*==============================================================================
  14. SAFETY
==============================================================================*/
SELECT
      ValidationSection='14 - SCRIPT 61 SAFETY'
    , ReadOnlyDiagnostic='YES'
    , Capture43Modified='NO'
    , CPUWorkloadProcedureModified='NO'
    , SQLAgentJobsModified='NO'
    , ExistingEvidenceModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalDBAAnswerChanged='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        'Review Sections 2, 3, 4, 6, 8, 10, and 13. Design the next CPU positive control from measured workload capacity rather than changing RCA thresholds.';
GO
