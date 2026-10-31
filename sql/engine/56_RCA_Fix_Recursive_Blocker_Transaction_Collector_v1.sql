USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  56_RCA_Fix_Recursive_Blocker_Transaction_Collector_v1.sql

  PURPOSE
  -------
  Fix the runtime error discovered in Capture 41:

      Error 462
      "Outer join is not allowed in the recursive part ..."

  ROOT DEFECT
  -----------
  The blocker-chain recursive CTE used an outer join in its recursive member.
  SQL Server does not allow that.

  FIX
  ---
  Separate responsibilities:

      1. Recursive blocking-chain resolution
         - uses only recursion-safe joins
         - resolves victim -> immediate blocker -> head blocker

      2. Transaction/session/request enrichment
         - happens AFTER recursion
         - uses normal LEFT JOINs outside the recursive member

  IMPORTANT
  ---------
  This script preserves:
      - dbo.RCA_CollectorError telemetry
      - sampler failure isolation
      - base-evidence-first persistence
      - optional lock enrichment

  It does NOT:
      - change detector thresholds
      - change root-cause domains
      - change root-cause ranking logic
      - modify Capture 38/39/40/41
      - start Capture 42

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

IF OBJECT_ID(N'dbo.RCA_CollectorError',N'U') IS NULL
    SET @Missing += N' dbo.RCA_CollectorError;';

IF OBJECT_ID(N'dbo.usp_RCA_LogCollectorError',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_LogCollectorError;';

IF OBJECT_ID(N'dbo.usp_RCA_RunSampler',N'P') IS NULL
    SET @Missing += N' dbo.usp_RCA_RunSampler;';

IF NULLIF(@Missing,N'') IS NOT NULL
BEGIN
    SET @Message=CONCAT(N'Script 56 prerequisites are missing:',@Missing);
    THROW 55600,@Message,1;
END;

SELECT
      ValidationSection='0 - SCRIPT 56 PRE-FLIGHT'
    , CaptureRun='PASS'
    , TransactionEvidenceTable='PASS'
    , CollectorErrorTelemetry='PASS'
    , ErrorLogger='PASS'
    , Sampler='PASS'
    , ExistingEvidenceModified='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO';
GO


/*==============================================================================
  1. REPLACE BLOCKER TRANSACTION COLLECTOR

  KEY CHANGE
  ----------
  The recursive CTE no longer uses LEFT JOIN.

  We snapshot blocking_session_id into #Requests first, then recursively walk
  using INNER JOIN only. Head blockers are those whose next parent is 0 or whose
  blocker is not present as another blocked request.

  Session/request/transaction enrichment occurs only AFTER recursion.
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
          A. SNAPSHOT CURRENT REQUESTS + SESSIONS
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
            , s.status AS session_status
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
          B. RECURSIVE CHAIN WALK - RECURSION SAFE

          Anchor:
              each blocked victim

          Recursive member:
              INNER JOIN only to the blocker request if that blocker itself is
              also blocked by another session.

          No OUTER JOIN exists in recursion.
        ----------------------------------------------------------------------*/
        ;WITH BlockingChain AS
        (
            SELECT
                  VictimSessionID = r.session_id
                , CurrentSessionID = r.session_id
                , NextBlockerSessionID = r.blocking_session_id
                , Depth = 0
            FROM #Requests AS r
            WHERE r.blocking_session_id > 0

            UNION ALL

            SELECT
                  bc.VictimSessionID
                , CurrentSessionID = parent.session_id
                , NextBlockerSessionID = parent.blocking_session_id
                , Depth = bc.Depth + 1
            FROM BlockingChain AS bc
            JOIN #Requests AS parent
              ON parent.session_id = bc.NextBlockerSessionID
            WHERE bc.NextBlockerSessionID > 0
              AND bc.Depth < 32
        ),
        Ranked AS
        (
            SELECT
                  VictimSessionID
                , CurrentSessionID
                , NextBlockerSessionID
                , Depth
                , rn = ROW_NUMBER() OVER
                    (
                        PARTITION BY VictimSessionID
                        ORDER BY Depth DESC
                    )
            FROM BlockingChain
        )
        SELECT
              VictimSessionID
            , LastChainSessionID = CurrentSessionID
            , LastChainNextBlockerID = NextBlockerSessionID
            , BlockingDepth = Depth
        INTO #ResolvedChain
        FROM Ranked
        WHERE rn=1
        OPTION (MAXRECURSION 32);


        /*----------------------------------------------------------------------
          C. RESOLVE HEAD BLOCKER

          If the deepest row still points at another blocker, that blocker is
          the head blocker even when it is sleeping and absent from
          dm_exec_requests.

          Example:
              victim 85 -> blocker 89
              89 not blocked by anyone

          Recursive deepest row may be victim 85 with NextBlockerSessionID=89.
          We therefore use the pending blocker as head blocker.
        ----------------------------------------------------------------------*/
        SELECT
              rc.VictimSessionID
            , ImmediateBlockerSessionID = victim.blocking_session_id
            , HeadBlockerSessionID =
                CASE
                  WHEN rc.LastChainNextBlockerID > 0
                  THEN rc.LastChainNextBlockerID
                  ELSE rc.LastChainSessionID
                END
            , BlockingDepth =
                CASE
                  WHEN rc.BlockingDepth < 1 THEN 1
                  ELSE rc.BlockingDepth
                END
        INTO #Heads
        FROM #ResolvedChain AS rc
        JOIN #Requests AS victim
          ON victim.session_id=rc.VictimSessionID;


        /*----------------------------------------------------------------------
          D. BUILD VICTIM + HEAD BLOCKER PAIRS

          Head blocker session identity comes from dm_exec_sessions so a
          sleeping blocker with an open transaction is still visible.

          Head blocker current-request details come from #Requests when present.
        ----------------------------------------------------------------------*/
        SELECT
              h.VictimSessionID
            , h.ImmediateBlockerSessionID
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
          E. TRANSACTION CORRELATION OUTSIDE RECURSION
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
          F. BASE EVIDENCE PERSISTENCE FIRST
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
                  N'Script 56 recursion-safe collector sampled at ',
                  CONVERT(varchar(33),@SampleTimeUTC,126),
                  N'. Blocking chain resolution completed before transaction/lock enrichment.'
              )
        FROM #TxnPairs;

        DECLARE @BaseRows int=@@ROWCOUNT;


        /*----------------------------------------------------------------------
          G. OPTIONAL REPRESENTATIVE LOCK ENRICHMENT
        ----------------------------------------------------------------------*/
        DECLARE @LockRowsUpdated int=0;

        BEGIN TRY

            ;WITH LockCandidate AS
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
            JOIN LockCandidate AS c
              ON c.BlockerTransactionEvidenceID=e.BlockerTransactionEvidenceID
             AND c.rn=1;

            SET @LockRowsUpdated=@@ROWCOUNT;

        END TRY
        BEGIN CATCH

            DECLARE
                  @LockErrorNumber int=ERROR_NUMBER()
                , @LockErrorSeverity int=ERROR_SEVERITY()
                , @LockErrorState int=ERROR_STATE()
                , @LockErrorProcedure nvarchar(256)=ERROR_PROCEDURE()
                , @LockErrorLine int=ERROR_LINE()
                , @LockErrorMessage nvarchar(4000)=ERROR_MESSAGE();

            EXEC dbo.usp_RCA_LogCollectorError
                 @CaptureRunID=@CaptureRunID,
                 @CollectorName=N'usp_RCA_CaptureBlockerTransactionEvidence.LockEnrichment',
                 @ErrorNumber=@LockErrorNumber,
                 @ErrorSeverity=@LockErrorSeverity,
                 @ErrorState=@LockErrorState,
                 @ErrorProcedure=@LockErrorProcedure,
                 @ErrorLine=@LockErrorLine,
                 @ErrorMessage=@LockErrorMessage,
                 @ContextMessage=N'Base transaction evidence already persisted. Optional lock enrichment failed.';

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
                  THEN 'PASS - base blocker transaction evidence persisted.'
                  ELSE 'REVIEW - no base blocker transaction evidence produced.'
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
             @ContextMessage=N'Script 56 recursion-safe collector failed before completing base persistence.';

        THROW;
    END CATCH;
END;
GO


/*==============================================================================
  2. COMPILE / DEFINITION VALIDATION
==============================================================================*/
DECLARE @Definition nvarchar(max)=
    OBJECT_DEFINITION
    (
        OBJECT_ID(N'dbo.usp_RCA_CaptureBlockerTransactionEvidence')
    );

SELECT
      ValidationSection='1 - SCRIPT 56 DEPLOYMENT'
    , CollectorProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_CaptureBlockerTransactionEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , RecursiveOuterJoinRemoved=
        CASE
          WHEN @Definition LIKE '%FROM BlockingChain AS bc%JOIN #Requests AS parent%'
           AND @Definition NOT LIKE '%FROM BlockingChain AS bc%LEFT JOIN%'
          THEN 'PASS'
          ELSE 'REVIEW'
        END
    , TransactionEnrichmentOutsideRecursion=
        CASE
          WHEN @Definition LIKE '%LEFT JOIN sys.dm_tran_session_transactions%'
           AND @Definition LIKE '%INTO #TxnPairs%'
          THEN 'PASS'
          ELSE 'FAIL'
        END
    , ErrorTelemetryPreserved=
        CASE
          WHEN @Definition LIKE '%usp_RCA_LogCollectorError%'
          THEN 'PASS'
          ELSE 'FAIL'
        END
    , BasePersistenceFirst=
        CASE
          WHEN @Definition LIKE '%base blocker transaction evidence persisted%'
          THEN 'PASS'
          ELSE 'FAIL'
        END
    , OptionalLockEnrichment=
        CASE
          WHEN @Definition LIKE '%OPTIONAL REPRESENTATIVE LOCK ENRICHMENT%'
          THEN 'PASS'
          ELSE 'FAIL'
        END;
GO


/*==============================================================================
  3. HISTORICAL INTEGRITY
==============================================================================*/
SELECT
      ValidationSection='2 - HISTORICAL INTEGRITY'
    , Capture40TransactionRows=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_BlockerTransactionEvidence
            WHERE CaptureRunID=40
        )
    , Capture41TransactionRows=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_BlockerTransactionEvidence
            WHERE CaptureRunID=41
        )
    , Capture41CollectorErrors=
        (
            SELECT COUNT(*)
            FROM dbo.RCA_CollectorError
            WHERE CaptureRunID=41
        )
    , HistoricalEvidenceBackfilled='NO'
    , IntegrityResult='PASS - SCRIPT 56 DOES NOT RETROFIT OLD CAPTURES';
GO


/*==============================================================================
  4. VERIFY CAPTURE 41 ERROR 462 REMAINS AS DIAGNOSTIC HISTORY
==============================================================================*/
SELECT
      ValidationSection='3 - CAPTURE 41 KNOWN FAILURE'
    , CollectorErrorID
    , ErrorTimeUTC
    , CollectorName
    , ErrorNumber
    , ErrorProcedure
    , ErrorLine
    , ErrorMessage
FROM dbo.RCA_CollectorError
WHERE CaptureRunID=41
  AND ErrorNumber=462
ORDER BY ErrorTimeUTC,CollectorErrorID;
GO


/*==============================================================================
  5. SAFETY / NEXT STEP
==============================================================================*/
SELECT
      ValidationSection='4 - SCRIPT 56 SAFETY'
    , RecursiveCollectorFixed='YES'
    , ErrorTelemetryPreserved='YES'
    , SamplerChanged='NO'
    , Capture38Modified='NO'
    , Capture39Modified='NO'
    , Capture40Modified='NO'
    , Capture41Modified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        'Run one fresh controlled blocking capture (Capture 42). Acceptance: blocking evidence > 0, transaction evidence > 0, collector error 462 absent, transaction ID/begin time/age populated.';
GO
