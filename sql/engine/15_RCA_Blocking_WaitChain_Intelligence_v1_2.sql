USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
15_RCA_Blocking_WaitChain_Intelligence_v1_2.sql

PURPOSE
-------
Bind blocking/wait-chain intelligence to the EXISTING collector table:
    dbo.RCA_LiveRequestSnapshot

No new collector/XE session/Agent job is introduced.

INPUT
-----
dbo.RCA_LiveRequestSnapshot:
CaptureRunID, CaptureTimeUTC, SessionID, DatabaseName, WaitType, WaitTimeMs,
BlockingSessionID, CPUms, ElapsedMs, LogicalReads, PhysicalReads, Writes,
TotalRows, HostName, ProgramName, LoginName, RunningStatement.

DESIGN
------
One evidence row per victim session per capture run.
Repeated 5-second samples are aggregated.
The immediate blocker and terminal/head blocker are reconstructed from samples
taken at the same CaptureTimeUTC.
==============================================================================*/

IF COL_LENGTH('dbo.RCA_BlockingEvidence','VictimSessionID') IS NULL
    THROW 51080, 'Existing dbo.RCA_BlockingEvidence is not the expected v1 schema. Send its column list before continuing.', 1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildBlockingEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;

    ;WITH Blocked AS
    (
        SELECT
              s.LiveRequestSnapshotID
            , s.CaptureRunID
            , s.CaptureTimeUTC
            , s.SessionID AS VictimSessionID
            , s.BlockingSessionID AS ImmediateBlockerSessionID
            , s.WaitType
            , s.WaitTimeMs
            , s.DatabaseName
            , s.HostName AS VictimHostName
            , s.ProgramName AS VictimProgramName
            , s.LoginName AS VictimLoginName
            , s.RunningStatement AS VictimStatement
        FROM dbo.RCA_LiveRequestSnapshot s
        WHERE s.CaptureRunID=@CaptureRunID
          AND ISNULL(s.BlockingSessionID,0) > 0
          AND s.BlockingSessionID <> s.SessionID
    ),
    Chain AS
    (
        SELECT
              b.CaptureRunID
            , b.CaptureTimeUTC
            , b.VictimSessionID
            , b.ImmediateBlockerSessionID
            , b.ImmediateBlockerSessionID AS CurrentBlockerSessionID
            , CONVERT(int,1) AS BlockingDepth
            , CONVERT(varchar(max),
                '>'+CONVERT(varchar(20),b.VictimSessionID)+
                '>'+CONVERT(varchar(20),b.ImmediateBlockerSessionID)+'>') AS Path
        FROM Blocked b

        UNION ALL

        SELECT
              c.CaptureRunID
            , c.CaptureTimeUTC
            , c.VictimSessionID
            , c.ImmediateBlockerSessionID
            , nxt.BlockingSessionID
            , c.BlockingDepth+1
            , CONVERT(varchar(max),
                c.Path+CONVERT(varchar(20),nxt.BlockingSessionID)+'>')
        FROM Chain c
        JOIN dbo.RCA_LiveRequestSnapshot nxt
          ON nxt.CaptureRunID=c.CaptureRunID
         AND nxt.CaptureTimeUTC=c.CaptureTimeUTC
         AND nxt.SessionID=c.CurrentBlockerSessionID
        WHERE ISNULL(nxt.BlockingSessionID,0) > 0
          AND nxt.BlockingSessionID <> nxt.SessionID
          AND c.BlockingDepth < 16
          AND c.Path NOT LIKE '%>'+CONVERT(varchar(20),nxt.BlockingSessionID)+'>%'
    ),
    Terminal AS
    (
        SELECT *
        FROM
        (
            SELECT
                  c.*
                , rn=ROW_NUMBER() OVER
                    (PARTITION BY c.CaptureTimeUTC,c.VictimSessionID
                     ORDER BY c.BlockingDepth DESC)
            FROM Chain c
        ) x
        WHERE rn=1
    ),
    PerSample AS
    (
        SELECT
              b.CaptureRunID
            , b.CaptureTimeUTC
            , b.VictimSessionID
            , b.ImmediateBlockerSessionID
            , t.CurrentBlockerSessionID AS HeadBlockerSessionID
            , t.BlockingDepth
            , b.WaitType
            , b.WaitTimeMs
            , b.DatabaseName
            , b.VictimHostName
            , b.VictimProgramName
            , b.VictimLoginName
            , b.VictimStatement
            , hb.HostName AS HeadBlockerHostName
            , hb.ProgramName AS HeadBlockerProgramName
            , hb.LoginName AS HeadBlockerLoginName
            , hb.RunningStatement AS HeadBlockerStatement
        FROM Blocked b
        JOIN Terminal t
          ON t.CaptureRunID=b.CaptureRunID
         AND t.CaptureTimeUTC=b.CaptureTimeUTC
         AND t.VictimSessionID=b.VictimSessionID
        LEFT JOIN dbo.RCA_LiveRequestSnapshot hb
          ON hb.CaptureRunID=b.CaptureRunID
         AND hb.CaptureTimeUTC=b.CaptureTimeUTC
         AND hb.SessionID=t.CurrentBlockerSessionID
    ),
    Agg AS
    (
        SELECT
              CaptureRunID
            , VictimSessionID
            , ImmediateBlockerSessionID
            , HeadBlockerSessionID
            , BlockingDepth=MAX(BlockingDepth)
            , FirstObservedUTC=MIN(CaptureTimeUTC)
            , LastObservedUTC=MAX(CaptureTimeUTC)
            , SampleCount=COUNT_BIG(*)
            , MaxWaitTimeMs=MAX(WaitTimeMs)
        FROM PerSample
        GROUP BY
              CaptureRunID
            , VictimSessionID
            , ImmediateBlockerSessionID
            , HeadBlockerSessionID
    ),
    Ranked AS
    (
        SELECT
              a.*
            , p.WaitType
            , p.DatabaseName
            , p.VictimHostName
            , p.VictimProgramName
            , p.VictimLoginName
            , p.VictimStatement
            , p.HeadBlockerHostName
            , p.HeadBlockerProgramName
            , p.HeadBlockerLoginName
            , p.HeadBlockerStatement
            , rn=ROW_NUMBER() OVER
                (PARTITION BY a.CaptureRunID,a.VictimSessionID,
                              a.ImmediateBlockerSessionID,a.HeadBlockerSessionID
                 ORDER BY p.CaptureTimeUTC DESC)
        FROM Agg a
        JOIN PerSample p
          ON p.CaptureRunID=a.CaptureRunID
         AND p.VictimSessionID=a.VictimSessionID
         AND p.ImmediateBlockerSessionID=a.ImmediateBlockerSessionID
         AND p.HeadBlockerSessionID=a.HeadBlockerSessionID
    )
    INSERT dbo.RCA_BlockingEvidence
    (
          CaptureRunID
        , VictimExecutionEvidenceID
        , VictimSessionID
        , ImmediateBlockerSessionID
        , HeadBlockerSessionID
        , BlockingDepth
        , WaitType
        , WaitTimeMs
        , FirstObservedUTC
        , LastObservedUTC
        , SampleCount
        , VictimDatabaseName
        , VictimHostName
        , VictimProgramName
        , VictimLoginName
        , VictimStatement
        , HeadBlockerHostName
        , HeadBlockerProgramName
        , HeadBlockerLoginName
        , HeadBlockerStatement
        , RootCauseRole
        , Confidence
        , EvidenceSummary
        , CreatedTimeUTC
    )
    SELECT
          r.CaptureRunID
        , ee.ExecutionEvidenceID
        , r.VictimSessionID
        , r.ImmediateBlockerSessionID
        , r.HeadBlockerSessionID
        , r.BlockingDepth
        , r.WaitType
        , r.MaxWaitTimeMs
        , r.FirstObservedUTC
        , r.LastObservedUTC
        , CONVERT(int,r.SampleCount)
        , r.DatabaseName
        , r.VictimHostName
        , r.VictimProgramName
        , r.VictimLoginName
        , r.VictimStatement
        , r.HeadBlockerHostName
        , r.HeadBlockerProgramName
        , r.HeadBlockerLoginName
        , r.HeadBlockerStatement
        , CASE
            WHEN r.SampleCount >= 3
             AND (r.WaitType LIKE N'LCK[_]M[_]%' OR r.WaitType LIKE N'LCK%')
              THEN 'PRIMARY'
            ELSE 'CONTRIBUTING'
          END
        , CASE
            WHEN r.SampleCount >= 3 AND r.HeadBlockerSessionID IS NOT NULL
              THEN 'HIGH'
            ELSE 'MEDIUM'
          END
        , CONCAT(
            N'Victim session ',r.VictimSessionID,
            N' was blocked by session ',r.ImmediateBlockerSessionID,
            N'; head blocker=',COALESCE(CONVERT(varchar(20),r.HeadBlockerSessionID),'unknown'),
            N'; chain depth=',r.BlockingDepth,
            N'; wait=',COALESCE(r.WaitType,N'UNKNOWN'),
            N'; observed samples=',r.SampleCount,
            N'; first=',CONVERT(varchar(33),r.FirstObservedUTC,126),
            N'; last=',CONVERT(varchar(33),r.LastObservedUTC,126),
            N'. Head blocker host=',COALESCE(r.HeadBlockerHostName,N'UNKNOWN'),
            N'; program=',COALESCE(r.HeadBlockerProgramName,N'UNKNOWN'),
            N'; login=',COALESCE(r.HeadBlockerLoginName,N'UNKNOWN'),
            N'.')
        , SYSUTCDATETIME()
    FROM Ranked r
    OUTER APPLY
    (
        SELECT TOP (1) e.ExecutionEvidenceID
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=r.CaptureRunID
          AND e.SessionID=r.VictimSessionID
          AND e.EventTimeUTC >= DATEADD(second,-10,r.FirstObservedUTC)
          AND e.EventTimeUTC <= DATEADD(second, 30,r.LastObservedUTC)
        ORDER BY ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,r.LastObservedUTC))
    ) ee
    WHERE r.rn=1
    OPTION (MAXRECURSION 32);

    SELECT
          CaptureRunID=@CaptureRunID
        , BlockingCases=COUNT(*)
        , PrimaryCases=SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO

/* Installation validation */
SELECT
      BlockingEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidenceView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockingEvidence',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingSynthesis =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyBlockingSynthesis',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO
