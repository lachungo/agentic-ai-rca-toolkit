USE dbamaint;
GO
/*=============================================================================
  RCA V1 - SCRIPT 111K5 v1.0
  PRODUCTION HTML WRITER: ODBC 18 TRUSTED-CERTIFICATE CORRECTION

  Purpose
    Applies the exact BCP/TLS correction proved by SCRIPT 111K4.
    The production writer now:
      1. Retains encrypted ODBC Driver 18 transport.
      2. Uses BCP -u to trust the SQL Server certificate.
      3. Verifies the actual output file and byte size.
      4. Returns the timestamped C:\RCA HTML filename to the caller.

  Scope
    Complete replacement of dbo.usp_RCA_SaveHTMLReport only.
    The renderer, user front door, RCA data, XE, capture objects, detectors,
    thresholds, causal topology, and arbitration are unchanged.
=============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 63990, 'SCRIPT 111K5 ABORTED: run in a new query window with no open transaction.', 1;

IF OBJECT_ID(N'dbo.RCA_CaptureRun', N'U') IS NULL
   OR OBJECT_ID(N'dbo.usp_RCA_RenderHTMLReport', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_RCA_SaveHTMLReport', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1', N'P') IS NULL
    THROW 63991, 'SCRIPT 111K5 ABORTED: one or more certified HTML-report objects are missing.', 1;

SELECT
    N'0 - SCRIPT 111K5 PREFLIGHT' AS ValidationSection,
    CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')) AS ServerName,
    DB_NAME() AS RepositoryDatabase,
    OBJECT_ID(N'dbo.usp_RCA_SaveHTMLReport') AS ExistingWriterObjectID,
    OBJECT_ID(N'dbo.usp_RCA_RenderHTMLReport') AS RendererObjectID,
    OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1') AS FrontDoorObjectID,
    N'PASS' AS PreflightGate;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_SaveHTMLReport
    @CaptureRunID bigint,
    @OutputDirectory nvarchar(260) = N'C:\RCA'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatabaseName sysname;

    SELECT @DatabaseName = TargetDatabase
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID = @CaptureRunID;

    IF @DatabaseName IS NULL
        THROW 63982, 'Invalid CaptureRunID.', 1;

    IF NULLIF(LTRIM(RTRIM(@OutputDirectory)), N'') IS NULL
        THROW 63983, 'OutputDirectory is required.', 1;

    IF COALESCE(CONVERT(int,
       (
           SELECT value_in_use
           FROM sys.configurations
           WHERE name = N'xp_cmdshell'
       )), 0) <> 1
        THROW 63983, 'HTML rendered but file output is unavailable because xp_cmdshell is disabled. This procedure does not enable it.', 1;

    -- Remove filename-reserved characters from the database component.
    SET @DatabaseName = REPLACE(@DatabaseName, N'\', N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'/',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N':',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'*',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'?',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'"',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'<',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'>',  N'_');
    SET @DatabaseName = REPLACE(@DatabaseName, N'|',  N'_');

    DECLARE @Stamp char(15) =
        CONVERT(char(8), GETDATE(), 112) + N'_' +
        REPLACE(CONVERT(char(8), GETDATE(), 108), N':', N'');

    DECLARE @File nvarchar(4000) =
        @OutputDirectory +
        CASE WHEN RIGHT(@OutputDirectory, 1) = N'\' THEN N'' ELSE N'\' END +
        N'RCA_Incident_' + @DatabaseName + N'_' +
        CONVERT(nvarchar(30), @CaptureRunID) + N'_' + @Stamp + N'.html';

    DECLARE @Server nvarchar(256) =
        CONVERT(nvarchar(256), SERVERPROPERTY('ServerName'));

    /*
      -T       Windows integrated authentication
      -c       character output
      -C 65001 UTF-8 output
      -u       trust the SQL Server certificate while retaining encryption
    */
    DECLARE @Command nvarchar(4000) =
        N'bcp "EXEC dbamaint.dbo.usp_RCA_RenderHTMLReport @CaptureRunID=' +
        CONVERT(nvarchar(30), @CaptureRunID) +
        N'" queryout "' + REPLACE(@File, N'"', N'""') +
        N'" -S "' + REPLACE(@Server, N'"', N'""') +
        N'" -T -c -C 65001 -u 2>&1';

    DECLARE @BcpOutput TABLE
    (
        OutputOrder int IDENTITY(1,1) NOT NULL,
        OutputLine nvarchar(4000) NULL
    );

    INSERT @BcpOutput(OutputLine)
    EXEC master.dbo.xp_cmdshell @Command;

    DECLARE @FileCheck TABLE
    (
        OutputOrder int IDENTITY(1,1) NOT NULL,
        OutputLine nvarchar(4000) NULL
    );

    DECLARE @CheckCommand nvarchar(4000) =
        N'cmd /d /c if exist "' + REPLACE(@File, N'"', N'""') +
        N'" (for %I in ("' + REPLACE(@File, N'"', N'""') +
        N'") do @echo HTML_FILE_CREATED SizeBytes=%~zI) else (echo HTML_FILE_NOT_CREATED)';

    INSERT @FileCheck(OutputLine)
    EXEC master.dbo.xp_cmdshell @CheckCommand;

    DECLARE @FileSizeBytes bigint;

    SELECT TOP (1)
        @FileSizeBytes = TRY_CONVERT
        (
            bigint,
            SUBSTRING(OutputLine, CHARINDEX(N'=', OutputLine) + 1, 30)
        )
    FROM @FileCheck
    WHERE OutputLine LIKE N'HTML_FILE_CREATED SizeBytes=%';

    IF COALESCE(@FileSizeBytes, 0) <= 100
    BEGIN
        SELECT
            N'HTML FILE OUTPUT DIAGNOSTIC' AS ReportSection,
            N'BCP' AS DiagnosticSource,
            OutputOrder,
            OutputLine
        FROM @BcpOutput
        WHERE OutputLine IS NOT NULL

        UNION ALL

        SELECT
            N'HTML FILE OUTPUT DIAGNOSTIC',
            N'FILE CHECK',
            100000 + OutputOrder,
            OutputLine
        FROM @FileCheck
        WHERE OutputLine IS NOT NULL
        ORDER BY OutputOrder;

        THROW 63984, 'HTML report file was not written or was empty. Review the returned BCP and file-check diagnostics.', 1;
    END;

    SELECT
        N'RCA HTML REPORT' AS ReportSection,
        @CaptureRunID AS CaptureRunID,
        @DatabaseName AS DatabaseName,
        @File AS HtmlFile,
        @FileSizeBytes AS FileSizeBytes,
        N'ENCRYPTED_CONNECTION_WITH_TRUSTED_SERVER_CERTIFICATE' AS TransportState,
        N'PASS' AS Result;
END;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Definition nvarchar(max) =
    OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_SaveHTMLReport'));

DECLARE @WriterGate varchar(4) =
    CASE
        WHEN @Definition LIKE N'%-T -c -C 65001 -u 2>&1%'
         AND @Definition LIKE N'%HTML_FILE_CREATED SizeBytes=%'
         AND @Definition LIKE N'%@FileSizeBytes%'
        THEN 'PASS'
        ELSE 'FAIL'
    END;

SELECT
    N'1 - SCRIPT 111K5 DEPLOYMENT VERDICT' AS ValidationSection,
    @WriterGate AS Result,
    N'dbo.usp_RCA_SaveHTMLReport' AS ReplacedObject,
    OBJECT_ID(N'dbo.usp_RCA_SaveHTMLReport') AS WriterObjectID,
    N'BCP -u; ACTUAL FILE EXISTENCE; FILE SIZE > 100 BYTES' AS InstalledContract,
    N'RENDERER, FRONT DOOR, RCA DATA, XE, DETECTORS, THRESHOLDS, AND ARBITRATION UNCHANGED' AS SafetyStatement;

IF @WriterGate <> 'PASS'
    THROW 63992, 'SCRIPT 111K5 FAILED: corrected production HTML writer contract was not installed.', 1;

SELECT
    N'2 - NORMAL USER COMMAND' AS ValidationSection,
    N'EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1 @DatabaseName=N''RCA'', @BeginTimeLocal=''2026-08-23T06:35:38'', @EndTimeLocal=''2026-08-23T06:36:23'';' AS ExampleCommand,
    N'Creates a timestamped HTML report in C:\RCA and returns its exact path.' AS ExpectedBehavior;
GO
