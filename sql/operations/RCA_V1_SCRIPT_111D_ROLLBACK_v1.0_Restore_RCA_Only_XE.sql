USE dbamaint;
GO
/* RCA V1 - SCRIPT 111D ROLLBACK v1.0
   Restores RCA_DeepCapture to the pre-111D RCA-only predicate and 256 MB x 8
   file target. Removes only the two 111D jobs and its controller procedure. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @SessionName sysname=N'RCA_DeepCapture', @DatabaseID int=DB_ID(N'RCA'),
        @SessionID int, @TargetFile nvarchar(4000), @SQL nvarchar(max),
        @EventID int, @Package sysname, @Event sysname, @Actions nvarchar(max),
        @AddSQL nvarchar(max);

IF @@TRANCOUNT<>0 THROW 63870,'111D ROLLBACK ABORTED: use a new query window.',1;
SELECT @SessionID=event_session_id FROM sys.server_event_sessions WHERE name=@SessionName;
IF @SessionID IS NULL OR @DatabaseID IS NULL
    THROW 63871,'111D ROLLBACK ABORTED: session or RCA database is absent.',1;

SELECT TOP (1) @TargetFile=CONVERT(nvarchar(4000),f.value)
FROM sys.server_event_session_targets t
JOIN sys.server_event_session_fields f
  ON f.event_session_id=t.event_session_id AND f.object_id=t.target_id
WHERE t.event_session_id=@SessionID AND t.name=N'event_file' AND f.name=N'filename';
IF NULLIF(@TargetFile,N'') IS NULL THROW 63872,'111D ROLLBACK ABORTED: target filename unresolved.',1;

DECLARE @Events table
(EventOrder int IDENTITY PRIMARY KEY, PackageName sysname, EventName sysname, AddSQL nvarchar(max));
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT event_id,package,name FROM sys.server_event_session_events
WHERE event_session_id=@SessionID ORDER BY event_id;
OPEN c; FETCH NEXT FROM c INTO @EventID,@Package,@Event;
WHILE @@FETCH_STATUS=0
BEGIN
    SELECT @Actions=STUFF((SELECT N','+QUOTENAME(a.package)+N'.'+QUOTENAME(a.name)
      FROM sys.server_event_session_actions a
      WHERE a.event_session_id=@SessionID AND a.event_id=@EventID
      ORDER BY a.package,a.name FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,1,N'');
    SET @AddSQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER ADD EVENT '+
      QUOTENAME(@Package)+N'.'+QUOTENAME(@Event)+N' ('+
      CASE WHEN NULLIF(@Actions,N'') IS NOT NULL THEN N'ACTION ('+@Actions+N') ' ELSE N'' END+
      N'WHERE ([sqlserver].[database_id]=('+CONVERT(varchar(12),@DatabaseID)+N')));';
    INSERT @Events(PackageName,EventName,AddSQL) VALUES(@Package,@Event,@AddSQL);
    FETCH NEXT FROM c INTO @EventID,@Package,@Event;
END
CLOSE c; DEALLOCATE c;
IF (SELECT COUNT(*) FROM @Events)<>6 THROW 63873,'111D ROLLBACK ABORTED: expected six events.',1;

IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name=@SessionName)
BEGIN
    SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER STATE=STOP;';
    EXEC sys.sp_executesql @SQL;
END;
DECLARE d CURSOR LOCAL FAST_FORWARD FOR SELECT PackageName,EventName FROM @Events ORDER BY EventOrder;
OPEN d; FETCH NEXT FROM d INTO @Package,@Event;
WHILE @@FETCH_STATUS=0
BEGIN
    SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER DROP EVENT '+QUOTENAME(@Package)+N'.'+QUOTENAME(@Event)+N';';
    EXEC sys.sp_executesql @SQL;
    FETCH NEXT FROM d INTO @Package,@Event;
END
CLOSE d; DEALLOCATE d;
DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT AddSQL FROM @Events ORDER BY EventOrder;
OPEN a; FETCH NEXT FROM a INTO @AddSQL;
WHILE @@FETCH_STATUS=0
BEGIN
    EXEC sys.sp_executesql @AddSQL;
    FETCH NEXT FROM a INTO @AddSQL;
END
CLOSE a; DEALLOCATE a;

SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER DROP TARGET package0.event_file;';
EXEC sys.sp_executesql @SQL;
SET @SQL=N'ALTER EVENT SESSION '+QUOTENAME(@SessionName)+N' ON SERVER ADD TARGET package0.event_file'+
 N'(SET filename=N'''+REPLACE(@TargetFile,N'''',N'''''')+N''',max_file_size=(256),max_rollover_files=(8));';
EXEC sys.sp_executesql @SQL;
ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER WITH (STARTUP_STATE=OFF);
ALTER EVENT SESSION [RCA_DeepCapture] ON SERVER STATE=START;

IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_V1_XE_BusinessHours_Ensure')
 EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_V1_XE_BusinessHours_Ensure';
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'RCA_V1_XE_BusinessHours_Stop')
 EXEC msdb.dbo.sp_delete_job @job_name=N'RCA_V1_XE_BusinessHours_Stop';
DROP PROCEDURE IF EXISTS dbo.usp_RCA_ManageBusinessHoursXE;

SELECT 'SCRIPT 111D ROLLBACK VERDICT' ValidationSection,'PASS' Result,
       'RCA ONLY; 256 MB X 8; RUNNING; STARTUP_STATE OFF' RestoredState;
GO
