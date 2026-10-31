USE dbamaint;
GO
/*==============================================================================
 RCA V1 - SCRIPT 111B v1.2

 COMPLETE REPLACEMENT DEPLOYMENT: ONE-CALL LIVE RCA FRONT DOOR

 CORRECTIONS THROUGH v1.2
 ---------------------
   1. Accepts the RUNNING lifecycle state returned by usp_RCA_StartCapture.
   2. Calls usp_RCA_Stop exactly once; Stop already performs certified analysis.
   3. Closes either RUNNING or CAPTURING rows in the failure fallback.
   4. Supports both a fresh pre-111B installation and an existing v1.0 layout.
   5. Supplies WAITFOR DELAY as varchar(8), as required by SQL Server.

 NORMAL USER COMMAND
 -------------------
 EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowV1
      @DatabaseName = N'RCA_Demo';

 No CaptureRunID lookup or second command is required.
==============================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
      @PublicObjectID int=OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P')
    , @InternalObjectID int=OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',N'P')
    , @StartObjectID int=OBJECT_ID(N'dbo.usp_RCA_StartCapture',N'P')
    , @StopObjectID int=OBJECT_ID(N'dbo.usp_RCA_Stop',N'P')
    , @AnswerObjectID int=OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P')
    , @FreshConversion bit=0
    , @InitialTranCount int=@@TRANCOUNT;

IF @InitialTranCount<>0
    THROW 63830,'SCRIPT 111B v1.2 ABORTED: run in a new query batch with no open transaction.',1;

IF @PublicObjectID IS NULL
    THROW 63831,'SCRIPT 111B v1.2 ABORTED: dbo.usp_RCA_WhyIsDatabaseSlowV1 is missing.',1;

IF @StartObjectID IS NULL OR @StopObjectID IS NULL OR @AnswerObjectID IS NULL
    THROW 63832,'SCRIPT 111B v1.2 ABORTED: a required certified lifecycle/report object is missing.',1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.parameters
    WHERE object_id=@StartObjectID AND name=N'@CaptureReason'
)
OR NOT EXISTS
(
    SELECT 1 FROM sys.parameters
    WHERE object_id=@StartObjectID AND name=N'@CaptureRunID' AND is_output=1
)
OR NOT EXISTS
(
    SELECT 1 FROM sys.parameters
    WHERE object_id=@StopObjectID AND name=N'@CaptureRunID'
)
    THROW 63833,'SCRIPT 111B v1.2 ABORTED: a lifecycle parameter contract changed.',1;

DECLARE @Permissions TABLE
(
      PermissionOrder int IDENTITY(1,1) NOT NULL
    , StateCode char(1) NOT NULL
    , PermissionName sysname NOT NULL
    , GranteeName sysname NOT NULL
);

/* On a fresh conversion these permissions belong to the old report procedure
   and must be reapplied to the replacement public object. */
IF @InternalObjectID IS NULL
BEGIN
    SET @FreshConversion=1;

    IF EXISTS (SELECT 1 FROM sys.crypt_properties WHERE major_id=@PublicObjectID)
        THROW 63834,'SCRIPT 111B v1.2 ABORTED: the existing report procedure is cryptographically signed.',1;

    INSERT @Permissions(StateCode,PermissionName,GranteeName)
    SELECT dp.state,dp.permission_name,USER_NAME(dp.grantee_principal_id)
    FROM sys.database_permissions AS dp
    WHERE dp.class=1
      AND dp.major_id=@PublicObjectID
      AND dp.minor_id=0;
END;

SELECT
      '0 - SCRIPT 111B v1.2 PREFLIGHT' AS ValidationSection
    , @@SERVERNAME AS ServerName
    , DB_NAME() AS RepositoryDatabase
    , @PublicObjectID AS PublicObjectIDBefore
    , @InternalObjectID AS InternalReportObjectIDBefore
    , @FreshConversion AS FreshConversionRequired
    , 'PASS' AS PreflightGate;

BEGIN TRY
    BEGIN TRANSACTION;

    IF @FreshConversion=1
    BEGIN
        EXEC sys.sp_rename
             @objname=N'dbo.usp_RCA_WhyIsDatabaseSlowV1',
             @newname=N'usp_RCA_WhyIsDatabaseSlowV1_Report',
             @objtype=N'OBJECT';
    END;

    EXEC sys.sp_executesql N'
CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlowV1
      @DatabaseName sysname
    , @CaptureRunID bigint = NULL
    , @IncludeDetails bit = 0
    , @ObservationSeconds int = 45
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @ResolvedCaptureRunID bigint=@CaptureRunID
        , @CaptureReason nvarchar(1000)
        , @Delay varchar(8)
        , @CaptureStarted bit=0
        , @CaptureStopped bit=0;

    IF NULLIF(LTRIM(RTRIM(@DatabaseName)),N'''') IS NULL
        THROW 63820,''DatabaseName is required.'',1;

    IF DB_ID(@DatabaseName) IS NULL
        THROW 63821,''The requested database does not exist on this SQL Server.'',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name=@DatabaseName
          AND state_desc=N''ONLINE''
          AND HAS_DBACCESS(name)=1
    )
        THROW 63822,''The requested database is not ONLINE or is not accessible.'',1;

    /* Optional historical replay remains available for senior/support use. */
    IF @ResolvedCaptureRunID IS NOT NULL
    BEGIN
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@ResolvedCaptureRunID
              AND TargetDatabase=@DatabaseName
        )
            THROW 63823,''The supplied CaptureRunID does not belong to the requested database.'',1;

        EXEC dbo.usp_RCA_WhyIsDatabaseSlowV1_Report
             @DatabaseName=@DatabaseName,
             @CaptureRunID=@ResolvedCaptureRunID,
             @IncludeDetails=@IncludeDetails;
        RETURN;
    END;

    IF @ObservationSeconds<15 OR @ObservationSeconds>300
        THROW 63824,''ObservationSeconds must be between 15 and 300.'',1;

    SET @CaptureReason=CONCAT
    (
        N''ONE-CALL LIVE RCA | DB='',@DatabaseName,
        N'' | RequestedBy='',ORIGINAL_LOGIN(),
        N'' | Host='',COALESCE(HOST_NAME(),N''UNKNOWN''),
        N'' | App='',COALESCE(APP_NAME(),N''UNKNOWN'')
    );

    BEGIN TRY
        EXEC dbo.usp_RCA_StartCapture
             @CaptureReason=@CaptureReason,
             @CaptureRunID=@ResolvedCaptureRunID OUTPUT;

        IF @ResolvedCaptureRunID IS NULL
            THROW 63825,''StartCapture did not return a CaptureRunID.'',1;

        SET @CaptureStarted=1;

        UPDATE dbo.RCA_CaptureRun
           SET TargetDatabase=@DatabaseName
         WHERE CaptureRunID=@ResolvedCaptureRunID
           AND CaptureStatus IN (''RUNNING'',''CAPTURING'')
           AND EndTimeUTC IS NULL;

        IF @@ROWCOUNT<>1
            THROW 63826,''The new capture row could not be assigned to the requested database.'',1;

        SET @Delay=CONVERT
        (
            varchar(8),
            DATEADD(second,@ObservationSeconds,CONVERT(datetime,''19000101'',112)),
            108
        );
        WAITFOR DELAY @Delay;

        /* usp_RCA_Stop performs the certified parse/analyze/arbitration path. */
        EXEC dbo.usp_RCA_Stop @CaptureRunID=@ResolvedCaptureRunID;
        SET @CaptureStopped=1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.RCA_CaptureRun
            WHERE CaptureRunID=@ResolvedCaptureRunID
              AND TargetDatabase=@DatabaseName
              AND CaptureStatus=N''ANALYZED''
              AND EndTimeUTC IS NOT NULL
        )
            THROW 63828,''Stop completed, but the capture did not reach ANALYZED state.'',1;

        EXEC dbo.usp_RCA_WhyIsDatabaseSlowV1_Report
             @DatabaseName=@DatabaseName,
             @CaptureRunID=@ResolvedCaptureRunID,
             @IncludeDetails=@IncludeDetails;
    END TRY
    BEGIN CATCH
        DECLARE
              @ErrorNumber int=ERROR_NUMBER()
            , @ErrorMessage nvarchar(4000)=ERROR_MESSAGE()
            , @OneCallErrorMessage nvarchar(2048);

        IF @CaptureStarted=1 AND @CaptureStopped=0 AND @ResolvedCaptureRunID IS NOT NULL
        BEGIN
            BEGIN TRY
                EXEC dbo.usp_RCA_Stop @CaptureRunID=@ResolvedCaptureRunID;
                SET @CaptureStopped=1;
            END TRY
            BEGIN CATCH
                /* The status fallback below prevents an orphaned active row. */
            END CATCH;
        END;

        IF @ResolvedCaptureRunID IS NOT NULL
        BEGIN
            UPDATE dbo.RCA_CaptureRun
               SET CaptureStatus=N''FAILED'',
                   EndTimeUTC=COALESCE(EndTimeUTC,SYSUTCDATETIME())
             WHERE CaptureRunID=@ResolvedCaptureRunID
               AND CaptureStatus IN (N''RUNNING'',N''CAPTURING'');
        END;

        SET @OneCallErrorMessage=CONCAT
        (
            ''One-call RCA failed. CaptureRunID='',
            COALESCE(CONVERT(varchar(30),@ResolvedCaptureRunID),''NOT CREATED''),
            ''; original error '',@ErrorNumber,'': '',@ErrorMessage
        );

        THROW 63827,@OneCallErrorMessage,1;
    END CATCH;
END;';

    IF @FreshConversion=1
    BEGIN
        DECLARE
              @StateCode char(1)
            , @PermissionName sysname
            , @GranteeName sysname
            , @PermissionSQL nvarchar(max);

        DECLARE permission_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT StateCode,PermissionName,GranteeName
        FROM @Permissions
        ORDER BY PermissionOrder;

        OPEN permission_cursor;
        FETCH NEXT FROM permission_cursor INTO @StateCode,@PermissionName,@GranteeName;

        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @PermissionSQL=
                CASE @StateCode WHEN 'D' THEN N'DENY ' WHEN 'R' THEN N'REVOKE ' ELSE N'GRANT ' END
                +QUOTENAME(@PermissionName)
                +N' ON OBJECT::dbo.usp_RCA_WhyIsDatabaseSlowV1 TO '
                +QUOTENAME(@GranteeName)
                +CASE WHEN @StateCode='W' THEN N' WITH GRANT OPTION' ELSE N'' END+N';';

            EXEC sys.sp_executesql @PermissionSQL;
            FETCH NEXT FROM permission_cursor INTO @StateCode,@PermissionName,@GranteeName;
        END;

        CLOSE permission_cursor;
        DEALLOCATE permission_cursor;
    END;

    IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P') IS NULL
       OR OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',N'P') IS NULL
        THROW 63835,'SCRIPT 111B v1.2 FAILED: public or internal report procedure is missing.',1;

    COMMIT TRANSACTION;

    SELECT
          '1 - SCRIPT 111B v1.2 DEPLOYMENT VERDICT' AS ValidationSection
        , 'PASS' AS Result
        , OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P') AS PublicFrontDoorObjectID
        , OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',N'P') AS InternalReportObjectID
        , @FreshConversion AS FreshConversionPerformed
        , 'RUNNING/CAPTURING ACCEPTED; STOP ANALYZES ONCE' AS CorrectionState
        , 'NO LIVE CAPTURE EXECUTED DURING DEPLOYMENT' AS SafetyStatement;

    SELECT
          '2 - NORMAL USER COMMAND' AS ValidationSection
        , N'EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowV1 @DatabaseName=N''RCA_Demo'';' AS Command
        , 'One command creates, observes, stops, analyzes, arbitrates, and reports.' AS Behavior;
END TRY
BEGIN CATCH
    DECLARE
          @DeploymentErrorNumber int=ERROR_NUMBER()
        , @DeploymentErrorLine int=ERROR_LINE()
        , @DeploymentErrorMessage nvarchar(4000)=ERROR_MESSAGE();

    IF CURSOR_STATUS('local','permission_cursor')>=0 CLOSE permission_cursor;
    IF CURSOR_STATUS('local','permission_cursor')>-3 DEALLOCATE permission_cursor;
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;

    SELECT
          'ERROR - SCRIPT 111B v1.2 ROLLBACK CONFIRMATION' AS ValidationSection
        , @DeploymentErrorNumber AS ErrorNumber
        , @DeploymentErrorLine AS ErrorLine
        , @DeploymentErrorMessage AS ErrorMessage
        , @@TRANCOUNT AS OpenTransactionCount
        , 'DEPLOYMENT ROLLED BACK' AS SafetyStatus;

    THROW;
END CATCH;
GO
