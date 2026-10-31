
USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
15_RCA_Blocking_WaitChain_Intelligence_v1.sql

PURPOSE
-------
Add first-class blocking / wait-chain intelligence without changing the
collector architecture already validated for Runs 3, 5, and 6.

ARCHITECTURE
------------
RCA_LiveRequestSnapshot / sampler evidence
    -> blocking chain reconstruction
    -> RCA_BlockingEvidence
    -> RCA_Recommendation
    -> RCA_RootCauseSynthesis
    -> Incident report integration

IMPORTANT
---------
- Uses existing sampled request evidence as the authoritative source for
  blocking relationships.
- Does not replace parameter-sensitive, statistics/cardinality, or memory-spill
  detectors.
- Treats blocking as PRIMARY only when material blocked time exists and no
  stronger upstream cause has already been established for the victim.
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_BlockingEvidence
    (
          BlockingEvidenceID bigint IDENTITY(1,1) NOT NULL
              CONSTRAINT PK_RCA_BlockingEvidence PRIMARY KEY CLUSTERED
        , CaptureRunID bigint NOT NULL
        , VictimSessionID int NOT NULL
        , VictimExecutionEvidenceID bigint NULL
        , ImmediateBlockerSessionID int NULL
        , HeadBlockerSessionID int NULL
        , WaitType nvarchar(256) NULL
        , WaitDurationMs bigint NULL
        , BlockingDepth int NOT NULL
        , VictimDatabaseName sysname NULL
        , VictimHostName nvarchar(512) NULL
        , VictimProgramName nvarchar(512) NULL
        , VictimLoginName nvarchar(512) NULL
        , VictimStatement nvarchar(max) NULL
        , BlockerHostName nvarchar(512) NULL
        , BlockerProgramName nvarchar(512) NULL
        , BlockerLoginName nvarchar(512) NULL
        , BlockerStatement nvarchar(max) NULL
        , HeadBlockerHostName nvarchar(512) NULL
        , HeadBlockerProgramName nvarchar(512) NULL
        , HeadBlockerLoginName nvarchar(512) NULL
        , HeadBlockerStatement nvarchar(max) NULL
        , HeadBlockerOpenTransactionCount int NULL
        , UpstreamCauseCategory varchar(80) NULL
        , RootCauseRole varchar(20) NOT NULL
        , Confidence varchar(20) NOT NULL
        , EvidenceSummary nvarchar(max) NOT NULL
        , CreatedTimeUTC datetime2(3) NOT NULL
              CONSTRAINT DF_RCA_BlockingEvidence_CreatedTimeUTC DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_BlockingEvidence_Run
        ON dbo.RCA_BlockingEvidence(CaptureRunID,VictimSessionID,HeadBlockerSessionID);
END;
GO

CREATE OR ALTER VIEW dbo.vw_RCA_BlockingEvidence
AS
SELECT *
FROM dbo.RCA_BlockingEvidence;
GO

/*==============================================================================
Expected sampler source columns.
The detector uses dynamic SQL so it can adapt to the existing snapshot table
without changing prior Runs. It looks for one of these common names:
  SessionID / session_id
  BlockingSessionID / blocking_session_id
  WaitType / wait_type
  CaptureTime / SampleTimeUTC / CaptureTimeUTC
  DatabaseName
  HostName
  ProgramName
  LoginName
  RunningStatement / StatementText / InputBuffer
  OpenTransactionCount
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildBlockingEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;

    DECLARE @Source sysname;

    SELECT TOP (1) @Source = QUOTENAME(s.name)+N'.'+QUOTENAME(t.name)
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id=t.schema_id
    WHERE t.name IN
    (
        N'RCA_LiveRequestSnapshot',
        N'RCA_ServerSnapshot',
        N'RCA_RequestSnapshot',
        N'RCA_LiveSnapshot'
    )
    ORDER BY CASE t.name
                 WHEN N'RCA_LiveRequestSnapshot' THEN 1
                 WHEN N'RCA_RequestSnapshot' THEN 2
                 WHEN N'RCA_LiveSnapshot' THEN 3
                 ELSE 4
             END;

    IF @Source IS NULL
    BEGIN
        RAISERROR('No supported RCA sampler request snapshot table was found.',16,1);
        RETURN;
    END;

    DECLARE @obj int=OBJECT_ID(@Source);

    DECLARE
          @SessionCol sysname
        , @BlockerCol sysname
        , @WaitCol sysname
        , @TimeCol sysname
        , @DbCol sysname
        , @HostCol sysname
        , @ProgramCol sysname
        , @LoginCol sysname
        , @StmtCol sysname
        , @OpenTranCol sysname;

    SELECT @SessionCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN (N'SessionID',N'session_id');

    SELECT @BlockerCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN
        (N'BlockingSessionID',N'blocking_session_id');

    SELECT @WaitCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN (N'WaitType',N'wait_type');

    SELECT @TimeCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN
        (N'CaptureTime',N'CaptureTimeUTC',N'SampleTimeUTC',N'SnapshotTimeUTC');

    SELECT @DbCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN (N'DatabaseName',N'database_name');

    SELECT @HostCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN (N'HostName',N'host_name');

    SELECT @ProgramCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN (N'ProgramName',N'program_name');

    SELECT @LoginCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN (N'LoginName',N'login_name');

    SELECT @StmtCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN
        (N'RunningStatement',N'StatementText',N'InputBuffer',N'SqlText');

    SELECT @OpenTranCol=name
    FROM sys.columns WHERE object_id=@obj AND name IN
        (N'OpenTransactionCount',N'open_transaction_count');

    IF @SessionCol IS NULL OR @BlockerCol IS NULL
    BEGIN
        RAISERROR('Sampler table %s does not contain session/blocking columns.',16,1,@Source);
        RETURN;
    END;

    DECLARE @sql nvarchar(max)=N'
    ;WITH S AS
    (
        SELECT
              CaptureRunID
            , SessionID = TRY_CONVERT(int,'+QUOTENAME(@SessionCol)+N')
            , BlockingSessionID = TRY_CONVERT(int,'+QUOTENAME(@BlockerCol)+N')'
            + CASE WHEN @WaitCol IS NOT NULL
                   THEN N', WaitType=CONVERT(nvarchar(256),'+QUOTENAME(@WaitCol)+N')'
                   ELSE N', WaitType=CONVERT(nvarchar(256),NULL)' END
            + CASE WHEN @TimeCol IS NOT NULL
                   THEN N', SampleTime=TRY_CONVERT(datetime2(3),'+QUOTENAME(@TimeCol)+N')'
                   ELSE N', SampleTime=CONVERT(datetime2(3),NULL)' END
            + CASE WHEN @DbCol IS NOT NULL
                   THEN N', DatabaseName=CONVERT(sysname,'+QUOTENAME(@DbCol)+N')'
                   ELSE N', DatabaseName=CONVERT(sysname,NULL)' END
            + CASE WHEN @HostCol IS NOT NULL
                   THEN N', HostName=CONVERT(nvarchar(512),'+QUOTENAME(@HostCol)+N')'
                   ELSE N', HostName=CONVERT(nvarchar(512),NULL)' END
            + CASE WHEN @ProgramCol IS NOT NULL
                   THEN N', ProgramName=CONVERT(nvarchar(512),'+QUOTENAME(@ProgramCol)+N')'
                   ELSE N', ProgramName=CONVERT(nvarchar(512),NULL)' END
            + CASE WHEN @LoginCol IS NOT NULL
                   THEN N', LoginName=CONVERT(nvarchar(512),'+QUOTENAME(@LoginCol)+N')'
                   ELSE N', LoginName=CONVERT(nvarchar(512),NULL)' END
            + CASE WHEN @StmtCol IS NOT NULL
                   THEN N', StatementText=CONVERT(nvarchar(max),'+QUOTENAME(@StmtCol)+N')'
                   ELSE N', StatementText=CONVERT(nvarchar(max),NULL)' END
            + CASE WHEN @OpenTranCol IS NOT NULL
                   THEN N', OpenTranCount=TRY_CONVERT(int,'+QUOTENAME(@OpenTranCol)+N')'
                   ELSE N', OpenTranCount=CONVERT(int,NULL)' END
        FROM '+@Source+N'
        WHERE CaptureRunID=@CaptureRunID
    ),
    Blocked AS
    (
        SELECT *
        FROM S
        WHERE ISNULL(BlockingSessionID,0)>0
          AND BlockingSessionID<>SessionID
    ),
    Chain AS
    (
        SELECT
              VictimSessionID=b.SessionID
            , CurrentSessionID=b.SessionID
            , ImmediateBlockerSessionID=b.BlockingSessionID
            , NextBlockerSessionID=b.BlockingSessionID
            , Depth=1
            , b.WaitType
            , FirstSample=b.SampleTime
            , LastSample=b.SampleTime
        FROM Blocked b

        UNION ALL

        SELECT
              c.VictimSessionID
            , CurrentSessionID=s.SessionID
            , c.ImmediateBlockerSessionID
            , NextBlockerSessionID=s.BlockingSessionID
            , Depth=c.Depth+1
            , c.WaitType
            , c.FirstSample
            , CASE WHEN s.SampleTime>c.LastSample THEN s.SampleTime ELSE c.LastSample END
        FROM Chain c
        JOIN S s
          ON s.SessionID=c.NextBlockerSessionID
        WHERE ISNULL(s.BlockingSessionID,0)>0
          AND s.BlockingSessionID<>s.SessionID
          AND c.Depth<16
    ),
    Head AS
    (
        SELECT
              c.VictimSessionID
            , ImmediateBlockerSessionID=MAX(c.ImmediateBlockerSessionID)
            , HeadBlockerSessionID=
                COALESCE
                (
                    MAX(CASE WHEN ISNULL(c.NextBlockerSessionID,0)=0
                             THEN c.CurrentSessionID END),
                    MAX(CASE WHEN c.Depth=
                         (SELECT MAX(c2.Depth)
                          FROM Chain c2
                          WHERE c2.VictimSessionID=c.VictimSessionID)
                         THEN c.NextBlockerSessionID END),
                    MAX(c.NextBlockerSessionID)
                )
            , BlockingDepth=MAX(c.Depth)
            , WaitType=MAX(c.WaitType)
            , FirstSample=MIN(c.FirstSample)
            , LastSample=MAX(c.LastSample)
        FROM Chain c
        GROUP BY c.VictimSessionID
    ),
    Final AS
    (
        SELECT
              h.*
            , WaitDurationMs=
                CASE WHEN h.FirstSample IS NOT NULL AND h.LastSample IS NOT NULL
                     THEN DATEDIFF_BIG(millisecond,h.FirstSample,h.LastSample)
                     ELSE NULL END
            , v.DatabaseName AS VictimDatabaseName
            , v.HostName AS VictimHostName
            , v.ProgramName AS VictimProgramName
            , v.LoginName AS VictimLoginName
            , v.StatementText AS VictimStatement
            , ib.HostName AS BlockerHostName
            , ib.ProgramName AS BlockerProgramName
            , ib.LoginName AS BlockerLoginName
            , ib.StatementText AS BlockerStatement
            , hb.HostName AS HeadBlockerHostName
            , hb.ProgramName AS HeadBlockerProgramName
            , hb.LoginName AS HeadBlockerLoginName
            , hb.StatementText AS HeadBlockerStatement
            , hb.OpenTranCount AS HeadBlockerOpenTransactionCount
        FROM Head h
        OUTER APPLY
        (
            SELECT TOP (1) *
            FROM S
            WHERE SessionID=h.VictimSessionID
            ORDER BY SampleTime DESC
        ) v
        OUTER APPLY
        (
            SELECT TOP (1) *
            FROM S
            WHERE SessionID=h.ImmediateBlockerSessionID
            ORDER BY SampleTime DESC
        ) ib
        OUTER APPLY
        (
            SELECT TOP (1) *
            FROM S
            WHERE SessionID=h.HeadBlockerSessionID
            ORDER BY SampleTime DESC
        ) hb
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
        , UpstreamCauseCategory
        , RootCauseRole
        , Confidence
        , EvidenceSummary
    )
    SELECT
          @CaptureRunID
        , f.VictimSessionID
        , ee.ExecutionEvidenceID
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
        , f.HeadBlockerOpenTransactionCount
        , NULL
        , ''PRIMARY''
        , CASE
              WHEN ISNULL(f.BlockingDepth,0)>=1
               AND (ISNULL(f.WaitDurationMs,0)>=5000 OR f.WaitDurationMs IS NULL)
              THEN ''HIGH''
              ELSE ''MEDIUM''
          END
        , CONCAT
          (
              N''Victim session '',f.VictimSessionID,
              N'' was blocked by session '',COALESCE(CONVERT(varchar(20),f.ImmediateBlockerSessionID),''NULL''),
              N''; head blocker='',COALESCE(CONVERT(varchar(20),f.HeadBlockerSessionID),''NULL''),
              N''; chain depth='',f.BlockingDepth,
              N''; wait='',COALESCE(f.WaitType,N''UNKNOWN''),
              N''; sampled blocked duration='',COALESCE(CONVERT(varchar(30),f.WaitDurationMs),''NULL''),N'' ms. '',
              N''Head blocker host='',COALESCE(f.HeadBlockerHostName,N''NULL''),
              N''; program='',COALESCE(f.HeadBlockerProgramName,N''NULL''),
              N''; login='',COALESCE(f.HeadBlockerLoginName,N''NULL''),
              N''; open transactions='',COALESCE(CONVERT(varchar(20),f.HeadBlockerOpenTransactionCount),''NULL''),N''.''
          )
    FROM Final f
    OUTER APPLY
    (
        SELECT TOP (1)
              e.ExecutionEvidenceID
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
          AND e.SessionID=f.VictimSessionID
        ORDER BY ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,COALESCE(f.LastSample,e.EventTimeUTC)))
    ) ee
    OPTION (MAXRECURSION 32);';

    EXEC sys.sp_executesql
         @sql,
         N'@CaptureRunID bigint',
         @CaptureRunID=@CaptureRunID;

    UPDATE b
       SET UpstreamCauseCategory=
           CASE
               WHEN EXISTS
               (
                   SELECT 1
                   FROM dbo.RCA_ParameterSensitivePlanEvidence p
                   WHERE p.CaptureRunID=b.CaptureRunID
                     AND p.ImpactedExecutionEvidenceID=b.VictimExecutionEvidenceID
                     AND p.Confidence IN ('HIGH','MEDIUM')
               )
               THEN 'PARAMETER_SENSITIVE_PLAN_REUSE'
               WHEN EXISTS
               (
                   SELECT 1
                   FROM dbo.RCA_StatisticsCardinalityEvidence s
                   WHERE s.CaptureRunID=b.CaptureRunID
                     AND s.ImpactedExecutionEvidenceID=b.VictimExecutionEvidenceID
                     AND s.Confidence IN ('HIGH','MEDIUM')
               )
               THEN 'STATISTICS_CARDINALITY_REGRESSION'
               WHEN EXISTS
               (
                   SELECT 1
                   FROM dbo.RCA_MemorySpillEvidence m
                   WHERE m.CaptureRunID=b.CaptureRunID
                     AND m.ImpactedExecutionEvidenceID=b.VictimExecutionEvidenceID
                     AND m.RootCauseRole='PRIMARY'
                     AND m.Confidence='HIGH'
               )
               THEN 'MEMORY_GRANT_SPILL'
               ELSE NULL
           END
    FROM dbo.RCA_BlockingEvidence b
    WHERE b.CaptureRunID=@CaptureRunID;

    UPDATE b
       SET RootCauseRole=
           CASE WHEN UpstreamCauseCategory IS NULL THEN 'PRIMARY'
                ELSE 'CONTRIBUTING' END,
           Confidence=
           CASE
               WHEN UpstreamCauseCategory IS NULL
                AND BlockingDepth>=1
                AND ISNULL(WaitDurationMs,5000)>=5000
               THEN 'HIGH'
               ELSE 'MEDIUM'
           END,
           EvidenceSummary=
               CONCAT(EvidenceSummary,
                      CASE WHEN UpstreamCauseCategory IS NULL
                           THEN N' No stronger upstream parameter/statistics/memory-spill cause was established; blocking classified PRIMARY.'
                           ELSE CONCAT(N' Blocking classified CONTRIBUTING because stronger upstream evidence exists: ',
                                       UpstreamCauseCategory,N'.')
                      END)
    FROM dbo.RCA_BlockingEvidence b
    WHERE b.CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_Recommendation
    WHERE CaptureRunID=@CaptureRunID
      AND RootCauseCategory='BLOCKING_WAIT_CHAIN';

    INSERT dbo.RCA_Recommendation
    (
          CaptureRunID
        , ExecutionEvidenceID
        , Priority
        , Confidence
        , RootCauseCategory
        , RootCauseSummary
        , EvidenceSummary
        , WhyItMatters
        , RecommendedAction
        , EvidenceCount
        , HighSeverityFindingCount
        , MediumSeverityFindingCount
    )
    SELECT
          b.CaptureRunID
        , COALESCE(b.VictimExecutionEvidenceID,0)
        , CASE WHEN b.RootCauseRole='PRIMARY' AND b.Confidence='HIGH' THEN 1
               WHEN b.RootCauseRole='PRIMARY' THEN 2 ELSE 3 END
        , b.Confidence
        , 'BLOCKING_WAIT_CHAIN'
        , CASE WHEN b.RootCauseRole='PRIMARY'
               THEN N'Blocking/wait-chain behavior prevented the affected request from progressing.'
               ELSE N'Blocking was observed but appears secondary to a stronger upstream root cause.'
          END
        , b.EvidenceSummary
        , N'Blocking can make an otherwise healthy query appear slow because elapsed time accumulates while another session holds an incompatible resource.'
        , CONCAT
          (
              N'Investigate head blocker session ',
              COALESCE(CONVERT(varchar(20),b.HeadBlockerSessionID),'NULL'),
              N', its transaction scope, host/program/login, and statement. ',
              N'Correct the blocking transaction or concurrency pattern before tuning the victim query.'
          )
        , CASE WHEN b.BlockingDepth>0 THEN b.BlockingDepth ELSE 1 END
        , CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END
        , CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END
    FROM dbo.RCA_BlockingEvidence b
    WHERE b.CaptureRunID=@CaptureRunID;

    SELECT
          CaptureRunID=@CaptureRunID
        , DetectedCases=COUNT(*)
        , PrimaryCases=SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , ContributingCases=SUM(CASE WHEN RootCauseRole='CONTRIBUTING' THEN 1 ELSE 0 END)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
        , MaxBlockingDepth=MAX(BlockingDepth)
    FROM dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ApplyBlockingSynthesis
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE s
       SET
         PrimaryCause =
           CASE WHEN b.RootCauseRole='PRIMARY'
                THEN N'Blocking/wait-chain contention prevented the affected request from progressing.'
                ELSE s.PrimaryCause END,
         PrimaryEvidence =
           CASE WHEN b.RootCauseRole='PRIMARY'
                THEN b.EvidenceSummary
                ELSE s.PrimaryEvidence END,
         ContributingFactor1 =
           CASE WHEN b.RootCauseRole='CONTRIBUTING'
                THEN N'Blocking/wait-chain contention amplified elapsed time.'
                ELSE s.ContributingFactor1 END,
         ContributingEvidence1 =
           CASE WHEN b.RootCauseRole='CONTRIBUTING'
                THEN b.EvidenceSummary
                ELSE s.ContributingEvidence1 END,
         Action1 =
           CASE WHEN b.RootCauseRole='PRIMARY'
                THEN CONCAT(N'Investigate head blocker session ',
                            b.HeadBlockerSessionID,
                            N', its open transaction, application owner, and statement.')
                ELSE s.Action1 END,
         Action2 =
           CASE WHEN b.RootCauseRole='PRIMARY'
                THEN N'Correct the blocking transaction/concurrency pattern before changing the victim query plan.'
                ELSE s.Action2 END,
         Confidence =
           CASE WHEN b.RootCauseRole='PRIMARY' AND b.Confidence='HIGH'
                THEN 'HIGH' ELSE s.Confidence END,
         ExecutiveSummary =
           CASE WHEN b.RootCauseRole='PRIMARY'
                THEN CONCAT
                     (
                         N'Probable root cause: blocking/wait-chain contention. Victim session ',
                         b.VictimSessionID,
                         N' was blocked behind head blocker session ',
                         COALESCE(CONVERT(varchar(20),b.HeadBlockerSessionID),'unknown'),
                         N' with chain depth ',b.BlockingDepth,
                         N'. Wait type=',COALESCE(b.WaitType,N'UNKNOWN'),
                         N'. ',b.EvidenceSummary
                     )
                ELSE s.ExecutiveSummary END
    FROM dbo.RCA_RootCauseSynthesis s
    JOIN dbo.RCA_BlockingEvidence b
      ON b.CaptureRunID=s.CaptureRunID
     AND b.VictimExecutionEvidenceID=s.ExecutionEvidenceID
    WHERE s.CaptureRunID=@CaptureRunID;

    SELECT
          CaptureRunID=@CaptureRunID
        , BlockingSynthesisUpdated=@@ROWCOUNT;
END;
GO

/* Integrate into existing analysis workflow if procedure exists. */
IF OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun',N'P') IS NOT NULL
BEGIN
    DECLARE @def nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun'));

    IF @def NOT LIKE N'%usp_RCA_BuildBlockingEvidence%'
    BEGIN
        SET @def=REPLACE
        (
            @def,
            N'EXEC dbo.usp_RCA_BuildRootCauseSynthesis',
            N'EXEC dbo.usp_RCA_BuildBlockingEvidence @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_BuildRootCauseSynthesis'
        );

        SET @def=REPLACE
        (
            @def,
            N'EXEC dbo.usp_RCA_ApplyMemorySpillSynthesis',
            N'EXEC dbo.usp_RCA_ApplyMemorySpillSynthesis'
        );

        IF @def LIKE N'%usp_RCA_ApplyMemorySpillSynthesis%'
           AND @def NOT LIKE N'%usp_RCA_ApplyBlockingSynthesis%'
        BEGIN
            SET @def=REPLACE
            (
                @def,
                N'EXEC dbo.usp_RCA_ApplyMemorySpillSynthesis @CaptureRunID=@CaptureRunID;',
                N'EXEC dbo.usp_RCA_ApplyMemorySpillSynthesis @CaptureRunID=@CaptureRunID;
    EXEC dbo.usp_RCA_ApplyBlockingSynthesis @CaptureRunID=@CaptureRunID;'
            );
        END;

        IF LEFT(LTRIM(@def),16)=N'CREATE PROCEDURE '
            SET @def=STUFF(@def,1,16,N'CREATE OR ALTER PROCEDURE ');
        ELSE IF LEFT(LTRIM(@def),12)=N'CREATE PROC '
            SET @def=STUFF(@def,1,12,N'CREATE OR ALTER PROC ');

        EXEC sys.sp_executesql @def;
    END;
END;
GO

SELECT
      BlockingEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidenceView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockingEvidence',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , BlockingSynthesis =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyBlockingSynthesis',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , AnalyzeWorkflow =
        CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_AnalyzeCaptureRun'))
                  LIKE N'%usp_RCA_BuildBlockingEvidence%'
             THEN 'PASS' ELSE 'FAIL' END;
GO
