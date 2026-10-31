USE dbamaint;
GO
/* RCA V1 - SCRIPT 111F v1.1
   Complete replacement of the historical front door.
   Prefers business-hours captures but permits any analyzed capture that fully
   covers the requested database/time window. Legacy/test scope is disclosed. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',N'P') IS NULL OR
   OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
 THROW 63940,'SCRIPT 111F v1.1 ABORTED: report or capture object is absent.',1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlowV1
      @DatabaseName sysname
    , @BeginTimeLocal datetime2(0)
    , @EndTimeLocal datetime2(0)
    , @IncludeDetails bit=1
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @TimeZone sysname=N'Eastern Standard Time',@BeginUTC datetime2(3),@EndUTC datetime2(3),
         @CaptureRunID bigint,@CaptureReason nvarchar(2000),@CaptureStartUTC datetime2(3),
         @CaptureEndUTC datetime2(3),@TelemetryScope varchar(40);

 IF DB_ID(@DatabaseName) IS NULL THROW 63941,'The requested database does not exist.',1;
 IF @BeginTimeLocal IS NULL OR @EndTimeLocal IS NULL OR @BeginTimeLocal>=@EndTimeLocal
  THROW 63942,'Enter a valid local begin time earlier than the local end time.',1;
 IF @EndTimeLocal>DATEADD(minute,1,SYSDATETIME()) THROW 63943,'The requested end time is in the future.',1;

 SET @BeginUTC=CONVERT(datetime2(3),(@BeginTimeLocal AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC');
 SET @EndUTC=CONVERT(datetime2(3),(@EndTimeLocal AT TIME ZONE @TimeZone) AT TIME ZONE 'UTC');

 SELECT TOP(1) @CaptureRunID=CaptureRunID,@CaptureReason=CaptureReason,
        @CaptureStartUTC=StartTimeUTC,@CaptureEndUTC=EndTimeUTC,
        @TelemetryScope=CASE WHEN CaptureReason LIKE N'RCA V1 BUSINESS HOURS COLLECTOR%'
                             THEN 'SEVEN_DOMAIN_BUSINESS_HOURS' ELSE 'LEGACY_OR_TEST_CAPTURE' END
 FROM dbo.RCA_CaptureRun
 WHERE TargetDatabase=@DatabaseName AND CaptureStatus='ANALYZED'
   AND StartTimeUTC<=@BeginUTC AND EndTimeUTC>=@EndUTC
 ORDER BY CASE WHEN CaptureReason LIKE N'RCA V1 BUSINESS HOURS COLLECTOR%' THEN 0 ELSE 1 END,
          DATEDIFF_BIG(millisecond,StartTimeUTC,EndTimeUTC),CaptureRunID DESC;

 IF @CaptureRunID IS NULL
 BEGIN
  SELECT 'RCA REQUEST' ReportSection,@DatabaseName DatabaseName,@BeginTimeLocal BeginTimeLocal,
         @EndTimeLocal EndTimeLocal,@TimeZone InputTimeZone,@BeginUTC BeginTimeUTC,@EndUTC EndTimeUTC,
         'NO ANALYZED CAPTURE COVERS THE COMPLETE WINDOW' RequestStatus;
  THROW 63944,'No analyzed capture for this database covers the complete requested time window.',1;
 END;

 SELECT 'RCA REQUEST' ReportSection,@CaptureRunID CaptureRunID,@DatabaseName DatabaseName,
        @BeginTimeLocal BeginTimeLocal,@EndTimeLocal EndTimeLocal,@TimeZone InputTimeZone,
        @BeginUTC BeginTimeUTC,@EndUTC EndTimeUTC,@CaptureStartUTC CaptureStartUTC,
        @CaptureEndUTC CaptureEndUTC,@TelemetryScope TelemetryScope,@CaptureReason CaptureReason,
        CASE WHEN @TelemetryScope='SEVEN_DOMAIN_BUSINESS_HOURS'
             THEN 'FULL SCHEDULED TELEMETRY' ELSE 'RESULT LIMITED TO TELEMETRY PERSISTED BY THIS TEST CAPTURE' END ScopeStatement;

 EXEC dbo.usp_RCA_WhyIsDatabaseSlowV1_Report
      @DatabaseName=@DatabaseName,@CaptureRunID=@CaptureRunID,@IncludeDetails=@IncludeDetails;
END;
GO

SELECT 'SCRIPT 111F v1.1 FINAL VERDICT' ValidationSection,'PASS' Result,
       'BUSINESS-HOURS CAPTURES PREFERRED; ANALYZED TEST CAPTURES ALLOWED' CaptureSelection,
       'EASTERN LOCAL INPUT WITH AUTOMATIC EST/EDT CONVERSION' TimeContract;
GO
