USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  54_RCA_Blocker_Transaction_Collector_Hardening_v2.sql

  PURPOSE
  -------
  Harden blocker-transaction evidence collection after Capture 40 proved:

      Server snapshots           = captured
      Blocking evidence          = captured
      Head blocker               = identified
      Blocker execution evidence = captured
      Transaction evidence       = 0 rows

  The existing collector was called from the sampler inside TRY/CATCH, but
  failures were intentionally suppressed. That protected the primary sampler,
  but it also hid the reason transaction evidence was not persisted.

  SCRIPT 54 DOES FOUR THINGS
  --------------------------
  1. Adds persistent collector-error telemetry.
  2. Replaces the transaction collector with a staged design:
         A. blocking relationship
         B. blocker session
         C. transaction identity / age
         D. optional lock enrichment
     The base evidence row is committed to the INSERT even if lock/object
     enrichment cannot be resolved.
  3. Updates the sampler so supplemental collector failures are logged rather
     than silently discarded.
  4. Validates deployment without starting another capture.

  IMPORTANT
  ---------
  This script does NOT:
      - alter RCA root-cause thresholds
      - alter cause-ranking logic
      - rebuild historical findings
      - fabricate Capture 40 transaction evidence
      - start Capture 41

==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Missing nvarchar(max)=N'';
DECLARE @Message nvarchar(2048);

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL
    SET @Missing += N' dbo.RCA_CaptureRun;';

IF OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence',N'U') IS NULL
    SET @Missing += N' dbo.RCA_BlockerTransactionEvidence;';

IF OBJECT_ID(N'dbo.usp_RCA_CaptureLiveSnapshot',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_CaptureLiveSnapshot;';

IF OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_RunSampler;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message=CONCAT(N'Script 54 prerequisites are missing:',@Missing);
    THROW 55400,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 54 PRE-FLIGHT'
    , CaptureRun='PASS'
    , TransactionEvidenceTable='PASS'
    , LiveSnapshot='PASS'
    , Sampler='PASS'
    , ExistingEvidenceModified='NO'
    , RootCauseThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  1. COLLECTOR ERROR TELEMETRY
==============================================================================*/
IF OBJECT_ID(N'dbo.RCA_CollectorError',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_CollectorError
    (
          CollectorErrorID bigint IDENTITY(1,1) NOT NULL
              CONSTRAINT PK_RCA_CollectorError PRIMARY KEY
        , CaptureRunID bigint NULL
        , ErrorTimeUTC datetime2(3) NOT NULL
              CONSTRAINT DF_RCA_CollectorError_ErrorTimeUTC
              DEFAULT SYSUTCDATETIME()
        , CollectorName sysname NOT NULL
        , ErrorNumber int NULL
        , ErrorSeverity int NULL
        , ErrorState int NULL
        , ErrorProcedure nvarchar(256) NULL
        , ErrorLine int NULL
        , ErrorMessage nvarchar(4000) NULL
        , ContextMessage nvarchar(2000) NULL
    );

    CREATE INDEX IX_RCA_CollectorError_CaptureTime
        ON dbo.RCA_CollectorError
        (
              CaptureRunID
            , ErrorTimeUTC
        );
END;
GO


/*==============================================================================
  2. ERROR LOGGING PROCEDURE
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_LogCollectorError
      @CaptureRunID bigint = NULL
    , @CollectorName sysname
    , @ErrorNumber int = NULL
    , @ErrorSeverity int = NULL
    , @ErrorState int = NULL
    , @ErrorProcedure nvarchar(256) = NULL
    , @ErrorLine int = NULL
    , @ErrorMessage nvarchar(4000) = NULL
    , @ContextMessage nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        INSERT dbo.RCA_CollectorError
        (
              CaptureRunID
            , ErrorTimeUTC
            , CollectorName
            , ErrorNumber
            , ErrorSeverity
            , ErrorState
            , ErrorProcedure
            , ErrorLine
            , ErrorMessage
            , ContextMessage
        )
        VALUES
        (
              @CaptureRunID
            , SYSUTCDATETIME()
            , @CollectorName
            , @ErrorNumber
            , @ErrorSeverity
            , @ErrorState
            , @ErrorProcedure
            , @ErrorLine
            , @ErrorMessage
            , @ContextMessage
        );
    END TRY
    BEGIN CATCH
        -- Error logging must never kill the RCA sampler.
    END CATCH;
END;
GO


/*==============================================================================
  3. HARDENED TRANSACTION COLLECTOR

  DESIGN CHANGE
  -------------
  The old collector tried to perform transaction correlation, lock correlation,
  object mapping, and persistence in one large INSERT.

  This version first builds the blocking pair, then transaction state, and
  inserts a BASE evidence row. Only after that does it attempt optional lock
  enrichment.

  Therefore:
      failure mapping a lock/object != loss of transaction evidence.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_CaptureBlockerTransactionEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @SampleTimeUTC datetime2(3)=SYSUTCDATETIME();

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
    BEGIN
        THROW 55110,N'CaptureRunID does not exist.',1;
    END;

    BEGIN TRY

        /*----------------------------------------------------------------------
          A. CURRENT REQUEST / SESSION SNAPSHOT
        ----------------------------------------------------------------------*/
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
          ON s.session_id=r.session_id
        WHERE s.is_user_process=1
           OR r.blocking_session_id<>0;

        IF NOT EXISTS
        (
            SELECT 1
            FROM #Requests
            WHERE blocking_session_id>0
        )
        BEGIN
            SELECT
                  CaptureRunID=@CaptureRunID
                , SampleTimeUTC=@SampleTimeUTC
                , BlockingPairs=0
                , TransactionEvidenceRowsInserted=0
                , LockEnrichmentRowsUpdated=0
                , Message='No blocking relationship existed at this sample.';
            RETURN;
        END;


        /*----------------------------------------------------------------------
          B. WALK EACH BLOCKING CHAIN
        ----------------------------------------------------------------------*/
        ;WITH Chain AS
        (
            SELECT
                  VictimSessionID=r.session_id
                , CurrentSessionID=r.session_id
                , ParentBlockerSessionID=r.blocking_session_id
                , Depth=0
            FROM #Requests AS r
            WHERE r.blocking_session_id>0

            UNION ALL

            SELECT
                  c.VictimSessionID
                , CurrentSessionID=c.ParentBlockerSessionID
                , ParentBlockerSessionID=ISNULL(parent.blocking_session_id,0)
                , Depth=c.Depth+1
            FROM Chain AS c
            LEFT JOIN #Requests AS parent
              ON parent.session_id=c.ParentBlockerSessionID
            WHERE c.ParentBlockerSessionID>0
              AND c.Depth<32
        ),
        Ranked AS
        (
            SELECT
                  VictimSessionID
                , CurrentSessionID
                , ParentBlockerSessionID
                , Depth
                , rn=ROW_NUMBER() OVER
                    (
                        PARTITION BY VictimSessionID
                        ORDER BY Depth DESC
                    )
            FROM Chain
        )
        SELECT
              VictimSessionID
            , HeadBlockerSessionID=CurrentSessionID
            , BlockingDepth=Depth
        INTO #Heads
        FROM Ranked
        WHERE rn=1
        OPTION (MAXRECURSION 32);

        UPDATE h
           SET HeadBlockerSessionID=v.blocking_session_id,
               BlockingDepth=CASE WHEN h.BlockingDepth<1 THEN 1 ELSE h.BlockingDepth END
        FROM #Heads AS h
        JOIN #Requests AS v
          ON v.session_id=h.VictimSessionID
        WHERE h.HeadBlockerSessionID=h.VictimSessionID
          AND v.blocking_session_id>0;


        /*----------------------------------------------------------------------
          C. BUILD PAIRS

          Important change:
          A head blocker can sometimes be sleeping and therefore absent from
          dm_exec_requests while still owning an open transaction.

          We therefore obtain blocker identity from dm_exec_sessions even when
          there is no current blocker request row.
        ----------------------------------------------------------------------*/
        SELECT
              h.VictimSessionID
            , ImmediateBlockerSessionID=v.blocking_session_id
            , h.HeadBlockerSessionID
            , h.BlockingDepth

            , VictimDatabaseName=DB_NAME(v.database_id)
            , VictimWaitType=v.wait_type
            , VictimWaitDurationMs=CONVERT(bigint,v.wait_time)
            , VictimStatus=v.status
            , VictimCommand=v.command
            , VictimHostName=v.host_name
            , VictimProgramName=v.program_name
            , VictimLoginName=v.login_name
            , VictimBatchText=vt.text
            , VictimStatementText=
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

            , BlockerDatabaseName=DB_NAME(br.database_id)
            , BlockerStatus=COALESCE(br.status,bs.status)
            , BlockerCommand=br.command
            , BlockerHostName=bs.host_name
            , BlockerProgramName=bs.program_name
            , BlockerLoginName=bs.login_name
            , BlockerBatchText=bt.text
            , BlockerStatementText=
                CASE
                  WHEN bt.text IS NULL OR br.session_id IS NULL THEN NULL
                  ELSE SUBSTRING
                       (
                           bt.text,
                           (br.statement_start_offset/2)+1,
                           (
                               (
                                   CASE br.statement_end_offset
                                     WHEN -1 THEN DATALENGTH(bt.text)
                                     ELSE br.statement_end_offset
                                   END
                                   - br.statement_start_offset
                               )/2
                           )+1
                       )
                END
            , BlockerOpenTransactionCount=
                COALESCE(br.open_transaction_count,bs.open_transaction_count)

        INTO #Pairs

        FROM #Heads AS h

        JOIN #Requests AS v
          ON v.session_id=h.VictimSessionID

        LEFT JOIN #Requests AS br
          ON br.session_id=h.HeadBlockerSessionID

        LEFT JOIN sys.dm_exec_sessions AS bs
          ON bs.session_id=h.HeadBlockerSessionID

        OUTER APPLY sys.dm_exec_sql_text(v.sql_handle) AS vt
        OUTER APPLY sys.dm_exec_sql_text(br.sql_handle) AS bt;


        /*----------------------------------------------------------------------
          D. TRANSACTION STATE

          One row per pair + correlated session transaction.

          If SQL Server exposes no transaction DMV row at that exact instant,
          LEFT JOIN preserves the blocker pair anyway.
        ----------------------------------------------------------------------*/
        SELECT
              p.*
            , TransactionID=st.transaction_id
            , TransactionBeginTimeUTC=at.transaction_begin_time
            , TransactionAgeMs=
                CASE
                  WHEN at.transaction_begin_time IS NULL THEN NULL
                  ELSE DATEDIFF_BIG
                       (
                           millisecond,
                           at.transaction_begin_time,
                           @SampleTimeUTC
                       )
                END
            , TransactionType=at.transaction_type
            , TransactionState=at.transaction_state
            , TransactionName=at.name
            , TransactionUOW=at.transaction_uow
            , IsUserTransaction=st.is_user_transaction
            , IsLocal=st.is_local
        INTO #TxnPairs
        FROM #Pairs AS p
        LEFT JOIN sys.dm_tran_session_transactions AS st
          ON st.session_id=p.HeadBlockerSessionID
        LEFT JOIN sys.dm_tran_active_transactions AS at
          ON at.transaction_id=st.transaction_id;


        /*----------------------------------------------------------------------
          E. PERSIST BASE TRANSACTION EVIDENCE FIRST
        ----------------------------------------------------------------------*/
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

            , TransactionID
            , TransactionBeginTimeUTC
            , TransactionAgeMs
            , TransactionType
            , TransactionState
            , TransactionName
            , TransactionUOW
            , IsUserTransaction
            , IsLocal

            , 'LIVE_DMV_SAMPLER'
            , CONCAT
              (
                  N'Base blocker/transaction evidence persisted at ',
                  CONVERT(varchar(33),@SampleTimeUTC,126),
                  N'. Lock/object enrichment is optional and must not determine whether this base evidence survives.'
              )
        FROM #TxnPairs;

        DECLARE @BaseRows int=@@ROWCOUNT;


        /*----------------------------------------------------------------------
          F. OPTIONAL LOCK ENRICHMENT

          Do not fail base collection if this section fails.
          Enrich each new base evidence row with ONE representative GRANTED
          blocker lock. This is sufficient to prove lock ownership/resource
          without multiplying base transaction rows.

          Cross-database object names are intentionally NOT resolved here.
          Resource database ID/entity IDs are persisted first. Object/index
          mapping can be a separate later enrichment step.
        ----------------------------------------------------------------------*/
        DECLARE @LockRowsUpdated int=0;

        BEGIN TRY

            ;WITH Candidate AS
            (
                SELECT
                      e.BlockerTransactionEvidenceID
                    , l.resource_type
                    , l.resource_subtype
                    , l.resource_database_id
                    , l.request_mode
                    , l.request_status
                    , l.request_owner_type
                    , LockRequestOwnerID=TRY_CONVERT(bigint,l.request_owner_id)
                    , l.resource_associated_entity_id
                    , l.resource_description
                    , rn=ROW_NUMBER() OVER
                        (
                            PARTITION BY e.BlockerTransactionEvidenceID
                            ORDER BY
                                  CASE WHEN l.request_status='GRANT' THEN 1 ELSE 2 END
                                , CASE l.resource_type
                                    WHEN 'KEY' THEN 1
                                    WHEN 'RID' THEN 2
                                    WHEN 'PAGE' THEN 3
                                    WHEN 'HOBT' THEN 4
                                    WHEN 'OBJECT' THEN 5
                                    ELSE 6
                                  END
                                , l.resource_type
                        )
                FROM dbo.RCA_BlockerTransactionEvidence AS e
                JOIN sys.dm_tran_locks AS l
                  ON l.request_session_id=e.HeadBlockerSessionID
                 AND l.request_status='GRANT'
                WHERE e.CaptureRunID=@CaptureRunID
                  AND e.SampleTimeUTC=@SampleTimeUTC
            )
            UPDATE e
               SET LockResourceType=c.resource_type,
                   LockResourceSubtype=c.resource_subtype,
                   LockDatabaseID=c.resource_database_id,
                   LockDatabaseName=DB_NAME(c.resource_database_id),
                   LockRequestMode=c.request_mode,
                   LockRequestStatus=c.request_status,
                   LockRequestOwnerType=c.request_owner_type,
                   LockRequestOwnerID=c.LockRequestOwnerID,
                   ResourceAssociatedEntityID=c.resource_associated_entity_id,
                   ResourceDescription=c.resource_description,
                   EvidenceIntegrityNote=
                       CONCAT
                       (
                           e.EvidenceIntegrityNote,
                           N' Representative granted lock enrichment succeeded.'
                       )
            FROM dbo.RCA_BlockerTransactionEvidence AS e
            JOIN Candidate AS c
              ON c.BlockerTransactionEvidenceID=e.BlockerTransactionEvidenceID
             AND c.rn=1;

            SET @LockRowsUpdated=@@ROWCOUNT;

        END TRY
        BEGIN CATCH

            DECLARE
                  @LockErrorNumber int = ERROR_NUMBER()
                , @LockErrorSeverity int = ERROR_SEVERITY()
                , @LockErrorState int = ERROR_STATE()
                , @LockErrorProcedure nvarchar(256) = ERROR_PROCEDURE()
                , @LockErrorLine int = ERROR_LINE()
                , @LockErrorMessage nvarchar(4000) = ERROR_MESSAGE();

            EXEC dbo.usp_RCA_LogCollectorError
                 @CaptureRunID=@CaptureRunID,
                 @CollectorName=N'usp_RCA_CaptureBlockerTransactionEvidence.LockEnrichment',
                 @ErrorNumber=@LockErrorNumber,
                 @ErrorSeverity=@LockErrorSeverity,
                 @ErrorState=@LockErrorState,
                 @ErrorProcedure=@LockErrorProcedure,
                 @ErrorLine=@LockErrorLine,
                 @ErrorMessage=@LockErrorMessage,
                 @ContextMessage=N'Base transaction evidence was already persisted. Lock enrichment failed only.';

        END CATCH;


        SELECT
              CaptureRunID=@CaptureRunID
            , SampleTimeUTC=@SampleTimeUTC
            , BlockingPairs=(SELECT COUNT(*) FROM #Pairs)
            , TransactionEvidenceRowsInserted=@BaseRows
            , LockEnrichmentRowsUpdated=@LockRowsUpdated
            , Message=
                CASE
                  WHEN @BaseRows>0
                  THEN 'Base blocker transaction evidence persisted.'
                  ELSE 'No blocker transaction evidence row was produced.'
                END;

    END TRY
    BEGIN CATCH

        DECLARE
              @ErrorNumber int=ERROR_NUMBER()
            , @ErrorSeverity int=ERROR_SEVERITY()
            , @ErrorState int=ERROR_STATE()
            , @ErrorProcedure nvarchar(256)=ERROR_PROCEDURE()
            , @ErrorLine int=ERROR_LINE()
            , @ErrorMessage nvarchar(4000)=ERROR_MESSAGE();

        EXEC dbo.usp_RCA_LogCollectorError
             @CaptureRunID=@CaptureRunID,
             @CollectorName=N'usp_RCA_CaptureBlockerTransactionEvidence',
             @ErrorNumber=@ErrorNumber,
             @ErrorSeverity=@ErrorSeverity,
             @ErrorState=@ErrorState,
             @ErrorProcedure=@ErrorProcedure,
             @ErrorLine=@ErrorLine,
             @ErrorMessage=@ErrorMessage,
             @ContextMessage=N'Hardened collector failed before completing base persistence.';

        THROW;
    END CATCH;
END;
GO


/*==============================================================================
  4. PATCH SAMPLER TO LOG SUPPLEMENTAL COLLECTOR FAILURES

  Preserve the exact existing sampler behavior and parameters.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_RunSampler
      @CaptureRunID bigint
    , @DurationMinutes int = 5
    , @SampleSeconds int = 5
AS
BEGIN
    SET NOCOUNT ON;

    IF @DurationMinutes NOT BETWEEN 1 AND 60
        THROW 63010,N'@DurationMinutes must be between 1 and 60.',1;

    IF @SampleSeconds NOT BETWEEN 1 AND 60
        THROW 63011,N'@SampleSeconds must be between 1 and 60.',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
          AND CaptureStatus=N'RUNNING'
    )
        THROW 63012,N'CaptureRunID must exist and be RUNNING.',1;

    DECLARE
          @StopAt datetime2(3)=DATEADD(minute,@DurationMinutes,SYSUTCDATETIME())
        , @Delay varchar(8)
        , @Samples int=0
        , @TransactionCaptureFailures int=0;

    SET @Delay=
        '00:00:'+
        RIGHT('00'+CONVERT(varchar(2),@SampleSeconds),2);

    WHILE SYSUTCDATETIME()<@StopAt
    BEGIN
        EXEC dbo.usp_RCA_CaptureLiveSnapshot
             @CaptureRunID=@CaptureRunID;

        BEGIN TRY

            EXEC dbo.usp_RCA_CaptureBlockerTransactionEvidence
                 @CaptureRunID=@CaptureRunID;

        END TRY
        BEGIN CATCH

            SET @TransactionCaptureFailures+=1;

            DECLARE
                  @SamplerErrorNumber int = ERROR_NUMBER()
                , @SamplerErrorSeverity int = ERROR_SEVERITY()
                , @SamplerErrorState int = ERROR_STATE()
                , @SamplerErrorProcedure nvarchar(256) = ERROR_PROCEDURE()
                , @SamplerErrorLine int = ERROR_LINE()
                , @SamplerErrorMessage nvarchar(4000) = ERROR_MESSAGE();

            EXEC dbo.usp_RCA_LogCollectorError
                 @CaptureRunID=@CaptureRunID,
                 @CollectorName=N'usp_RCA_RunSampler.TransactionCollector',
                 @ErrorNumber=@SamplerErrorNumber,
                 @ErrorSeverity=@SamplerErrorSeverity,
                 @ErrorState=@SamplerErrorState,
                 @ErrorProcedure=@SamplerErrorProcedure,
                 @ErrorLine=@SamplerErrorLine,
                 @ErrorMessage=@SamplerErrorMessage,
                 @ContextMessage=N'Transaction collector failed inside sampler; primary live sampling continued.';

        END CATCH;

        SET @Samples+=1;

        WAITFOR DELAY @Delay;
    END;

    SELECT
          CaptureRunID=@CaptureRunID
        , SamplesCaptured=@Samples
        , SampleSeconds=@SampleSeconds
        , DurationMinutes=@DurationMinutes
        , TransactionCaptureFailures=@TransactionCaptureFailures;
END;
GO


/*==============================================================================
  5. HUMAN-READABLE COLLECTOR HEALTH
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowCollectorHealth
    @CaptureRunID bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          ReportSection='RCA COLLECTOR HEALTH'
        , CollectorErrorID
        , CaptureRunID
        , ErrorTimeUTC
        , CollectorName
        , ErrorNumber
        , ErrorSeverity
        , ErrorState
        , ErrorProcedure
        , ErrorLine
        , ErrorMessage
        , ContextMessage
    FROM dbo.RCA_CollectorError
    WHERE @CaptureRunID IS NULL
       OR CaptureRunID=@CaptureRunID
    ORDER BY ErrorTimeUTC DESC,CollectorErrorID DESC;
END;
GO


/*==============================================================================
  6. DEPLOYMENT VALIDATION
==============================================================================*/
DECLARE
      @CollectorDefinition nvarchar(max)=
          OBJECT_DEFINITION
          (
              OBJECT_ID(N'dbo.usp_RCA_CaptureBlockerTransactionEvidence')
          )
    , @SamplerDefinition nvarchar(max)=
          OBJECT_DEFINITION
          (
              OBJECT_ID(N'dbo.usp_RCA_RunSampler')
          );

SELECT
      ValidationSection='1 - SCRIPT 54 DEPLOYMENT'
    , CollectorErrorTable=
        CASE WHEN OBJECT_ID(N'dbo.RCA_CollectorError',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , CollectorErrorProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_LogCollectorError',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HardenedCollector=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_CaptureBlockerTransactionEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , BasePersistenceFirst=
        CASE WHEN @CollectorDefinition LIKE '%Base blocker/transaction evidence persisted%'
             THEN 'PASS' ELSE 'FAIL' END
    , LockEnrichmentIsolated=
        CASE WHEN @CollectorDefinition LIKE '%LockEnrichment%'
              AND @CollectorDefinition LIKE '%Base transaction evidence was already persisted%'
             THEN 'PASS' ELSE 'FAIL' END
    , SamplerErrorLogging=
        CASE WHEN @SamplerDefinition LIKE '%usp_RCA_LogCollectorError%'
             THEN 'PASS' ELSE 'FAIL' END
    , CollectorHealthReport=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ShowCollectorHealth',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
  7. CAPTURE 40 INTEGRITY

  Capture 40 must remain at zero rows. We do not backfill it.
==============================================================================*/
SELECT
      ValidationSection='2 - CAPTURE 40 HISTORICAL INTEGRITY'
    , CaptureRunID=40
    , TransactionEvidenceRows=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_BlockerTransactionEvidence
            WHERE CaptureRunID=40
        )
    , CollectorErrorsLogged=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_CollectorError
            WHERE CaptureRunID=40
        )
    , IntegrityResult=
        CASE
          WHEN NOT EXISTS
          (
              SELECT 1
              FROM dbo.RCA_BlockerTransactionEvidence
              WHERE CaptureRunID=40
          )
          THEN 'PASS - NO CAPTURE 40 TRANSACTION EVIDENCE BACKFILLED'
          ELSE 'REVIEW - CAPTURE 40 CONTAINS TRANSACTION EVIDENCE'
        END;
GO


/*==============================================================================
  8. VERIFY CURRENT COLLECTOR/ERROR SCHEMA
==============================================================================*/
SELECT
      ValidationSection='3 - TRANSACTION EVIDENCE CORE COLUMNS'
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
    , IsNullable=c.is_nullable
FROM sys.columns AS c
WHERE c.object_id=OBJECT_ID(N'dbo.RCA_BlockerTransactionEvidence')
  AND c.name IN
  (
      'CaptureRunID',
      'SampleTimeUTC',
      'VictimSessionID',
      'HeadBlockerSessionID',
      'BlockerOpenTransactionCount',
      'TransactionID',
      'TransactionBeginTimeUTC',
      'TransactionAgeMs',
      'LockResourceType',
      'LockDatabaseID',
      'LockRequestMode',
      'LockRequestStatus',
      'ResourceAssociatedEntityID'
  )
ORDER BY c.column_id;
GO


/*==============================================================================
  9. SAFETY / NEXT STEP
==============================================================================*/
SELECT
      ValidationSection='4 - SCRIPT 54 SAFETY'
    , CollectorHardened='YES'
    , CollectorFailuresNowPersisted='YES'
    , BaseTransactionEvidenceProtectedFromLockEnrichmentFailure='YES'
    , Capture38Modified='NO'
    , Capture39Modified='NO'
    , Capture40Modified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        'Run one fresh controlled blocking validation after reviewing Script 54 deployment. If the collector fails, query dbo.RCA_CollectorError for the exact runtime error instead of guessing.';
GO


/*==============================================================================
  USEFUL COMMAND AFTER THE NEXT TEST
  ----------------------------------

  EXEC DBA.dbo.usp_RCA_ShowCollectorHealth
       @CaptureRunID = <new CaptureRunID>;

==============================================================================*/
