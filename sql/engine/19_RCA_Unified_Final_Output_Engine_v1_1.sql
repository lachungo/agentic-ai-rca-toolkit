USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
19_RCA_Unified_Final_Output_Engine_v1_1.sql

PURPOSE
-------
Refine the unified final output engine after Run 13 exposed two presentation
gaps:

1. For blocking incidents, "MOST IMPACTED EXECUTIONS" could surface an XE
   execution row such as USE RCA instead of the actual blocked statement.

2. A session may be both a victim and an intermediate blocker. The final
   report should distinguish:
       HEAD BLOCKER
       INTERMEDIATE BLOCKER / VICTIM
       VICTIM

NO COLLECTOR CHANGES.
NO XE CHANGES.
NO SAMPLER CHANGES.
NO DETECTOR CHANGES.
NO EXISTING EVIDENCE IS DELETED.

This patch only improves the final reporting layer.
==============================================================================*/


/*==============================================================================
1. BLOCKING REQUEST ROLE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalBlockingRequestRole
AS
WITH Victims AS
(
    SELECT
          b.CaptureRunID
        , b.HeadBlockerSessionID
        , b.VictimSessionID
        , b.ImmediateBlockerSessionID
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
        , b.RootCauseRole
        , b.Confidence
        , IsIntermediateBlocker =
            CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_BlockingEvidence AS child
                    WHERE child.CaptureRunID = b.CaptureRunID
                      AND child.HeadBlockerSessionID = b.HeadBlockerSessionID
                      AND child.ImmediateBlockerSessionID = b.VictimSessionID
                )
                THEN 1 ELSE 0
            END
    FROM dbo.RCA_BlockingEvidence AS b
),
HeadBlockers AS
(
    SELECT
          b.CaptureRunID
        , b.HeadBlockerSessionID
        , DatabaseName =
            MAX(b.VictimDatabaseName)
        , HostName =
            MAX(b.HeadBlockerHostName)
        , ProgramName =
            MAX(b.HeadBlockerProgramName)
        , LoginName =
            MAX(b.HeadBlockerLoginName)
        , StatementText =
            MAX(CONVERT(nvarchar(4000),b.HeadBlockerStatement))
        , RootCauseRole =
            CASE
                WHEN SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>0
                THEN CONVERT(varchar(20),'PRIMARY')
                ELSE CONVERT(varchar(20),'CONTRIBUTING')
            END
        , Confidence =
            CASE
                WHEN SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)>0
                THEN CONVERT(varchar(20),'HIGH')
                WHEN SUM(CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END)>0
                THEN CONVERT(varchar(20),'MEDIUM')
                ELSE CONVERT(varchar(20),'LOW')
            END
        , FirstObservedUTC =
            MIN(b.FirstObservedUTC)
        , LastObservedUTC =
            MAX(b.LastObservedUTC)
        , SampleCount =
            SUM(b.SampleCount)
        , MaxObservedWaitMs =
            MAX(b.WaitDurationMs)
    FROM dbo.RCA_BlockingEvidence AS b
    GROUP BY
          b.CaptureRunID
        , b.HeadBlockerSessionID
)
SELECT
      h.CaptureRunID
    , h.HeadBlockerSessionID
    , SessionID =
        h.HeadBlockerSessionID
    , RequestRole =
        CONVERT(varchar(40),'HEAD BLOCKER')
    , ImmediateBlockerSessionID =
        CONVERT(int,NULL)
    , BlockingDepth =
        CONVERT(int,0)
    , WaitType =
        CONVERT(nvarchar(512),NULL)
    , WaitDurationMs =
        CONVERT(bigint,NULL)
    , h.FirstObservedUTC
    , h.LastObservedUTC
    , h.SampleCount
    , DatabaseName =
        h.DatabaseName
    , HostName =
        h.HostName
    , ProgramName =
        h.ProgramName
    , LoginName =
        h.LoginName
    , StatementText =
        CONVERT(nvarchar(max),h.StatementText)
    , h.RootCauseRole
    , h.Confidence
    , IsIntermediateBlocker =
        CONVERT(bit,0)
FROM HeadBlockers AS h

UNION ALL

SELECT
      v.CaptureRunID
    , v.HeadBlockerSessionID
    , SessionID =
        v.VictimSessionID
    , RequestRole =
        CONVERT
        (
            varchar(40),
            CASE
                WHEN v.IsIntermediateBlocker=1
                THEN 'INTERMEDIATE BLOCKER / VICTIM'
                ELSE 'VICTIM'
            END
        )
    , v.ImmediateBlockerSessionID
    , v.BlockingDepth
    , v.WaitType
    , v.WaitDurationMs
    , v.FirstObservedUTC
    , v.LastObservedUTC
    , v.SampleCount
    , DatabaseName =
        v.VictimDatabaseName
    , HostName =
        v.VictimHostName
    , ProgramName =
        v.VictimProgramName
    , LoginName =
        v.VictimLoginName
    , StatementText =
        v.VictimStatement
    , v.RootCauseRole
    , v.Confidence
    , IsIntermediateBlocker =
        CONVERT(bit,v.IsIntermediateBlocker)
FROM Victims AS v;
GO


/*==============================================================================
2. ALTER FINAL OUTPUT PROCEDURE
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
          @CauseCategory        = CauseCategory
        , @CauseDisplayName     = CauseDisplayName
        , @Confidence           = Confidence
        , @RootCauseRole        = RootCauseRole
        , @PrimaryEvidence      = PrimaryEvidence
        , @RecommendedAction    = RecommendedAction
        , @ImpactedRequestCount = ImpactedRequestCount
        , @HeadBlockerSessionID = HeadBlockerSessionID
        , @BlockingDepth        = BlockingDepth
        , @MaxObservedWaitMs    = MaxObservedWaitMs
        , @DurationRatio        = DurationRatio
        , @CPURatio             = CPURatio
        , @LogicalReadRatio     = LogicalReadRatio
    FROM dbo.vw_RCA_FinalCauseRanking
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          RoleRank
        , ConfidenceRank
        , ImpactRank
        , EvidenceStrengthRank
        , CASE CauseCategory
              WHEN 'PARAMETER_SENSITIVE_PLAN_REUSE'    THEN 1
              WHEN 'STATISTICS_CARDINALITY_REGRESSION' THEN 2
              WHEN 'MEMORY_GRANT_SPILL'                THEN 3
              WHEN 'BLOCKING_WAIT_CHAIN'               THEN 4
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
    DECLARE
          @ExecutiveSummary nvarchar(max)
        , @CompetingCauseSummary nvarchar(max);

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
                COALESCE
                (
                    CONVERT
                    (
                        varchar(30),
                        CONVERT(decimal(19,1),@MaxObservedWaitMs/1000.0)
                    ),
                    'UNKNOWN'
                ),
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

    SELECT
        @CompetingCauseSummary =
        STUFF
        (
            (
                SELECT
                    N'; ' +
                    CONCAT
                    (
                        c.CauseDisplayName,
                        N' [',
                        c.RootCauseRole,
                        N'/',
                        c.Confidence,
                        N']'
                    )
                FROM dbo.vw_RCA_FinalCauseRanking AS c
                WHERE c.CaptureRunID=@CaptureRunID
                  AND c.CauseCategory<>@CauseCategory
                ORDER BY
                      c.RoleRank
                    , c.ConfidenceRank
                    , c.ImpactRank
                    , c.EvidenceStrengthRank
                FOR XML PATH(''),TYPE
            ).value('.','nvarchar(max)')
        ,1,2,N'');

    IF NULLIF(@CompetingCauseSummary,N'') IS NULL
        SET @CompetingCauseSummary =
            N'No stronger competing dedicated detector was established for this capture.';


    /*--------------------------------------------------------------------------
      RESULT SET 1 - EXECUTIVE INCIDENT SUMMARY
    --------------------------------------------------------------------------*/
    SELECT
          ReportSection         = '1 - EXECUTIVE INCIDENT SUMMARY'
        , CaptureRunID          = @CaptureRunID
        , TargetDatabase        = @TargetDatabase
        , CaptureReason         = @CaptureReason
        , StartTimeUTC          = @StartTimeUTC
        , EndTimeUTC            = @EndTimeUTC
        , PrimaryCauseCategory  = @CauseCategory
        , PrimaryCause          = @CauseDisplayName
        , RootCauseRole         = @RootCauseRole
        , Confidence            = @Confidence
        , ImpactedRequestCount  = @ImpactedRequestCount
        , HeadBlockerSessionID  = @HeadBlockerSessionID
        , MaxBlockingDepth      = @BlockingDepth
        , MaxObservedWaitMs     = @MaxObservedWaitMs
        , ExecutiveSummary      = @ExecutiveSummary
        , WhyWeBelieveIt        = @PrimaryEvidence
        , CompetingCauses       = @CompetingCauseSummary
        , RecommendedNextAction = @RecommendedAction;


    /*--------------------------------------------------------------------------
      RESULT SET 2 - RANKED CAUSES
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
      RESULT SET 3

      BLOCKING:
        Use the sampler-backed blocking evidence because it contains the actual
        waiting statement and resolved blocking role.

      NON-BLOCKING:
        Preserve the original "most impacted executions" behavior.
    --------------------------------------------------------------------------*/
    IF @CauseCategory='BLOCKING_WAIT_CHAIN'
    BEGIN
        SELECT
              ReportSection='3 - IMPACTED REQUESTS / BLOCKING CHAIN'
            , r.HeadBlockerSessionID
            , r.SessionID
            , r.RequestRole
            , r.ImmediateBlockerSessionID
            , r.BlockingDepth
            , r.WaitType
            , WaitSeconds =
                CONVERT(decimal(19,2),r.WaitDurationMs/1000.0)
            , r.SampleCount
            , r.FirstObservedUTC
            , r.LastObservedUTC
            , r.DatabaseName
            , r.HostName
            , r.ProgramName
            , r.LoginName
            , r.StatementText
            , r.RootCauseRole
            , r.Confidence
        FROM dbo.vw_RCA_FinalBlockingRequestRole AS r
        WHERE r.CaptureRunID=@CaptureRunID
        ORDER BY
              r.HeadBlockerSessionID
            , r.BlockingDepth
            , r.SessionID;
    END
    ELSE
    BEGIN
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
    END


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
      RESULT SET 5 - BLOCKING FORENSIC DETAIL
    --------------------------------------------------------------------------*/
    SELECT
          ReportSection='5 - BLOCKING REQUEST DETAIL'
        , b.BlockingEvidenceID
        , b.VictimSessionID
        , VictimRole =
            CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_BlockingEvidence AS child
                    WHERE child.CaptureRunID=b.CaptureRunID
                      AND child.HeadBlockerSessionID=b.HeadBlockerSessionID
                      AND child.ImmediateBlockerSessionID=b.VictimSessionID
                )
                THEN 'INTERMEDIATE BLOCKER / VICTIM'
                ELSE 'VICTIM'
            END
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
        SELECT
              ReportSection='6A - PARAMETER-SENSITIVE PLAN EVIDENCE'
            , *
        FROM dbo.RCA_ParameterSensitivePlanEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        SELECT
              ReportSection='6B - STATISTICS / CARDINALITY EVIDENCE'
            , *
        FROM dbo.RCA_StatisticsCardinalityEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        SELECT
              ReportSection='6C - MEMORY GRANT / SPILL EVIDENCE'
            , *
        FROM dbo.RCA_MemorySpillEvidence
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY ImpactedExecutionEvidenceID;

        SELECT
              ReportSection='6D - PLAN FINDINGS'
            , *
        FROM dbo.RCA_PlanFinding
        WHERE CaptureRunID=@CaptureRunID
        ORDER BY
              CASE Severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , ExecutionEvidenceID
            , PlanFindingID;

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
3. INSTALLATION VALIDATION
==============================================================================*/

SELECT
      BlockingRequestRoleView =
        CASE
            WHEN OBJECT_ID(N'dbo.vw_RCA_FinalBlockingRequestRole',N'V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END
    , FinalOutputProcedureV11 =
        CASE
            WHEN OBJECT_ID(N'dbo.usp_RCA_ShowFinalIncidentOutput',N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL'
        END;
GO


/*==============================================================================
4. RUN 13 ROLE VALIDATION
==============================================================================*/

SELECT
      CaptureRunID
    , HeadBlockerSessionID
    , SessionID
    , RequestRole
    , ImmediateBlockerSessionID
    , BlockingDepth
    , WaitType
    , WaitDurationMs
    , SampleCount
    , StatementText
FROM dbo.vw_RCA_FinalBlockingRequestRole
WHERE CaptureRunID=13
ORDER BY
      HeadBlockerSessionID
    , BlockingDepth
    , SessionID;
GO


/*==============================================================================
EXPECTED RUN 13 ROLE SHAPE

69  HEAD BLOCKER
75  INTERMEDIATE BLOCKER / VICTIM
76  VICTIM
77  VICTIM

The important point is that 75 is not incorrectly presented as the ultimate
root blocker even though it directly blocks downstream requests.
==============================================================================*/


/*==============================================================================
5. RE-RUN FINAL REPORT
==============================================================================*/

EXEC dbo.usp_RCA_ShowFinalIncidentOutput
     @CaptureRunID=13,
     @IncludeTechnicalEvidence=0;
GO
