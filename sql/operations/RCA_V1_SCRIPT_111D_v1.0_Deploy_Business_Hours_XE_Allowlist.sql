USE dbamaint;
GO
/*==============================================================================
 RCA V1 - SCRIPT 111D v1.0

 DEPLOY BUSINESS-HOURS RCA XE COLLECTION

   Session:       RCA_DeepCapture (preserved for parser compatibility)
   Databases:     RCA and RCA_Demo only
   Window:        08:00 through 17:00, SQL Server local time, every day
   Retention:     256 MB x 40 rollover files = approximately 10 GB
   Startup state: OFF; SQL Agent owns the daily lifecycle

 The script preserves all configured events and actions. It changes only their
 database predicate, the event-file rollover count, and automated lifecycle.
==============================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
      @SessionName sysname=N'RCA_DeepCapture'
    , @DatabaseOne sysname=N'RCA'
    , @DatabaseTwo sysname=N'RCA_Demo'
    , @DatabaseOneID int=DB_ID(N'RCA')
    , @DatabaseTwoID int=DB_ID(N'RCA_Demo')
    , @SessionID int
    , @WasRunning bit
    , @OriginalStartupState bit
    , @TargetFile nvarchar(4000)
    , @OriginalMaxFileSize int
    , @OriginalMaxRolloverFiles int
    , @NewPredicate nvarchar(max)
    , @SQL nvarchar(max)
    , @EventID int
    , @PackageName sysname
    , @EventName sysname
    , @OriginalPredicate nvarchar(max)
    , @ActionList nvarchar(max)
    , @OriginalAddSQL nvarchar(max)
    , @NewAddSQL nvarchar(max);

IF @@TRANCOUNT<>0
    THROW 63850,'SCRIPT 111D ABORTED: run in a new query window with no open transaction.',1;

SELECT
      @SessionID=event_session_id
    , @OriginalStartupState=startup_state
FROM sys.server_event_sessions
WHERE name COLLATE DATABASE_DEFAULT=@SessionName COLLATE DATABASE_DEFAULT;

SET @WasRunning=CONVERT(bit,CASE WHEN EXISTS
(
    SELECT 1 FROM sys.dm_xe_sessions
    WHERE name COLLATE DATABASE_DEFAULT=@SessionName COLLATE DATABASE_DEFAULT
) THEN 1 ELSE 0 END);

IF @SessionID IS NULL
    THROW 63851,'SCRIPT 111D ABORTED: RCA_DeepCapture does not exist.',1;

IF @DatabaseOneID IS NULL OR @DatabaseTwoID IS NULL
    THROW 63852,'SCRIPT 111D ABORTED: RCA and RCA_Demo must both exist.',1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.server_event_session_targets
    WHERE event_session_id=@SessionID AND name=N'event_file'
)
    THROW 63853,'SCRIPT 111D ABORTED: RCA_DeepCapture has no event_file target.',1;

SELECT TOP (1) @TargetFile=CONVERT(nvarchar(4000),f.value)
FROM sys.server_event_session_targets AS t
JOIN sys.server_event_session_fields AS f
  ON f.event_session_id=t.event_session_id AND f.object_id=t.target_id
WHERE t.event_session_id=@SessionID
  AND t.name=N'event_file'
  AND f.name=N'filename';

SELECT
      @OriginalMaxFileSize=MAX(CASE WHEN f.name=N'max_file_size' THEN TRY_CONVERT(int,f.value) END)
    , @OriginalMaxRolloverFiles=MAX(CASE WHEN f.name=N'max_rollover_files' THEN TRY_CONVERT(int,f.value) END)
FROM sys.server_event_session_targets AS t
JOIN sys.server_event_session_fields AS f
  ON f.event_session_id=t.event_session_id AND f.object_id=t.target_id
WHERE t.event_session_id=@SessionID AND t.name=N'event_file';

SET @OriginalMaxFileSize=COALESCE(@OriginalMaxFileSize,256);
SET @OriginalMaxRolloverFiles=COALESCE(@OriginalMaxRolloverFiles,8);

IF NULLIF(@TargetFile,N'') IS NULL
    THROW 63854,'SCRIPT 111D ABORTED: event_file filename could not be resolved.',1;

/* The certified session currently has no SET event fields. Abort rather than
   silently lose an unexpected field added after 111D0. */
IF EXISTS
(
    SELECT 1
    FROM sys.server_event_session_events AS e
    JOIN sys.server_event_session_fields AS f
      ON f.event_session_id=e.event_session_id AND f.object_id=e.event_id
    WHERE e.event_session_id=@SessionID
      AND f.name IS NOT NULL
)
    THROW 63855,'SCRIPT 111D ABORTED: an XE event SET-field contract appeared after 111D0.',1;

DECLARE @Events TABLE
(
      EventOrder int IDENTITY(1,1) NOT NULL PRIMARY KEY
    , EventID int NOT NULL
    , PackageName sysname NOT NULL
    , EventName sysname NOT NULL
    , OriginalPredicate nvarchar(max) NULL
    , ActionList nvarchar(max) NULL
    , OriginalAddSQL nvarchar(max) NULL
    , NewAddSQL nvarchar(max) NULL
);

DECLARE event_source CURSOR LOCAL FAST_FORWARD FOR
SELECT event_id,package,name,predicate
FROM sys.server_event_session_events
WHERE event_session_id=@SessionID
ORDER BY event_id;

OPEN event_source;
FETCH NEXT FROM event_source INTO @EventID,@PackageName,@EventName,@OriginalPredicate;

WHILE @@FETCH_STATUS=0
BEGIN
    SELECT @ActionList=STUFF
    (
        (
            SELECT N','+QUOTENAME(a.package)+N'.'+QUOTENAME(a.name)
            FROM sys.server_event_session_actions AS a
            WHERE a.event_session_id=@SessionID AND a.event_id=@EventID
            ORDER BY a.package,a.name
            FOR XML PATH(''),TYPE
        ).value('.','nvarchar(max)'),1,1,N''
    );

    SET @NewPredicate=N'(([sqlserver].[database_id]=('+CONVERT(varchar(12),@DatabaseOneID)+
                      N')) OR ([sqlserver].[database_id]=('+CONVERT(varchar(12),@DatabaseTwoID)+N')))';

    SET @OriginalAddSQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER ADD EVENT '+
        QUOTENAME(@PackageName)+N'.'+QUOTENAME(@EventName)+
        CASE WHEN NULLIF(@ActionList,N'') IS NULL AND NULLIF(@OriginalPredicate,N'') IS NULL THEN N''
             ELSE N' ('+
                  CASE WHEN NULLIF(@ActionList,N'') IS NOT NULL THEN N'ACTION ('+@ActionList+N')' ELSE N'' END+
                  CASE WHEN NULLIF(@ActionList,N'') IS NOT NULL AND NULLIF(@OriginalPredicate,N'') IS NOT NULL THEN N' ' ELSE N'' END+
                  CASE WHEN NULLIF(@OriginalPredicate,N'') IS NOT NULL THEN N'WHERE '+@OriginalPredicate ELSE N'' END+N')'
        END+N';';

    SET @NewAddSQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER ADD EVENT '+
        QUOTENAME(@PackageName)+N'.'+QUOTENAME(@EventName)+N' ('+
        CASE WHEN NULLIF(@ActionList,N'') IS NOT NULL THEN N'ACTION ('+@ActionList+N') ' ELSE N'' END+
        N'WHERE '+@NewPredicate+N');';

    INSERT @Events(EventID,PackageName,EventName,OriginalPredicate,ActionList,OriginalAddSQL,NewAddSQL)
    VALUES(@EventID,@PackageName,@EventName,@OriginalPredicate,@ActionList,@OriginalAddSQL,@NewAddSQL);

    FETCH NEXT FROM event_source INTO @EventID,@PackageName,@EventName,@OriginalPredicate;
END;

CLOSE event_source;
DEALLOCATE event_source;

IF (SELECT COUNT(*) FROM @Events)<>6
    THROW 63856,'SCRIPT 111D ABORTED: expected six certified RCA XE events.',1;

SELECT
      '0 - SCRIPT 111D PREFLIGHT' AS ValidationSection
    , @@SERVERNAME AS ServerName
    , DB_NAME() AS RepositoryDatabase
    , CURRENT_TIMEZONE() AS SQLServerTimeZone
    , @SessionName AS SessionName
    , @WasRunning AS WasRunning
    , @OriginalStartupState AS OriginalStartupState
    , @DatabaseOne AS AllowedDatabase1
    , @DatabaseOneID AS AllowedDatabaseID1
    , @DatabaseTwo AS AllowedDatabase2
    , @DatabaseTwoID AS AllowedDatabaseID2
    , @TargetFile AS EventFile
    , 256 AS MaxFileSizeMB
    , 40 AS MaxRolloverFiles
    , 10240 AS ApproximateMaximumMB
    , 'PASS' AS PreflightGate;

BEGIN TRY
    IF @WasRunning=1
    BEGIN
        SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER STATE=STOP;';
        EXEC sys.sp_executesql @SQL;
    END;

    DECLARE event_drop CURSOR LOCAL FAST_FORWARD FOR
    SELECT PackageName,EventName FROM @Events ORDER BY EventOrder;
    OPEN event_drop;
    FETCH NEXT FROM event_drop INTO @PackageName,@EventName;
    WHILE @@FETCH_STATUS=0
    BEGIN
        SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER DROP EVENT '+
                 QUOTENAME(@PackageName)+N'.'+QUOTENAME(@EventName)+N';';
        EXEC sys.sp_executesql @SQL;
        FETCH NEXT FROM event_drop INTO @PackageName,@EventName;
    END;
    CLOSE event_drop;
    DEALLOCATE event_drop;

    DECLARE event_add CURSOR LOCAL FAST_FORWARD FOR
    SELECT NewAddSQL FROM @Events ORDER BY EventOrder;
    OPEN event_add;
    FETCH NEXT FROM event_add INTO @NewAddSQL;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC sys.sp_executesql @NewAddSQL;
        FETCH NEXT FROM event_add INTO @NewAddSQL;
    END;
    CLOSE event_add;
    DEALLOCATE event_add;

    SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER DROP TARGET package0.event_file;';
    EXEC sys.sp_executesql @SQL;

    SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER ADD TARGET package0.event_file'+
             N'(SET filename=N'''+REPLACE(@TargetFile,N'''',N'''''')+N''',max_file_size=(256),max_rollover_files=(40));';
    EXEC sys.sp_executesql @SQL;

    SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER WITH (STARTUP_STATE=OFF);';
    EXEC sys.sp_executesql @SQL;

    /* Business-hours controller. SQL Agent schedules use SQL Server local time. */
    EXEC sys.sp_executesql N'
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ManageBusinessHoursXE
      @ForceState varchar(10)=NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceState IS NOT NULL AND @ForceState NOT IN (''START'',''STOP'')
        THROW 63860,''ForceState must be START, STOP, or NULL.'',1;

    DECLARE
          @Now time(0)=CONVERT(time(0),SYSDATETIME())
        , @ShouldRun bit
        , @IsRunning bit=CONVERT(bit,CASE WHEN EXISTS
          (SELECT 1 FROM sys.dm_xe_sessions WHERE name=N''RCA_DeepCapture'') THEN 1 ELSE 0 END);

    SET @ShouldRun=CASE
        WHEN @ForceState=''START'' THEN 1
        WHEN @ForceState=''STOP'' THEN 0
        WHEN @Now>=''08:00:00'' AND @Now<''17:00:00'' THEN 1
        ELSE 0 END;

    IF @ShouldRun=1 AND @IsRunning=0
        ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=START;
    ELSE IF @ShouldRun=0 AND @IsRunning=1
        ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=STOP;

    SELECT
          SYSDATETIME() AS ServerLocalTime
        , CURRENT_TIMEZONE() AS SQLServerTimeZone
        , @ShouldRun AS ShouldRun
        , CONVERT(bit,CASE WHEN EXISTS
          (SELECT 1 FROM sys.dm_xe_sessions WHERE name=N''RCA_DeepCapture'') THEN 1 ELSE 0 END) AS IsRunning
        , COALESCE(@ForceState,''SCHEDULE'') AS RequestedMode;
END;';

    /* Recreate only the two precisely named RCA V1 controller jobs. */
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_V1_XE_BusinessHours_Ensure')
        EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_V1_XE_BusinessHours_Ensure';
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_V1_XE_BusinessHours_Stop')
        EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_V1_XE_BusinessHours_Stop';

    DECLARE @OwnerLogin sysname=SUSER_SNAME(0), @JobID uniqueidentifier;

    EXEC msdb.dbo.sp_add_job
         @job_name=N'RCA_V1_XE_BusinessHours_Ensure',@enabled=1,
         @description=N'Ensures RCA_DeepCapture runs 08:00-17:00 SQL Server local time.',
         @owner_login_name=@OwnerLogin,@job_id=@JobID OUTPUT;
    EXEC msdb.dbo.sp_add_jobstep
         @job_id=@JobID,@step_name=N'Enforce RCA XE business-hours state',
         @subsystem=N'TSQL',@database_name=N'dbamaint',
         @command=N'EXEC dbo.usp_RCA_ManageBusinessHoursXE;';
    EXEC msdb.dbo.sp_add_jobschedule
         @job_id=@JobID,@name=N'RCA V1 every 5 minutes 0800-1659',
         @freq_type=4,@freq_interval=1,@freq_subday_type=4,@freq_subday_interval=5,
         @active_start_time=080000,@active_end_time=165959;
    EXEC msdb.dbo.sp_add_jobserver @job_id=@JobID;

    SET @JobID=NULL;
    EXEC msdb.dbo.sp_add_job
         @job_name=N'RCA_V1_XE_BusinessHours_Stop',@enabled=1,
         @description=N'Stops RCA_DeepCapture daily at 17:00 SQL Server local time.',
         @owner_login_name=@OwnerLogin,@job_id=@JobID OUTPUT;
    EXEC msdb.dbo.sp_add_jobstep
         @job_id=@JobID,@step_name=N'Stop RCA XE',@subsystem=N'TSQL',
         @database_name=N'dbamaint',
         @command=N'EXEC dbo.usp_RCA_ManageBusinessHoursXE @ForceState=''STOP'';';
    EXEC msdb.dbo.sp_add_jobschedule
         @job_id=@JobID,@name=N'RCA V1 daily 1700 stop',
         @freq_type=4,@freq_interval=1,@freq_subday_type=1,@active_start_time=170000;
    EXEC msdb.dbo.sp_add_jobserver @job_id=@JobID;

    EXEC dbo.usp_RCA_ManageBusinessHoursXE;

    SELECT
          '1 - SCRIPT 111D DEPLOYMENT VERDICT' AS ValidationSection
        , 'PASS' AS Result
        , CURRENT_TIMEZONE() AS SQLServerTimeZone
        , '08:00:00' AS DailyStartLocal
        , '17:00:00' AS DailyStopLocal
        , @DatabaseOne AS AllowedDatabase1
        , @DatabaseTwo AS AllowedDatabase2
        , @TargetFile AS EventFile
        , 10240 AS ApproximateMaximumMB
        , 'OLDEST FILES RECYCLE AT 40 X 256 MB' AS RetentionBehavior;
END TRY
BEGIN CATCH
    DECLARE @Err nvarchar(2048)=CONCAT('SCRIPT 111D FAILED: ',ERROR_NUMBER(),': ',ERROR_MESSAGE());

    /* Best-effort restoration of the exact original six events/actions/predicates. */
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name COLLATE DATABASE_DEFAULT=@SessionName COLLATE DATABASE_DEFAULT)
        BEGIN
            SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER STATE=STOP;';
            EXEC sys.sp_executesql @SQL;
        END;

        DECLARE recovery_drop CURSOR LOCAL FAST_FORWARD FOR
        SELECT package,name FROM sys.server_event_session_events WHERE event_session_id=@SessionID;
        OPEN recovery_drop;
        FETCH NEXT FROM recovery_drop INTO @PackageName,@EventName;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER DROP EVENT '+
                     QUOTENAME(@PackageName)+N'.'+QUOTENAME(@EventName)+N';';
            EXEC sys.sp_executesql @SQL;
            FETCH NEXT FROM recovery_drop INTO @PackageName,@EventName;
        END;
        CLOSE recovery_drop;
        DEALLOCATE recovery_drop;

        DECLARE recovery_add CURSOR LOCAL FAST_FORWARD FOR
        SELECT OriginalAddSQL FROM @Events ORDER BY EventOrder;
        OPEN recovery_add;
        FETCH NEXT FROM recovery_add INTO @OriginalAddSQL;
        WHILE @@FETCH_STATUS=0
        BEGIN
            EXEC sys.sp_executesql @OriginalAddSQL;
            FETCH NEXT FROM recovery_add INTO @OriginalAddSQL;
        END;
        CLOSE recovery_add;
        DEALLOCATE recovery_add;

        IF EXISTS
        (
            SELECT 1 FROM sys.server_event_session_targets
            WHERE event_session_id=@SessionID AND name=N'event_file'
        )
        BEGIN
            SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER DROP TARGET package0.event_file;';
            EXEC sys.sp_executesql @SQL;
        END;

        SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER ADD TARGET package0.event_file'+
                 N'(SET filename=N'''+REPLACE(@TargetFile,N'''',N'''''')+N''',max_file_size=('+
                 CONVERT(varchar(12),@OriginalMaxFileSize)+N'),max_rollover_files=('+
                 CONVERT(varchar(12),@OriginalMaxRolloverFiles)+N'));';
        EXEC sys.sp_executesql @SQL;

        SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER WITH (STARTUP_STATE='+
                 CASE WHEN @OriginalStartupState=1 THEN N'ON' ELSE N'OFF' END+N');';
        EXEC sys.sp_executesql @SQL;
        IF @WasRunning=1
        BEGIN
            SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER STATE=START;';
            EXEC sys.sp_executesql @SQL;
        END;
    END TRY
    BEGIN CATCH
        SET @Err=CONCAT(@Err,'; automatic XE restoration also failed: ',ERROR_MESSAGE());
    END CATCH;

    THROW 63859,@Err,1;
END CATCH;
GO
