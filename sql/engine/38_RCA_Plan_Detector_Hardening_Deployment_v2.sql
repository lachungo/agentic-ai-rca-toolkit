USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  38_RCA_Plan_Detector_Hardening_Deployment_v2.sql

  PURPOSE
  -------
  Consolidated deployment for the hardened actual-plan detector layer.

  FIXES IN THIS VERSION
  ---------------------
  v1 failed because SQL Server requires the argument supplied to XML.exist()
  to be a STRING LITERAL. v1 attempted to concatenate XQuery strings with +.

  This version:
      * contains NO ancestor:: XQuery
      * contains NO concatenated arguments inside XML.exist()
      * uses only literal SQL Server-compatible XQuery expressions
      * rebuilds the three hardened finding families as one transaction
      * validates CaptureRunID 38 afterward

  DETECTOR FAMILIES
  -----------------
      1. IMPLICIT_CONVERSION
      2. LARGE_SCAN
      3. STATISTICS_RISK
==============================================================================*/

DECLARE @CaptureRunID bigint = 38;

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 51200,N'dbo.RCA_CaptureRun does not exist.',1;

IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanStatistics',N'U') IS NULL
    THROW 51201,N'Required RCA plan-analysis tables are missing.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID
)
    THROW 51202,N'CaptureRunID 38 does not exist.',1;

SELECT
      DeploymentSection='0 - PRE-FLIGHT'
    , CaptureRunID=@CaptureRunID
    , ActualPlans=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID)
    , PlanOperators=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanOperator WHERE CaptureRunID=@CaptureRunID)
    , CardinalityMismatchFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH')
    , LargeScanFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='LARGE_SCAN')
    , ImplicitConversionFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='IMPLICIT_CONVERSION')
    , StatisticsRiskFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='STATISTICS_RISK');
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildImplicitConversionFindings
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID
      AND FindingType='IMPLICIT_CONVERSION';

    ;WITH XMLNAMESPACES
    (
        DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
    ),
    RelOps AS
    (
        SELECT
              pe.CaptureRunID
            , pe.PlanEvidenceID
            , pe.LinkedExecutionEvidenceID
            , NodeID=r.n.value('(@NodeId)[1]','int')
            , PhysicalOp=r.n.value('(@PhysicalOp)[1]','nvarchar(128)')
            , LogicalOp=r.n.value('(@LogicalOp)[1]','nvarchar(128)')
            , RelOpXML=r.n.query('.')
        FROM dbo.RCA_PlanEvidence pe
        CROSS APPLY pe.ActualExecutionPlanXML.nodes
        (
            '/ShowPlanXML/BatchSequence/Batch/Statements//RelOp'
        ) r(n)
        WHERE pe.CaptureRunID=@CaptureRunID
          AND pe.ActualExecutionPlanXML IS NOT NULL
    ),
    Classified AS
    (
        SELECT
              ro.*
            , ConversionLocation =
                CASE
                    WHEN ro.RelOpXML.exist('/RelOp/ComputeScalar/DefinedValues/DefinedValue/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'COMPUTE_SCALAR_EXPRESSION'
                    WHEN ro.RelOpXML.exist('/RelOp/Filter/Predicate/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'FILTER_PREDICATE'
                    WHEN ro.RelOpXML.exist('/RelOp/IndexScan/Predicate/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'INDEX_PREDICATE'
                    WHEN ro.RelOpXML.exist('/RelOp/IndexScan/SeekPredicates//Convert[@Implicit="1"]')=1
                    THEN 'SEEK_PREDICATE'
                    WHEN ro.RelOpXML.exist('/RelOp/NestedLoops/Predicate/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'NESTED_LOOPS_PREDICATE'
                    WHEN ro.RelOpXML.exist('/RelOp/Merge/Residual/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'MERGE_RESIDUAL'
                    WHEN ro.RelOpXML.exist('/RelOp/Hash/ProbeResidual/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'HASH_PROBE_RESIDUAL'
                    WHEN ro.RelOpXML.exist('/RelOp/Hash/BuildResidual/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'HASH_BUILD_RESIDUAL'
                    WHEN ro.RelOpXML.exist('/RelOp/StreamAggregate/DefinedValues/DefinedValue/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'STREAM_AGGREGATE_EXPRESSION'
                    WHEN ro.RelOpXML.exist('/RelOp/SequenceProject/DefinedValues/DefinedValue/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'SEQUENCE_PROJECT_EXPRESSION'
                    WHEN ro.RelOpXML.exist('/RelOp/TableValuedFunction/ParameterList/ScalarOperator//Convert[@Implicit="1"]')=1
                    THEN 'TVF_PARAMETER'
                    ELSE NULL
                END
        FROM RelOps ro
    )
    INSERT dbo.RCA_PlanFinding
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , Severity
        , FindingType
        , FindingText
        , RecommendedAction
    )
    SELECT
          c.CaptureRunID
        , c.PlanEvidenceID
        , c.LinkedExecutionEvidenceID
        , CASE
            WHEN c.ConversionLocation IN
                 ('SEEK_PREDICATE','INDEX_PREDICATE',
                  'FILTER_PREDICATE','NESTED_LOOPS_PREDICATE',
                  'MERGE_RESIDUAL','HASH_PROBE_RESIDUAL','HASH_BUILD_RESIDUAL')
              THEN 'MEDIUM'
            ELSE 'LOW'
          END
        , 'IMPLICIT_CONVERSION'
        , CONCAT
          (
              'Operator-local implicit conversion observed at ',
              COALESCE(c.PhysicalOp,'UNKNOWN'),
              ' NodeId ',
              CONVERT(varchar(20),c.NodeID),
              '. Location=',c.ConversionLocation,
              '. This finding is local to the operator and is not inherited from descendant RelOps.'
          )
        , CASE
            WHEN c.ConversionLocation IN
                 ('SEEK_PREDICATE','INDEX_PREDICATE',
                  'FILTER_PREDICATE','NESTED_LOOPS_PREDICATE',
                  'MERGE_RESIDUAL','HASH_PROBE_RESIDUAL','HASH_BUILD_RESIDUAL')
            THEN
              'Review the compared data types and predicate expression. Confirm whether the conversion affects index access, join choice, or cardinality before changing schema or parameter data types.'
            ELSE
              'Treat this as plan-expression evidence only. Do not change data types unless the conversion can be shown to affect an access path, predicate, join, cardinality estimate, or measurable cost.'
          END
    FROM Classified c
    WHERE c.ConversionLocation IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildLargeScanFindings
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID
      AND FindingType='LARGE_SCAN';

    ;WITH ScanEvidence AS
    (
        SELECT
              po.CaptureRunID
            , po.PlanEvidenceID
            , po.ExecutionEvidenceID
            , po.NodeID
            , po.PhysicalOp
            , po.LogicalOp
            , po.DatabaseName
            , po.SchemaName
            , po.TableName
            , po.IndexName
            , po.IndexKind
            , po.EstimateRows
            , po.ActualRows
            , po.ActualRowsRead
            , po.EstimateActualRatio
            , OutputReadPercent=
                CASE
                  WHEN po.ActualRowsRead>0 AND po.ActualRows IS NOT NULL
                  THEN CONVERT(decimal(19,4),
                         po.ActualRows*100.0/NULLIF(po.ActualRowsRead,0))
                END
        FROM dbo.RCA_PlanOperator po
        WHERE po.CaptureRunID=@CaptureRunID
          AND (po.PhysicalOp LIKE '%Scan%' OR po.LogicalOp LIKE '%Scan%')
          AND COALESCE(po.ActualRowsRead,po.ActualRows)>=1000000
    )
    INSERT dbo.RCA_PlanFinding
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , Severity
        , FindingType
        , FindingText
        , RecommendedAction
    )
    SELECT
          s.CaptureRunID
        , s.PlanEvidenceID
        , s.ExecutionEvidenceID
        , 'HIGH'
        , 'LARGE_SCAN'
        , CONCAT
          (
              COALESCE(s.PhysicalOp,'Scan'),
              ' read approximately ',
              CONVERT(varchar(40),CONVERT(decimal(19,0),COALESCE(s.ActualRowsRead,s.ActualRows))),
              ' row(s)',
              CASE WHEN s.TableName IS NOT NULL THEN CONCAT(' from ',s.TableName) ELSE '' END,
              CASE WHEN s.IndexName IS NOT NULL THEN CONCAT(' using ',s.IndexName) ELSE '' END,
              '. Output rows=',
              COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,0),s.ActualRows)),'UNKNOWN'),
              '; output/read=',
              COALESCE(CONVERT(varchar(40),s.OutputReadPercent),'UNKNOWN'),
              '%; estimate/actual ratio=',
              COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,4),s.EstimateActualRatio)),'UNKNOWN'),
              '.'
          )
        , 'Treat this as a large-scan observation, not proof of root cause. Review how many rows the query genuinely requires, predicate selectivity, existing indexes, optimizer missing-index evidence, and measured workload impact before changing the access path.'
    FROM ScanEvidence s;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildStatisticsRiskFindings
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID
      AND FindingType='STATISTICS_RISK';

    ;WITH RuntimeQuality AS
    (
        SELECT
              po.CaptureRunID
            , po.PlanEvidenceID
            , po.TableName
            , SevereCardinalityOperators=
                SUM
                (
                    CASE
                      WHEN po.EstimateActualRatio>=10
                        OR (po.EstimateActualRatio>0 AND po.EstimateActualRatio<=0.10)
                      THEN 1 ELSE 0
                    END
                )
            , WorstNormalizedRatio=
                MAX
                (
                    CASE
                      WHEN po.EstimateActualRatio IS NULL OR po.EstimateActualRatio=0 THEN NULL
                      WHEN po.EstimateActualRatio>=1 THEN po.EstimateActualRatio
                      ELSE 1.0/po.EstimateActualRatio
                    END
                )
        FROM dbo.RCA_PlanOperator po
        WHERE po.CaptureRunID=@CaptureRunID
          AND po.ActualRows IS NOT NULL
          AND po.EstimateRows IS NOT NULL
        GROUP BY po.CaptureRunID,po.PlanEvidenceID,po.TableName
    )
    INSERT dbo.RCA_PlanFinding
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , Severity
        , FindingType
        , FindingText
        , RecommendedAction
    )
    SELECT
          ps.CaptureRunID
        , ps.PlanEvidenceID
        , ps.ExecutionEvidenceID
        , 'MEDIUM'
        , 'STATISTICS_RISK'
        , CONCAT
          (
              'Statistics ',COALESCE(ps.StatisticsName,'[UNKNOWN]'),
              ' on ',COALESCE(ps.TableName,'[UNKNOWN]'),
              ' have metadata that warrants review AND runtime cardinality evidence shows significant estimate error. SamplingPercent=',
              COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,6),ps.SamplingPercent)),'UNKNOWN'),
              '; ModificationCount=',
              COALESCE(CONVERT(varchar(40),ps.ModificationCount),'UNKNOWN'),
              '; StatsAgeHours=',
              COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,2),ps.StatsAgeHours)),'UNKNOWN'),
              '; worst normalized estimate error=',
              COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,4),rq.WorstNormalizedRatio)),'UNKNOWN'),
              'x.'
          )
        , 'Runtime estimate error corroborates the statistics metadata. Review data distribution and histogram quality, then test a targeted statistics update in a controlled environment before production change.'
    FROM dbo.RCA_PlanStatistics ps
    JOIN RuntimeQuality rq
      ON rq.CaptureRunID=ps.CaptureRunID
     AND rq.PlanEvidenceID=ps.PlanEvidenceID
     AND REPLACE(REPLACE(ISNULL(rq.TableName,N''),N'[',N''),N']',N'')
         =
         REPLACE(REPLACE(ISNULL(ps.TableName,N''),N'[',N''),N']',N'')
    WHERE ps.CaptureRunID=@CaptureRunID
      AND rq.SevereCardinalityOperators>0
      AND
      (
           ISNULL(ps.SamplingPercent,100.0)<20.0
        OR ISNULL(ps.ModificationCount,0)>0
        OR ISNULL(ps.StatsAgeHours,0)>=168.0
      );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildHardenedPlanFindings
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC dbo.usp_RCA_BuildImplicitConversionFindings @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_BuildLargeScanFindings @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_BuildStatisticsRiskFindings @CaptureRunID=@CaptureRunID;
END;
GO

SELECT
      ValidationSection='1 - DEPLOYMENT COMPILE CHECK'
    , ImplicitConversionBuilder=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildImplicitConversionFindings',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , LargeScanBuilder=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildLargeScanFindings',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , StatisticsRiskBuilder=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildStatisticsRiskFindings',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ConsolidatedBuilder=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildHardenedPlanFindings',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

IF OBJECT_ID(N'dbo.usp_RCA_BuildImplicitConversionFindings',N'P') IS NULL
    THROW 51210,N'Implicit conversion builder did not compile.',1;
IF OBJECT_ID(N'dbo.usp_RCA_BuildLargeScanFindings',N'P') IS NULL
    THROW 51211,N'Large scan builder did not compile.',1;
IF OBJECT_ID(N'dbo.usp_RCA_BuildStatisticsRiskFindings',N'P') IS NULL
    THROW 51212,N'Statistics risk builder did not compile.',1;
IF OBJECT_ID(N'dbo.usp_RCA_BuildHardenedPlanFindings',N'P') IS NULL
    THROW 51213,N'Consolidated builder did not compile.',1;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='2 - BEFORE HARDENED REBUILD'
    , FindingType
    , Severity
    , FindingCount=COUNT_BIG(*)
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
GROUP BY FindingType,Severity
ORDER BY FindingType,Severity;
GO

DECLARE @CaptureRunID bigint=38;

BEGIN TRY
    BEGIN TRANSACTION;
    EXEC dbo.usp_RCA_BuildHardenedPlanFindings @CaptureRunID=@CaptureRunID;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='3 - AFTER HARDENED REBUILD'
    , FindingType
    , Severity
    , FindingCount=COUNT_BIG(*)
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
GROUP BY FindingType,Severity
ORDER BY FindingType,Severity;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='4 - HARDENED IMPLICIT CONVERSION FINDINGS'
    , PlanFindingID
    , PlanEvidenceID
    , ExecutionEvidenceID
    , Severity
    , FindingType
    , FindingText
    , RecommendedAction
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
  AND FindingType='IMPLICIT_CONVERSION'
ORDER BY PlanEvidenceID,PlanFindingID;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='5 - HARDENED LARGE SCAN FINDINGS'
    , PlanFindingID
    , PlanEvidenceID
    , ExecutionEvidenceID
    , Severity
    , FindingType
    , FindingText
    , RecommendedAction
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
  AND FindingType='LARGE_SCAN'
ORDER BY PlanEvidenceID,PlanFindingID;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='6 - HARDENED STATISTICS RISK FINDINGS'
    , PlanFindingID
    , PlanEvidenceID
    , ExecutionEvidenceID
    , Severity
    , FindingType
    , FindingText
    , RecommendedAction
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
  AND FindingType='STATISTICS_RISK'
ORDER BY PlanEvidenceID,PlanFindingID;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='7 - STATISTICS CONTEXT'
    , ps.PlanEvidenceID
    , ps.TableName
    , ps.StatisticsName
    , ps.ModificationCount
    , ps.SamplingPercent
    , ps.StatsAgeHours
    , RuntimeOperators=COUNT_BIG(po.PlanOperatorID)
    , BestEstimateActualRatio=MIN(po.EstimateActualRatio)
    , WorstEstimateActualRatio=MAX(po.EstimateActualRatio)
    , SevereCardinalityOperators=
        SUM(CASE WHEN po.EstimateActualRatio>=10 OR (po.EstimateActualRatio>0 AND po.EstimateActualRatio<=0.10) THEN 1 ELSE 0 END)
    , Assessment=
        CASE
          WHEN SUM(CASE WHEN po.EstimateActualRatio>=10 OR (po.EstimateActualRatio>0 AND po.EstimateActualRatio<=0.10) THEN 1 ELSE 0 END)>0
          THEN 'CARDINALITY ERROR CORROBORATES STATISTICS REVIEW'
          ELSE 'LOW SAMPLING NOT SHOWN TO BE HARMFUL'
        END
FROM dbo.RCA_PlanStatistics ps
LEFT JOIN dbo.RCA_PlanOperator po
  ON po.CaptureRunID=ps.CaptureRunID
 AND po.PlanEvidenceID=ps.PlanEvidenceID
 AND REPLACE(REPLACE(ISNULL(po.TableName,N''),N'[',N''),N']',N'')
     =
     REPLACE(REPLACE(ISNULL(ps.TableName,N''),N'[',N''),N']',N'')
 AND po.EstimateActualRatio IS NOT NULL
WHERE ps.CaptureRunID=@CaptureRunID
GROUP BY ps.PlanEvidenceID,ps.TableName,ps.StatisticsName,ps.ModificationCount,ps.SamplingPercent,ps.StatsAgeHours
ORDER BY ps.PlanEvidenceID,ps.StatisticsName;
GO

DECLARE @CaptureRunID bigint=38;

SELECT
      ValidationSection='8 - FINAL DETECTOR MATRIX'
    , CaptureRunID=@CaptureRunID
    , ActualPlans=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID)
    , PlanOperators=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanOperator WHERE CaptureRunID=@CaptureRunID)
    , CardinalityMismatchFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH')
    , LargeScanFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='LARGE_SCAN')
    , ImplicitConversionFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='IMPLICIT_CONVERSION')
    , StatisticsRiskFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='STATISTICS_RISK');
GO

DECLARE @CaptureRunID bigint=38;
DECLARE @ActualPlans bigint,@PlanOperators bigint,@Cardinality bigint,@LargeScan bigint,@Implicit bigint,@Stats bigint;

SELECT
      @ActualPlans=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanEvidence WHERE CaptureRunID=@CaptureRunID)
    , @PlanOperators=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanOperator WHERE CaptureRunID=@CaptureRunID)
    , @Cardinality=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH')
    , @LargeScan=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='LARGE_SCAN')
    , @Implicit=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='IMPLICIT_CONVERSION')
    , @Stats=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='STATISTICS_RISK');

SELECT
      ValidationSection='9 - ACCEPTANCE'
    , CaptureRunID=@CaptureRunID
    , ActualPlans=@ActualPlans
    , PlanOperators=@PlanOperators
    , CardinalityMismatchFindings=@Cardinality
    , LargeScanFindings=@LargeScan
    , ImplicitConversionFindings=@Implicit
    , StatisticsRiskFindings=@Stats
    , CardinalityRegression=CASE WHEN @Cardinality=0 THEN 'PASS' ELSE 'FAIL' END
    , LargeScanPreservation=CASE WHEN @LargeScan=4 THEN 'PASS' ELSE 'REVIEW' END
    , StatisticsHardening=CASE WHEN @Stats=0 THEN 'PASS' ELSE 'REVIEW' END
    , OverallResult=
        CASE
          WHEN @ActualPlans=7 AND @PlanOperators=28 AND @Cardinality=0 AND @LargeScan=4 AND @Stats=0
          THEN 'PASS - HARDENED DETECTOR LAYER READY FOR REVIEW'
          ELSE 'REVIEW REQUIRED - DO NOT START CAPTURE 39'
        END;
GO

SELECT
      ValidationSection='10 - SAFETY'
    , SourceXEChanged='NO'
    , ActualPlanXMLChanged='NO'
    , PlanOperatorsChanged='NO'
    , CardinalityDetectorChanged='NO'
    , RootCauseThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , NextStep='Review Sections 4-9. Do not start Capture 39 until accepted.';
GO
