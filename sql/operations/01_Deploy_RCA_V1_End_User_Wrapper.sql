USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlowV1
      @DatabaseName   sysname
    , @CaptureRunID   bigint = NULL
    , @IncludeDetails bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ResolvedCaptureRunID bigint;

    IF @CaptureRunID IS NOT NULL
    BEGIN
        SELECT @ResolvedCaptureRunID = CaptureRunID
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
          AND TargetDatabase = @DatabaseName;
    END
    ELSE
    BEGIN
        SELECT TOP (1) @ResolvedCaptureRunID = CaptureRunID
        FROM dbo.RCA_CaptureRun
        WHERE TargetDatabase = @DatabaseName
          AND CaptureStatus IN ('ANALYZED','STOPPED')
        ORDER BY COALESCE(EndTimeUTC,StartTimeUTC) DESC, CaptureRunID DESC;
    END;

    IF @ResolvedCaptureRunID IS NULL
    BEGIN
        SELECT
              ReportSection = 'RCA REQUEST'
            , DatabaseName = @DatabaseName
            , CaptureRunID = CAST(NULL AS bigint)
            , Answer = 'NO COMPLETED RCA CAPTURE FOUND'
            , NextStep = 'Start an RCA capture while the slowdown is occurring, stop it after the incident window, then ask again.';
        RETURN;
    END;

    SELECT
          ReportSection = 'RCA REQUEST'
        , cr.CaptureRunID
        , cr.TargetDatabase AS DatabaseName
        , cr.CaptureReason
        , cr.StartTimeUTC
        , cr.EndTimeUTC
        , cr.CaptureStatus
    FROM dbo.RCA_CaptureRun AS cr
    WHERE cr.CaptureRunID = @ResolvedCaptureRunID;

    EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID = @ResolvedCaptureRunID;

    IF @IncludeDetails = 0 RETURN;

    IF OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary', N'V') IS NOT NULL
        SELECT ReportSection='ROOT CAUSE SUMMARY', *
        FROM dbo.vw_RCA_CrossDomainCauseSummary
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_ExecutionEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='EXECUTION EVIDENCE', *
        FROM dbo.RCA_ExecutionEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID
        ORDER BY CPUms DESC, DurationMs DESC;

    IF OBJECT_ID(N'dbo.RCA_RuntimeParameter', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_RuntimeParameter', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='RUNTIME PARAMETERS', *
        FROM dbo.RCA_RuntimeParameter
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_PlanEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_PlanEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='ACTUAL EXECUTION PLANS', *
        FROM dbo.RCA_PlanEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_BlockingEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_BlockingEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='BLOCKING / WAIT CHAIN', *
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_BlockerTransactionEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='BLOCKER TRANSACTION', *
        FROM dbo.RCA_BlockerTransactionEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_CPUSchedulerEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_CPUSchedulerEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='CPU / SCHEDULER', *
        FROM dbo.RCA_CPUSchedulerEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_MemoryPressureEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_MemoryPressureEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='MEMORY PRESSURE', *
        FROM dbo.RCA_MemoryPressureEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_IOStorageEvidence', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_IOStorageEvidence', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='I/O / STORAGE', *
        FROM dbo.RCA_IOStorageEvidence
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_Recommendation', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_Recommendation', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='RECOMMENDATIONS', *
        FROM dbo.RCA_Recommendation
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_PlanFinding', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_PlanFinding', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='PLAN FINDINGS', *
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_PlanStatistics', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_PlanStatistics', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='PLAN STATISTICS', *
        FROM dbo.RCA_PlanStatistics
        WHERE CaptureRunID=@ResolvedCaptureRunID;

    IF OBJECT_ID(N'dbo.RCA_PlanOperator', N'U') IS NOT NULL
       AND COL_LENGTH(N'dbo.RCA_PlanOperator', N'CaptureRunID') IS NOT NULL
        SELECT ReportSection='PLAN OPERATORS', *
        FROM dbo.RCA_PlanOperator
        WHERE CaptureRunID=@ResolvedCaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyIsDemoDatabaseSlow
      @CaptureRunID   bigint = NULL
    , @IncludeDetails bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_WhyIsDatabaseSlowV1
         @DatabaseName = N'RCA_Demo',
         @CaptureRunID = @CaptureRunID,
         @IncludeDetails = @IncludeDetails;
END;
GO

SELECT
      ValidationSection = 'RCA V1 END USER DEPLOYMENT'
    , WhyIsDatabaseSlowV1 = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , WhyIsDemoDatabaseSlow = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDemoDatabaseSlow',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CanonicalAnswer = CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CoreRCALogicChanged = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , ParserChanged = 'NO';
GO
