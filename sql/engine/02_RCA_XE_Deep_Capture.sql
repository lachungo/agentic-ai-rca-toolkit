USE master;
GO
IF DB_ID(N'DBA') IS NULL CREATE DATABASE DBA;
GO
ALTER DATABASE DBA SET RECOVERY SIMPLE;
GO
USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* 02_RCA_XE_Deep_Capture.sql
   Zero-threshold RCA lab capture for SQL Server 2025.
   Requires:
      RCA database from 01_RCA_Lab_Build.sql
      Windows folder C:\RCA\XE with MODIFY permission for SQL Server service account.
*/

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name=N'RCA_DeepCapture')
    ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=STOP;
GO
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name=N'RCA_DeepCapture')
    DROP EVENT SESSION [RCA_DeepCapture] ON SERVER;
GO

DROP VIEW IF EXISTS dbo.vw_RCA_ExecutionEvidence;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_ShowReport;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_ImportXE;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_CaptureLiveSnapshot;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_StopCapture;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_StartCapture;
DROP TABLE IF EXISTS dbo.RCA_PlanEvidence;
DROP TABLE IF EXISTS dbo.RCA_ExecutionEvidence;
DROP TABLE IF EXISTS dbo.RCA_LiveRequestSnapshot;
DROP TABLE IF EXISTS dbo.RCA_ServerSnapshot;
DROP TABLE IF EXISTS dbo.RCA_XERaw;
DROP TABLE IF EXISTS dbo.RCA_CaptureRun;
GO

CREATE TABLE dbo.RCA_CaptureRun
(
    CaptureRunID bigint IDENTITY(1,1) PRIMARY KEY,
    TargetDatabase sysname NOT NULL,
    CaptureReason nvarchar(1000) NULL,
    StartTimeUTC datetime2(3) NOT NULL,
    EndTimeUTC datetime2(3) NULL,
    CaptureStatus varchar(20) NOT NULL,
    CreatedBy sysname NOT NULL DEFAULT ORIGINAL_LOGIN()
);
GO

CREATE TABLE dbo.RCA_XERaw
(
    XERawID bigint IDENTITY(1,1) PRIMARY KEY,
    EventKey varbinary(32) NOT NULL UNIQUE,
    EventName sysname NOT NULL,
    EventTimeUTC datetime2(7) NOT NULL,
    SourceFileName nvarchar(260) NULL,
    SourceFileOffset bigint NULL,
    EventXML xml NOT NULL,
    ImportedTimeUTC datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_RCA_XERaw_Time ON dbo.RCA_XERaw(EventTimeUTC,EventName);
GO

CREATE TABLE dbo.RCA_ExecutionEvidence
(
    ExecutionEvidenceID bigint IDENTITY(1,1) PRIMARY KEY,
    CaptureRunID bigint NULL,
    XERawID bigint NOT NULL UNIQUE,
    EventName sysname NOT NULL,
    EventTimeUTC datetime2(7) NOT NULL,
    DatabaseName sysname NULL,
    SessionID int NULL,
    ObjectName nvarchar(512) NULL,
    SubmittedCommand nvarchar(max) NULL,
    ParameterText nvarchar(max) NULL,
    ParameterEvidenceStatus varchar(40) NULL,
    HostName nvarchar(256) NULL,
    ProgramName nvarchar(256) NULL,
    LoginName nvarchar(256) NULL,
    CPUms decimal(19,3) NULL,
    DurationMs decimal(19,3) NULL,
    LogicalReads bigint NULL,
    PhysicalReads bigint NULL,
    Writes bigint NULL,
    TotalRows bigint NULL,
    QueryHash varbinary(8) NULL,
    QueryPlanHash varbinary(8) NULL,
    PlanHandle varbinary(64) NULL,
    FOREIGN KEY(XERawID) REFERENCES dbo.RCA_XERaw(XERawID) ON DELETE CASCADE
);
GO

CREATE TABLE dbo.RCA_PlanEvidence
(
    PlanEvidenceID bigint IDENTITY(1,1) PRIMARY KEY,
    CaptureRunID bigint NULL,
    XERawID bigint NOT NULL UNIQUE,
    EventTimeUTC datetime2(7) NOT NULL,
    DatabaseName sysname NULL,
    SessionID int NULL,
    SQLText nvarchar(max) NULL,
    QueryHash varbinary(8) NULL,
    QueryPlanHash varbinary(8) NULL,
    PlanHandle varbinary(64) NULL,
    ActualExecutionPlanXML xml NOT NULL,
    RequestedMemoryKB bigint NULL,
    GrantedMemoryKB bigint NULL,
    MaxUsedMemoryKB bigint NULL,
    ActualDOP int NULL,
    LinkedExecutionEvidenceID bigint NULL,
    FOREIGN KEY(XERawID) REFERENCES dbo.RCA_XERaw(XERawID) ON DELETE CASCADE
);
GO

CREATE TABLE dbo.RCA_ServerSnapshot
(
    ServerSnapshotID bigint IDENTITY(1,1) PRIMARY KEY,
    CaptureRunID bigint NOT NULL,
    CaptureTimeUTC datetime2(3) NOT NULL,
    SqlCpuPercent decimal(9,2) NULL,
    OtherCpuPercent decimal(9,2) NULL,
    SystemIdlePercent decimal(9,2) NULL,
    BufferCacheHitRatio decimal(19,6) NULL,
    PageLifeExpectancySeconds bigint NULL,
    TotalServerMemoryMB decimal(19,2) NULL,
    TargetServerMemoryMB decimal(19,2) NULL,
    AvailablePhysicalMemoryMB decimal(19,2) NULL,
    MemoryGrantsPending bigint NULL,
    MemoryGrantsOutstanding bigint NULL,
    RunnableTasks int NULL,
    ServerMaxDOP int NULL,
    CostThresholdForParallelism int NULL,
    FOREIGN KEY(CaptureRunID) REFERENCES dbo.RCA_CaptureRun(CaptureRunID) ON DELETE CASCADE
);
GO

CREATE TABLE dbo.RCA_LiveRequestSnapshot
(
    LiveRequestSnapshotID bigint IDENTITY(1,1) PRIMARY KEY,
    CaptureRunID bigint NOT NULL,
    CaptureTimeUTC datetime2(3) NOT NULL,
    SessionID int NOT NULL,
    RequestID int NOT NULL,
    DatabaseName sysname NULL,
    Status nvarchar(60) NULL,
    Command nvarchar(60) NULL,
    WaitType nvarchar(120) NULL,
    WaitTimeMs bigint NULL,
    BlockingSessionID int NULL,
    CPUms bigint NULL,
    ElapsedMs bigint NULL,
    LogicalReads bigint NULL,
    PhysicalReads bigint NULL,
    Writes bigint NULL,
    TotalRows bigint NULL,
    DOP int NULL,
    RequestedMemoryKB bigint NULL,
    GrantedMemoryKB bigint NULL,
    UsedMemoryKB bigint NULL,
    MaxUsedMemoryKB bigint NULL,
    HostName nvarchar(256) NULL,
    ProgramName nvarchar(256) NULL,
    LoginName nvarchar(256) NULL,
    RunningStatement nvarchar(max) NULL,
    FOREIGN KEY(CaptureRunID) REFERENCES dbo.RCA_CaptureRun(CaptureRunID) ON DELETE CASCADE
);
GO

/* Validate events before creating the session. */
SELECT name
FROM sys.dm_xe_objects
WHERE object_type='event'
  AND name IN
  (
      'rpc_starting','rpc_completed','sql_batch_starting',
      'sql_batch_completed','sp_statement_completed',
      'query_post_execution_showplan'
  )
ORDER BY name;
GO

DECLARE @dbid int=DB_ID(N'RCA');
IF @dbid IS NULL THROW 61000,N'RCA database not found.',1;

DECLARE @sql nvarchar(max)=N'
CREATE EVENT SESSION [RCA_DeepCapture] ON SERVER

ADD EVENT sqlserver.rpc_starting
(
 ACTION(sqlserver.client_app_name,sqlserver.client_hostname,
        sqlserver.database_name,sqlserver.plan_handle,
        sqlserver.query_hash,sqlserver.query_plan_hash,
        sqlserver.server_principal_name,sqlserver.session_id,
        sqlserver.sql_text)
 WHERE ([sqlserver].[database_id]=('+CONVERT(nvarchar(20),@dbid)+N'))
),
ADD EVENT sqlserver.rpc_completed
(
 ACTION(sqlserver.client_app_name,sqlserver.client_hostname,
        sqlserver.database_name,sqlserver.plan_handle,
        sqlserver.query_hash,sqlserver.query_plan_hash,
        sqlserver.server_principal_name,sqlserver.session_id,
        sqlserver.sql_text)
 WHERE ([sqlserver].[database_id]=('+CONVERT(nvarchar(20),@dbid)+N'))
),
ADD EVENT sqlserver.sql_batch_starting
(
 ACTION(sqlserver.client_app_name,sqlserver.client_hostname,
        sqlserver.database_name,sqlserver.plan_handle,
        sqlserver.query_hash,sqlserver.query_plan_hash,
        sqlserver.server_principal_name,sqlserver.session_id,
        sqlserver.sql_text)
 WHERE ([sqlserver].[database_id]=('+CONVERT(nvarchar(20),@dbid)+N'))
),
ADD EVENT sqlserver.sql_batch_completed
(
 ACTION(sqlserver.client_app_name,sqlserver.client_hostname,
        sqlserver.database_name,sqlserver.plan_handle,
        sqlserver.query_hash,sqlserver.query_plan_hash,
        sqlserver.server_principal_name,sqlserver.session_id,
        sqlserver.sql_text)
 WHERE ([sqlserver].[database_id]=('+CONVERT(nvarchar(20),@dbid)+N'))
),
ADD EVENT sqlserver.sp_statement_completed
(
 ACTION(sqlserver.client_app_name,sqlserver.client_hostname,
        sqlserver.database_name,sqlserver.plan_handle,
        sqlserver.query_hash,sqlserver.query_plan_hash,
        sqlserver.server_principal_name,sqlserver.session_id,
        sqlserver.sql_text)
 WHERE ([sqlserver].[database_id]=('+CONVERT(nvarchar(20),@dbid)+N'))
),
ADD EVENT sqlserver.query_post_execution_showplan
(
 ACTION(sqlserver.client_app_name,sqlserver.client_hostname,
        sqlserver.database_name,sqlserver.plan_handle,
        sqlserver.query_hash,sqlserver.query_plan_hash,
        sqlserver.server_principal_name,sqlserver.session_id,
        sqlserver.sql_text)
 WHERE ([sqlserver].[database_id]=('+CONVERT(nvarchar(20),@dbid)+N'))
)
ADD TARGET package0.event_file
(
 SET filename=N''C:\RCA\XE\RCA_DeepCapture.xel'',
     max_file_size=(256),max_rollover_files=(8)
)
WITH
(
 MAX_MEMORY=32768 KB,
 EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
 MAX_DISPATCH_LATENCY=1 SECONDS,
 MAX_EVENT_SIZE=16384 KB,
 TRACK_CAUSALITY=ON,
 STARTUP_STATE=OFF
);';

EXEC sys.sp_executesql @sql;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_CaptureLiveSnapshot
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sqlcpu decimal(9,2),@idle decimal(9,2),@other decimal(9,2),
            @bchr decimal(19,6),@ple bigint,@totalmem decimal(19,2),
            @targetmem decimal(19,2),@availmem decimal(19,2),
            @mgp bigint,@mgo bigint,@runnable int,@maxdop int,@ctfp int;

    BEGIN TRY
      ;WITH rb AS
      (
        SELECT TOP(1) CONVERT(xml,record) x
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type=N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE N'%<SystemHealth>%'
        ORDER BY [timestamp] DESC
      )
      SELECT @idle=x.value('(//SystemHealth/SystemIdle)[1]','decimal(9,2)'),
             @sqlcpu=x.value('(//SystemHealth/ProcessUtilization)[1]','decimal(9,2)')
      FROM rb;
      SET @other=100-COALESCE(@idle,0)-COALESCE(@sqlcpu,0);
    END TRY
    BEGIN CATCH
      SELECT @idle=NULL,@sqlcpu=NULL,@other=NULL;
    END CATCH;

    SELECT @bchr=CONVERT(decimal(19,6),
             100.0*MAX(CASE WHEN counter_name=N'Buffer cache hit ratio'
                             AND instance_name=N'' THEN cntr_value END)
             /NULLIF(MAX(CASE WHEN counter_name=N'Buffer cache hit ratio base'
                               AND instance_name=N'' THEN cntr_value END),0))
    FROM sys.dm_os_performance_counters;

    SELECT @ple=MAX(cntr_value)
    FROM sys.dm_os_performance_counters
    WHERE counter_name=N'Page life expectancy' AND instance_name=N'';

    SELECT @totalmem=MAX(CASE WHEN counter_name=N'Total Server Memory (KB)'
                              THEN cntr_value END)/1024.0,
           @targetmem=MAX(CASE WHEN counter_name=N'Target Server Memory (KB)'
                               THEN cntr_value END)/1024.0,
           @mgp=MAX(CASE WHEN counter_name=N'Memory Grants Pending'
                         THEN cntr_value END),
           @mgo=MAX(CASE WHEN counter_name=N'Memory Grants Outstanding'
                         THEN cntr_value END)
    FROM sys.dm_os_performance_counters
    WHERE instance_name=N'';

    SELECT @availmem=available_physical_memory_kb/1024.0
    FROM sys.dm_os_sys_memory;

    SELECT @runnable=SUM(runnable_tasks_count)
    FROM sys.dm_os_schedulers
    WHERE status=N'VISIBLE ONLINE';

    SELECT @maxdop=CONVERT(int,value_in_use)
    FROM sys.configurations WHERE name=N'max degree of parallelism';

    SELECT @ctfp=CONVERT(int,value_in_use)
    FROM sys.configurations WHERE name=N'cost threshold for parallelism';

    INSERT dbo.RCA_ServerSnapshot
    (
      CaptureRunID,CaptureTimeUTC,SqlCpuPercent,OtherCpuPercent,SystemIdlePercent,
      BufferCacheHitRatio,PageLifeExpectancySeconds,TotalServerMemoryMB,
      TargetServerMemoryMB,AvailablePhysicalMemoryMB,MemoryGrantsPending,
      MemoryGrantsOutstanding,RunnableTasks,ServerMaxDOP,CostThresholdForParallelism
    )
    VALUES
    (
      @CaptureRunID,SYSUTCDATETIME(),@sqlcpu,@other,@idle,@bchr,@ple,@totalmem,
      @targetmem,@availmem,@mgp,@mgo,@runnable,@maxdop,@ctfp
    );

    INSERT dbo.RCA_LiveRequestSnapshot
    (
      CaptureRunID,CaptureTimeUTC,SessionID,RequestID,DatabaseName,Status,Command,
      WaitType,WaitTimeMs,BlockingSessionID,CPUms,ElapsedMs,LogicalReads,
      PhysicalReads,Writes,TotalRows,DOP,RequestedMemoryKB,GrantedMemoryKB,
      UsedMemoryKB,MaxUsedMemoryKB,HostName,ProgramName,LoginName,RunningStatement
    )
    SELECT
      @CaptureRunID,SYSUTCDATETIME(),r.session_id,r.request_id,DB_NAME(r.database_id),
      r.status,r.command,r.wait_type,r.wait_time,r.blocking_session_id,r.cpu_time,
      r.total_elapsed_time,r.logical_reads,r.reads,r.writes,r.row_count,r.dop,
      mg.requested_memory_kb,mg.granted_memory_kb,mg.used_memory_kb,mg.max_used_memory_kb,
      s.host_name,s.program_name,s.login_name,
      SUBSTRING(txt.text,(r.statement_start_offset/2)+1,
        CASE WHEN r.statement_end_offset=-1
             THEN LEN(CONVERT(nvarchar(max),txt.text))
             ELSE ((r.statement_end_offset-r.statement_start_offset)/2)+1 END)
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) txt
    LEFT JOIN sys.dm_exec_query_memory_grants mg
      ON mg.session_id=r.session_id AND mg.request_id=r.request_id
    WHERE r.database_id=DB_ID(N'RCA') AND r.session_id<>@@SPID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_StartCapture
    @CaptureReason nvarchar(1000)=N'RCA Deep Capture Lab',
    @CaptureRunID bigint=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name=N'RCA_DeepCapture')
        ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=STOP;

    INSERT dbo.RCA_CaptureRun(TargetDatabase,CaptureReason,StartTimeUTC,CaptureStatus)
    VALUES(N'RCA',@CaptureReason,SYSUTCDATETIME(),N'RUNNING');

    SET @CaptureRunID=SCOPE_IDENTITY();

    ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=START;
    EXEC dbo.usp_RCA_CaptureLiveSnapshot @CaptureRunID;

    SELECT @CaptureRunID CaptureRunID,N'RUNNING' CaptureStatus;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_StopCapture
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RCA_CaptureLiveSnapshot @CaptureRunID;

    IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name=N'RCA_DeepCapture')
        ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=STOP;

    UPDATE dbo.RCA_CaptureRun
    SET EndTimeUTC=SYSUTCDATETIME(),CaptureStatus=N'STOPPED'
    WHERE CaptureRunID=@CaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ImportXE
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @start datetime2(3),@finish datetime2(3);

    SELECT @start=StartTimeUTC,@finish=COALESCE(EndTimeUTC,SYSUTCDATETIME())
    FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID;

    IF @start IS NULL THROW 61010,N'Invalid CaptureRunID.',1;

    CREATE TABLE #x
    (
      object_name nvarchar(256),event_data nvarchar(max),
      file_name nvarchar(260),file_offset bigint,timestamp_utc datetime2(7)
    );

    INSERT #x
    SELECT object_name,CONVERT(nvarchar(max),event_data),
           file_name,file_offset,timestamp_utc
    FROM sys.fn_xe_file_target_read_file
         (N'C:\RCA\XE\RCA_DeepCapture*.xel',NULL,NULL,NULL)
    WHERE timestamp_utc>=@start AND timestamp_utc<=DATEADD(second,5,@finish);

    INSERT dbo.RCA_XERaw(EventKey,EventName,EventTimeUTC,
                         SourceFileName,SourceFileOffset,EventXML)
    SELECT
      HASHBYTES('SHA2_256',CONCAT(file_name,N'|',file_offset,N'|',
                                  object_name,N'|',
                                  CONVERT(nvarchar(33),timestamp_utc,126))),
      object_name,timestamp_utc,file_name,file_offset,TRY_CONVERT(xml,event_data)
    FROM #x x
    WHERE TRY_CONVERT(xml,event_data) IS NOT NULL
      AND NOT EXISTS
      (
        SELECT 1 FROM dbo.RCA_XERaw r
        WHERE r.EventKey=HASHBYTES('SHA2_256',
          CONCAT(x.file_name,N'|',x.file_offset,N'|',x.object_name,N'|',
                 CONVERT(nvarchar(33),x.timestamp_utc,126)))
      );

    INSERT dbo.RCA_ExecutionEvidence
    (
      CaptureRunID,XERawID,EventName,EventTimeUTC,DatabaseName,SessionID,ObjectName,
      SubmittedCommand,ParameterText,ParameterEvidenceStatus,HostName,ProgramName,
      LoginName,CPUms,DurationMs,LogicalReads,PhysicalReads,Writes,TotalRows,
      QueryHash,QueryPlanHash,PlanHandle
    )
    SELECT
      @CaptureRunID,r.XERawID,r.EventName,r.EventTimeUTC,
      NULLIF(r.EventXML.value('(/event/action[@name="database_name"]/value/text())[1]',
                              'nvarchar(128)'),N''),
      TRY_CONVERT(int,r.EventXML.value(
                    '(/event/action[@name="session_id"]/value/text())[1]',
                    'nvarchar(20)')),
      NULLIF(r.EventXML.value(
                    '(/event/data[@name="object_name"]/value/text())[1]',
                    'nvarchar(512)'),N''),
      NULLIF(COALESCE(
        NULLIF(r.EventXML.value('(/event/data[@name="statement"]/value/text())[1]',
                                'nvarchar(max)'),N''),
        NULLIF(r.EventXML.value('(/event/data[@name="batch_text"]/value/text())[1]',
                                'nvarchar(max)'),N''),
        NULLIF(r.EventXML.value('(/event/action[@name="sql_text"]/value/text())[1]',
                                'nvarchar(max)'),N'')),N''),
      CASE
        WHEN r.EventName=N'rpc_completed'
          THEN NULLIF(r.EventXML.value(
                '(/event/data[@name="statement"]/value/text())[1]',
                'nvarchar(max)'),N'')
        WHEN r.EventName=N'sql_batch_completed'
          THEN NULLIF(r.EventXML.value(
                '(/event/data[@name="batch_text"]/value/text())[1]',
                'nvarchar(max)'),N'')
      END,
      CASE WHEN r.EventName=N'rpc_completed' THEN N'RPC_ACTUAL_SUBMISSION'
           WHEN r.EventName=N'sql_batch_completed' THEN N'BATCH_ACTUAL_SUBMISSION'
           ELSE N'STATEMENT_TEXT' END,
      NULLIF(r.EventXML.value(
                '(/event/action[@name="client_hostname"]/value/text())[1]',
                'nvarchar(256)'),N''),
      NULLIF(r.EventXML.value(
                '(/event/action[@name="client_app_name"]/value/text())[1]',
                'nvarchar(256)'),N''),
      NULLIF(r.EventXML.value(
                '(/event/action[@name="server_principal_name"]/value/text())[1]',
                'nvarchar(256)'),N''),
      TRY_CONVERT(decimal(19,3),r.EventXML.value(
                '(/event/data[@name="cpu_time"]/value/text())[1]','nvarchar(50)'))/1000.0,
      TRY_CONVERT(decimal(19,3),r.EventXML.value(
                '(/event/data[@name="duration"]/value/text())[1]','nvarchar(50)'))/1000.0,
      TRY_CONVERT(bigint,r.EventXML.value(
                '(/event/data[@name="logical_reads"]/value/text())[1]','nvarchar(50)')),
      COALESCE(
        TRY_CONVERT(bigint,r.EventXML.value(
                '(/event/data[@name="physical_reads"]/value/text())[1]','nvarchar(50)')),
        TRY_CONVERT(bigint,r.EventXML.value(
                '(/event/data[@name="reads"]/value/text())[1]','nvarchar(50)'))),
      TRY_CONVERT(bigint,r.EventXML.value(
                '(/event/data[@name="writes"]/value/text())[1]','nvarchar(50)')),
      TRY_CONVERT(bigint,r.EventXML.value(
                '(/event/data[@name="row_count"]/value/text())[1]','nvarchar(50)')),
      TRY_CONVERT(varbinary(8),r.EventXML.value(
                '(/event/action[@name="query_hash"]/value/text())[1]','nvarchar(34)'),1),
      TRY_CONVERT(varbinary(8),r.EventXML.value(
                '(/event/action[@name="query_plan_hash"]/value/text())[1]','nvarchar(34)'),1),
      TRY_CONVERT(varbinary(64),r.EventXML.value(
                '(/event/action[@name="plan_handle"]/value/text())[1]','nvarchar(130)'),1)
    FROM dbo.RCA_XERaw r
    WHERE r.EventTimeUTC>=@start AND r.EventTimeUTC<=DATEADD(second,5,@finish)
      AND r.EventName IN(N'rpc_completed',N'sql_batch_completed',N'sp_statement_completed')
      AND NOT EXISTS(SELECT 1 FROM dbo.RCA_ExecutionEvidence e WHERE e.XERawID=r.XERawID);

    ;WITH P AS
    (
      SELECT r.XERawID,r.EventTimeUTC,r.EventXML,
             PlanXML=r.EventXML.query(
               '(/event/data[@name="showplan_xml"]/value/*)[1]')
      FROM dbo.RCA_XERaw r
      WHERE r.EventTimeUTC>=@start AND r.EventTimeUTC<=DATEADD(second,5,@finish)
        AND r.EventName=N'query_post_execution_showplan'
    )
    INSERT dbo.RCA_PlanEvidence
    (
      CaptureRunID,XERawID,EventTimeUTC,DatabaseName,SessionID,SQLText,
      QueryHash,QueryPlanHash,PlanHandle,ActualExecutionPlanXML,
      RequestedMemoryKB,GrantedMemoryKB,MaxUsedMemoryKB,ActualDOP
    )
    SELECT
      @CaptureRunID,p.XERawID,p.EventTimeUTC,
      NULLIF(p.EventXML.value(
        '(/event/action[@name="database_name"]/value/text())[1]','nvarchar(128)'),N''),
      TRY_CONVERT(int,p.EventXML.value(
        '(/event/action[@name="session_id"]/value/text())[1]','nvarchar(20)')),
      NULLIF(p.EventXML.value(
        '(/event/action[@name="sql_text"]/value/text())[1]','nvarchar(max)'),N''),
      TRY_CONVERT(varbinary(8),p.EventXML.value(
        '(/event/action[@name="query_hash"]/value/text())[1]','nvarchar(34)'),1),
      TRY_CONVERT(varbinary(8),p.EventXML.value(
        '(/event/action[@name="query_plan_hash"]/value/text())[1]','nvarchar(34)'),1),
      TRY_CONVERT(varbinary(64),p.EventXML.value(
        '(/event/action[@name="plan_handle"]/value/text())[1]','nvarchar(130)'),1),
      p.PlanXML,
      TRY_CONVERT(bigint,p.PlanXML.value(
       'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@RequestedMemory)[1]','nvarchar(50)')),
      TRY_CONVERT(bigint,p.PlanXML.value(
       'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@GrantedMemory)[1]','nvarchar(50)')),
      TRY_CONVERT(bigint,p.PlanXML.value(
       'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@MaxUsedMemory)[1]','nvarchar(50)')),
      TRY_CONVERT(int,p.PlanXML.value(
       'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//QueryPlan/@DegreeOfParallelism)[1]','nvarchar(20)'))
    FROM P p
    WHERE CONVERT(nvarchar(max),p.PlanXML)<>N''
      AND NOT EXISTS(SELECT 1 FROM dbo.RCA_PlanEvidence pe WHERE pe.XERawID=p.XERawID);

    UPDATE pe
      SET LinkedExecutionEvidenceID=m.ExecutionEvidenceID
    FROM dbo.RCA_PlanEvidence pe
    CROSS APPLY
    (
      SELECT TOP(1) e.ExecutionEvidenceID
      FROM dbo.RCA_ExecutionEvidence e
      WHERE e.CaptureRunID=@CaptureRunID
        AND e.SessionID=pe.SessionID
        AND ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,pe.EventTimeUTC))<=15000
      ORDER BY CASE WHEN e.QueryHash=pe.QueryHash AND pe.QueryHash IS NOT NULL
                    THEN 0 ELSE 1 END,
               ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,pe.EventTimeUTC))
    )m
    WHERE pe.CaptureRunID=@CaptureRunID AND pe.LinkedExecutionEvidenceID IS NULL;

    UPDATE dbo.RCA_CaptureRun SET CaptureStatus=N'IMPORTED'
    WHERE CaptureRunID=@CaptureRunID;

    SELECT @CaptureRunID CaptureRunID,
      (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence WHERE CaptureRunID=@CaptureRunID)
        CompletedEvidence,
      (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence
       WHERE CaptureRunID=@CaptureRunID AND ParameterText IS NOT NULL)
        ParameterRows,
      (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID)
        ActualPlans,
      (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence
       WHERE CaptureRunID=@CaptureRunID AND LinkedExecutionEvidenceID IS NOT NULL)
        LinkedPlans;
END;
GO

CREATE OR ALTER VIEW dbo.vw_RCA_ExecutionEvidence
AS
SELECT
  e.CaptureRunID,e.ExecutionEvidenceID,e.EventTimeUTC,e.DatabaseName,e.SessionID,
  e.ObjectName,e.CPUms,e.DurationMs,e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows,
  CONVERT(decimal(19,2),p.RequestedMemoryKB/1024.0) QueryMemoryRequestedMB,
  CONVERT(decimal(19,2),p.GrantedMemoryKB/1024.0) QueryMemoryGrantedMB,
  CONVERT(decimal(19,2),p.MaxUsedMemoryKB/1024.0) QueryMemoryMaxUsedMB,
  p.ActualDOP,e.HostName,e.ProgramName,e.LoginName,e.ParameterEvidenceStatus,
  e.ParameterText,e.SubmittedCommand,
  CONVERT(bit,CASE WHEN p.ActualExecutionPlanXML IS NULL THEN 0 ELSE 1 END)
    HasActualExecutionPlan,
  p.ActualExecutionPlanXML,e.QueryHash,e.QueryPlanHash,e.PlanHandle
FROM dbo.RCA_ExecutionEvidence e
LEFT JOIN dbo.RCA_PlanEvidence p
  ON p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowReport
  @CaptureRunID bigint
AS
BEGIN
  SET NOCOUNT ON;

  SELECT *
  FROM dbo.vw_RCA_ExecutionEvidence
  WHERE CaptureRunID=@CaptureRunID
  ORDER BY CPUms DESC,LogicalReads DESC,DurationMs DESC;

  SELECT CaptureRunID,COUNT(*) Samples,
         MAX(SqlCpuPercent) PeakSqlCpuPercent,
         MIN(BufferCacheHitRatio) MinimumBufferCacheHitRatio,
         MIN(PageLifeExpectancySeconds) MinimumPLE,
         MIN(AvailablePhysicalMemoryMB) MinimumAvailablePhysicalMemoryMB,
         MAX(MemoryGrantsPending) MaximumMemoryGrantsPending,
         MAX(MemoryGrantsOutstanding) MaximumMemoryGrantsOutstanding,
         MAX(RunnableTasks) MaximumRunnableTasks,
         MAX(ServerMaxDOP) ServerMaxDOP
  FROM dbo.RCA_ServerSnapshot
  WHERE CaptureRunID=@CaptureRunID
  GROUP BY CaptureRunID;

  SELECT *
  FROM dbo.RCA_LiveRequestSnapshot
  WHERE CaptureRunID=@CaptureRunID
  ORDER BY CaptureTimeUTC,CPUms DESC;
END;
GO

SELECT
  IIF(EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name=N'RCA_DeepCapture'),
      N'PASS',N'FAIL') XE,
  IIF(OBJECT_ID(N'dbo.usp_RCA_StartCapture',N'P') IS NULL,N'FAIL',N'PASS') StartProc,
  IIF(OBJECT_ID(N'dbo.usp_RCA_CaptureLiveSnapshot',N'P') IS NULL,N'FAIL',N'PASS') SnapshotProc,
  IIF(OBJECT_ID(N'dbo.usp_RCA_ImportXE',N'P') IS NULL,N'FAIL',N'PASS') ImportProc,
  IIF(OBJECT_ID(N'dbo.usp_RCA_ShowReport',N'P') IS NULL,N'FAIL',N'PASS') ReportProc;
GO

/* TEST - 3 WINDOWS

WINDOW 1:
USE DBA;
DECLARE @RunID bigint;
EXEC dbo.usp_RCA_StartCapture
  @CaptureReason=N'Laptop deep capture test',
  @CaptureRunID=@RunID OUTPUT;
SELECT @RunID CaptureRunID;

WINDOW 2:
USE DBA;
EXEC dbo.usp_RCA_CaptureLiveSnapshot @CaptureRunID=1;
GO 20

WINDOW 3:
USE RCA;
EXEC dbo.usp_RCA_PerformanceQuery
 @AsOfDate='2026-08-08',
 @EntityClassID=2,
 @PortfolioID=1001,
 @LookbackMonths=12,
 @DeletePercent=20;

Then heavy:
EXEC dbo.usp_RCA_PerformanceQuery
 @AsOfDate='2026-08-08',
 @EntityClassID=2,
 @PortfolioID=0,
 @LookbackMonths=36,
 @DeletePercent=20;

BACK TO WINDOW 1:
USE DBA;
EXEC dbo.usp_RCA_StopCapture @CaptureRunID=1;
EXEC dbo.usp_RCA_ImportXE @CaptureRunID=1;
EXEC dbo.usp_RCA_ShowReport @CaptureRunID=1;

Click ActualExecutionPlanXML to open the graphical actual execution plan.
*/
