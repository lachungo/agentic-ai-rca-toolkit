USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  37_RCA_Plan_Detector_Validation_v2.sql

  PURPOSE
  -------
  READ-ONLY validation of the three remaining plan-finding families after the
  cardinality parser repair:

      1. IMPLICIT_CONVERSION
      2. LARGE_SCAN
      3. STATISTICS_RISK

  TEST FIXTURE
  ------------
  CaptureRunID 38

  WHY THIS EXISTS
  ---------------
  Capture 38 is now a reliable regression fixture:
      - actual Showplan capture works
      - execution -> actual plan correlation works
      - operator runtime counters are now operator-local
      - false 201x/202x/203x cardinality findings are gone

  This script does NOT alter:
      - dbo.usp_RCA_ParseCaptureRun
      - any detector threshold
      - any RCA domain
      - any evidence table
      - any finding row

  The goal is to determine which remaining findings are genuinely supported
  before we harden the detector logic.
==============================================================================*/

DECLARE @CaptureRunID bigint = 38;

-------------------------------------------------------------------------------
-- 0. PREREQUISITES
-------------------------------------------------------------------------------
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID
)
    THROW 52500,N'CaptureRunID 38 does not exist.',1;

IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
 OR OBJECT_ID(N'dbo.RCA_PlanStatistics',N'U') IS NULL
    THROW 52501,N'Required RCA plan-analysis tables are missing.',1;

-------------------------------------------------------------------------------
-- 1. BASELINE FINDING COUNTS
-------------------------------------------------------------------------------
SELECT
      ValidationSection='1 - CURRENT PLAN FINDING COUNTS'
    , FindingType
    , Severity
    , FindingCount=COUNT(*)
FROM dbo.RCA_PlanFinding
WHERE CaptureRunID=@CaptureRunID
GROUP BY FindingType,Severity
ORDER BY FindingType,Severity;

-------------------------------------------------------------------------------
-- 2. ACTUAL PLAN INVENTORY
-------------------------------------------------------------------------------
SELECT
      ValidationSection='2 - ACTUAL PLAN INVENTORY'
    , pe.PlanEvidenceID
    , pe.LinkedExecutionEvidenceID
    , pe.EventTimeUTC
    , pe.DatabaseName
    , pe.SessionID
    , pe.RequestedMemoryKB
    , pe.GrantedMemoryKB
    , pe.MaxUsedMemoryKB
    , pe.ActualDOP
    , QueryHash=CASE WHEN pe.QueryHash IS NULL THEN NULL
                     ELSE CONVERT(varchar(18),pe.QueryHash,1) END
    , QueryPlanHash=CASE WHEN pe.QueryPlanHash IS NULL THEN NULL
                         ELSE CONVERT(varchar(18),pe.QueryPlanHash,1) END
    , SQLText=pe.SQLText
FROM dbo.RCA_PlanEvidence pe
WHERE pe.CaptureRunID=@CaptureRunID
ORDER BY pe.EventTimeUTC,pe.PlanEvidenceID;

-------------------------------------------------------------------------------
-- 3. IMPLICIT CONVERSION - SQL SERVER COMPATIBLE XML INSPECTION
--
-- SQL Server XQuery does not support the XPath ancestor:: axis.
-- Iterate each RelOp first, then inspect implicit Convert nodes in its subtree.
--
-- IMPORTANT:
-- A parent RelOp can contain child RelOps, so this section is diagnostic.
-- Section 4 compares these XML observations with the persisted parser flags.
-------------------------------------------------------------------------------
;WITH XMLNAMESPACES
(
    DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
)
SELECT
      ValidationSection='3 - IMPLICIT CONVERSION XML OBSERVATIONS'
    , pe.PlanEvidenceID
    , pe.EventTimeUTC
    , pe.SessionID
    , RelOpNodeID=r.n.value('@NodeId','int')
    , PhysicalOp=r.n.value('@PhysicalOp','nvarchar(128)')
    , LogicalOp=r.n.value('@LogicalOp','nvarchar(128)')
    , ImplicitConvertCount=COUNT_BIG(*)
FROM dbo.RCA_PlanEvidence pe
CROSS APPLY pe.ActualExecutionPlanXML.nodes
(
    '/ShowPlanXML/BatchSequence/Batch/Statements//RelOp'
) r(n)
CROSS APPLY r.n.nodes
(
    './/ScalarOperator/Convert[@Implicit="1"]'
) c(n)
WHERE pe.CaptureRunID=@CaptureRunID
GROUP BY
      pe.PlanEvidenceID
    , pe.EventTimeUTC
    , pe.SessionID
    , r.n.value('@NodeId','int')
    , r.n.value('@PhysicalOp','nvarchar(128)')
    , r.n.value('@LogicalOp','nvarchar(128)')
ORDER BY pe.PlanEvidenceID,RelOpNodeID;

-------------------------------------------------------------------------------
-- 4. IMPLICIT CONVERSION - PERSISTED PARSER FLAGS AND FINDINGS
--
-- This deliberately avoids making a new root-cause claim.  It shows exactly
-- what the current parser persisted and what finding rows were emitted.
-------------------------------------------------------------------------------
SELECT
      ValidationSection='4A - PERSISTED IMPLICIT CONVERSION OPERATOR FLAGS'
    , o.PlanEvidenceID
    , o.ExecutionEvidenceID
    , o.NodeID
    , o.PhysicalOp
    , o.LogicalOp
    , o.DatabaseName
    , o.SchemaName
    , o.TableName
    , o.IndexName
    , o.HasImplicitConversion
FROM dbo.RCA_PlanOperator o
WHERE o.CaptureRunID=@CaptureRunID
  AND o.HasImplicitConversion=1
ORDER BY o.PlanEvidenceID,o.NodeID;

SELECT
      ValidationSection='4B - PERSISTED IMPLICIT CONVERSION FINDINGS'
    , f.PlanFindingID
    , f.PlanEvidenceID
    , f.ExecutionEvidenceID
    , f.Severity
    , f.FindingType
    , f.FindingText
    , f.RecommendedAction
FROM dbo.RCA_PlanFinding f
WHERE f.CaptureRunID=@CaptureRunID
  AND f.FindingType='IMPLICIT_CONVERSION'
ORDER BY f.PlanEvidenceID,f.PlanFindingID;

-------------------------------------------------------------------------------
-- 5. IMPLICIT CONVERSION - SUMMARY
-------------------------------------------------------------------------------
SELECT
      ValidationSection='5 - IMPLICIT CONVERSION SUMMARY'
    , CurrentFlaggedOperators=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanOperator
            WHERE CaptureRunID=@CaptureRunID
              AND HasImplicitConversion=1
        )
    , CurrentFindingRows=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding
            WHERE CaptureRunID=@CaptureRunID
              AND FindingType='IMPLICIT_CONVERSION'
        )
    , Interpretation=
        'VALIDATE XML OBSERVATIONS AGAINST PERSISTED FLAGS BEFORE CHANGING DETECTOR LOGIC';

-------------------------------------------------------------------------------
-- 6. LARGE SCAN - RAW OPERATOR EVIDENCE
-------------------------------------------------------------------------------
SELECT
      ValidationSection='6 - LARGE SCAN RAW EVIDENCE'
    , o.PlanEvidenceID
    , pe.EventTimeUTC
    , pe.SessionID
    , o.NodeID
    , o.PhysicalOp
    , o.LogicalOp
    , o.DatabaseName
    , o.SchemaName
    , o.TableName
    , o.IndexName
    , o.IndexKind
    , o.EstimateRows
    , o.ActualRows
    , o.ActualRowsRead
    , OutputVsRowsReadPercent =
        CASE
          WHEN COALESCE(o.ActualRowsRead,0)>0
           AND o.ActualRows IS NOT NULL
          THEN CONVERT(decimal(19,4),
               (o.ActualRows*100.0)/NULLIF(o.ActualRowsRead,0))
        END
    , RowsDiscarded =
        CASE
          WHEN o.ActualRowsRead IS NOT NULL AND o.ActualRows IS NOT NULL
          THEN o.ActualRowsRead-o.ActualRows
        END
    , EstimateActualRatio=o.EstimateActualRatio
FROM dbo.RCA_PlanOperator o
JOIN dbo.RCA_PlanEvidence pe
  ON pe.CaptureRunID=o.CaptureRunID
 AND pe.PlanEvidenceID=o.PlanEvidenceID
WHERE o.CaptureRunID=@CaptureRunID
  AND o.PhysicalOp LIKE '%Scan%'
  AND COALESCE(o.ActualRowsRead,o.ActualRows)>=100000
ORDER BY pe.EventTimeUTC,o.PlanEvidenceID,o.NodeID;

-------------------------------------------------------------------------------
-- 7. LARGE SCAN - DEDUPLICATE REPEATED PLAN OBSERVATIONS
--
-- Four findings can be four executions of the same workload, not four
-- independent root causes.
-------------------------------------------------------------------------------
SELECT
      ValidationSection='7 - LARGE SCAN WORKLOAD PATTERN'
    , DatabaseName
    , SchemaName
    , TableName
    , IndexName
    , PhysicalOp
    , DistinctActualPlans=COUNT(DISTINCT PlanEvidenceID)
    , MinRowsRead=MIN(ActualRowsRead)
    , MaxRowsRead=MAX(ActualRowsRead)
    , AvgRowsRead=CONVERT(decimal(38,2),AVG(CONVERT(decimal(38,2),ActualRowsRead)))
    , MinOutputRows=MIN(ActualRows)
    , MaxOutputRows=MAX(ActualRows)
    , MinEstimateActualRatio=MIN(EstimateActualRatio)
    , MaxEstimateActualRatio=MAX(EstimateActualRatio)
FROM dbo.RCA_PlanOperator
WHERE CaptureRunID=@CaptureRunID
  AND PhysicalOp LIKE '%Scan%'
  AND COALESCE(ActualRowsRead,ActualRows)>=100000
GROUP BY
      DatabaseName
    , SchemaName
    , TableName
    , IndexName
    , PhysicalOp
ORDER BY TableName,IndexName;

-------------------------------------------------------------------------------
-- 8. MISSING-INDEX RECOMMENDATIONS PRESENT IN ACTUAL SHOWPLAN
--
-- This is evidence only. It is not an instruction to create an index.
-------------------------------------------------------------------------------
;WITH XMLNAMESPACES
(
    DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
)
SELECT
      ValidationSection='8 - OPTIMIZER MISSING INDEX EVIDENCE'
    , pe.PlanEvidenceID
    , pe.EventTimeUTC
    , pe.SessionID
    , ImpactPercent =
        TRY_CONVERT(decimal(19,4),
            mig.g.value('@Impact','nvarchar(50)'))
    , DatabaseName =
        mi.i.value('@Database','nvarchar(256)')
    , SchemaName =
        mi.i.value('@Schema','nvarchar(256)')
    , TableName =
        mi.i.value('@Table','nvarchar(512)')
    , EqualityColumns =
        STUFF
        (
            (
                SELECT N', ' + cg.c.value('@Name','nvarchar(256)')
                FROM mi.i.nodes('ColumnGroup[@Usage="EQUALITY"]/Column') cg(c)
                FOR XML PATH(''),TYPE
            ).value('.','nvarchar(max)'),
            1,2,N''
        )
    , InequalityColumns =
        STUFF
        (
            (
                SELECT N', ' + cg.c.value('@Name','nvarchar(256)')
                FROM mi.i.nodes('ColumnGroup[@Usage="INEQUALITY"]/Column') cg(c)
                FOR XML PATH(''),TYPE
            ).value('.','nvarchar(max)'),
            1,2,N''
        )
    , IncludeColumns =
        STUFF
        (
            (
                SELECT N', ' + cg.c.value('@Name','nvarchar(256)')
                FROM mi.i.nodes('ColumnGroup[@Usage="INCLUDE"]/Column') cg(c)
                FOR XML PATH(''),TYPE
            ).value('.','nvarchar(max)'),
            1,2,N''
        )
FROM dbo.RCA_PlanEvidence pe
CROSS APPLY pe.ActualExecutionPlanXML.nodes('//MissingIndexes/MissingIndexGroup') mig(g)
CROSS APPLY mig.g.nodes('MissingIndex') mi(i)
WHERE pe.CaptureRunID=@CaptureRunID
ORDER BY pe.PlanEvidenceID,ImpactPercent DESC;

-------------------------------------------------------------------------------
-- 9. STATISTICS RISK - RAW EVIDENCE + OBSERVED ESTIMATE QUALITY
--
-- Low sampling alone is not proof that the statistic harmed this execution.
-- Correlate statistics metadata with the actual estimate quality seen on the
-- table/index operators in the same plan.
-------------------------------------------------------------------------------
;WITH Stats AS
(
    SELECT
          s.PlanStatisticsID
        , s.PlanEvidenceID
        , s.ExecutionEvidenceID
        , s.DatabaseName
        , s.SchemaName
        , s.TableName
        , s.StatisticsName
        , s.LastUpdate
        , s.ModificationCount
        , s.SamplingPercent
        , s.StatsAgeHours
    FROM dbo.RCA_PlanStatistics s
    WHERE s.CaptureRunID=@CaptureRunID
),
OperatorQuality AS
(
    SELECT
          o.PlanEvidenceID
        , o.TableName
        , BestRatio=
            MIN(CASE
                  WHEN o.EstimateActualRatio IS NULL THEN NULL
                  WHEN o.EstimateActualRatio>=1
                    THEN o.EstimateActualRatio
                  ELSE 1.0/NULLIF(o.EstimateActualRatio,0)
                END)
        , WorstRatio=
            MAX(CASE
                  WHEN o.EstimateActualRatio IS NULL THEN NULL
                  WHEN o.EstimateActualRatio>=1
                    THEN o.EstimateActualRatio
                  ELSE 1.0/NULLIF(o.EstimateActualRatio,0)
                END)
        , OperatorsWithRuntime=COUNT(CASE WHEN o.ActualRows IS NOT NULL THEN 1 END)
    FROM dbo.RCA_PlanOperator o
    WHERE o.CaptureRunID=@CaptureRunID
    GROUP BY o.PlanEvidenceID,o.TableName
)
SELECT
      ValidationSection='9 - STATISTICS RISK CONTEXT'
    , s.PlanEvidenceID
    , s.DatabaseName
    , s.SchemaName
    , s.TableName
    , s.StatisticsName
    , s.LastUpdate
    , s.ModificationCount
    , s.SamplingPercent
    , s.StatsAgeHours
    , q.OperatorsWithRuntime
    , q.BestRatio
    , q.WorstRatio
    , EvidenceAssessment=
        CASE
          WHEN q.WorstRatio IS NULL
            THEN 'INSUFFICIENT RUNTIME CARDINALITY EVIDENCE'
          WHEN q.WorstRatio < 2
            THEN 'ESTIMATES ACCURATE; LOW SAMPLING NOT SHOWN TO BE HARMFUL'
          WHEN q.WorstRatio < 10
            THEN 'SOME ESTIMATE ERROR; STATISTICS MAY BE CONTRIBUTING'
          ELSE
            'LARGE ESTIMATE ERROR; STATISTICS DESERVE STRONGER REVIEW'
        END
FROM Stats s
LEFT JOIN OperatorQuality q
  ON q.PlanEvidenceID=s.PlanEvidenceID
 AND
 (
      REPLACE(REPLACE(ISNULL(q.TableName,N''),N'[',N''),N']',N'')
      =
      REPLACE(REPLACE(ISNULL(s.TableName,N''),N'[',N''),N']',N'')
 )
ORDER BY s.PlanEvidenceID,s.StatisticsName;

-------------------------------------------------------------------------------
-- 10. STATISTICS FINDINGS VS ACTUAL ESTIMATE QUALITY
-------------------------------------------------------------------------------
SELECT
      ValidationSection='10 - CURRENT STATISTICS FINDINGS'
    , f.PlanFindingID
    , f.PlanEvidenceID
    , f.ExecutionEvidenceID
    , f.Severity
    , f.FindingText
    , f.RecommendedAction
FROM dbo.RCA_PlanFinding f
WHERE f.CaptureRunID=@CaptureRunID
  AND f.FindingType='STATISTICS_RISK'
ORDER BY f.PlanEvidenceID,f.PlanFindingID;

-------------------------------------------------------------------------------
-- 11. CAPTURE 38 DETECTOR REGRESSION SUMMARY
--
-- SQL Server-compatible summary.  No unsupported ancestor:: XQuery is used.
-------------------------------------------------------------------------------
SELECT
      ValidationSection='11 - CAPTURE 38 DETECTOR REGRESSION'
    , CaptureRunID=@CaptureRunID
    , ActualPlans=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanEvidence
            WHERE CaptureRunID=@CaptureRunID
        )
    , PlanOperators=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanOperator
            WHERE CaptureRunID=@CaptureRunID
        )
    , CardinalityMismatchFindings=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding
            WHERE CaptureRunID=@CaptureRunID
              AND FindingType='CARDINALITY_MISMATCH'
        )
    , LargeScanFindings=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding
            WHERE CaptureRunID=@CaptureRunID
              AND FindingType='LARGE_SCAN'
        )
    , ImplicitConversionFindings=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding
            WHERE CaptureRunID=@CaptureRunID
              AND FindingType='IMPLICIT_CONVERSION'
        )
    , StatisticsRiskFindings=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding
            WHERE CaptureRunID=@CaptureRunID
              AND FindingType='STATISTICS_RISK'
        )
    , Result=
        CASE
          WHEN
              (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence
               WHERE CaptureRunID=@CaptureRunID)=7
          AND (SELECT COUNT(*) FROM dbo.RCA_PlanOperator
               WHERE CaptureRunID=@CaptureRunID)=28
          AND (SELECT COUNT(*) FROM dbo.RCA_PlanFinding
               WHERE CaptureRunID=@CaptureRunID
                 AND FindingType='CARDINALITY_MISMATCH')=0
          AND (SELECT COUNT(*) FROM dbo.RCA_PlanFinding
               WHERE CaptureRunID=@CaptureRunID
                 AND FindingType='LARGE_SCAN')=4
          AND (SELECT COUNT(*) FROM dbo.RCA_PlanFinding
               WHERE CaptureRunID=@CaptureRunID
                 AND FindingType='IMPLICIT_CONVERSION')=14
          AND (SELECT COUNT(*) FROM dbo.RCA_PlanFinding
               WHERE CaptureRunID=@CaptureRunID
                 AND FindingType='STATISTICS_RISK')=4
          THEN 'PASS - CAPTURE 38 BASELINE COUNTS PRESERVED'
          ELSE 'REVIEW - ONE OR MORE CAPTURE 38 BASELINE COUNTS CHANGED'
        END;

-------------------------------------------------------------------------------
-- 12. SAFETY CONFIRMATION
-------------------------------------------------------------------------------
SELECT
      ValidationSection='12 - SAFETY'
    , CaptureRunID=@CaptureRunID
    , DataModified='NO'
    , ProceduresAltered='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , NextStep='Use these results to build one consolidated detector-hardening deployment; do not start Capture 39 yet.';
GO
