USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  51_RCA_Blocker_Transaction_Evidence_v1.sql

  PURPOSE
  -------
  Add the missing PERSISTED transaction / lock-ownership evidence needed to
  answer the DBA question:

      "Why is DB1 slow?"

  specifically for blocking incidents:

      Which session was blocking?
      What transaction was open?
      When did that transaction begin?
      How old was it?
      What SQL batch / statement was active?
      Which lock resource was being held?
      What object / index can SQL Server map that lock to?
      Which victim request was waiting behind it?

  IMPORTANT
  ---------
  This script is ADDITIVE.

  It does NOT:
      - change root-cause thresholds
      - change root-cause domains
      - rebuild historical findings
      - rewrite Capture 38 / 39 evidence
      - manufacture transaction history that was never captured

  It creates a new evidence family that must be sampled DURING an incident.

  NEW OBJECTS
  -----------
      dbo.RCA_BlockerTransactionEvidence
      dbo.usp_RCA_CaptureBlockerTransactionEvidence
      dbo.vw_RCA_BlockerTransactionEvidence
      dbo.usp_RCA_ShowBlockerTransactionEvidence

  SAMPLER INTEGRATION
  -------------------
  During each RCA sampler interval, call:

      EXEC DBA.dbo.usp_RCA_CaptureBlockerTransactionEvidence
           @CaptureRunID = <current CaptureRunID>;

  This procedure is intentionally safe to call even when there is no blocking.
  In that case it simply inserts zero rows.

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
BEGIN
    THROW 55100,
          'Script 51 requires dbo.RCA_CaptureRun.',
          1;
END;
GO


/*==============================================================================
  1. TRANSACTION / LOCK EVIDENCE TABLE
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_BlockerTransactionEvidence
    (
          BlockerTransactionEvidenceID bigint IDENTITY(1,1) NOT NULL
              CONSTRAINT PK_RCA_BlockerTransactionEvidence PRIMARY KEY

        , CaptureRunID bigint NOT NULL

        , SampleTimeUTC datetime2(3) NOT NULL

        -----------------------------------------------------------------------
        -- Victim / blocking relationship
        -----------------------------------------------------------------------
        , VictimSessionID int NOT NULL
        , ImmediateBlockerSessionID int NULL
        , HeadBlockerSessionID int NULL
        , BlockingDepth int NULL
        , VictimDatabaseName sysname NULL
        , VictimWaitType nvarchar(256) NULL
        , VictimWaitDurationMs bigint NULL
        , VictimStatus nvarchar(60) NULL
        , VictimCommand nvarchar(128) NULL
        , VictimHostName nvarchar(256) NULL
        , VictimProgramName nvarchar(512) NULL
        , VictimLoginName nvarchar(256) NULL
        , VictimBatchText nvarchar(max) NULL
        , VictimStatementText nvarchar(max) NULL

        -----------------------------------------------------------------------
        -- Head blocker identity
        -----------------------------------------------------------------------
        , BlockerDatabaseName sysname NULL
        , BlockerStatus nvarchar(60) NULL
        , BlockerCommand nvarchar(128) NULL
        , BlockerHostName nvarchar(256) NULL
        , BlockerProgramName nvarchar(512) NULL
        , BlockerLoginName nvarchar(256) NULL
        , BlockerBatchText nvarchar(max) NULL
        , BlockerStatementText nvarchar(max) NULL
        , BlockerOpenTransactionCount int NULL

        -----------------------------------------------------------------------
        -- Persisted transaction state
        -----------------------------------------------------------------------
        , TransactionID bigint NULL
        , TransactionBeginTimeUTC datetime2(3) NULL
        , TransactionAgeMs bigint NULL
        , TransactionType int NULL
        , TransactionState int NULL
        , TransactionName nvarchar(256) NULL
        , TransactionUOW uniqueidentifier NULL
        , IsUserTransaction bit NULL
        , IsLocal bit NULL

        -----------------------------------------------------------------------
        -- Lock ownership
        -----------------------------------------------------------------------
        , LockResourceType nvarchar(60) NULL
        , LockResourceSubtype nvarchar(60) NULL
        , LockDatabaseID int NULL
        , LockDatabaseName sysname NULL
        , LockRequestMode nvarchar(60) NULL
        , LockRequestStatus nvarchar(60) NULL
        , LockRequestOwnerType nvarchar(60) NULL
        , LockRequestOwnerID bigint NULL
        , ResourceAssociatedEntityID bigint NULL
        , ResourceDescription nvarchar(2048) NULL

        -----------------------------------------------------------------------
        -- Object mapping when SQL Server exposes a mappable resource
        -----------------------------------------------------------------------
        , LockedObjectID int NULL
        , LockedSchemaName sysname NULL
        , LockedObjectName sysname NULL
        , LockedIndexID int NULL
        , LockedIndexName sysname NULL
        , LockedPartitionNumber int NULL

        -----------------------------------------------------------------------
        -- Interpretation / integrity
        -----------------------------------------------------------------------
        , EvidenceSource varchar(50) NOT NULL
              CONSTRAINT DF_RCA_BlockerTransactionEvidence_EvidenceSource
              DEFAULT('LIVE_DMV_SAMPLER')

        , EvidenceIntegrityNote nvarchar(2000) NULL
    );

    CREATE INDEX IX_RCA_BlockerTransactionEvidence_Capture
        ON dbo.RCA_BlockerTransactionEvidence
        (
              CaptureRunID
            , SampleTimeUTC
            , HeadBlockerSessionID
            , VictimSessionID
        );

    CREATE INDEX IX_RCA_BlockerTransactionEvidence_Transaction
        ON dbo.RCA_BlockerTransactionEvidence
        (
              CaptureRunID
            , TransactionID
            , HeadBlockerSessionID
        );

    CREATE INDEX IX_RCA_BlockerTransactionEvidence_Lock
        ON dbo.RCA_BlockerTransactionEvidence
        (
              CaptureRunID
            , LockDatabaseID
            , LockedObjectID
            , LockRequestMode
        );
END;
GO


/*==============================================================================
  2. LIVE CAPTURE PROCEDURE

  DESIGN
  ------
  A. Snapshot current requests / sessions.
  B. Identify blocked victims.
  C. Walk the blocking chain to the head blocker.
  D. Correlate the head blocker to active transaction DMVs.
  E. Capture GRANTED locks owned by the head-blocker transaction/session.
  F. Persist victim + blocker + transaction + lock + object mapping together.

  IMPORTANT
  ---------
  The current statement may be WAITFOR, SELECT, etc.  It tells us what the
  session was doing at sample time.  It does not automatically prove that the
  current statement originally acquired every lock being held.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_CaptureBlockerTransactionEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID = @CaptureRunID
    )
    BEGIN
        DECLARE @msg nvarchar(2048) =
            CONCAT(N'CaptureRunID ',@CaptureRunID,N' does not exist.');
        THROW 55110,@msg,1;
    END;

    DECLARE @SampleTimeUTC datetime2(3) = SYSUTCDATETIME();

    ---------------------------------------------------------------------------
    -- Current request/session snapshot.
    ---------------------------------------------------------------------------
    SELECT
          r.session_id
        , r.blocking_session_id
        , r.database_id
        , r.wait_type
        , r.wait_time
        , r.status
        , r.command
        , r.sql_handle
        , r.statement_start_offset
        , r.statement_end_offset
        , r.open_transaction_count
        , s.host_name
        , s.program_name
        , s.login_name
    INTO #Requests
    FROM sys.dm_exec_requests AS r
    JOIN sys.dm_exec_sessions AS s
      ON s.session_id = r.session_id
    WHERE s.is_user_process = 1
       OR r.blocking_session_id <> 0;

    IF NOT EXISTS
    (
        SELECT 1
        FROM #Requests
        WHERE blocking_session_id > 0
    )
    BEGIN
        SELECT
              CaptureRunID = @CaptureRunID
            , SampleTimeUTC = @SampleTimeUTC
            , TransactionEvidenceRowsInserted = 0
            , Message = 'No blocking relationship existed at this sample.';
        RETURN;
    END;

    ---------------------------------------------------------------------------
    -- Blocking-chain recursion.
    --
    -- Start at each blocked victim. Walk victim -> blocker -> blocker until a
    -- session has no parent blocker in the current request snapshot.
    ---------------------------------------------------------------------------
    ;WITH Chain AS
    (
        SELECT
              VictimSessionID = r.session_id
            , CurrentSessionID = r.session_id
            , ParentBlockerSessionID = r.blocking_session_id
            , Depth = 0
        FROM #Requests AS r
        WHERE r.blocking_session_id > 0

        UNION ALL

        SELECT
              c.VictimSessionID
            , CurrentSessionID = c.ParentBlockerSessionID
            , ParentBlockerSessionID = ISNULL(parent.blocking_session_id,0)
            , Depth = c.Depth + 1
        FROM Chain AS c
        LEFT JOIN #Requests AS parent
          ON parent.session_id = c.ParentBlockerSessionID
        WHERE c.ParentBlockerSessionID > 0
          AND c.Depth < 32
    ),
    Ranked AS
    (
        SELECT
              VictimSessionID
            , CurrentSessionID
            , ParentBlockerSessionID
            , Depth
            , rn = ROW_NUMBER() OVER
              (
                  PARTITION BY VictimSessionID
                  ORDER BY Depth DESC
              )
        FROM Chain
    )
    SELECT
          VictimSessionID
        , HeadBlockerSessionID = CurrentSessionID
        , BlockingDepth = Depth
    INTO #Heads
    FROM Ranked
    WHERE rn = 1
    OPTION (MAXRECURSION 32);

    ---------------------------------------------------------------------------
    -- Normalize cases where recursion lands on the victim itself rather than
    -- the direct blocker.  For a simple one-level chain, the head blocker is
    -- the victim's immediate blocker.
    ---------------------------------------------------------------------------
    UPDATE h
       SET HeadBlockerSessionID = v.blocking_session_id,
           BlockingDepth =
               CASE WHEN h.BlockingDepth < 1 THEN 1 ELSE h.BlockingDepth END
    FROM #Heads AS h
    JOIN #Requests AS v
      ON v.session_id = h.VictimSessionID
    WHERE h.HeadBlockerSessionID = h.VictimSessionID
      AND v.blocking_session_id > 0;

    ---------------------------------------------------------------------------
    -- Build victim/head-blocker pairs and text.
    ---------------------------------------------------------------------------
    SELECT
          h.VictimSessionID
        , ImmediateBlockerSessionID = v.blocking_session_id
        , h.HeadBlockerSessionID
        , h.BlockingDepth

        , VictimDatabaseName = DB_NAME(v.database_id)
        , VictimWaitType = v.wait_type
        , VictimWaitDurationMs = CONVERT(bigint,v.wait_time)
        , VictimStatus = v.status
        , VictimCommand = v.command
        , VictimHostName = v.host_name
        , VictimProgramName = v.program_name
        , VictimLoginName = v.login_name
        , VictimBatchText = vt.text
        , VictimStatementText =
            CASE
              WHEN vt.text IS NULL THEN NULL
              ELSE SUBSTRING
                   (
                       vt.text,
                       (v.statement_start_offset/2)+1,
                       (
                           (
                               CASE v.statement_end_offset
                                 WHEN -1 THEN DATALENGTH(vt.text)
                                 ELSE v.statement_end_offset
                               END
                               - v.statement_start_offset
                           )/2
                       )+1
                   )
            END

        , BlockerDatabaseName = DB_NAME(b.database_id)
        , BlockerStatus = b.status
        , BlockerCommand = b.command
        , BlockerHostName = b.host_name
        , BlockerProgramName = b.program_name
        , BlockerLoginName = b.login_name
        , BlockerBatchText = bt.text
        , BlockerStatementText =
            CASE
              WHEN bt.text IS NULL THEN NULL
              ELSE SUBSTRING
                   (
                       bt.text,
                       (b.statement_start_offset/2)+1,
                       (
                           (
                               CASE b.statement_end_offset
                                 WHEN -1 THEN DATALENGTH(bt.text)
                                 ELSE b.statement_end_offset
                               END
                               - b.statement_start_offset
                           )/2
                       )+1
                   )
            END
        , BlockerOpenTransactionCount = b.open_transaction_count

    INTO #Pairs

    FROM #Heads AS h

    JOIN #Requests AS v
      ON v.session_id = h.VictimSessionID

    LEFT JOIN #Requests AS b
      ON b.session_id = h.HeadBlockerSessionID

    OUTER APPLY sys.dm_exec_sql_text(v.sql_handle) AS vt
    OUTER APPLY sys.dm_exec_sql_text(b.sql_handle) AS bt;

    ---------------------------------------------------------------------------
    -- Persist a row for each granted lock owned by the blocker transaction.
    --
    -- If no lock DMV row maps cleanly, the OUTER APPLY still gives us a
    -- transaction-only evidence row so transaction age is not lost.
    ---------------------------------------------------------------------------
    INSERT dbo.RCA_BlockerTransactionEvidence
    (
          CaptureRunID
        , SampleTimeUTC

        , VictimSessionID
        , ImmediateBlockerSessionID
        , HeadBlockerSessionID
        , BlockingDepth
        , VictimDatabaseName
        , VictimWaitType
        , VictimWaitDurationMs
        , VictimStatus
        , VictimCommand
        , VictimHostName
        , VictimProgramName
        , VictimLoginName
        , VictimBatchText
        , VictimStatementText

        , BlockerDatabaseName
        , BlockerStatus
        , BlockerCommand
        , BlockerHostName
        , BlockerProgramName
        , BlockerLoginName
        , BlockerBatchText
        , BlockerStatementText
        , BlockerOpenTransactionCount

        , TransactionID
        , TransactionBeginTimeUTC
        , TransactionAgeMs
        , TransactionType
        , TransactionState
        , TransactionName
        , TransactionUOW
        , IsUserTransaction
        , IsLocal

        , LockResourceType
        , LockResourceSubtype
        , LockDatabaseID
        , LockDatabaseName
        , LockRequestMode
        , LockRequestStatus
        , LockRequestOwnerType
        , LockRequestOwnerID
        , ResourceAssociatedEntityID
        , ResourceDescription

        , LockedObjectID
        , LockedSchemaName
        , LockedObjectName
        , LockedIndexID
        , LockedIndexName
        , LockedPartitionNumber

        , EvidenceSource
        , EvidenceIntegrityNote
    )
    SELECT
          @CaptureRunID
        , @SampleTimeUTC

        , p.VictimSessionID
        , p.ImmediateBlockerSessionID
        , p.HeadBlockerSessionID
        , p.BlockingDepth
        , p.VictimDatabaseName
        , p.VictimWaitType
        , p.VictimWaitDurationMs
        , p.VictimStatus
        , p.VictimCommand
        , p.VictimHostName
        , p.VictimProgramName
        , p.VictimLoginName
        , p.VictimBatchText
        , p.VictimStatementText

        , p.BlockerDatabaseName
        , p.BlockerStatus
        , p.BlockerCommand
        , p.BlockerHostName
        , p.BlockerProgramName
        , p.BlockerLoginName
        , p.BlockerBatchText
        , p.BlockerStatementText
        , p.BlockerOpenTransactionCount

        , at.transaction_id
        , at.transaction_begin_time
        , CASE
            WHEN at.transaction_begin_time IS NULL THEN NULL
            ELSE DATEDIFF_BIG
                 (
                     millisecond,
                     at.transaction_begin_time,
                     @SampleTimeUTC
                 )
          END
        , at.transaction_type
        , at.transaction_state
        , at.name
        , at.transaction_uow
        , st.is_user_transaction
        , st.is_local

        , lk.resource_type
        , lk.resource_subtype
        , lk.resource_database_id
        , DB_NAME(lk.resource_database_id)
        , lk.request_mode
        , lk.request_status
        , lk.request_owner_type
        , TRY_CONVERT(bigint,lk.request_owner_id)
        , lk.resource_associated_entity_id
        , lk.resource_description

        , obj.ObjectID
        , obj.SchemaName
        , obj.ObjectName
        , obj.IndexID
        , obj.IndexName
        , obj.PartitionNumber

        , 'LIVE_DMV_SAMPLER'
        , CONCAT(
              N'Current-state DMV evidence sampled at ',
              CONVERT(varchar(33),@SampleTimeUTC,126),
              N'. Current blocker statement identifies what the session was executing at sample time; ',
              N'it does not independently prove which earlier statement originally acquired each retained lock.'
          )

    FROM #Pairs AS p

    LEFT JOIN sys.dm_tran_session_transactions AS st
      ON st.session_id = p.HeadBlockerSessionID

    LEFT JOIN sys.dm_tran_active_transactions AS at
      ON at.transaction_id = st.transaction_id

    OUTER APPLY
    (
        SELECT TOP (100)
              l.resource_type
            , l.resource_subtype
            , l.resource_database_id
            , l.request_mode
            , l.request_status
            , l.request_owner_type
            , l.request_owner_id
            , l.resource_associated_entity_id
            , l.resource_description
        FROM sys.dm_tran_locks AS l
        WHERE
            (
                at.transaction_id IS NOT NULL
                AND
                (
                       TRY_CONVERT(bigint,l.request_owner_id) = at.transaction_id
                    OR
                       (
                           l.request_session_id = p.HeadBlockerSessionID
                           AND l.request_status = 'GRANT'
                       )
                )
            )
            OR
            (
                at.transaction_id IS NULL
                AND l.request_session_id = p.HeadBlockerSessionID
                AND l.request_status = 'GRANT'
            )
        ORDER BY
              CASE WHEN l.request_status='GRANT' THEN 1 ELSE 2 END
            , l.resource_type
    ) AS lk

    OUTER APPLY
    (
        SELECT TOP (1)
              ObjectID =
                  COALESCE
                  (
                      ptn.object_id,
                      CASE
                        WHEN lk.resource_type = 'OBJECT'
                        THEN TRY_CONVERT(int,lk.resource_associated_entity_id)
                      END
                  )
            , SchemaName =
                  OBJECT_SCHEMA_NAME
                  (
                      COALESCE
                      (
                          ptn.object_id,
                          CASE
                            WHEN lk.resource_type = 'OBJECT'
                            THEN TRY_CONVERT(int,lk.resource_associated_entity_id)
                          END
                      ),
                      lk.resource_database_id
                  )
            , ObjectName =
                  OBJECT_NAME
                  (
                      COALESCE
                      (
                          ptn.object_id,
                          CASE
                            WHEN lk.resource_type = 'OBJECT'
                            THEN TRY_CONVERT(int,lk.resource_associated_entity_id)
                          END
                      ),
                      lk.resource_database_id
                  )
            , IndexID = ptn.index_id
            , IndexName =
                  CASE
                    WHEN ptn.object_id IS NOT NULL
                     AND ptn.index_id IS NOT NULL
                     AND lk.resource_database_id = DB_ID()
                    THEN
                        (
                            SELECT i.name
                            FROM sys.indexes AS i
                            WHERE i.object_id = ptn.object_id
                              AND i.index_id = ptn.index_id
                        )
                  END
            , PartitionNumber = ptn.partition_number
        FROM
        (
            SELECT
                  p2.object_id
                , p2.index_id
                , p2.partition_number
            FROM sys.partitions AS p2
            WHERE p2.hobt_id = lk.resource_associated_entity_id

            UNION ALL

            SELECT
                  p3.object_id
                , p3.index_id
                , p3.partition_number
            FROM sys.partitions AS p3
            WHERE p3.partition_id = lk.resource_associated_entity_id
        ) AS ptn
    ) AS obj;

    DECLARE @Rows int = @@ROWCOUNT;

    ---------------------------------------------------------------------------
    -- If a blocker had no transaction/lock DMV row at the exact instant of the
    -- join, persist one relationship row rather than losing the sample.
    ---------------------------------------------------------------------------
    IF @Rows = 0
    BEGIN
        INSERT dbo.RCA_BlockerTransactionEvidence
        (
              CaptureRunID
            , SampleTimeUTC
            , VictimSessionID
            , ImmediateBlockerSessionID
            , HeadBlockerSessionID
            , BlockingDepth
            , VictimDatabaseName
            , VictimWaitType
            , VictimWaitDurationMs
            , VictimStatus
            , VictimCommand
            , VictimHostName
            , VictimProgramName
            , VictimLoginName
            , VictimBatchText
            , VictimStatementText
            , BlockerDatabaseName
            , BlockerStatus
            , BlockerCommand
            , BlockerHostName
            , BlockerProgramName
            , BlockerLoginName
            , BlockerBatchText
            , BlockerStatementText
            , BlockerOpenTransactionCount
            , EvidenceSource
            , EvidenceIntegrityNote
        )
        SELECT
              @CaptureRunID
            , @SampleTimeUTC
            , VictimSessionID
            , ImmediateBlockerSessionID
            , HeadBlockerSessionID
            , BlockingDepth
            , VictimDatabaseName
            , VictimWaitType
            , VictimWaitDurationMs
            , VictimStatus
            , VictimCommand
            , VictimHostName
            , VictimProgramName
            , VictimLoginName
            , VictimBatchText
            , VictimStatementText
            , BlockerDatabaseName
            , BlockerStatus
            , BlockerCommand
            , BlockerHostName
            , BlockerProgramName
            , BlockerLoginName
            , BlockerBatchText
            , BlockerStatementText
            , BlockerOpenTransactionCount
            , 'LIVE_DMV_SAMPLER'
            , N'Blocking relationship captured, but no transaction/lock DMV row could be correlated at this exact sample.'
        FROM #Pairs;

        SET @Rows = @@ROWCOUNT;
    END;

    SELECT
          CaptureRunID = @CaptureRunID
        , SampleTimeUTC = @SampleTimeUTC
        , TransactionEvidenceRowsInserted = @Rows
        , Message =
            CASE
              WHEN @Rows > 0
              THEN 'Blocker transaction / lock evidence persisted.'
              ELSE 'Blocking existed, but no blocker transaction evidence row was persisted.'
            END;
END;
GO


/*==============================================================================
  3. HUMAN-FRIENDLY VIEW
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_BlockerTransactionEvidence
AS
SELECT
      e.BlockerTransactionEvidenceID
    , e.CaptureRunID
    , e.SampleTimeUTC

    , e.VictimSessionID
    , e.ImmediateBlockerSessionID
    , e.HeadBlockerSessionID
    , e.BlockingDepth
    , e.VictimDatabaseName
    , e.VictimWaitType
    , e.VictimWaitDurationMs

    , e.BlockerHostName
    , e.BlockerProgramName
    , e.BlockerLoginName
    , e.BlockerBatchText
    , e.BlockerStatementText
    , e.BlockerOpenTransactionCount

    , e.TransactionID
    , e.TransactionBeginTimeUTC
    , e.TransactionAgeMs
    , TransactionAgeSeconds =
        CASE
          WHEN e.TransactionAgeMs IS NULL THEN NULL
          ELSE CONVERT(decimal(19,1),e.TransactionAgeMs/1000.0)
        END
    , e.TransactionType
    , e.TransactionState
    , e.TransactionName
    , e.TransactionUOW
    , e.IsUserTransaction
    , e.IsLocal

    , e.LockResourceType
    , e.LockResourceSubtype
    , e.LockDatabaseName
    , e.LockRequestMode
    , e.LockRequestStatus
    , e.LockRequestOwnerType
    , e.ResourceAssociatedEntityID
    , e.ResourceDescription

    , e.LockedSchemaName
    , e.LockedObjectName
    , e.LockedIndexName
    , e.LockedPartitionNumber

    , TransactionExplanation =
        CONCAT(
            N'Head blocker session ',
            e.HeadBlockerSessionID,
            CASE
              WHEN e.TransactionID IS NOT NULL
              THEN CONCAT(
                    N' owned transaction ',
                    e.TransactionID,
                    N' which began at ',
                    CONVERT(varchar(33),e.TransactionBeginTimeUTC,126),
                    N' and was approximately ',
                    CONVERT(decimal(19,1),e.TransactionAgeMs/1000.0),
                    N' seconds old at the sample. '
                   )
              ELSE
                    N' had no correlated transaction ID persisted at this sample. '
            END,

            CASE
              WHEN e.LockResourceType IS NOT NULL
              THEN CONCAT(
                    N'The blocker held/requested a ',
                    e.LockRequestMode,
                    N' ',
                    e.LockResourceType,
                    N' lock',
                    CASE
                      WHEN e.LockedObjectName IS NOT NULL
                      THEN CONCAT(
                            N' associated with ',
                            QUOTENAME(e.LockDatabaseName),
                            N'.',
                            QUOTENAME(e.LockedSchemaName),
                            N'.',
                            QUOTENAME(e.LockedObjectName),
                            CASE
                              WHEN e.LockedIndexName IS NOT NULL
                              THEN CONCAT(N' index ',QUOTENAME(e.LockedIndexName))
                              ELSE N''
                            END
                           )
                      ELSE N''
                    END,
                    N'. '
                   )
              ELSE N''
            END,

            N'Victim session ',
            e.VictimSessionID,
            N' was waiting on ',
            COALESCE(e.VictimWaitType,N'an unknown wait'),
            N'.'
        )

FROM dbo.RCA_BlockerTransactionEvidence AS e;
GO


/*==============================================================================
  4. DBA REPORT PROCEDURE
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowBlockerTransactionEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          ReportSection = 'BLOCKER TRANSACTION EVIDENCE'
        , *
    FROM dbo.vw_RCA_BlockerTransactionEvidence
    WHERE CaptureRunID = @CaptureRunID
    ORDER BY
          SampleTimeUTC
        , VictimSessionID
        , HeadBlockerSessionID
        , BlockerTransactionEvidenceID;
END;
GO


/*==============================================================================
  5. DEPLOYMENT VALIDATION
==============================================================================*/
SELECT
      ValidationSection = '1 - SCRIPT 51 DEPLOYMENT'
    , EvidenceTable =
        CASE
          WHEN OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence',N'U') IS NOT NULL
          THEN 'PASS' ELSE 'FAIL'
        END
    , CaptureProcedure =
        CASE
          WHEN OBJECT_ID(N'dbo.usp_RCA_CaptureBlockerTransactionEvidence',N'P') IS NOT NULL
          THEN 'PASS' ELSE 'FAIL'
        END
    , EvidenceView =
        CASE
          WHEN OBJECT_ID(N'dbo.vw_RCA_BlockerTransactionEvidence',N'V') IS NOT NULL
          THEN 'PASS' ELSE 'FAIL'
        END
    , ReportProcedure =
        CASE
          WHEN OBJECT_ID(N'dbo.usp_RCA_ShowBlockerTransactionEvidence',N'P') IS NOT NULL
          THEN 'PASS' ELSE 'FAIL'
        END
    , ExistingEvidenceModified = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , NewCaptureStarted = 'NO';
GO


/*==============================================================================
  6. HISTORICAL CAPTURE 39 EXPECTATION

  Script 51 did not exist during Capture 39, so we intentionally expect ZERO
  rows for Capture 39.

  This proves we are not backfilling transaction history after the fact.
==============================================================================*/
SELECT
      ValidationSection = '2 - CAPTURE 39 HISTORICAL INTEGRITY'
    , CaptureRunID = 39
    , TransactionEvidenceRows =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_BlockerTransactionEvidence
            WHERE CaptureRunID = 39
        )
    , ExpectedResult =
        '0 rows expected because transaction evidence was not sampled during Capture 39'
    , IntegrityResult =
        CASE
          WHEN NOT EXISTS
          (
              SELECT 1
              FROM dbo.RCA_BlockerTransactionEvidence
              WHERE CaptureRunID = 39
          )
          THEN 'PASS - NO HISTORICAL TRANSACTION EVIDENCE MANUFACTURED'
          ELSE 'REVIEW - CAPTURE 39 CONTAINS NEW TRANSACTION EVIDENCE ROWS'
        END;
GO


/*==============================================================================
  7. SAMPLER INTEGRATION INSTRUCTION

  DO NOT blindly alter the existing sampler here because we have intentionally
  not assumed its exact implementation.

  The one line to integrate into the existing sampler loop is:

      EXEC DBA.dbo.usp_RCA_CaptureBlockerTransactionEvidence
           @CaptureRunID = @CaptureRunID;

  It should run at the SAME interval as RCA_ServerSnapshot / blocking sampling.

  After integration, the next controlled blocking capture should prove:
      TransactionID populated
      TransactionBeginTimeUTC populated
      TransactionAgeMs populated
      BlockerOpenTransactionCount populated when DMV exposes it
      Lock resource / mode populated
      Object/index populated when mappable
==============================================================================*/
SELECT
      ValidationSection = '3 - SAMPLER INTEGRATION'
    , IntegrationRequired = 'YES'
    , ProcedureToCall = 'DBA.dbo.usp_RCA_CaptureBlockerTransactionEvidence'
    , RecommendedLocation =
        'Inside the existing RCA sampler loop, once per normal sampler interval'
    , HistoricalBackfill = 'NO'
    , NextValidation =
        'Run a fresh controlled blocking capture only after sampler integration.';
GO


/*==============================================================================
  8. SAFETY
==============================================================================*/
SELECT
      ValidationSection = '4 - SCRIPT 51 SAFETY'
    , NewEvidenceFamilyAdded = 'YES'
    , ExistingEvidenceModified = 'NO'
    , Capture38Modified = 'NO'
    , Capture39Modified = 'NO'
    , FindingsRebuilt = 'NO'
    , DetectorThresholdsChanged = 'NO'
    , RootCauseDomainsChanged = 'NO'
    , RootCauseLogicChanged = 'NO'
    , HistoricalTransactionDataInvented = 'NO'
    , NewCaptureStarted = 'NO'
    , NextStep =
        'Integrate one call to usp_RCA_CaptureBlockerTransactionEvidence into the existing sampler loop, then perform the next controlled blocking capture to validate transaction begin time, transaction age, and lock-resource attribution.';
GO
