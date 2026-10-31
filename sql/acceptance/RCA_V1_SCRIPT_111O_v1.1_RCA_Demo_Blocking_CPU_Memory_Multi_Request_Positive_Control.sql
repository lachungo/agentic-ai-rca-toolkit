USE dbamaint;
GO
/*=============================================================================
  RCA V1 - SCRIPT 111O v1.1
  RCA_DEMO BLOCKING + CPU/MEMORY MULTI-REQUEST POSITIVE CONTROL

  EXPECTED RUNTIME
    Approximately 2 minutes.

  ACCEPTANCE
    * One head blocker and at least three distinct blocked victim requests.
    * CPU/scheduler and/or memory-grant/spill evidence.
    * A captured parameterized query with a directly linked actual plan.
    * Three required runtime input parameters tied to that exact plan.
    * An analyzed capture and timestamped HTML report.

  SAFETY
    * RCA_Demo lab objects only; dedicated RCA_V1_111O_* Agent jobs only.
    * Bounded waits and workload duration.
    * Does not attempt to exhaust server memory.
    * Temporary objects and jobs are removed; capture and HTML are preserved.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT<>0
    THROW 64100,'SCRIPT 111O ABORTED: run in a new SSMS query window.',1;

IF DB_ID(N'RCA_Demo') IS NULL
    THROW 64101,'SCRIPT 111O ABORTED: RCA_Demo does not exist.',1;

IF NOT EXISTS (SELECT 1 FROM msdb.sys.tables WHERE name=N'sysjobs')
    THROW 64102,'SCRIPT 111O ABORTED: SQL Server Agent metadata is unavailable.',1;

DECLARE @Required TABLE(ObjectName sysname,ObjectType char(2));
INSERT @Required VALUES
 (N'dbo.usp_RCA_StartCapture',N'P'),(N'dbo.usp_RCA_StopCapture',N'P'),
 (N'dbo.usp_RCA_ImportXE',N'P'),(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P'),
 (N'dbo.usp_RCA_CaptureLiveSnapshot',N'P'),
 (N'dbo.usp_RCA_CaptureBlockerTransactionEvidence',N'P'),
 (N'dbo.usp_RCA_SaveHTMLReport',N'P');

IF EXISTS (SELECT 1 FROM @Required WHERE OBJECT_ID(ObjectName,ObjectType) IS NULL)
BEGIN
    SELECT ObjectName,ObjectType,
           ObjectState=CASE WHEN OBJECT_ID(ObjectName,ObjectType) IS NULL THEN N'MISSING' ELSE N'PRESENT' END
    FROM @Required;
    THROW 64103,'SCRIPT 111O ABORTED: a required RCA procedure is missing.',1;
END;

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name=N'RCA_DeepCapture')
    THROW 64104,'SCRIPT 111O ABORTED: RCA_DeepCapture is already running. Do not interrupt an active capture.',1;

DECLARE @Suffix varchar(20)=CONVERT(varchar(20),@@SPID);
DECLARE @BlockerJob sysname=N'RCA_V1_111O_'+@Suffix+N'_Blocker';
DECLARE @Victim1Job sysname=N'RCA_V1_111O_'+@Suffix+N'_Victim1';
DECLARE @Victim2Job sysname=N'RCA_V1_111O_'+@Suffix+N'_Victim2';
DECLARE @Victim3Job sysname=N'RCA_V1_111O_'+@Suffix+N'_Victim3';
DECLARE @CPUJob sysname=N'RCA_V1_111O_'+@Suffix+N'_CPU_Memory';
DECLARE @SamplerJob sysname=N'RCA_V1_111O_'+@Suffix+N'_Sampler';
DECLARE @CaptureRunID bigint=NULL;
DECLARE @OriginalErrorNumber int,@OriginalErrorMessage nvarchar(4000);

BEGIN TRY
    /* Remove only stale artifacts dedicated to this positive control. */
    DECLARE @OldJob sysname;
    DECLARE stale_jobs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'RCA_V1_111O[_]%';
    OPEN stale_jobs;
    FETCH NEXT FROM stale_jobs INTO @OldJob;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC msdb.dbo.sp_delete_job @job_name=@OldJob,@delete_unused_schedule=1;
        FETCH NEXT FROM stale_jobs INTO @OldJob;
    END;
    CLOSE stale_jobs;
    DEALLOCATE stale_jobs;

    EXEC(N'USE RCA_Demo;
          DROP PROCEDURE IF EXISTS dbo.usp_RCA_111O_CPUAndMemory;
          DROP PROCEDURE IF EXISTS dbo.usp_RCA_111O_BlockedVictim;
          DROP TABLE IF EXISTS dbo.RCA_111O_CPUData;
          DROP TABLE IF EXISTS dbo.RCA_111O_BlockingDemo;');

    EXEC(N'USE RCA_Demo;
          CREATE TABLE dbo.RCA_111O_BlockingDemo
          (
              RowID int NOT NULL CONSTRAINT PK_RCA_111O_BlockingDemo PRIMARY KEY,
              Payload varchar(4000) NOT NULL,
              LastVictimLabel varchar(50) NULL
          );
          INSERT dbo.RCA_111O_BlockingDemo(RowID,Payload)
          VALUES (1,REPLICATE(''A'',4000)),(2,REPLICATE(''B'',4000)),
                 (3,REPLICATE(''C'',4000)),(4,REPLICATE(''D'',4000));

          CREATE TABLE dbo.RCA_111O_CPUData
          (
              RowID int NOT NULL CONSTRAINT PK_RCA_111O_CPUData PRIMARY KEY,
              CustomerGroup int NOT NULL,
              Amount decimal(19,4) NOT NULL,
              SearchText varchar(200) NOT NULL,
              Padding char(300) NOT NULL
          );

          ;WITH n AS
          (
              SELECT TOP (180000)
                     rn=ROW_NUMBER() OVER(ORDER BY (SELECT NULL))
              FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
          )
          INSERT dbo.RCA_111O_CPUData(RowID,CustomerGroup,Amount,SearchText,Padding)
          SELECT CONVERT(int,rn),CONVERT(int,rn%1000),
                 CONVERT(decimal(19,4),(rn%20000)+0.75),
                 CONCAT(''RCA_DEMO-111O-'',RIGHT(REPLICATE(''0'',12)+CONVERT(varchar(20),rn),12)),
                 REPLICATE(CHAR(65+(rn%26)),300)
          FROM n OPTION(MAXDOP 2);');

    EXEC(N'USE RCA_Demo;
          EXEC(N''CREATE PROCEDURE dbo.usp_RCA_111O_BlockedVictim
              @RowID int,
              @VictimLabel varchar(50)
          AS
          BEGIN
              SET NOCOUNT ON;
              UPDATE dbo.RCA_111O_BlockingDemo
              SET LastVictimLabel=@VictimLabel
              WHERE RowID=@RowID;
          END;'');

          EXEC(N''CREATE PROCEDURE dbo.usp_RCA_111O_CPUAndMemory
              @CustomerGroup int,
              @SearchToken varchar(40),
              @MinimumAmount decimal(19,4)
          AS
          BEGIN
              SET NOCOUNT ON;
              DECLARE @CalculatedValue bigint,@MatchedRows bigint;
              CREATE TABLE #SortedWork
              (
                  RowID int NOT NULL,
                  SortKey varbinary(32) NOT NULL,
                  Amount decimal(19,4) NOT NULL,
                  Padding char(300) NOT NULL
              );

              INSERT #SortedWork(RowID,SortKey,Amount,Padding)
              SELECT TOP (110000)
                     RowID,
                     HASHBYTES(''''SHA2_256'''',SearchText+@SearchToken+CONVERT(varchar(30),Amount)),
                     Amount,Padding
              FROM dbo.RCA_111O_CPUData
              WHERE CustomerGroup>=@CustomerGroup
                AND Amount>=@MinimumAmount
              ORDER BY HASHBYTES(''''SHA2_256'''',SearchText+@SearchToken+CONVERT(varchar(30),Amount)),
                       Amount DESC
              OPTION(MAXDOP 4);

              SELECT @CalculatedValue=CHECKSUM_AGG(BINARY_CHECKSUM(RowID,SortKey,Amount,Padding)),
                     @MatchedRows=COUNT_BIG(*)
              FROM #SortedWork
              OPTION(MAXDOP 4);

              SELECT CalculatedValue=@CalculatedValue,MatchedRows=@MatchedRows;
          END;'');');

    EXEC dbo.usp_RCA_StartCapture
         @CaptureReason=N'SCRIPT 111O RCA_Demo blocking + CPU/memory multi-request positive control',
         @CaptureRunID=@CaptureRunID OUTPUT;

    UPDATE dbo.RCA_CaptureRun
    SET TargetDatabase=N'RCA_Demo'
    WHERE CaptureRunID=@CaptureRunID AND CaptureStatus=N'RUNNING';

    DECLARE @BlockerCommand nvarchar(max)=N'USE RCA_Demo;
        SET NOCOUNT ON;
        BEGIN TRAN;
        UPDATE dbo.RCA_111O_BlockingDemo
        SET Payload=Payload
        WHERE RowID BETWEEN 1 AND 4;
        WAITFOR DELAY ''00:01:15'';
        ROLLBACK;';
    DECLARE @Victim1Command nvarchar(max)=N'USE RCA_Demo; EXEC dbo.usp_RCA_111O_BlockedVictim @RowID=1,@VictimLabel=''VICTIM-1'';';
    DECLARE @Victim2Command nvarchar(max)=N'USE RCA_Demo; EXEC dbo.usp_RCA_111O_BlockedVictim @RowID=2,@VictimLabel=''VICTIM-2'';';
    DECLARE @Victim3Command nvarchar(max)=N'USE RCA_Demo; EXEC dbo.usp_RCA_111O_BlockedVictim @RowID=3,@VictimLabel=''VICTIM-3'';';
    DECLARE @CPUCommand nvarchar(max)=N'USE RCA_Demo;
        SET NOCOUNT ON;
        DECLARE @Until datetime2(0)=DATEADD(second,65,SYSDATETIME());
        DECLARE @Iteration int=0;
        WHILE SYSDATETIME()<@Until
        BEGIN
            SET @Iteration+=1;
            IF @Iteration%2=1
                EXEC dbo.usp_RCA_111O_CPUAndMemory
                     @CustomerGroup=150,
                     @SearchToken=''RCA_DEMO-111O-COMPILED'',
                     @MinimumAmount=2500.7500;
            ELSE
                EXEC dbo.usp_RCA_111O_CPUAndMemory
                     @CustomerGroup=700,
                     @SearchToken=''RCA_DEMO-111O-RUNTIME'',
                     @MinimumAmount=12000.7500;
        END;';
    DECLARE @SamplerCommand nvarchar(max)=N'USE dbamaint;
        SET NOCOUNT ON;
        DECLARE @Until datetime2(0)=DATEADD(second,70,SYSDATETIME());
        WHILE SYSDATETIME()<@Until
        BEGIN
            EXEC dbo.usp_RCA_CaptureLiveSnapshot @CaptureRunID='+CONVERT(nvarchar(30),@CaptureRunID)+N';
            EXEC dbo.usp_RCA_CaptureBlockerTransactionEvidence @CaptureRunID='+CONVERT(nvarchar(30),@CaptureRunID)+N';
            WAITFOR DELAY ''00:00:02'';
        END;';

    DECLARE @Jobs TABLE(JobName sysname,DatabaseName sysname,Command nvarchar(max));
    INSERT @Jobs VALUES
      (@BlockerJob,N'RCA_Demo',@BlockerCommand),(@Victim1Job,N'RCA_Demo',@Victim1Command),
      (@Victim2Job,N'RCA_Demo',@Victim2Command),(@Victim3Job,N'RCA_Demo',@Victim3Command),
      (@CPUJob,N'RCA_Demo',@CPUCommand),(@SamplerJob,N'dbamaint',@SamplerCommand);

    DECLARE @JobName sysname,@JobDatabase sysname,@JobCommand nvarchar(max);
    DECLARE create_jobs CURSOR LOCAL FAST_FORWARD FOR SELECT JobName,DatabaseName,Command FROM @Jobs;
    OPEN create_jobs;
    FETCH NEXT FROM create_jobs INTO @JobName,@JobDatabase,@JobCommand;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC msdb.dbo.sp_add_job @job_name=@JobName,@enabled=1,@delete_level=0;
        EXEC msdb.dbo.sp_add_jobstep @job_name=@JobName,@step_name=N'RCA 111O bounded workload',
             @subsystem=N'TSQL',@database_name=@JobDatabase,@command=@JobCommand,
             @on_success_action=1,@on_fail_action=2;
        EXEC msdb.dbo.sp_add_jobserver @job_name=@JobName;
        FETCH NEXT FROM create_jobs INTO @JobName,@JobDatabase,@JobCommand;
    END;
    CLOSE create_jobs;
    DEALLOCATE create_jobs;

    EXEC msdb.dbo.sp_start_job @job_name=@BlockerJob;
    WAITFOR DELAY '00:00:04';
    EXEC msdb.dbo.sp_start_job @job_name=@Victim1Job;
    EXEC msdb.dbo.sp_start_job @job_name=@Victim2Job;
    EXEC msdb.dbo.sp_start_job @job_name=@Victim3Job;
    EXEC msdb.dbo.sp_start_job @job_name=@CPUJob;
    EXEC msdb.dbo.sp_start_job @job_name=@SamplerJob;

    WAITFOR DELAY '00:01:25';

    EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_ImportXE @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_AnalyzeCaptureRun @CaptureRunID=@CaptureRunID,@Reparse=1;

    DECLARE @DistinctVictims int=(SELECT COUNT(DISTINCT VictimSessionID) FROM dbo.RCA_BlockingEvidence WHERE CaptureRunID=@CaptureRunID);
    DECLARE @MaxImpactedRequests int=(SELECT ISNULL(MAX(ImpactedRequestCount),0) FROM dbo.vw_RCA_FinalCauseCandidates WHERE CaptureRunID=@CaptureRunID AND CauseCategory=N'BLOCKING_WAIT_CHAIN');
    DECLARE @CPUOrMemoryCauseCount int=(SELECT COUNT(*) FROM dbo.vw_RCA_FinalCauseCandidates WHERE CaptureRunID=@CaptureRunID AND (CauseCategory=N'CPU_SCHEDULER_PRESSURE' OR CauseCategory IN (N'MEMORY_GRANT_SPILL',N'INSTANCE_MEMORY_PRESSURE')));
    DECLARE @LinkedPlanCount int=(SELECT COUNT(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID AND LinkedExecutionEvidenceID IS NOT NULL AND ActualExecutionPlanXML IS NOT NULL);
    DECLARE @RequiredParameterCount int=(SELECT COUNT(DISTINCT ParameterName) FROM dbo.RCA_RuntimeParameter WHERE CaptureRunID=@CaptureRunID AND ParameterName IN (N'@CustomerGroup',N'@SearchToken',N'@MinimumAmount'));

    SELECT ValidationSection=N'1 - SCRIPT 111O ACCEPTANCE GATES',
           CaptureRunID=@CaptureRunID,
           BlockingVictimGate=CASE WHEN @DistinctVictims>=3 THEN N'PASS' ELSE N'FAIL' END,
           DistinctBlockingVictims=@DistinctVictims,
           MultiRequestGate=CASE WHEN @MaxImpactedRequests>=3 THEN N'PASS' ELSE N'FAIL' END,
           MaxImpactedRequests=@MaxImpactedRequests,
           CPUOrMemoryCauseGate=CASE WHEN @CPUOrMemoryCauseCount>=1 THEN N'PASS' ELSE N'FAIL' END,
           CPUOrMemoryCauseCount=@CPUOrMemoryCauseCount,
           LinkedActualPlanGate=CASE WHEN @LinkedPlanCount>=1 THEN N'PASS' ELSE N'FAIL' END,
           LinkedActualPlans=@LinkedPlanCount,
           RuntimeParameterGate=CASE WHEN @RequiredParameterCount=3 THEN N'PASS' ELSE N'FAIL' END,
           RequiredRuntimeParameters=@RequiredParameterCount;

    IF @DistinctVictims<3 OR @MaxImpactedRequests<3 OR @CPUOrMemoryCauseCount<1 OR @LinkedPlanCount<1 OR @RequiredParameterCount<3
        THROW 64105,'SCRIPT 111O FAILED: blocking, CPU/memory, plan, or parameter acceptance gate did not pass.',1;

    UPDATE dbo.RCA_CaptureRun
    SET CaptureStatus=N'ANALYZED'
    WHERE CaptureRunID=@CaptureRunID AND CaptureStatus=N'STOPPED';

    EXEC dbo.usp_RCA_SaveHTMLReport @CaptureRunID=@CaptureRunID,@OutputDirectory=N'C:\RCA';

    SELECT ValidationSection=N'2 - BLOCKING CHAINS AND IMPACTED REQUESTS',*
    FROM dbo.RCA_BlockingEvidence WHERE CaptureRunID=@CaptureRunID
    ORDER BY HeadBlockerSessionID,VictimSessionID;

    SELECT ValidationSection=N'3 - SUPPORTED FINAL CAUSES',*
    FROM dbo.vw_RCA_FinalCauseCandidates WHERE CaptureRunID=@CaptureRunID
    ORDER BY CASE RootCauseRole WHEN N'PRIMARY' THEN 1 ELSE 2 END,CauseCategory;

    /* Successful cleanup of temporary workload artifacts. */
    DECLARE cleanup_jobs CURSOR LOCAL FAST_FORWARD FOR SELECT JobName FROM @Jobs;
    OPEN cleanup_jobs;
    FETCH NEXT FROM cleanup_jobs INTO @JobName;
    WHILE @@FETCH_STATUS=0
    BEGIN
        IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@JobName)
            EXEC msdb.dbo.sp_delete_job @job_name=@JobName,@delete_unused_schedule=1;
        FETCH NEXT FROM cleanup_jobs INTO @JobName;
    END;
    CLOSE cleanup_jobs;
    DEALLOCATE cleanup_jobs;

    EXEC(N'USE RCA_Demo;
          DROP PROCEDURE IF EXISTS dbo.usp_RCA_111O_CPUAndMemory;
          DROP PROCEDURE IF EXISTS dbo.usp_RCA_111O_BlockedVictim;
          DROP TABLE IF EXISTS dbo.RCA_111O_CPUData;
          DROP TABLE IF EXISTS dbo.RCA_111O_BlockingDemo;');

    SELECT ValidationSection=N'4 - SCRIPT 111O FINAL VERDICT',Result=N'PASS',CaptureRunID=@CaptureRunID,
           PreservedEvidence=N'ANALYZED CAPTURE + TIMESTAMPED HTML',
           Cleanup=N'TEMPORARY JOBS AND RCA_DEMO OBJECTS REMOVED';
END TRY
BEGIN CATCH
    SELECT @OriginalErrorNumber=ERROR_NUMBER(),@OriginalErrorMessage=ERROR_MESSAGE();

    IF @CaptureRunID IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID AND CaptureStatus=N'RUNNING')
    BEGIN TRY
        EXEC dbo.usp_RCA_StopCapture @CaptureRunID=@CaptureRunID;
    END TRY BEGIN CATCH END CATCH;

    DECLARE @CleanupJob sysname;
    DECLARE failed_jobs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'RCA_V1_111O[_]%';
    OPEN failed_jobs;
    FETCH NEXT FROM failed_jobs INTO @CleanupJob;
    WHILE @@FETCH_STATUS=0
    BEGIN
        BEGIN TRY
            IF EXISTS
            (
                SELECT 1
                FROM msdb.dbo.sysjobactivity AS ja
                JOIN msdb.dbo.syssessions AS ss ON ss.session_id=ja.session_id
                JOIN msdb.dbo.sysjobs AS sj ON sj.job_id=ja.job_id
                WHERE ss.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
                  AND sj.name=@CleanupJob
                  AND ja.start_execution_date IS NOT NULL
                  AND ja.stop_execution_date IS NULL
            )
                EXEC msdb.dbo.sp_stop_job @job_name=@CleanupJob;
            EXEC msdb.dbo.sp_delete_job @job_name=@CleanupJob,@delete_unused_schedule=1;
        END TRY BEGIN CATCH END CATCH;
        FETCH NEXT FROM failed_jobs INTO @CleanupJob;
    END;
    CLOSE failed_jobs;
    DEALLOCATE failed_jobs;

    BEGIN TRY
        EXEC(N'USE RCA_Demo;
              DROP PROCEDURE IF EXISTS dbo.usp_RCA_111O_CPUAndMemory;
              DROP PROCEDURE IF EXISTS dbo.usp_RCA_111O_BlockedVictim;
              DROP TABLE IF EXISTS dbo.RCA_111O_CPUData;
              DROP TABLE IF EXISTS dbo.RCA_111O_BlockingDemo;');
    END TRY BEGIN CATCH END CATCH;

    DECLARE @FinalErrorMessage nvarchar(2048)=FORMATMESSAGE(
        'SCRIPT 111O failed. CaptureRunID=%s; original error %d: %s',
        COALESCE(CONVERT(varchar(30),@CaptureRunID),'NULL'),
        @OriginalErrorNumber,@OriginalErrorMessage);
    THROW 64106,@FinalErrorMessage,1;
END CATCH;
GO
