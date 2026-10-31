USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
39_RCA_User_Experience_v1.sql

Purpose:
Build the DBA-facing RCA product layer over the validated engine.

Run:
    EXEC dbo.usp_RCA_UserExperience @CaptureRunID = 38;

Design:
- Observation != causation.
- No PRIMARY MEDIUM/HIGH cause => NO ROOT CAUSE CONFIRMED.
- Query text, parameters, plan XML, plan interpretation, server health,
  next actions, and incident context are surfaced in one workflow.
- Existing detector thresholds and RCA domains are not changed.
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    THROW 51300,N'dbo.RCA_CaptureRun is missing.',1;
IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL
    THROW 51301,N'dbo.RCA_ExecutionEvidence is missing.',1;
IF OBJECT_ID(N'dbo.RCA_PlanEvidence',N'U') IS NULL
    THROW 51302,N'dbo.RCA_PlanEvidence is missing.',1;
IF OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL
    THROW 51303,N'dbo.RCA_PlanOperator is missing.',1;
IF OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL
    THROW 51304,N'dbo.RCA_PlanFinding is missing.',1;
IF OBJECT_ID(N'dbo.RCA_ServerSnapshot',N'U') IS NULL
    THROW 51305,N'dbo.RCA_ServerSnapshot is missing.',1;
IF OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NULL
    THROW 51306,N'dbo.vw_RCA_FinalCauseRanking is missing.',1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_UserExperience
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@CaptureRunID)
        THROW 51310,N'Invalid CaptureRunID.',1;

    DECLARE
          @PrimaryCauseCategory varchar(100)
        , @PrimaryCauseDisplay nvarchar(256)
        , @PrimaryConfidence varchar(20)
        , @PrimaryEvidence nvarchar(max)
        , @PrimaryAction nvarchar(max)
        , @PrimaryExecutionEvidenceID bigint
        , @CaptureStatus varchar(40)
        , @StartTimeUTC datetime2
        , @EndTimeUTC datetime2;

    SELECT
          @CaptureStatus=CaptureStatus
        , @StartTimeUTC=StartTimeUTC
        , @EndTimeUTC=EndTimeUTC
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SELECT TOP (1)
          @PrimaryCauseCategory=CauseCategory
        , @PrimaryCauseDisplay=CauseDisplayName
        , @PrimaryConfidence=Confidence
        , @PrimaryEvidence=PrimaryEvidence
        , @PrimaryAction=RecommendedAction
        , @PrimaryExecutionEvidenceID=ImpactedExecutionEvidenceID
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseRole='PRIMARY'
      AND Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , EvidenceCount DESC
        , ImpactedRequestCount DESC;

    /* 1 - INCIDENT ASSESSMENT */
    ;WITH TopWorkload AS
    (
        SELECT TOP (1)
              e.ExecutionEvidenceID,e.CPUms,e.DurationMs,e.LogicalReads
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID THEN 0 ELSE 1 END
            , ISNULL(e.CPUms,0) DESC
            , ISNULL(e.LogicalReads,0) DESC
            , ISNULL(e.DurationMs,0) DESC
    )
    SELECT
          ReportSection='1 - INCIDENT ASSESSMENT'
        , Answer=CASE WHEN @PrimaryCauseCategory IS NULL
                      THEN 'NO ROOT CAUSE CONFIRMED'
                      ELSE 'ROOT CAUSE IDENTIFIED' END
        , AssessmentState=CASE WHEN @CaptureStatus='RUNNING' THEN 'PRELIMINARY' ELSE 'FINAL' END
        , PrimaryCause=COALESCE(@PrimaryCauseDisplay,N'No supported primary cause')
        , Confidence=COALESCE(@PrimaryConfidence,'N/A')
        , CaptureStatus=@CaptureStatus
        , IncidentStartUTC=@StartTimeUTC
        , IncidentEndUTC=@EndTimeUTC
        , ExecutiveSummary=
            CASE
              WHEN @PrimaryCauseCategory IS NOT NULL
              THEN CONCAT('The RCA engine identified ',@PrimaryCauseDisplay,
                          ' as the primary supported cause with ',
                          @PrimaryConfidence,' confidence. ',
                          COALESCE(@PrimaryEvidence,N''))
              ELSE CONCAT(
                   'The captured SQL Server evidence did not establish a PRIMARY root cause at MEDIUM/HIGH confidence. ',
                   'The report shows the highest-impact observed workload and actual-plan evidence without claiming causation. ',
                   CASE WHEN tw.ExecutionEvidenceID IS NOT NULL
                        THEN CONCAT('Highest observed execution consumed ',
                                    COALESCE(CONVERT(varchar(40),tw.CPUms),'0'),' ms CPU, ran ',
                                    COALESCE(CONVERT(varchar(40),tw.DurationMs),'0'),' ms, and performed ',
                                    COALESCE(CONVERT(varchar(40),tw.LogicalReads),'0'),' logical reads. ')
                        ELSE '' END,
                   'Current plan findings: ',
                   (SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='LARGE_SCAN'),
                   ' large scan(s), ',
                   (SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='IMPLICIT_CONVERSION'),
                   ' operator-local implicit conversion(s), ',
                   (SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH'),
                   ' cardinality mismatch(es), ',
                   (SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='STATISTICS_RISK'),
                   ' supported statistics-risk finding(s).')
            END
    FROM TopWorkload tw;

    /* 2 - TOP WORKLOAD / ATTRIBUTION */
    SELECT TOP (10)
          ReportSection=CASE WHEN @PrimaryExecutionEvidenceID IS NULL
                             THEN '2 - TOP WORKLOAD OBSERVED'
                             ELSE '2 - WHO / WHAT CAUSED IT?' END
        , AttributionStatus=
            CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID
                 THEN 'PRIMARY ATTRIBUTED EXECUTION'
                 WHEN @PrimaryExecutionEvidenceID IS NULL
                 THEN 'OBSERVED WORKLOAD - NOT PROVEN ROOT CAUSE'
                 ELSE 'CORRELATED WORKLOAD EVIDENCE' END
        , e.ExecutionEvidenceID,e.EventTimeUTC,e.DatabaseName,e.SessionID
        , ProcedureOrObject=e.ObjectName
        , e.HostName,e.ProgramName,e.LoginName
        , e.CPUms,e.DurationMs,e.LogicalReads,e.PhysicalReads,e.Writes,e.TotalRows
        , QueryText=e.SubmittedCommand
    FROM dbo.RCA_ExecutionEvidence e
    WHERE e.CaptureRunID=@CaptureRunID
    ORDER BY
          CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID THEN 0 ELSE 1 END
        , ISNULL(e.CPUms,0) DESC
        , ISNULL(e.LogicalReads,0) DESC
        , ISNULL(e.DurationMs,0) DESC;

    /* 3 - QUERY + PARAMETERS */
    SELECT TOP (10)
          ReportSection='3 - QUERY + PARAMETERS'
        , e.ExecutionEvidenceID,e.DatabaseName,e.SessionID
        , ProcedureOrObject=e.ObjectName
        , QueryText=e.SubmittedCommand
        , CapturedParameters=e.ParameterText
        , ParameterEvidenceStatus=COALESCE(e.ParameterEvidenceStatus,
              CASE WHEN NULLIF(LTRIM(RTRIM(e.ParameterText)),N'') IS NULL
                   THEN 'NOT CAPTURED' ELSE 'CAPTURED' END)
        , e.HostName,e.ProgramName,e.LoginName
        , QueryHash=CASE WHEN e.QueryHash IS NULL THEN NULL ELSE CONVERT(varchar(18),e.QueryHash,1) END
        , QueryPlanHash=CASE WHEN e.QueryPlanHash IS NULL THEN NULL ELSE CONVERT(varchar(18),e.QueryPlanHash,1) END
        , PlanHandle=CASE WHEN e.PlanHandle IS NULL THEN NULL ELSE CONVERT(varchar(130),e.PlanHandle,1) END
    FROM dbo.RCA_ExecutionEvidence e
    WHERE e.CaptureRunID=@CaptureRunID
    ORDER BY
          CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID THEN 0 ELSE 1 END
        , ISNULL(e.CPUms,0) DESC
        , ISNULL(e.LogicalReads,0) DESC
        , ISNULL(e.DurationMs,0) DESC;

    /* 4 - ACTUAL EXECUTION PLAN */
    ;WITH RankedExecution AS
    (
        SELECT e.*,
               rn=ROW_NUMBER() OVER
               (ORDER BY CASE WHEN e.ExecutionEvidenceID=@PrimaryExecutionEvidenceID THEN 0 ELSE 1 END,
                         ISNULL(e.CPUms,0) DESC,
                         ISNULL(e.LogicalReads,0) DESC,
                         ISNULL(e.DurationMs,0) DESC)
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
    )
    SELECT TOP (10)
          ReportSection='4 - ACTUAL EXECUTION PLAN'
        , e.ExecutionEvidenceID,e.DatabaseName,e.SessionID
        , ProcedureOrObject=e.ObjectName
        , e.CPUms,e.DurationMs,e.LogicalReads
        , PlanEvidenceID=ap.PlanEvidenceID
        , PlanAvailability=CASE WHEN ap.ActualExecutionPlanXML IS NOT NULL
                                THEN 'ACTUAL SHOWPLAN CAPTURED - CLICK XML IN SSMS'
                                ELSE 'NO DEFENSIBLY CORRELATED ACTUAL PLAN' END
        , PlanSource=COALESCE(ap.CorrelationMethod,'NOT_AVAILABLE')
        , ActualExecutionPlanXML=ap.ActualExecutionPlanXML
        , ImportantNote=CASE
              WHEN ap.CorrelationMethod='ACTUAL_SHOWPLAN_XE_DIRECT_LINK'
                THEN 'Actual-showplan XML was directly linked to this execution.'
              WHEN ap.CorrelationMethod='ACTUAL_SHOWPLAN_XE_STRICT_CORRELATION'
                THEN 'Actual-showplan XML was correlated using run, database, session, SQL text and event timestamp.'
              ELSE 'No actual plan can be responsibly attributed to this execution.' END
    FROM RankedExecution e
    OUTER APPLY
    (
        SELECT TOP (1)
              p.PlanEvidenceID,p.ActualExecutionPlanXML
            , CorrelationMethod=CASE WHEN p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID
                                     THEN 'ACTUAL_SHOWPLAN_XE_DIRECT_LINK'
                                     ELSE 'ACTUAL_SHOWPLAN_XE_STRICT_CORRELATION' END
        FROM dbo.RCA_PlanEvidence p
        WHERE p.CaptureRunID=e.CaptureRunID
          AND p.ActualExecutionPlanXML IS NOT NULL
          AND
          (
              p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID
              OR
              (
                  p.LinkedExecutionEvidenceID IS NULL
                  AND p.SessionID=e.SessionID
                  AND ISNULL(p.DatabaseName,N'')=ISNULL(e.DatabaseName,N'')
                  AND NULLIF(LTRIM(RTRIM(p.SQLText)),N'')=NULLIF(LTRIM(RTRIM(e.SubmittedCommand)),N'')
                  AND ABS(DATEDIFF_BIG(millisecond,p.EventTimeUTC,e.EventTimeUTC))<=100
              )
          )
        ORDER BY CASE WHEN p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID THEN 0 ELSE 1 END,
                 ABS(DATEDIFF_BIG(millisecond,p.EventTimeUTC,e.EventTimeUTC)),
                 p.PlanEvidenceID DESC
    ) ap
    ORDER BY e.rn;

    /* 5 - HUMAN PLAN INTERPRETATION */
    ;WITH OpSummary AS
    (
        SELECT
              o.PlanEvidenceID
            , MaxRowsRead=MAX(CASE WHEN o.PhysicalOp LIKE '%Scan%' OR o.LogicalOp LIKE '%Scan%'
                                   THEN COALESCE(o.ActualRowsRead,o.ActualRows) END)
            , MaxRowsOutput=MAX(CASE WHEN o.PhysicalOp LIKE '%Scan%' OR o.LogicalOp LIKE '%Scan%'
                                     THEN o.ActualRows END)
            , SpillOperators=SUM(CASE WHEN o.HasSpillWarning=1 THEN 1 ELSE 0 END)
            , WorstNormalizedEstimateError=MAX(CASE
                    WHEN o.EstimateActualRatio IS NULL OR o.EstimateActualRatio=0 THEN NULL
                    WHEN o.EstimateActualRatio>=1 THEN o.EstimateActualRatio
                    ELSE 1.0/o.EstimateActualRatio END)
        FROM dbo.RCA_PlanOperator o
        WHERE o.CaptureRunID=@CaptureRunID
        GROUP BY o.PlanEvidenceID
    ),
    Findings AS
    (
        SELECT PlanEvidenceID,
               LargeScans=SUM(CASE WHEN FindingType='LARGE_SCAN' THEN 1 ELSE 0 END),
               Conversions=SUM(CASE WHEN FindingType='IMPLICIT_CONVERSION' THEN 1 ELSE 0 END),
               Cardinality=SUM(CASE WHEN FindingType='CARDINALITY_MISMATCH' THEN 1 ELSE 0 END),
               Stats=SUM(CASE WHEN FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
        GROUP BY PlanEvidenceID
    )
    SELECT
          ReportSection='5 - WHAT DID THE EXECUTION PLAN SHOW?'
        , p.PlanEvidenceID,p.EventTimeUTC,p.SessionID,p.DatabaseName
        , LargeScanFindings=ISNULL(f.LargeScans,0)
        , ImplicitConversionFindings=ISNULL(f.Conversions,0)
        , CardinalityMismatchFindings=ISNULL(f.Cardinality,0)
        , StatisticsRiskFindings=ISNULL(f.Stats,0)
        , SpillOperatorCount=ISNULL(o.SpillOperators,0)
        , o.MaxRowsRead,o.MaxRowsOutput
        , OutputVsReadPercent=CASE WHEN ISNULL(o.MaxRowsRead,0)>0 AND o.MaxRowsOutput IS NOT NULL
                                   THEN CONVERT(decimal(19,4),o.MaxRowsOutput*100.0/NULLIF(o.MaxRowsRead,0)) END
        , o.WorstNormalizedEstimateError
        , PlanInterpretation=CONCAT(
              CASE WHEN ISNULL(f.LargeScans,0)>0
                   THEN CONCAT('Large scan observed: approximately ',
                               COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,0),o.MaxRowsRead)),'UNKNOWN'),
                               ' rows read and ',
                               COALESCE(CONVERT(varchar(40),CONVERT(decimal(19,0),o.MaxRowsOutput)),'UNKNOWN'),
                               ' rows output. ')
                   ELSE 'No large-scan finding was emitted. ' END,
              CASE WHEN ISNULL(f.Cardinality,0)=0
                   THEN 'No supported cardinality-mismatch finding. '
                   ELSE CONCAT(f.Cardinality,' cardinality-mismatch finding(s). ') END,
              CASE WHEN ISNULL(f.Stats,0)=0
                   THEN 'Statistics were not supported as a harmful cause. '
                   ELSE CONCAT(f.Stats,' supported statistics-risk finding(s). ') END,
              CASE WHEN ISNULL(f.Conversions,0)>0
                   THEN CONCAT(f.Conversions,' operator-local implicit-conversion observation(s). ')
                   ELSE 'No operator-local implicit-conversion finding. ' END,
              CASE WHEN ISNULL(o.SpillOperators,0)>0
                   THEN CONCAT(o.SpillOperators,' operator(s) showed spill evidence.')
                   ELSE 'No spill warning was observed.' END)
    FROM dbo.RCA_PlanEvidence p
    LEFT JOIN OpSummary o ON o.PlanEvidenceID=p.PlanEvidenceID
    LEFT JOIN Findings f ON f.PlanEvidenceID=p.PlanEvidenceID
    WHERE p.CaptureRunID=@CaptureRunID
      AND p.ActualExecutionPlanXML IS NOT NULL
    ORDER BY p.EventTimeUTC,p.PlanEvidenceID;

    /* 6 - WHY DO WE BELIEVE THIS? */
    SELECT
          ReportSection='6 - WHY DO WE BELIEVE THIS?'
        , Confidence=COALESCE(@PrimaryConfidence,'N/A')
        , PrimaryEvidence=COALESCE(@PrimaryEvidence,N'No PRIMARY MEDIUM/HIGH-confidence root-cause evidence was established.')
        , EvidenceIntegrity=CASE WHEN @PrimaryCauseCategory IS NULL
                                THEN 'The utility intentionally did not manufacture a root cause.'
                                ELSE 'The conclusion comes from the validated RCA final-cause ranking.' END
        , CardinalityMismatchFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='CARDINALITY_MISMATCH')
        , LargeScanFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='LARGE_SCAN')
        , ImplicitConversionFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='IMPLICIT_CONVERSION')
        , StatisticsRiskFindings=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanFinding WHERE CaptureRunID=@CaptureRunID AND FindingType='STATISTICS_RISK');

    /* 7 - SERVER HEALTH */
    IF EXISTS (SELECT 1 FROM dbo.RCA_ServerSnapshot WHERE CaptureRunID=@CaptureRunID)
    BEGIN
        SELECT
              ReportSection='7 - SERVER HEALTH DURING INCIDENT'
            , ServerSamples=COUNT_BIG(*)
            , FirstSampleUTC=MIN(CaptureTimeUTC)
            , LastSampleUTC=MAX(CaptureTimeUTC)
            , PeakSqlCpuPercent=MAX(SqlCpuPercent)
            , AvgSqlCpuPercent=CONVERT(decimal(9,2),AVG(SqlCpuPercent))
            , PeakOtherCpuPercent=MAX(OtherCpuPercent)
            , LowestSystemIdlePercent=MIN(SystemIdlePercent)
            , PeakRunnableTasks=MAX(RunnableTasks)
            , LowestBufferCacheHitRatio=MIN(BufferCacheHitRatio)
            , AvgBufferCacheHitRatio=CONVERT(decimal(19,6),AVG(BufferCacheHitRatio))
            , LowestPLESeconds=MIN(PageLifeExpectancySeconds)
            , LowestAvailablePhysicalMemoryMB=MIN(AvailablePhysicalMemoryMB)
            , PeakMemoryGrantsPending=MAX(MemoryGrantsPending)
            , PeakMemoryGrantsOutstanding=MAX(MemoryGrantsOutstanding)
            , MinTotalServerMemoryMB=MIN(TotalServerMemoryMB)
            , MaxTargetServerMemoryMB=MAX(TargetServerMemoryMB)
            , ServerMaxDOP=MAX(ServerMaxDOP)
            , CostThresholdForParallelism=MAX(CostThresholdForParallelism)
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID=@CaptureRunID;
    END
    ELSE
    BEGIN
        SELECT ReportSection='7 - SERVER HEALTH DURING INCIDENT',
               EvidenceStatus='NO SERVER SNAPSHOTS',
               Meaning='CPU, scheduler, memory, Buffer Cache Hit Ratio, PLE and memory-grant health cannot be inferred.';
    END;

    /* 8 - WHAT SHOULD I DO? */
    ;WITH C AS
    (
        SELECT
              LargeScans=SUM(CASE WHEN FindingType='LARGE_SCAN' THEN 1 ELSE 0 END)
            , Conversions=SUM(CASE WHEN FindingType='IMPLICIT_CONVERSION' THEN 1 ELSE 0 END)
            , Stats=SUM(CASE WHEN FindingType='STATISTICS_RISK' THEN 1 ELSE 0 END)
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
    )
    SELECT
          ReportSection='8 - WHAT SHOULD I DO?'
        , Priority1=CASE
              WHEN @PrimaryCauseCategory IS NOT NULL
                THEN COALESCE(@PrimaryAction,N'Review the attributed workload and evidence.')
              WHEN ISNULL(c.LargeScans,0)>0
                THEN 'Review the highest-impact captured query and its business requirement. Validate whether the large scan is expected for the amount of data requested, then review indexing and predicate selectivity.'
              ELSE 'Correlate the user-reported slowdown with application/network evidence or repeat the RCA during active impact.' END
        , Priority2=CASE
              WHEN ISNULL(c.Conversions,0)>0
                THEN 'Inspect the operator-local implicit conversions. Change parameter or column data types only if a conversion is shown to affect predicates, joins, seeks, cardinality, or measurable cost.'
              ELSE 'Review the actual execution plans for repeated access-path or memory-grant inefficiency.' END
        , Priority3=CASE
              WHEN ISNULL(c.Stats,0)=0
                THEN 'Do not update statistics solely because the sampling percentage is low when runtime estimates are accurate.'
              ELSE 'Where statistics risk is corroborated by runtime estimate error, test a targeted statistics update in a controlled environment.' END
        , DoNotChangeYet=CASE
              WHEN @PrimaryCauseCategory IS NULL
                THEN 'Do not make a server-wide SQL configuration change, kill sessions, add RAM, change MAXDOP, rebuild statistics, or create an index solely from this capture.'
              ELSE 'Do not apply corrective changes until the attributed workload, business impact, and rollback risk are confirmed.' END
        , SafetyNote='Observation is not causation. Validate the business workload before production change.'
    FROM C c;

    /* 9 - PLAN FINDINGS */
    SELECT
          ReportSection='9 - PLAN FINDINGS'
        , pf.PlanFindingID,pf.PlanEvidenceID,pf.ExecutionEvidenceID
        , pf.Severity,pf.FindingType,pf.FindingText,pf.RecommendedAction
    FROM dbo.RCA_PlanFinding pf
    WHERE pf.CaptureRunID=@CaptureRunID
    ORDER BY CASE pf.Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,
             pf.FindingType,pf.PlanEvidenceID,pf.PlanFindingID;

    /* 10 - INCIDENT CONTEXT */
    IF OBJECT_ID(N'dbo.RCA_IncidentContext',N'U') IS NOT NULL
    BEGIN
        SELECT
              ReportSection='10 - INCIDENT CONTEXT'
            , r.CaptureRunID
            , RequestedDatabaseName=COALESCE(c.RequestedDatabaseName,N'ALL DATABASES')
            , c.IncidentDescription,c.RequestedBy,c.StartedFromHost,c.StartedFromProgram
            , r.StartTimeUTC,r.EndTimeUTC,r.CaptureStatus
            , CaptureDurationSeconds=DATEDIFF(second,r.StartTimeUTC,COALESCE(r.EndTimeUTC,SYSUTCDATETIME()))
            , ExecutionEvidenceRows=(SELECT COUNT_BIG(*) FROM dbo.RCA_ExecutionEvidence e WHERE e.CaptureRunID=r.CaptureRunID)
            , ActualShowplanRows=(SELECT COUNT_BIG(*) FROM dbo.RCA_PlanEvidence p WHERE p.CaptureRunID=r.CaptureRunID AND p.ActualExecutionPlanXML IS NOT NULL)
        FROM dbo.RCA_CaptureRun r
        LEFT JOIN dbo.RCA_IncidentContext c ON c.CaptureRunID=r.CaptureRunID
        WHERE r.CaptureRunID=@CaptureRunID;
    END
    ELSE
    BEGIN
        SELECT ReportSection='10 - INCIDENT CONTEXT',
               r.CaptureRunID,r.StartTimeUTC,r.EndTimeUTC,r.CaptureStatus,
               CaptureDurationSeconds=DATEDIFF(second,r.StartTimeUTC,COALESCE(r.EndTimeUTC,SYSUTCDATETIME()))
        FROM dbo.RCA_CaptureRun r
        WHERE r.CaptureRunID=@CaptureRunID;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowMeWhyItWasSlow
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RCA_UserExperience @CaptureRunID=@CaptureRunID;
END;
GO

SELECT
      ValidationSection='1 - USER EXPERIENCE DEPLOYMENT'
    , UserExperience=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_UserExperience',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ShowMeWhyItWasSlow',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

EXEC dbo.usp_RCA_UserExperience @CaptureRunID=38;
GO
