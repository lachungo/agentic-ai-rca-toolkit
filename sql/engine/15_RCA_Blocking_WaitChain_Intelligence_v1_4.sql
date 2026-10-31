USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
15_RCA_Blocking_WaitChain_Intelligence_v1_4.sql

PURPOSE
-------
Compile a blocking/wait-chain detector against the canonical schemas already
validated in this environment:

dbo.RCA_LiveRequestSnapshot
dbo.RCA_ExecutionEvidence
dbo.RCA_BlockingEvidence

This version:
- preserves the existing RCA_BlockingEvidence table;
- uses WaitDurationMs / VictimDatabaseName from the canonical schema;
- uses FirstObservedUTC / LastObservedUTC / SampleCount added by migration;
- links victims to RCA_ExecutionEvidence using SessionID and time proximity;
- reconstructs immediate blocker -> head blocker chains at each sampler timestamp;
- aggregates repeated samples into one evidence row per victim/head-blocker pair;
- keeps blocking independent from the existing parameter/statistics/memory detectors
  until Run 7 proves the detector.
==============================================================================*/


/*==============================================================================
1. CANONICAL EVIDENCE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_BlockingEvidence
AS
SELECT
      BlockingEvidenceID
    , CaptureRunID
    , VictimSessionID
    , VictimExecutionEvidenceID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , WaitType
    , WaitDurationMs
    , BlockingDepth
    , VictimDatabaseName
    , VictimHostName
    , VictimProgramName
    , VictimLoginName
    , VictimStatement
    , BlockerHostName
    , BlockerProgramName
    , BlockerLoginName
    , BlockerStatement
    , HeadBlockerHostName
    , HeadBlockerProgramName
    , HeadBlockerLoginName
    , HeadBlockerStatement
    , HeadBlockerOpenTransactionCount
    , FirstObservedUTC
    , LastObservedUTC
    , SampleCount
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
    , CreatedTimeUTC
FROM dbo.RCA_BlockingEvidence;
GO


/*==============================================================================
2. BLOCKING / WAIT-CHAIN EVIDENCE BUILDER
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildBlockingEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51140,N'Invalid CaptureRunID.',1;

    DELETE dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;

    /*--------------------------------------------------------------------------
      A. Blocked requests observed by the existing sampler.
    --------------------------------------------------------------------------*/
    ;WITH Blocked AS
    (
        SELECT
              s.CaptureRunID
            , s.CaptureTimeUTC
            , s.SessionID AS VictimSessionID
            , s.BlockingSessionID AS ImmediateBlockerSessionID
            , s.DatabaseName AS VictimDatabaseName
            , s.WaitType
            , s.WaitTimeMs
            , s.HostName AS VictimHostName
            , s.ProgramName AS VictimProgramName
            , s.LoginName AS VictimLoginName
            , s.RunningStatement AS VictimStatement
        FROM dbo.RCA_LiveRequestSnapshot AS s
        WHERE s.CaptureRunID=@CaptureRunID
          AND ISNULL(s.BlockingSessionID,0)>0
          AND s.BlockingSessionID<>s.SessionID
    ),

    /*--------------------------------------------------------------------------
      B. Walk the blocking chain inside the SAME sampler timestamp.

      Example:
          57 -> 61 -> 72

      victim=57
      immediate blocker=61
      head blocker=72
      depth=2
    --------------------------------------------------------------------------*/
    ChainWalk AS
    (
        SELECT
              b.CaptureRunID
            , b.CaptureTimeUTC
            , b.VictimSessionID
            , b.ImmediateBlockerSessionID
            , b.ImmediateBlockerSessionID AS CurrentBlockerSessionID
            , CONVERT(int,1) AS BlockingDepth
            , CONVERT(varchar(4000),
                '>'+CONVERT(varchar(20),b.VictimSessionID)+
                '>'+CONVERT(varchar(20),b.ImmediateBlockerSessionID)+'>') AS ChainPath
        FROM Blocked AS b

        UNION ALL

        SELECT
              cw.CaptureRunID
            , cw.CaptureTimeUTC
            , cw.VictimSessionID
            , cw.ImmediateBlockerSessionID
            , nxt.BlockingSessionID AS CurrentBlockerSessionID
            , cw.BlockingDepth+1
            , CONVERT(varchar(4000),
                cw.ChainPath+
                CONVERT(varchar(20),nxt.BlockingSessionID)+'>')
        FROM ChainWalk AS cw
        JOIN dbo.RCA_LiveRequestSnapshot AS nxt
          ON nxt.CaptureRunID=cw.CaptureRunID
         AND nxt.CaptureTimeUTC=cw.CaptureTimeUTC
         AND nxt.SessionID=cw.CurrentBlockerSessionID
        WHERE ISNULL(nxt.BlockingSessionID,0)>0
          AND nxt.BlockingSessionID<>nxt.SessionID
          AND cw.BlockingDepth<16
          AND cw.ChainPath NOT LIKE
              '%>'+CONVERT(varchar(20),nxt.BlockingSessionID)+'>%'
    ),

    /*--------------------------------------------------------------------------
      C. Deepest blocker observed for each victim/sample.
    --------------------------------------------------------------------------*/
    Terminal AS
    (
        SELECT
              cw.CaptureRunID
            , cw.CaptureTimeUTC
            , cw.VictimSessionID
            , cw.ImmediateBlockerSessionID
            , cw.CurrentBlockerSessionID AS HeadBlockerSessionID
            , cw.BlockingDepth
            , rn=ROW_NUMBER() OVER
               (
                   PARTITION BY
                       cw.CaptureRunID,
                       cw.CaptureTimeUTC,
                       cw.VictimSessionID
                   ORDER BY cw.BlockingDepth DESC
               )
        FROM ChainWalk AS cw
    ),

    /*--------------------------------------------------------------------------
      D. Enrich the victim, immediate blocker, and head blocker using the SAME
         sampler timestamp.
    --------------------------------------------------------------------------*/
    PerSample AS
    (
        SELECT
              b.CaptureRunID
            , b.CaptureTimeUTC
            , b.VictimSessionID
            , b.ImmediateBlockerSessionID
            , t.HeadBlockerSessionID
            , t.BlockingDepth
            , b.WaitType
            , b.WaitTimeMs
            , b.VictimDatabaseName
            , b.VictimHostName
            , b.VictimProgramName
            , b.VictimLoginName
            , b.VictimStatement
            , ib.HostName AS BlockerHostName
            , ib.ProgramName AS BlockerProgramName
            , ib.LoginName AS BlockerLoginName
            , ib.RunningStatement AS BlockerStatement
            , hb.HostName AS HeadBlockerHostName
            , hb.ProgramName AS HeadBlockerProgramName
            , hb.LoginName AS HeadBlockerLoginName
            , hb.RunningStatement AS HeadBlockerStatement
        FROM Blocked AS b
        JOIN Terminal AS t
          ON t.CaptureRunID=b.CaptureRunID
         AND t.CaptureTimeUTC=b.CaptureTimeUTC
         AND t.VictimSessionID=b.VictimSessionID
         AND t.rn=1
        LEFT JOIN dbo.RCA_LiveRequestSnapshot AS ib
          ON ib.CaptureRunID=b.CaptureRunID
         AND ib.CaptureTimeUTC=b.CaptureTimeUTC
         AND ib.SessionID=b.ImmediateBlockerSessionID
        LEFT JOIN dbo.RCA_LiveRequestSnapshot AS hb
          ON hb.CaptureRunID=b.CaptureRunID
         AND hb.CaptureTimeUTC=b.CaptureTimeUTC
         AND hb.SessionID=t.HeadBlockerSessionID
    ),

    /*--------------------------------------------------------------------------
      E. Aggregate repeated observations.
    --------------------------------------------------------------------------*/
    Agg AS
    (
        SELECT
              CaptureRunID
            , VictimSessionID
            , ImmediateBlockerSessionID
            , HeadBlockerSessionID
            , BlockingDepth=MAX(BlockingDepth)
            , WaitType=MAX(WaitType)
            , WaitDurationMs=MAX(WaitTimeMs)
            , FirstObservedUTC=MIN(CaptureTimeUTC)
            , LastObservedUTC=MAX(CaptureTimeUTC)
            , SampleCount=CONVERT(int,COUNT_BIG(*))
            , VictimDatabaseName=MAX(VictimDatabaseName)
            , VictimHostName=MAX(VictimHostName)
            , VictimProgramName=MAX(VictimProgramName)
            , VictimLoginName=MAX(VictimLoginName)
            , VictimStatement=MAX(CONVERT(nvarchar(4000),VictimStatement))
            , BlockerHostName=MAX(BlockerHostName)
            , BlockerProgramName=MAX(BlockerProgramName)
            , BlockerLoginName=MAX(BlockerLoginName)
            , BlockerStatement=MAX(CONVERT(nvarchar(4000),BlockerStatement))
            , HeadBlockerHostName=MAX(HeadBlockerHostName)
            , HeadBlockerProgramName=MAX(HeadBlockerProgramName)
            , HeadBlockerLoginName=MAX(HeadBlockerLoginName)
            , HeadBlockerStatement=MAX(CONVERT(nvarchar(4000),HeadBlockerStatement))
        FROM PerSample
        GROUP BY
              CaptureRunID
            , VictimSessionID
            , ImmediateBlockerSessionID
            , HeadBlockerSessionID
    ),

    /*--------------------------------------------------------------------------
      F. Link victim to execution evidence.

      We use:
      - same CaptureRunID
      - same SessionID
      - nearest completed execution to the observed blocking window

      This is correlation evidence, not the source of the blocking chain itself.
    --------------------------------------------------------------------------*/
    Final AS
    (
        SELECT
              a.*
            , ee.ExecutionEvidenceID AS VictimExecutionEvidenceID
        FROM Agg AS a
        OUTER APPLY
        (
            SELECT TOP (1)
                e.ExecutionEvidenceID
            FROM dbo.RCA_ExecutionEvidence AS e
            WHERE e.CaptureRunID=a.CaptureRunID
              AND e.SessionID=a.VictimSessionID
              AND e.EventTimeUTC >= DATEADD(second,-15,a.FirstObservedUTC)
              AND e.EventTimeUTC <= DATEADD(second, 60,a.LastObservedUTC)
            ORDER BY
                ABS(DATEDIFF_BIG
                (
                    millisecond,
                    e.EventTimeUTC,
                    a.LastObservedUTC
                )),
                e.ExecutionEvidenceID DESC
        ) AS ee
    )

    INSERT dbo.RCA_BlockingEvidence
    (
          CaptureRunID
        , VictimSessionID
        , VictimExecutionEvidenceID
        , ImmediateBlockerSessionID
        , HeadBlockerSessionID
        , WaitType
        , WaitDurationMs
        , BlockingDepth
        , VictimDatabaseName
        , VictimHostName
        , VictimProgramName
        , VictimLoginName
        , VictimStatement
        , BlockerHostName
        , BlockerProgramName
        , BlockerLoginName
        , BlockerStatement
        , HeadBlockerHostName
        , HeadBlockerProgramName
        , HeadBlockerLoginName
        , HeadBlockerStatement
        , HeadBlockerOpenTransactionCount
        , FirstObservedUTC
        , LastObservedUTC
        , SampleCount
        , UpstreamCauseCategory
        , RootCauseRole
        , Confidence
        , EvidenceSummary
    )
    SELECT
          f.CaptureRunID
        , f.VictimSessionID
        , f.VictimExecutionEvidenceID
        , f.ImmediateBlockerSessionID
        , f.HeadBlockerSessionID
        , f.WaitType
        , f.WaitDurationMs
        , f.BlockingDepth
        , f.VictimDatabaseName
        , f.VictimHostName
        , f.VictimProgramName
        , f.VictimLoginName
        , f.VictimStatement
        , f.BlockerHostName
        , f.BlockerProgramName
        , f.BlockerLoginName
        , f.BlockerStatement
        , f.HeadBlockerHostName
        , f.HeadBlockerProgramName
        , f.HeadBlockerLoginName
        , f.HeadBlockerStatement
        , NULL /* open transaction count not collected by current sampler */
        , f.FirstObservedUTC
        , f.LastObservedUTC
        , f.SampleCount
        , NULL /* upstream cause assigned later */
        , CASE
              WHEN f.SampleCount>=2
               AND
               (
                   f.WaitType LIKE N'LCK[_]M[_]%'
                   OR f.WaitType LIKE N'LCK%'
               )
              THEN 'PRIMARY'
              ELSE 'CONTRIBUTING'
          END
        , CASE
              WHEN f.SampleCount>=3
               AND f.HeadBlockerSessionID IS NOT NULL
              THEN 'HIGH'
              WHEN f.HeadBlockerSessionID IS NOT NULL
              THEN 'MEDIUM'
              ELSE 'LOW'
          END
        , CONCAT
          (
              N'Victim session ',f.VictimSessionID,
              N' was blocked by session ',
              COALESCE(CONVERT(varchar(20),f.ImmediateBlockerSessionID),'UNKNOWN'),
              N'; head blocker=',
              COALESCE(CONVERT(varchar(20),f.HeadBlockerSessionID),'UNKNOWN'),
              N'; blocking depth=',f.BlockingDepth,
              N'; wait=',COALESCE(f.WaitType,N'UNKNOWN'),
              N'; maximum observed wait=',
              COALESCE(CONVERT(varchar(30),f.WaitDurationMs),'UNKNOWN'),
              N' ms; observed in ',f.SampleCount,N' sampler snapshot(s) from ',
              CONVERT(varchar(33),f.FirstObservedUTC,126),
              N' through ',
              CONVERT(varchar(33),f.LastObservedUTC,126),
              N'. Victim database=',COALESCE(f.VictimDatabaseName,N'UNKNOWN'),
              N'; host=',COALESCE(f.VictimHostName,N'UNKNOWN'),
              N'; program=',COALESCE(f.VictimProgramName,N'UNKNOWN'),
              N'; login=',COALESCE(f.VictimLoginName,N'UNKNOWN'),
              N'. Immediate blocker host=',
              COALESCE(f.BlockerHostName,N'UNKNOWN'),
              N'; program=',COALESCE(f.BlockerProgramName,N'UNKNOWN'),
              N'; login=',COALESCE(f.BlockerLoginName,N'UNKNOWN'),
              N'. Head blocker host=',
              COALESCE(f.HeadBlockerHostName,N'UNKNOWN'),
              N'; program=',COALESCE(f.HeadBlockerProgramName,N'UNKNOWN'),
              N'; login=',COALESCE(f.HeadBlockerLoginName,N'UNKNOWN'),
              N'.'
          )
    FROM Final AS f
    OPTION (MAXRECURSION 32);

    /*--------------------------------------------------------------------------
      G. Competing-cause awareness.
      Do not let raw findings demote blocking.
      Only dedicated upstream detectors may do so.
    --------------------------------------------------------------------------*/
    UPDATE b
       SET UpstreamCauseCategory=
           CASE
               WHEN b.VictimExecutionEvidenceID IS NOT NULL
                AND EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_ParameterSensitivePlanEvidence AS p
                    WHERE p.CaptureRunID=b.CaptureRunID
                      AND p.ImpactedExecutionEvidenceID=b.VictimExecutionEvidenceID
                      AND p.Confidence IN ('HIGH','MEDIUM')
                )
               THEN 'PARAMETER_SENSITIVE_PLAN_REUSE'

               WHEN b.VictimExecutionEvidenceID IS NOT NULL
                AND EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_StatisticsCardinalityEvidence AS s
                    WHERE s.CaptureRunID=b.CaptureRunID
                      AND s.ImpactedExecutionEvidenceID=b.VictimExecutionEvidenceID
                      AND s.Confidence IN ('HIGH','MEDIUM')
                )
               THEN 'STATISTICS_CARDINALITY_REGRESSION'

               WHEN b.VictimExecutionEvidenceID IS NOT NULL
                AND EXISTS
                (
                    SELECT 1
                    FROM dbo.RCA_MemorySpillEvidence AS m
                    WHERE m.CaptureRunID=b.CaptureRunID
                      AND m.ImpactedExecutionEvidenceID=b.VictimExecutionEvidenceID
                      AND m.RootCauseRole='PRIMARY'
                      AND m.Confidence='HIGH'
                )
               THEN 'MEMORY_GRANT_SPILL'

               ELSE NULL
           END
    FROM dbo.RCA_BlockingEvidence AS b
    WHERE b.CaptureRunID=@CaptureRunID;

    UPDATE b
       SET RootCauseRole=
           CASE
               WHEN b.UpstreamCauseCategory IS NOT NULL
               THEN 'CONTRIBUTING'
               WHEN b.SampleCount>=2
                AND
                (
                    b.WaitType LIKE N'LCK[_]M[_]%'
                    OR b.WaitType LIKE N'LCK%'
                )
               THEN 'PRIMARY'
               ELSE 'CONTRIBUTING'
           END,
           Confidence=
           CASE
               WHEN b.SampleCount>=3
                AND b.HeadBlockerSessionID IS NOT NULL
               THEN 'HIGH'
               WHEN b.HeadBlockerSessionID IS NOT NULL
               THEN 'MEDIUM'
               ELSE 'LOW'
           END,
           EvidenceSummary=
               CONCAT
               (
                   b.EvidenceSummary,
                   CASE
                       WHEN b.UpstreamCauseCategory IS NULL
                       THEN
                           N' No stronger dedicated parameter-sensitive, statistics/cardinality, or memory-spill cause was established.'
                       ELSE
                           CONCAT
                           (
                               N' Blocking classified CONTRIBUTING because stronger upstream evidence exists: ',
                               b.UpstreamCauseCategory,N'.'
                           )
                   END
               )
    FROM dbo.RCA_BlockingEvidence AS b
    WHERE b.CaptureRunID=@CaptureRunID;

    SELECT
          CaptureRunID=@CaptureRunID
        , BlockingCases=COUNT(*)
        , PrimaryCases=SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , ContributingCases=SUM(CASE WHEN RootCauseRole='CONTRIBUTING' THEN 1 ELSE 0 END)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
        , MaxBlockingDepth=MAX(BlockingDepth)
        , MaxObservedWaitMs=MAX(WaitDurationMs)
        , MaxSampleCount=MAX(SampleCount)
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
3. BLOCKING-SPECIFIC SYNTHESIS VIEW/PROCEDURE
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_BlockingIncidentEvidence
AS
SELECT
      CaptureRunID
    , VictimExecutionEvidenceID
    , VictimSessionID
    , ImmediateBlockerSessionID
    , HeadBlockerSessionID
    , BlockingDepth
    , WaitType
    , WaitDurationMs
    , FirstObservedUTC
    , LastObservedUTC
    , SampleCount
    , VictimDatabaseName
    , VictimHostName
    , VictimProgramName
    , VictimLoginName
    , VictimStatement
    , BlockerHostName
    , BlockerProgramName
    , BlockerLoginName
    , BlockerStatement
    , HeadBlockerHostName
    , HeadBlockerProgramName
    , HeadBlockerLoginName
    , HeadBlockerStatement
    , HeadBlockerOpenTransactionCount
    , UpstreamCauseCategory
    , RootCauseRole
    , Confidence
    , EvidenceSummary
FROM dbo.RCA_BlockingEvidence;
GO


CREATE OR ALTER PROCEDURE dbo.usp_RCA_ApplyBlockingSynthesis
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          CaptureRunID
        , VictimExecutionEvidenceID
        , VictimSessionID
        , ImmediateBlockerSessionID
        , HeadBlockerSessionID
        , BlockingDepth
        , WaitType
        , WaitDurationMs
        , SampleCount
        , RootCauseRole
        , Confidence
        , UpstreamCauseCategory
        , PrimaryCause=
          CASE
              WHEN RootCauseRole='PRIMARY'
              THEN N'Blocking / wait-chain contention materially delayed the captured request.'
              ELSE N'Blocking contributed to elapsed time but was secondary to a stronger upstream cause.'
          END
        , Action1=
          CONCAT
          (
              N'Investigate head blocker session ',
              COALESCE(CONVERT(varchar(20),HeadBlockerSessionID),'UNKNOWN'),
              N' and identify the transaction or statement holding the required resource.'
          )
        , Action2=
          CASE
              WHEN WaitType LIKE N'LCK[_]M[_]%'
              THEN N'Review transaction duration, lock ownership, isolation level, and transaction scope.'
              ELSE N'Review the blocking wait type and resource held by the head blocker.'
          END
        , Action3=
          N'Correlate blocker host, application, login, and SQL text with the owning application workload.'
        , EvidenceSummary
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          CASE RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END
        , CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , WaitDurationMs DESC;
END;
GO


/*==============================================================================
4. INSTALLATION VALIDATION
==============================================================================*/

SELECT
      BlockingEvidenceTable=
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidenceView=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockingEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingDetector=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingSynthesis=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyBlockingSynthesis',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingIncidentView=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockingIncidentEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FirstObservedUTC=
        CASE WHEN COL_LENGTH(N'dbo.RCA_BlockingEvidence',N'FirstObservedUTC') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LastObservedUTC=
        CASE WHEN COL_LENGTH(N'dbo.RCA_BlockingEvidence',N'LastObservedUTC') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , SampleCount=
        CASE WHEN COL_LENGTH(N'dbo.RCA_BlockingEvidence',N'SampleCount') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
5. SAFE SMOKE TEST AGAINST AN EXISTING RUN WITH NO EXPECTED BLOCKING

This checks procedure execution only.
Zero rows / zero cases is acceptable here.
Change @SmokeRunID if CaptureRunID 6 does not exist.
==============================================================================*/

DECLARE @SmokeRunID bigint=6;

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@SmokeRunID
)
BEGIN
    EXEC dbo.usp_RCA_BuildBlockingEvidence
         @CaptureRunID=@SmokeRunID;

    SELECT
          SmokeRunID=@SmokeRunID
        , BlockingEvidenceRows=COUNT(*)
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@SmokeRunID;
END;
GO
