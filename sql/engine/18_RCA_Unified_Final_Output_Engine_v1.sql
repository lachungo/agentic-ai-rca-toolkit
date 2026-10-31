USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
18_RCA_Unified_Final_Output_Engine_v1.sql

PURPOSE
-------
Create a unified, human-readable RCA output layer over the evidence and
detectors already validated in this lab.

NO COLLECTOR CHANGES.
NO XE CHANGES.
NO SQL AGENT CHANGES.
NO EXISTING DETECTOR CHANGES.

INPUTS ALREADY PROVEN
---------------------
- Parameter-sensitive plan evidence
- Statistics / cardinality evidence
- Memory grant / spill evidence
- Blocking / wait-chain evidence
- Existing root-cause synthesis
- Existing execution / plan evidence
- Existing server snapshots

OUTPUT GOAL
-----------
Answer, in order:

1. What happened?
2. What was the primary cause?
3. How confident are we?
4. What was affected?
5. Why do we believe it?
6. What competing causes were considered / ruled out?
7. What should the DBA do next?
8. Where is the technical drill-down?

DESIGN PRINCIPLE
----------------
Detector-specific evidence remains authoritative.
This layer correlates and ranks evidence for presentation; it does not rewrite
the underlying detector evidence.

==============================================================================*/


/*==============================================================================
1. NORMALIZED CAUSE-CANDIDATE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseCandidates
AS

/*--------------------------------------------------------------------------
A. PARAMETER-SENSITIVE PLAN REUSE
--------------------------------------------------------------------------*/
SELECT
      p.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Parameter-sensitive plan reuse')
    , RootCauseRole              = CONVERT(varchar(20),'PRIMARY')
    , Confidence                 = p.Confidence
    , CorrelationKey             = CONVERT(nvarchar(200),CONCAT(N'EXEC:',p.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= p.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = p.DurationRatio
    , CPURatio                   = p.CPURatio
    , LogicalReadRatio           = p.LogicalReadRatio
    , EvidenceCount              = p.SharedStatementPlanCount
    , PrimaryEvidence            = p.EvidenceSummary
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        N'Validate the distinct parameter distributions with measured plan alternatives and re-test the identical runtime parameter values.')
FROM dbo.RCA_ParameterSensitivePlanEvidence AS p

UNION ALL

/*--------------------------------------------------------------------------
B. STATISTICS / CARDINALITY REGRESSION
--------------------------------------------------------------------------*/
SELECT
      s.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'STATISTICS_CARDINALITY_REGRESSION')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Statistics / cardinality regression')
    , RootCauseRole              = CONVERT(varchar(20),'PRIMARY')
    , Confidence                 = s.Confidence
    , CorrelationKey             = CONVERT(nvarchar(200),CONCAT(N'EXEC:',s.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= s.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = s.DurationRatio
    , CPURatio                   = s.CPURatio
    , LogicalReadRatio           = s.LogicalReadRatio
    , EvidenceCount              =
        s.CardinalityMismatchCount + s.StatisticsRiskCount + s.LargeScanCount
    , PrimaryEvidence            = s.EvidenceSummary
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        N'Review the statistics used by the affected operators, validate estimate-versus-actual row counts, and re-test after the least invasive corrective change.')
FROM dbo.RCA_StatisticsCardinalityEvidence AS s

UNION ALL

/*--------------------------------------------------------------------------
C. MEMORY GRANT / SPILL
--------------------------------------------------------------------------*/
SELECT
      m.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'MEMORY_GRANT_SPILL')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Memory grant / spill')
    , RootCauseRole              = m.RootCauseRole
    , Confidence                 = m.Confidence
    , CorrelationKey             = CONVERT(nvarchar(200),CONCAT(N'EXEC:',m.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID= m.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID       = CONVERT(int,NULL)
    , ImpactedRequestCount       = CONVERT(int,1)
    , BlockingDepth              = CONVERT(int,NULL)
    , MaxObservedWaitMs          = CONVERT(bigint,NULL)
    , DurationRatio              = m.DurationRatio
    , CPURatio                   = m.CPURatio
    , LogicalReadRatio           = m.LogicalReadRatio
    , EvidenceCount              = m.SpillOperatorCount
    , PrimaryEvidence            = m.EvidenceSummary
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        N'Review requested, granted, and used query memory together with spill operators; correct upstream estimate problems first when they are stronger causal evidence.')
FROM dbo.RCA_MemorySpillEvidence AS m

UNION ALL

/*--------------------------------------------------------------------------
D. BLOCKING / WAIT CHAIN

One normalized candidate per resolved head blocker.

This is the key presentation rule proven by Run 7C:
blast radius is grouped by HeadBlockerSessionID, NOT ImmediateBlockerSessionID.
--------------------------------------------------------------------------*/
SELECT
      b.CaptureRunID
    , CauseCategory              = CONVERT(varchar(80),'BLOCKING_WAIT_CHAIN')
    , CauseDisplayName           = CONVERT(nvarchar(200),N'Blocking / wait-chain contention')
    , RootCauseRole              =
        CASE
            WHEN SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>0
            THEN CONVERT(varchar(20),'PRIMARY')
            ELSE CONVERT(varchar(20),'CONTRIBUTING')
        END
    , Confidence                 =
        CASE
            WHEN SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)>0
            THEN CONVERT(varchar(20),'HIGH')
            WHEN SUM(CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END)>0
            THEN CONVERT(varchar(20),'MEDIUM')
            ELSE CONVERT(varchar(20),'LOW')
        END
    , CorrelationKey             =
        CONVERT(nvarchar(200),CONCAT(N'HEAD_BLOCKER:',b.HeadBlockerSessionID))
    , ImpactedExecutionEvidenceID= CONVERT(bigint,NULL)
    , HeadBlockerSessionID       = b.HeadBlockerSessionID
    , ImpactedRequestCount       = COUNT(DISTINCT b.VictimSessionID)
    , BlockingDepth              = MAX(b.BlockingDepth)
    , MaxObservedWaitMs          = MAX(b.WaitDurationMs)
    , DurationRatio              = CONVERT(decimal(19,4),NULL)
    , CPURatio                   = CONVERT(decimal(19,4),NULL)
    , LogicalReadRatio           = CONVERT(decimal(19,4),NULL)
    , EvidenceCount              = SUM(b.SampleCount)
    , PrimaryEvidence            =
        CONVERT(nvarchar(max),
        CONCAT
        (
            N'Head blocker session ',b.HeadBlockerSessionID,
            N' affected ',COUNT(DISTINCT b.VictimSessionID),
            N' distinct request(s). Maximum blocking depth=',MAX(b.BlockingDepth),
            N'; maximum observed wait=',MAX(b.WaitDurationMs),
            N' ms; total sampler observations=',SUM(b.SampleCount),N'.'
        ))
    , RecommendedAction          =
        CONVERT(nvarchar(4000),
        CONCAT
        (
            N'Investigate head blocker session ',b.HeadBlockerSessionID,
            N', identify the transaction retaining the required locks, and map the blocker host/application/login back to the owning workload.'
        ))
FROM dbo.RCA_BlockingEvidence AS b
GROUP BY
      b.CaptureRunID
    , b.HeadBlockerSessionID;
GO


/*==============================================================================
2. RANKED CAUSE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseRanking
AS
SELECT
      c.*
    , RoleRank =
        CASE c.RootCauseRole
            WHEN 'PRIMARY'      THEN 1
            WHEN 'CONTRIBUTING' THEN 2
            ELSE 3
        END
    , ConfidenceRank =
        CASE c.Confidence
            WHEN 'HIGH'   THEN 1
            WHEN 'MEDIUM' THEN 2
            WHEN 'LOW'    THEN 3
            ELSE 4
        END
    , ImpactRank =
        CASE
            WHEN ISNULL(c.ImpactedRequestCount,0)>=10 THEN 1
            WHEN ISNULL(c.ImpactedRequestCount,0)>=3  THEN 2
            ELSE 3
        END
    , EvidenceStrengthRank =
        CASE
            WHEN ISNULL(c.EvidenceCount,0)>=10 THEN 1
            WHEN ISNULL(c.EvidenceCount,0)>=3  THEN 2
            WHEN ISNULL(c.EvidenceCount,0)>=1  THEN 3
            ELSE 4
        END
FROM dbo.vw_RCA_FinalCauseCandidates AS c;
GO


/*==============================================================================
3. BLOCKING BLAST-RADIUS VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalBlockingBlastRadius
AS
SELECT
      b.CaptureRunID
    , b.HeadBlockerSessionID
    , DistinctVictims =
        COUNT(DISTINCT b.VictimSessionID)
    , PrimaryVictims =
        SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
    , HighConfidenceVictims =
        SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)
    , PersistentVictims =
        SUM(CASE WHEN b.SampleCount>=3 THEN 1 ELSE 0 END)
    , MaxBlockingDepth =
        MAX(b.BlockingDepth)
    , MaxObservedWaitMs =
        MAX(b.WaitDurationMs)
    , TotalSamplerObservations =
        SUM(b.SampleCount)
    , FirstObservedUTC =
        MIN(b.FirstObservedUTC)
    , LastObservedUTC =
        MAX(b.LastObservedUTC)
    , HeadBlockerHostName =
        MAX(b.HeadBlockerHostName)
    , HeadBlockerProgramName =
        MAX(b.HeadBlockerProgramName)
    , HeadBlockerLoginName =
        MAX(b.HeadBlockerLoginName)
    , HeadBlockerStatement =
        MAX(CONVERT(nvarchar(4000),b.HeadBlockerStatement))
FROM dbo.RCA_BlockingEvidence AS b
GROUP BY
      b.CaptureRunID
    , b.HeadBlockerSessionID;
GO


/*==============================================================================
4. UNIFIED FINAL OUTPUT PROCEDURE
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowFinalIncidentOutput
      @CaptureRunID bigint
    , @IncludeTechnicalEvidence bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51180,N'Invalid CaptureRunID.',1;


    /*--------------------------------------------------------------------------
      A. PRIMARY CANDIDATE
    --------------------------------------------------------------------------*/
    DECLARE
          @CauseCategory varchar(80)
        , @CauseDisplayName nvarchar(200)
        , @Confidence varchar(20)
        , @RootCauseRole varchar(20)
        , @PrimaryEvidence nvarchar(max)
        , @RecommendedAction nvarchar(4000)
        , @ImpactedRequestCount int
        , @HeadBlockerSessionID int
        , @BlockingDepth int
        , @MaxObservedWaitMs bigint
        , @DurationRatio decimal(19,4)
        , @CPURatio decimal(19,4)
        , @LogicalReadRatio decimal(19,4);

    SELECT TOP (1)
          @CauseCategory       = CauseCategory
        , @CauseDisplayName    = CauseDisplayName
        , @Confidence          = Confidence
        , @RootCauseRole       = RootCauseRole
        , @PrimaryEvidence     = PrimaryEvidence
        , @RecommendedAction   = RecommendedAction
        , @ImpactedRequestCount= ImpactedRequestCount
        , @HeadBlockerSessionID= HeadBlockerSessionID
        , @BlockingDepth       = BlockingDepth
        , @MaxObservedWaitMs   = MaxObservedWaitMs
        , @DurationRatio       = DurationRatio
        , @CPURatio            = CPURatio
        , @LogicalReadRatio    = LogicalReadRatio
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          RoleRank
        , ConfidenceRank
        , ImpactRank
        , EvidenceStrengthRank
        , CASE CauseCategory
              WHEN 'PARAMETER_SENSITIVE_PLAN_REUSE'   THEN 1
              WHEN 'STATISTICS_CARDINALITY_REGRESSION'THEN 2
              WHEN 'MEMORY_GRANT_SPILL'               THEN 3
              WHEN 'BLOCKING_WAIT_CHAIN'              THEN 4
              ELSE 9
          END;


    /*--------------------------------------------------------------------------
      B. CAPTURE METADATA
    --------------------------------------------------------------------------*/
    DECLARE
          @TargetDatabase sysname
        , @CaptureReason nvarchar(1000)
        , @StartTimeUTC datetime2
        , @EndTimeUTC datetime2;

    SELECT
          @TargetDatabase = TargetDatabase
        , @CaptureReason   = CaptureReason
        , @StartTimeUTC    = StartTimeUTC
        , @EndTimeUTC      = EndTimeUTC
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;


    /*--------------------------------------------------------------------------
      C. HUMAN-READABLE EXECUTIVE SUMMARY
    --------------------------------------------------------------------------*/
    DECLARE @ExecutiveSummary nvarchar(max);

    SET @ExecutiveSummary =
        CASE
            WHEN @CauseCategory='BLOCKING_WAIT_CHAIN'
            THEN CONCAT
            (
                N'Application work was delayed by a blocking chain rooted at SQL session ',
                COALESCE(CONVERT(varchar(20),@HeadBlockerSessionID),'UNKNOWN'),
                N'. The resolved head blocker affected ',
                COALESCE(CONVERT(varchar(20),@ImpactedRequestCount),'0'),
                N' distinct request(s), reached a maximum blocking depth of ',
                COALESCE(CONVERT(varchar(20),@BlockingDepth),'UNKNOWN'),
                N', and the longest captured wait was approximately ',
                COALESCE(CONVERT(varchar(30),CONVERT(decimal(19,1),@MaxObservedWaitMs/1000.0)),'UNKNOWN'),
                N' seconds. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='PARAMETER_SENSITIVE_PLAN_REUSE'
            THEN CONCAT
            (
                N'Application work regressed because a reused execution plan was not well suited to the captured runtime parameter distribution. ',
                N'Captured duration ratio=',COALESCE(CONVERT(varchar(30),@DurationRatio),'UNKNOWN'),
                N'x; CPU ratio=',COALESCE(CONVERT(varchar(30),@CPURatio),'UNKNOWN'),
                N'x; logical-read ratio=',COALESCE(CONVERT(varchar(30),@LogicalReadRatio),'UNKNOWN'),
                N'x. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='STATISTICS_CARDINALITY_REGRESSION'
            THEN CONCAT
            (
                N'Application work regressed because estimate quality and statistics/cardinality evidence materially diverged from the observed runtime workload. ',
                N'Captured duration ratio=',COALESCE(CONVERT(varchar(30),@DurationRatio),'UNKNOWN'),
                N'x; CPU ratio=',COALESCE(CONVERT(varchar(30),@CPURatio),'UNKNOWN'),
                N'x; logical-read ratio=',COALESCE(CONVERT(varchar(30),@LogicalReadRatio),'UNKNOWN'),
                N'x. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            WHEN @CauseCategory='MEMORY_GRANT_SPILL'
            THEN CONCAT
            (
                N'Application work experienced material memory-grant/spill behavior. ',
                N'Captured duration ratio=',COALESCE(CONVERT(varchar(30),@DurationRatio),'UNKNOWN'),
                N'x. Confidence=',COALESCE(@Confidence,'UNKNOWN'),N'.'
            )

            ELSE
                N'The RCA engine did not establish a dedicated high-confidence primary cause for this capture. Review ranked contributing evidence and technical details.'
        END;


    /*--------------------------------------------------------------------------
      RESULT SET 1 - EXECUTIVE INCIDENT SUMMARY
    --------------------------------------------------------------------------*/
    SELECT
          ReportSection        = '1 - EXECUTIVE INCIDENT SUMMARY'
        , CaptureRunID         = @CaptureRunID
        , TargetDatabase       = @TargetDatabase
        , CaptureReason        = @CaptureReason
        , StartTimeUTC         = @StartTimeUTC
        , EndTimeUTC           = @EndTimeUTC
        , PrimaryCauseCategory = @CauseCategory
        , PrimaryCause         = @CauseDisplayName
        , RootCauseRole        = @RootCauseRole
        , Confidence           = @Confidence
        , ImpactedRequestCount = @ImpactedRequestCount
        , HeadBlockerSessionID = @HeadBlockerSessionID
        , MaxBlockingDepth     = @BlockingDepth
        , MaxObservedWaitMs    = @MaxObservedWaitMs
        , ExecutiveSummary     = @ExecutiveSummary
        , WhyWeBelieveIt       = @PrimaryEvidence
        , RecommendedNextAction= @RecommendedAction;


    /*--------------------------------------------------------------------------
      RESULT SET 2 - RANKED CAUSES

      This is the bridge between the executive answer and detector detail.
    --------------------------------------------------------------------------*/
    SELECT
          ReportSection='2 - RANKED CAUSES'
        , CauseRank =
            ROW_NUMBER() OVER
            (
                ORDER BY
                      RoleRank
                    , ConfidenceRank
                    , ImpactRank
                    , EvidenceStrengthRank
            )
        , CauseCategory
        , CauseDisplayName
        , RootCauseRole
        , Confidence
        , ImpactedExecutionEvidenceID
        , HeadBlockerSessionID
        , ImpactedRequestCount
        , BlockingDepth
        , MaxObservedWaitMs
        , DurationRatio
        , CPURatio
        , LogicalReadRatio
        , EvidenceCount
        , PrimaryEvidence
        , RecommendedAction
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          RoleRank
        , ConfidenceRank
        , ImpactRank
        , EvidenceStrengthRank;


    /*--------------------------------------------------------------------------
      RESULT SET 3 - MOST IMPACTED EXECUTIONS
    --------------------------------------------------------------------------*/
    SELECT TOP (10)
          ReportSection='3 - MOST IMPACTED EXECUTIONS'
        , e.ExecutionEvidenceID
        , e.EventTimeUTC
        , e.DatabaseName
        , e.SessionID
        , e.ObjectName
        , e.HostName
        , e.ProgramName
        , e.LoginName
        , DurationSeconds =
            CONVERT(decimal(19,2),e.DurationMs/1000.0)
        , CPUSeconds =
            CONVERT(decimal(19,2),e.CPUms/1000.0)
        , e.LogicalReads
        , e.PhysicalReads
        , e.Writes
        , e.TotalRows
        , e.ParameterText
        , e.SubmittedCommand
    FROM dbo.RCA_ExecutionEvidence AS e
    WHERE e.CaptureRunID=@CaptureRunID
    ORDER BY
          ISNULL(e.DurationMs,0) DESC
        , ISNULL(e.CPUms,0) DESC
        , ISNULL(e.LogicalReads,0) DESC;


    /*--------------------------------------------------------------------------
      RESULT SET 4 - BLOCKING BLAST RADIUS
    --------------------------------------------------------------------------*/
    SELECT
          ReportSection='4 - BLOCKING BLAST RADIUS'
        , *
    FROM dbo.vw_RCA_FinalBlockingBlastRadius
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          DistinctVictims DESC
        , MaxObservedWaitMs DESC;


    /*--------------------------------------------------------------------------
      RESULT SET 5 - AFFECTED BLOCKING REQUESTS
    --------------------------------------------------------------------------*/
    SELECT
          ReportSection='5 - BLOCKING REQUEST DETAIL'
        , b.BlockingEvidenceID
        , b.VictimSessionID
        , b.VictimExecutionEvidenceID
        , b.ImmediateBlockerSessionID
        , b.HeadBlockerSessionID
        , b.BlockingDepth
        , b.WaitType
        , b.WaitDurationMs
        , b.FirstObservedUTC
        , b.LastObservedUTC
        , b.SampleCount
        , b.VictimDatabaseName
        , b.VictimHostName
        , b.VictimProgramName
        , b.VictimLoginName
        , b.VictimStatement
        , b.HeadBlockerHostName
        , b.HeadBlockerProgramName
        , b.HeadBlockerLoginName
        , b.HeadBlockerStatement
        , b.RootCauseRole
        , b.Confidence
        , b.EvidenceSummary
    FROM dbo.RCA_BlockingEvidence AS b
    WHERE b.CaptureRunID=@CaptureRunID
    ORDER BY
          b.HeadBlockerSessionID
        , b.BlockingDepth
        , b.VictimSessionID;


    /*--------------------------------------------------------------------------
      OPTIONAL TECHNICAL DRILL-DOWN
    --------------------------------------------------------------------------*/
    IF @IncludeTechnicalEvidence=1
    BEGIN
        /* 6A - Parameter-sensitive plan evidence */
        SELECT
              ReportSection='6A - PARAMETER-SENSITIVE PLAN EVIDENCE'
            , *
        FROM dbo.RCA_ParameterSensitivePlanEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        /* 6B - Statistics / cardinality evidence */
        SELECT
              ReportSection='6B - STATISTICS / CARDINALITY EVIDENCE'
            , *
        FROM dbo.RCA_StatisticsCardinalityEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        /* 6C - Memory spill evidence */
        SELECT
              ReportSection='6C - MEMORY GRANT / SPILL EVIDENCE'
            , *
        FROM dbo.RCA_MemorySpillEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        /* 6D - Plan findings */
        SELECT
              ReportSection='6D - PLAN FINDINGS'
            , *
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY
              CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , ExecutionEvidenceID
            , PlanFindingID;

        /* 6E - Server state */
        SELECT
              ReportSection='6E - SERVER STATE'
            , *
        FROM dbo.RCA_ServerSnapshot
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY CaptureTimeUTC;
    END;
END;
GO


/*==============================================================================
5. INSTALLATION VALIDATION
==============================================================================*/

SELECT
      FinalCauseCandidates =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseRanking =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseRanking',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingBlastRadius =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalBlockingBlastRadius',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalOutputProcedure =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ShowFinalIncidentOutput',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
6. VALIDATION MATRIX

These are the capture runs already exercised in the lab.

Run 3  - parameter-sensitive plan validation
Run 5  - statistics / cardinality validation
Run 6  - memory grant / spill validation
Run 7  - simple blocking
Run 8  - multi-level blocking
Run 13 - blocking blast radius

This query only returns runs that still exist.
==============================================================================*/

;WITH TestRuns AS
(
    SELECT CaptureRunID=CONVERT(bigint,3),  ExpectedCause='PARAMETER_SENSITIVE_PLAN_REUSE'
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
),
Ranked AS
(
    SELECT
          t.CaptureRunID
        , t.ExpectedCause
        , c.CauseCategory
        , c.CauseDisplayName
        , c.RootCauseRole
        , c.Confidence
        , c.ImpactedRequestCount
        , c.HeadBlockerSessionID
        , rn =
            ROW_NUMBER() OVER
            (
                PARTITION BY t.CaptureRunID
                ORDER BY
                      c.RoleRank
                    , c.ConfidenceRank
                    , c.ImpactRank
                    , c.EvidenceStrengthRank
            )
    FROM TestRuns AS t
    JOIN dbo.RCA_CaptureRun AS r
      ON r.CaptureRunID=t.CaptureRunID
    LEFT JOIN dbo.vw_RCA_FinalCauseRanking AS c
      ON c.CaptureRunID=t.CaptureRunID
)
SELECT
      CaptureRunID
    , ExpectedCause
    , DetectedTopCause=CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , ImpactedRequestCount
    , HeadBlockerSessionID
    , ValidationResult=
        CASE
            WHEN CauseCategory=ExpectedCause THEN 'PASS'
            ELSE 'REVIEW'
        END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO


/*==============================================================================
7. SAMPLE EXECUTIONS

Run these one at a time after installation.

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=3,
     @IncludeTechnicalEvidence=0;

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=5,
     @IncludeTechnicalEvidence=0;

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=6,
     @IncludeTechnicalEvidence=0;

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=7,
     @IncludeTechnicalEvidence=0;

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=8,
     @IncludeTechnicalEvidence=0;

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=13,
     @IncludeTechnicalEvidence=1;

==============================================================================*/
