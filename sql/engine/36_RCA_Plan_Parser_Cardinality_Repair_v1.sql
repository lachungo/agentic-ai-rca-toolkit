USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
36_RCA_Plan_Parser_Cardinality_Repair_v1.sql

Single deployment:
  1. Repairs descendant runtime-counter parsing in dbo.usp_RCA_ParseCaptureRun.
  2. Makes spill detection operator-local.
  3. Leaves implicit-conversion logic unchanged.
  4. Rebuilds CaptureRunID 38 from existing RCA_XERaw evidence.
  5. Re-runs the existing RCA analysis pipeline.
  6. Validates corrected operator cardinalities/findings.

No RCA thresholds or root-cause domains are changed.
==============================================================================*/

DECLARE @CaptureRunID bigint = 38;

IF OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NULL
    THROW 52400,N'dbo.usp_RCA_ParseCaptureRun does not exist.',1;

IF OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NULL
    THROW 52401,N'dbo.usp_RCA_AnalyzeCaptureRun does not exist.',1;

IF OBJECT_ID(N'dbo.RCA_XERaw',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
    THROW 52402,N'Required RCA evidence tables are missing.',1;

IF NOT EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
    THROW 52403,N'CaptureRunID 38 does not exist.',1;

DECLARE
      @Definition nvarchar(max)
    , @CreatePos int
    , @ReplacementCount int = 0;

SELECT @Definition = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'));

IF @Definition IS NULL
    THROW 52405,N'Unable to read dbo.usp_RCA_ParseCaptureRun definition.',1;

IF CHARINDEX(
       N'FROM op.r.nodes(''.//RunTimeCountersPerThread'') x(c)',
       @Definition
   ) = 0
BEGIN
    THROW 52406,
      N'Expected descendant runtime-counter expression was not found. Script stopped.',
      1;
END;

SET @Definition = REPLACE
(
    @Definition,
    N'FROM op.r.nodes(''.//RunTimeCountersPerThread'') x(c)',
    N'FROM op.r.nodes(''./RunTimeInformation/RunTimeCountersPerThread'') x(c)'
);
SET @ReplacementCount += 1;

IF CHARINDEX(
       N'''.//RunTimeCountersPerThread[@SpillLevel or @SpilledThreadCount]''',
       @Definition
   ) > 0
BEGIN
    SET @Definition = REPLACE
    (
        @Definition,
        N'''.//RunTimeCountersPerThread[@SpillLevel or @SpilledThreadCount]''',
        N'''./RunTimeInformation/RunTimeCountersPerThread[@SpillLevel or @SpilledThreadCount]'''
    );
    SET @ReplacementCount += 1;
END;

IF CHARINDEX(N'''.//SpillToTempDb''',@Definition)>0
BEGIN
    SET @Definition=REPLACE(@Definition,N'''.//SpillToTempDb''',N'''./Warnings/SpillToTempDb''');
    SET @ReplacementCount += 1;
END;

IF CHARINDEX(N'''.//HashSpillDetails''',@Definition)>0
BEGIN
    SET @Definition=REPLACE(@Definition,N'''.//HashSpillDetails''',N'''./Warnings/HashSpillDetails''');
    SET @ReplacementCount += 1;
END;

IF CHARINDEX(N'''.//SortSpillDetails''',@Definition)>0
BEGIN
    SET @Definition=REPLACE(@Definition,N'''.//SortSpillDetails''',N'''./Warnings/SortSpillDetails''');
    SET @ReplacementCount += 1;
END;

/* Intentionally leave .//Convert[@Implicit="1"] unchanged. */

SET @CreatePos=CHARINDEX(N'CREATE',UPPER(@Definition));
IF @CreatePos=0
    THROW 52407,N'CREATE token not found in parser definition.',1;

SET @Definition=STUFF(@Definition,@CreatePos,6,N'ALTER ');

IF CHARINDEX(
       N'FROM op.r.nodes(''.//RunTimeCountersPerThread'') x(c)',
       @Definition
   ) > 0
    THROW 52408,N'Unsafe descendant runtime-counter expression still exists.',1;

IF CHARINDEX(
       N'FROM op.r.nodes(''./RunTimeInformation/RunTimeCountersPerThread'') x(c)',
       @Definition
   ) = 0
    THROW 52409,N'Corrected runtime-counter expression is missing.',1;

SELECT
      DeploymentPhase='PRE-CHANGE VALIDATION'
    , CaptureRunID=@CaptureRunID
    , ParserSourceLoaded='PASS'
    , ProvenBugLocated='PASS'
    , ReplacementGroupsApplied=@ReplacementCount
    , CardinalityThresholdsChanged='NO'
    , RootCauseThresholdsChanged='NO'
    , ImplicitConversionLogicChanged='NO';

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC sys.sp_executesql @Definition;

    IF OBJECT_ID(N'dbo.RCA_ExecutionPlanEvidence',N'U') IS NOT NULL
        DELETE FROM dbo.RCA_ExecutionPlanEvidence WHERE CaptureRunID=@CaptureRunID;

    EXEC dbo.usp_RCA_AnalyzeCaptureRun
         @CaptureRunID=@CaptureRunID,
         @Reparse=1;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildBlockingEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildCPUSchedulerEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildCPUSchedulerEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildIOPressureEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildIOPressureEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildTempDBPressureEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildTempDBPressureEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildMemoryPressureEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildMemoryPressureEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildTransactionLogEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildTransactionLogEvidence @CaptureRunID=@CaptureRunID;

    IF OBJECT_ID(N'dbo.usp_RCA_BuildConnectivityEvidence',N'P') IS NOT NULL
        EXEC dbo.usp_RCA_BuildConnectivityEvidence @CaptureRunID=@CaptureRunID;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_PlanOperator o
        WHERE o.CaptureRunID=@CaptureRunID
          AND REPLACE(REPLACE(ISNULL(o.TableName,N''),N'[',N''),N']',N'')=N'RCA_Run8_CPU'
    )
        THROW 52410,N'Rebuild did not recreate RCA_Run8_CPU plan operators.',1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_PlanOperator o
        WHERE o.CaptureRunID=@CaptureRunID
          AND REPLACE(REPLACE(ISNULL(o.TableName,N''),N'[',N''),N']',N'')=N'RCA_Run8_CPU'
          AND o.NodeID IN (0,1,2,3)
          AND o.EstimateActualRatio >= 100
    )
        THROW 52411,N'Validation failed: descendant-counter inflation still exists.',1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='1 - PARSER DEPLOYMENT'
    , ParserExists=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CorrectRuntimeScope=
        CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'))
                  LIKE N'%./RunTimeInformation/RunTimeCountersPerThread%'
             THEN 'PASS' ELSE 'FAIL' END
    , OldRuntimeScopeRemoved=
        CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'))
                  LIKE N'%FROM op.r.nodes(''.//RunTimeCountersPerThread'') x(c)%'
             THEN 'FAIL' ELSE 'PASS' END;

SELECT
      ValidationSection='2 - CORRECTED OPERATOR CARDINALITY'
    , o.PlanEvidenceID
    , p.EventTimeUTC
    , p.SessionID
    , o.ExecutionEvidenceID
    , o.NodeID
    , o.PhysicalOp
    , o.LogicalOp
    , o.EstimateRows
    , o.ActualRows
    , o.ActualRowsRead
    , o.ActualExecutions
    , o.EstimateActualRatio
    , o.TableName
    , o.IndexName
    , o.HasSpillWarning
    , o.HasImplicitConversion
FROM dbo.RCA_PlanOperator o
JOIN dbo.RCA_PlanEvidence p
  ON p.CaptureRunID=o.CaptureRunID
 AND p.PlanEvidenceID=o.PlanEvidenceID
WHERE o.CaptureRunID=@CaptureRunID
  AND REPLACE(REPLACE(ISNULL(o.TableName,N''),N'[',N''),N']',N'')=N'RCA_Run8_CPU'
ORDER BY p.EventTimeUTC,o.NodeID;

SELECT
      ValidationSection='3 - CARDINALITY FINDINGS'
    , f.PlanFindingID
    , f.PlanEvidenceID
    , f.ExecutionEvidenceID
    , f.Severity
    , f.FindingType
    , f.FindingText
    , f.RecommendedAction
FROM dbo.RCA_PlanFinding f
WHERE f.CaptureRunID=@CaptureRunID
  AND f.FindingType='CARDINALITY_MISMATCH'
ORDER BY f.PlanEvidenceID,f.PlanFindingID;

SELECT
      ValidationSection='4 - PLAN FINDING COUNTS'
    , FindingType
    , Severity
    , FindingCount=COUNT(*)
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
GROUP BY FindingType,Severity
ORDER BY FindingType,Severity;

SELECT
      ValidationSection='5 - CAPTURE 38 REGRESSION RESULT'
    , CaptureRunID=@CaptureRunID
    , ActualPlans=(SELECT COUNT(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID)
    , PlanOperators=(SELECT COUNT(*) FROM dbo.RCA_PlanOperator WHERE CaptureRunID=@CaptureRunID)
    , CardinalityMismatchFindings=
        (SELECT COUNT(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH')
    , HighCardinalityMismatchFindings=
        (SELECT COUNT(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH' AND Severity='HIGH')
    , LargeScanFindings=
        (SELECT COUNT(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='LARGE_SCAN')
    , ImplicitConversionFindings=
        (SELECT COUNT(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='IMPLICIT_CONVERSION')
    , StatisticsRiskFindings=
        (SELECT COUNT(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='STATISTICS_RISK')
    , Result=
        CASE
          WHEN EXISTS
          (
              SELECT 1
              FROM dbo.RCA_PlanOperator o
              WHERE o.CaptureRunID=@CaptureRunID
                AND REPLACE(REPLACE(ISNULL(o.TableName,N''),N'[',N''),N']',N'')=N'RCA_Run8_CPU'
                AND o.NodeID IN(0,1,2,3)
                AND o.EstimateActualRatio>=100
          )
          THEN 'FAIL - DESCENDANT COUNTER INFLATION REMAINS'
          ELSE 'PASS - OPERATOR-LOCAL RUNTIME COUNTERS'
        END;
GO

/* After execution, send back validation sections 2-5.
   Do not start Capture 39 yet. */
