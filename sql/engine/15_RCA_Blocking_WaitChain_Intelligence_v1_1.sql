
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


/*==============================================================================
Detector implementation
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildBlockingEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE dbo.RCA_BlockingEvidence
    WHERE CaptureRunID=@CaptureRunID;

    /*
      The existing RCA sampler is intentionally not guessed here.
      First determine which sampler table contains the blocking columns.
      If none is found, return a precise installation message rather than
      creating malformed dynamic SQL.
    */
    DECLARE @SourceObjectID int;

    SELECT TOP (1) @SourceObjectID=t.object_id
    FROM sys.tables t
    WHERE EXISTS
    (
        SELECT 1 FROM sys.columns c
        WHERE c.object_id=t.object_id
          AND c.name IN (N'BlockingSessionID',N'blocking_session_id')
    )
    AND EXISTS
    (
        SELECT 1 FROM sys.columns c
        WHERE c.object_id=t.object_id
          AND c.name IN (N'SessionID',N'session_id')
    )
    AND EXISTS
    (
        SELECT 1 FROM sys.columns c
        WHERE c.object_id=t.object_id
          AND c.name=N'CaptureRunID'
    )
    ORDER BY
        CASE
          WHEN t.name LIKE N'RCA%Snapshot%' THEN 1
          WHEN t.name LIKE N'RCA%Sample%' THEN 2
          ELSE 3
        END,
        t.name;

    IF @SourceObjectID IS NULL
    BEGIN
        THROW 51070,
        'Blocking detector installed, but no sampler table containing CaptureRunID + SessionID + BlockingSessionID was found. Run the sampler schema discovery query supplied with Run 7 before executing the detector.',
        1;
    END;

    /*
      Actual chain population is installed after sampler-schema discovery.
      This deliberate guard prevents assumptions about column names in an
      already-working collector.
    */
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RCA_ApplyBlockingSynthesis
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE s
       SET PrimaryCause =
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
                              CONVERT(varchar(20),b.HeadBlockerSessionID),
                              N', its open transaction, application owner, and statement.')
                  ELSE s.Action1 END,
           Action2 =
             CASE WHEN b.RootCauseRole='PRIMARY'
                  THEN N'Correct the blocking transaction/concurrency pattern before changing the victim query plan.'
                  ELSE s.Action2 END,
           Confidence =
             CASE WHEN b.RootCauseRole='PRIMARY'
                       AND b.Confidence='HIGH'
                  THEN 'HIGH'
                  ELSE s.Confidence END,
           ExecutiveSummary =
             CASE WHEN b.RootCauseRole='PRIMARY'
                  THEN CONCAT(
                       N'Probable root cause: blocking/wait-chain contention. Victim session ',
                       CONVERT(varchar(20),b.VictimSessionID),
                       N' was blocked behind head blocker session ',
                       COALESCE(CONVERT(varchar(20),b.HeadBlockerSessionID),'unknown'),
                       N' with chain depth ',
                       CONVERT(varchar(20),b.BlockingDepth),
                       N'. Wait type=',
                       COALESCE(b.WaitType,N'UNKNOWN'),
                       N'. ',
                       b.EvidenceSummary)
                  ELSE s.ExecutiveSummary END
    FROM dbo.RCA_RootCauseSynthesis s
    INNER JOIN dbo.RCA_BlockingEvidence b
      ON b.CaptureRunID=s.CaptureRunID
     AND b.VictimExecutionEvidenceID=s.ExecutionEvidenceID
    WHERE s.CaptureRunID=@CaptureRunID;

    SELECT
        CaptureRunID=@CaptureRunID,
        BlockingSynthesisUpdated=@@ROWCOUNT;
END;
GO

SELECT
      BlockingEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_BlockingEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingEvidenceView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_BlockingEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildBlockingEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BlockingSynthesis =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ApplyBlockingSynthesis',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO

/*==============================================================================
SAMPLER SCHEMA DISCOVERY -- RUN THIS NEXT

This is intentionally included before we bind the detector to the existing
sampler. It lets us use the real collector schema instead of patching guesses.
==============================================================================*/
SELECT
      TableName=QUOTENAME(SCHEMA_NAME(t.schema_id))+N'.'+QUOTENAME(t.name)
    , c.column_id
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
    , c.max_length
    , c.precision
    , c.scale
    , c.is_nullable
FROM sys.tables t
JOIN sys.columns c
  ON c.object_id=t.object_id
WHERE
       t.name LIKE N'%RCA%'
   AND
   (
          c.name IN
          (
              N'CaptureRunID',
              N'SessionID',N'session_id',
              N'BlockingSessionID',N'blocking_session_id',
              N'WaitType',N'wait_type',
              N'WaitTimeMs',N'wait_time_ms',
              N'CaptureTime',N'CaptureTimeUTC',
              N'SampleTimeUTC',N'SnapshotTimeUTC',
              N'DatabaseName',N'database_name',
              N'HostName',N'host_name',
              N'ProgramName',N'program_name',
              N'LoginName',N'login_name',
              N'RunningStatement',N'StatementText',
              N'InputBuffer',N'SqlText',
              N'OpenTransactionCount',N'open_transaction_count'
          )
       OR t.name LIKE N'%Snapshot%'
       OR t.name LIKE N'%Sample%'
   )
ORDER BY t.name,c.column_id;
GO
