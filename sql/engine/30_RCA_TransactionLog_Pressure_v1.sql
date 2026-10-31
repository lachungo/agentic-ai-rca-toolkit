USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
    30_RCA_TransactionLog_Pressure_v1.sql

    PURPOSE
    -------
    Add transaction-log pressure / log-write bottlenecks as a dedicated
    RCA root-cause domain.

    NEW ROOT-CAUSE CATEGORY
    -----------------------
        TRANSACTION_LOG_PRESSURE

    WHAT THIS DOMAIN DETECTS
    ------------------------
      1. Sustained transaction-log write latency
      2. Sustained WRITELOG / log-governor waiting
      3. Transaction-log space pressure
      4. Heavy log generation when corroborated by latency/waits/space pressure

    SUBTYPES
    --------
        LOG_WRITE_LATENCY
        LOG_SPACE_PRESSURE
        LOG_WRITE_QUEUE_PRESSURE
        LOG_PRESSURE_MIXED
        LOG_ACTIVITY_ONLY

    IMPORTANT
    ---------
    High transaction-log activity alone is NOT a root cause.

    A busy log file can be healthy.

    This domain therefore requires corroboration before promoting log activity
    to PRIMARY/HIGH or PRIMARY/MEDIUM.

    NEW RAW SOURCE
    --------------
        dbo.RCA_LogSnapshot

    SAMPLER
    -------
        dbo.usp_RCA_RunLogSampler

    EVIDENCE
    --------
        dbo.RCA_TransactionLogEvidence
        dbo.vw_RCA_TransactionLogEvidence
        dbo.usp_RCA_BuildTransactionLogEvidence

    EXISTING ENGINE INTEGRATION
    ---------------------------
        dbo.vw_RCA_FinalCauseCandidates
        dbo.usp_RCA_WhyWasItSlow

    NO EXISTING XE CHANGES.
    NO EXISTING RCA SAMPLER CHANGES.
==============================================================================*/


/*==============================================================================
    1. RAW TRANSACTION LOG SNAPSHOT
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_LogSnapshot',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_LogSnapshot
    (
          LogSnapshotID             bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_LogSnapshot PRIMARY KEY

        , CaptureRunID              bigint NOT NULL
        , CaptureTimeUTC            datetime2(3) NOT NULL

        , DatabaseID                int NOT NULL
        , DatabaseName              sysname NOT NULL
        , RecoveryModelDesc         nvarchar(60) NULL

        , FileID                    int NOT NULL
        , LogicalFileName           sysname NULL
        , PhysicalName              nvarchar(520) NULL

        , LogSizeMB                 decimal(19,2) NULL
        , LogSpaceUsedPercent       decimal(9,4) NULL

        , NumWrites                 bigint NULL
        , BytesWritten              bigint NULL
        , IoStallWriteMs            bigint NULL

        , LogWaiterCount            int NOT NULL
        , WriteLogWaiterCount       int NOT NULL
        , LogRateGovernorWaiterCount int NOT NULL

        , CreatedTimeUTC            datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_LogSnapshot_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_LogSnapshot_RunTime
        ON dbo.RCA_LogSnapshot
        (
            CaptureRunID,
            CaptureTimeUTC,
            DatabaseID,
            FileID
        );
END;
GO


/*==============================================================================
    2. TRANSACTION LOG SAMPLER
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_RunLogSampler
      @CaptureRunID bigint
    , @DurationMinutes int=3
    , @SampleSeconds int=5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DurationMinutes < 1
        THROW 51800,N'@DurationMinutes must be >= 1.',1;

    IF @SampleSeconds < 1 OR @SampleSeconds > 86399
        THROW 51801,N'@SampleSeconds must be between 1 and 86399.',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51802,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_LogSnapshot
    WHERE CaptureRunID=@CaptureRunID;

    DECLARE
          @StartTimeUTC datetime2(3)=SYSUTCDATETIME()
        , @StopAt datetime2(3)
        , @Delay varchar(8)
        , @Samples int=0;

    SET @StopAt=DATEADD(minute,@DurationMinutes,@StartTimeUTC);

    SET @Delay=
        RIGHT('00'+CONVERT(varchar(2),@SampleSeconds/3600),2)
        + ':' +
        RIGHT('00'+CONVERT(varchar(2),(@SampleSeconds%3600)/60),2)
        + ':' +
        RIGHT('00'+CONVERT(varchar(2),@SampleSeconds%60),2);

    CREATE TABLE #LogSpace
    (
          DatabaseName sysname
        , LogSizeMB decimal(19,4)
        , LogSpaceUsedPercent decimal(19,4)
        , Status int
    );

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        TRUNCATE TABLE #LogSpace;

        INSERT #LogSpace
        EXEC (N'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS;');

        ;WITH Waiters AS
        (
            SELECT
                  r.database_id
                , LogWaiterCount=
                    SUM
                    (
                        CASE
                            WHEN r.wait_type IN
                                 (
                                     N'WRITELOG',
                                     N'LOG_RATE_GOVERNOR',
                                     N'LOG_POOL_CONSUMER',
                                     N'LOG_POOL_CONSUMER_SET'
                                 )
                                THEN 1
                            ELSE 0
                        END
                    )
                , WriteLogWaiterCount=
                    SUM(CASE WHEN r.wait_type=N'WRITELOG' THEN 1 ELSE 0 END)
                , LogRateGovernorWaiterCount=
                    SUM(CASE WHEN r.wait_type=N'LOG_RATE_GOVERNOR' THEN 1 ELSE 0 END)
            FROM sys.dm_exec_requests AS r
            WHERE r.database_id > 0
            GROUP BY r.database_id
        )
        INSERT dbo.RCA_LogSnapshot
        (
              CaptureRunID
            , CaptureTimeUTC
            , DatabaseID
            , DatabaseName
            , RecoveryModelDesc
            , FileID
            , LogicalFileName
            , PhysicalName
            , LogSizeMB
            , LogSpaceUsedPercent
            , NumWrites
            , BytesWritten
            , IoStallWriteMs
            , LogWaiterCount
            , WriteLogWaiterCount
            , LogRateGovernorWaiterCount
        )
        SELECT
              @CaptureRunID
            , SYSUTCDATETIME()
            , vfs.database_id
            , DB_NAME(vfs.database_id)
            , d.recovery_model_desc
            , vfs.file_id
            , mf.name
            , mf.physical_name
            , CONVERT(decimal(19,2),ls.LogSizeMB)
            , CONVERT(decimal(9,4),ls.LogSpaceUsedPercent)
            , vfs.num_of_writes
            , vfs.num_of_bytes_written
            , vfs.io_stall_write_ms
            , ISNULL(w.LogWaiterCount,0)
            , ISNULL(w.WriteLogWaiterCount,0)
            , ISNULL(w.LogRateGovernorWaiterCount,0)
        FROM sys.dm_io_virtual_file_stats(NULL,NULL) AS vfs
        JOIN sys.master_files AS mf
          ON mf.database_id=vfs.database_id
         AND mf.file_id=vfs.file_id
        JOIN sys.databases AS d
          ON d.database_id=vfs.database_id
        LEFT JOIN #LogSpace AS ls
          ON ls.DatabaseName=d.name
        LEFT JOIN Waiters AS w
          ON w.database_id=vfs.database_id
        WHERE mf.type_desc='LOG';

        SET @Samples+=1;

        WAITFOR DELAY @Delay;
    END;

    SELECT
          CaptureRunID=@CaptureRunID
        , LogSamplesCaptured=@Samples
        , SampleSeconds=@SampleSeconds
        , DurationMinutes=@DurationMinutes
        , DelayUsed=@Delay;
END;
GO


/*==============================================================================
    3. TRANSACTION LOG EVIDENCE TABLE
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_TransactionLogEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_TransactionLogEvidence
    (
          TransactionLogEvidenceID       bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_TransactionLogEvidence PRIMARY KEY

        , CaptureRunID                    bigint NOT NULL
        , DatabaseID                      int NOT NULL
        , DatabaseName                    sysname NOT NULL
        , FileID                          int NOT NULL
        , LogicalFileName                 sysname NULL
        , PhysicalName                    nvarchar(520) NULL
        , RecoveryModelDesc               nvarchar(60) NULL

        , PressureSubtype                 varchar(80) NOT NULL

        , SampleCount                     int NOT NULL
        , ObservationSeconds              decimal(19,2) NULL

        , PeakLogSpaceUsedPercent         decimal(9,4) NULL
        , AvgLogSpaceUsedPercent          decimal(9,4) NULL
        , HighLogSpaceSampleCount         int NOT NULL

        , DeltaWrites                     bigint NULL
        , DeltaWriteMB                    decimal(19,2) NULL
        , DeltaWriteStallMs               bigint NULL
        , AvgWriteLatencyMs               decimal(19,4) NULL
        , WriteThroughputMBps             decimal(19,4) NULL

        , PeakLogWaiters                  int NOT NULL
        , PeakWriteLogWaiters             int NOT NULL
        , PeakLogRateGovernorWaiters      int NOT NULL
        , LogWaitPressureSampleCount      int NOT NULL

        , WriteLatencyPressure            bit NOT NULL
        , LogSpacePressure                bit NOT NULL
        , LogWaitPressure                 bit NOT NULL
        , HeavyLogGeneration              bit NOT NULL

        , RootCauseRole                   varchar(20) NOT NULL
        , Confidence                      varchar(20) NOT NULL

        , EvidenceSummary                 nvarchar(max) NOT NULL
        , RecommendedAction               nvarchar(max) NOT NULL

        , CreatedTimeUTC                  datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_TransactionLogEvidence_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_TransactionLogEvidence_Run
        ON dbo.RCA_TransactionLogEvidence
        (
            CaptureRunID,
            RootCauseRole,
            Confidence
        );
END;
GO


/*==============================================================================
    4. TRANSACTION LOG EVIDENCE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_TransactionLogEvidence
AS
SELECT *
FROM dbo.RCA_TransactionLogEvidence;
GO


/*==============================================================================
    5. TRANSACTION LOG DETECTOR

    CONSERVATIVE THRESHOLDS
    -----------------------
    Write latency pressure:
        >= 20 ms average log-write latency

    Log space pressure:
        >= 85% log used for >= 3 samples

    Log waiter pressure:
        WRITELOG / log-governor waiting for >= 3 samples

    Heavy log generation:
        >= 256 MB written during observation window

    IMPORTANT
    ---------
    Heavy log generation alone is activity, not a root cause.
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildTransactionLogEvidence
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
        THROW 51810,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_TransactionLogEvidence
    WHERE CaptureRunID=@CaptureRunID;

    ;WITH s AS
    (
        SELECT
              *
            , rn_first=
                ROW_NUMBER() OVER
                (
                    PARTITION BY CaptureRunID,DatabaseID,FileID
                    ORDER BY CaptureTimeUTC,LogSnapshotID
                )
            , rn_last=
                ROW_NUMBER() OVER
                (
                    PARTITION BY CaptureRunID,DatabaseID,FileID
                    ORDER BY CaptureTimeUTC DESC,LogSnapshotID DESC
                )
        FROM dbo.RCA_LogSnapshot
        WHERE CaptureRunID=@CaptureRunID
    ),
    a AS
    (
        SELECT
              CaptureRunID
            , DatabaseID
            , DatabaseName=MAX(DatabaseName)
            , FileID
            , LogicalFileName=MAX(LogicalFileName)
            , PhysicalName=MAX(PhysicalName)
            , RecoveryModelDesc=MAX(RecoveryModelDesc)

            , SampleCount=COUNT(*)

            , ObservationSeconds=
                CONVERT
                (
                    decimal(19,2),
                    DATEDIFF_BIG
                    (
                        millisecond,
                        MIN(CaptureTimeUTC),
                        MAX(CaptureTimeUTC)
                    ) / 1000.0
                )

            , PeakLogSpaceUsedPercent=MAX(LogSpaceUsedPercent)
            , AvgLogSpaceUsedPercent=AVG(CONVERT(decimal(19,4),LogSpaceUsedPercent))
            , HighLogSpaceSampleCount=
                SUM(CASE WHEN LogSpaceUsedPercent>=85 THEN 1 ELSE 0 END)

            , FirstWrites=
                MAX(CASE WHEN rn_first=1 THEN NumWrites END)
            , LastWrites=
                MAX(CASE WHEN rn_last=1 THEN NumWrites END)

            , FirstBytesWritten=
                MAX(CASE WHEN rn_first=1 THEN BytesWritten END)
            , LastBytesWritten=
                MAX(CASE WHEN rn_last=1 THEN BytesWritten END)

            , FirstWriteStall=
                MAX(CASE WHEN rn_first=1 THEN IoStallWriteMs END)
            , LastWriteStall=
                MAX(CASE WHEN rn_last=1 THEN IoStallWriteMs END)

            , PeakLogWaiters=MAX(LogWaiterCount)
            , PeakWriteLogWaiters=MAX(WriteLogWaiterCount)
            , PeakLogRateGovernorWaiters=MAX(LogRateGovernorWaiterCount)

            , LogWaitPressureSampleCount=
                SUM(CASE WHEN LogWaiterCount>0 THEN 1 ELSE 0 END)
        FROM s
        GROUP BY CaptureRunID,DatabaseID,FileID
    ),
    c AS
    (
        SELECT
              *
            , DeltaWrites=
                CASE
                    WHEN LastWrites>=FirstWrites
                        THEN LastWrites-FirstWrites
                END

            , DeltaWriteMB=
                CONVERT
                (
                    decimal(19,2),
                    CASE
                        WHEN LastBytesWritten>=FirstBytesWritten
                            THEN (LastBytesWritten-FirstBytesWritten)/1048576.0
                    END
                )

            , DeltaWriteStallMs=
                CASE
                    WHEN LastWriteStall>=FirstWriteStall
                        THEN LastWriteStall-FirstWriteStall
                END
        FROM a
    )
    INSERT dbo.RCA_TransactionLogEvidence
    (
          CaptureRunID
        , DatabaseID
        , DatabaseName
        , FileID
        , LogicalFileName
        , PhysicalName
        , RecoveryModelDesc
        , PressureSubtype
        , SampleCount
        , ObservationSeconds
        , PeakLogSpaceUsedPercent
        , AvgLogSpaceUsedPercent
        , HighLogSpaceSampleCount
        , DeltaWrites
        , DeltaWriteMB
        , DeltaWriteStallMs
        , AvgWriteLatencyMs
        , WriteThroughputMBps
        , PeakLogWaiters
        , PeakWriteLogWaiters
        , PeakLogRateGovernorWaiters
        , LogWaitPressureSampleCount
        , WriteLatencyPressure
        , LogSpacePressure
        , LogWaitPressure
        , HeavyLogGeneration
        , RootCauseRole
        , Confidence
        , EvidenceSummary
        , RecommendedAction
    )
    SELECT
          CaptureRunID
        , DatabaseID
        , DatabaseName
        , FileID
        , LogicalFileName
        , PhysicalName
        , RecoveryModelDesc

        , PressureSubtype=
            CASE
                WHEN
                (
                    (DeltaWrites>0 AND DeltaWriteStallMs*1.0/DeltaWrites>=20)
                    AND
                    (
                        HighLogSpaceSampleCount>=3
                        OR LogWaitPressureSampleCount>=3
                    )
                )
                OR
                (
                    HighLogSpaceSampleCount>=3
                    AND LogWaitPressureSampleCount>=3
                )
                    THEN 'LOG_PRESSURE_MIXED'

                WHEN DeltaWrites>0
                 AND DeltaWriteStallMs*1.0/DeltaWrites>=20
                    THEN 'LOG_WRITE_LATENCY'

                WHEN HighLogSpaceSampleCount>=3
                    THEN 'LOG_SPACE_PRESSURE'

                WHEN LogWaitPressureSampleCount>=3
                    THEN 'LOG_WRITE_QUEUE_PRESSURE'

                ELSE 'LOG_ACTIVITY_ONLY'
            END

        , SampleCount
        , ObservationSeconds
        , PeakLogSpaceUsedPercent
        , AvgLogSpaceUsedPercent
        , HighLogSpaceSampleCount
        , DeltaWrites
        , DeltaWriteMB
        , DeltaWriteStallMs

        , AvgWriteLatencyMs=
            CONVERT
            (
                decimal(19,4),
                CASE
                    WHEN DeltaWrites>0
                        THEN DeltaWriteStallMs*1.0/DeltaWrites
                END
            )

        , WriteThroughputMBps=
            CONVERT
            (
                decimal(19,4),
                CASE
                    WHEN ObservationSeconds>0
                        THEN DeltaWriteMB/ObservationSeconds
                END
            )

        , PeakLogWaiters
        , PeakWriteLogWaiters
        , PeakLogRateGovernorWaiters
        , LogWaitPressureSampleCount

        , WriteLatencyPressure=
            CONVERT
            (
                bit,
                CASE
                    WHEN DeltaWrites>0
                     AND DeltaWriteStallMs*1.0/DeltaWrites>=20
                        THEN 1
                    ELSE 0
                END
            )

        , LogSpacePressure=
            CONVERT(bit,CASE WHEN HighLogSpaceSampleCount>=3 THEN 1 ELSE 0 END)

        , LogWaitPressure=
            CONVERT(bit,CASE WHEN LogWaitPressureSampleCount>=3 THEN 1 ELSE 0 END)

        , HeavyLogGeneration=
            CONVERT(bit,CASE WHEN ISNULL(DeltaWriteMB,0)>=256 THEN 1 ELSE 0 END)

        , RootCauseRole=
            CASE
                WHEN
                (
                    (DeltaWrites>0 AND DeltaWriteStallMs*1.0/DeltaWrites>=20)
                    OR HighLogSpaceSampleCount>=3
                    OR LogWaitPressureSampleCount>=3
                )
                    THEN 'PRIMARY'
                ELSE 'CONTRIBUTING'
            END

        , Confidence=
            CASE
                WHEN
                (
                    (DeltaWrites>0 AND DeltaWriteStallMs*1.0/DeltaWrites>=20)
                    AND
                    (
                        HighLogSpaceSampleCount>=5
                        OR LogWaitPressureSampleCount>=5
                    )
                )
                OR
                (
                    HighLogSpaceSampleCount>=5
                    AND LogWaitPressureSampleCount>=5
                )
                    THEN 'HIGH'

                WHEN
                (
                    (DeltaWrites>0 AND DeltaWriteStallMs*1.0/DeltaWrites>=20)
                    OR HighLogSpaceSampleCount>=3
                    OR LogWaitPressureSampleCount>=3
                )
                    THEN 'MEDIUM'

                ELSE 'LOW'
            END

        , EvidenceSummary=
            CONVERT
            (
                nvarchar(max),
                CONCAT
                (
                    'Database ',DatabaseName,
                    '; log file ',COALESCE(LogicalFileName,N'?'),
                    '; samples=',SampleCount,
                    '; observation=',COALESCE(CONVERT(varchar(30),ObservationSeconds),'NULL'),' sec',
                    '; peak log used=',COALESCE(CONVERT(varchar(30),PeakLogSpaceUsedPercent),'NULL'),'%',
                    '; high-log-space samples=',HighLogSpaceSampleCount,
                    '; writes=',COALESCE(CONVERT(varchar(30),DeltaWrites),'NULL'),
                    '; written=',COALESCE(CONVERT(varchar(30),DeltaWriteMB),'NULL'),' MB',
                    '; avg log-write latency=',
                    COALESCE
                    (
                        CONVERT
                        (
                            varchar(30),
                            CASE WHEN DeltaWrites>0 THEN DeltaWriteStallMs*1.0/DeltaWrites END
                        ),
                        'NULL'
                    ),
                    ' ms',
                    '; peak log waiters=',PeakLogWaiters,
                    '; peak WRITELOG waiters=',PeakWriteLogWaiters,
                    '; peak log-rate-governor waiters=',PeakLogRateGovernorWaiters,
                    '; log-wait pressure samples=',LogWaitPressureSampleCount,
                    '.'
                )
            )

        , RecommendedAction=
            CONVERT
            (
                nvarchar(max),
                CASE
                    WHEN DeltaWrites>0
                     AND DeltaWriteStallMs*1.0/DeltaWrites>=20
                    THEN
                        'Investigate transaction-log write latency first. Correlate WRITELOG waits, storage latency, log-file placement, autogrowth events, backup/log-backup activity, and the workload generating log records before changing SQL Server settings.'

                    WHEN HighLogSpaceSampleCount>=3
                    THEN
                        'Investigate why the transaction log remained heavily utilized. Check active transactions, log reuse wait description, log-backup health, replication/AG dependencies, and autogrowth history before shrinking or growing the log.'

                    WHEN LogWaitPressureSampleCount>=3
                    THEN
                        'Identify sessions repeatedly waiting on WRITELOG or log-governor resources and correlate them with commit rate, transaction size, log throughput, storage response time, and workload concurrency.'

                    ELSE
                        'Transaction-log activity was observed without sufficient latency, wait, or space-pressure evidence. Do not change transaction-log configuration solely from this capture.'
                END
            )
    FROM c;

    SELECT
          CaptureRunID=@CaptureRunID
        , LogCases=COUNT(*)
        , PrimaryCases=SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , HighConfidence=SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_TransactionLogEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
    6. FINAL CAUSE CANDIDATE INTEGRATION

    Complete replacement preserving validated domains and appending log pressure.
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseCandidates
AS

SELECT
      p.CaptureRunID
    , CauseCategory=CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    , CauseDisplayName=CONVERT(nvarchar(200),N'Parameter-sensitive plan reuse')
    , RootCauseRole=CONVERT(varchar(20),'PRIMARY')
    , Confidence=p.Confidence
    , CorrelationKey=CONVERT(nvarchar(200),CONCAT(N'EXEC:',p.ImpactedExecutionEvidenceID))
    , ImpactedExecutionEvidenceID=p.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID=CONVERT(int,NULL)
    , ImpactedRequestCount=CONVERT(int,1)
    , BlockingDepth=CONVERT(int,NULL)
    , MaxObservedWaitMs=CONVERT(bigint,NULL)
    , DurationRatio=p.DurationRatio
    , CPURatio=p.CPURatio
    , LogicalReadRatio=p.LogicalReadRatio
    , EvidenceCount=p.SharedStatementPlanCount
    , PrimaryEvidence=p.EvidenceSummary
    , RecommendedAction=
        CONVERT(nvarchar(4000),
        N'Validate the distinct parameter distributions with measured plan alternatives and re-test the identical runtime parameter values.')
FROM dbo.RCA_ParameterSensitivePlanEvidence AS p

UNION ALL

SELECT
      s.CaptureRunID
    , CONVERT(varchar(80),'STATISTICS_CARDINALITY_REGRESSION')
    , CONVERT(nvarchar(200),N'Statistics / cardinality regression')
    , CONVERT(varchar(20),'PRIMARY')
    , s.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'EXEC:',s.ImpactedExecutionEvidenceID))
    , s.ImpactedExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , s.DurationRatio
    , s.CPURatio
    , s.LogicalReadRatio
    , s.CardinalityMismatchCount+s.StatisticsRiskCount+s.LargeScanCount
    , s.EvidenceSummary
    , CONVERT(nvarchar(4000),
      N'Review the statistics used by the affected operators, validate estimate-versus-actual row counts, and re-test after the least invasive corrective change.')
FROM dbo.RCA_StatisticsCardinalityEvidence AS s

UNION ALL

SELECT
      m.CaptureRunID
    , CONVERT(varchar(80),'MEMORY_GRANT_SPILL')
    , CONVERT(nvarchar(200),N'Memory grant / spill')
    , m.RootCauseRole
    , m.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'EXEC:',m.ImpactedExecutionEvidenceID))
    , m.ImpactedExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , m.DurationRatio
    , m.CPURatio
    , m.LogicalReadRatio
    , m.SpillOperatorCount
    , m.EvidenceSummary
    , CONVERT(nvarchar(4000),
      N'Review requested, granted, and used query memory together with spill operators; correct upstream estimate problems first when they are stronger causal evidence.')
FROM dbo.RCA_MemorySpillEvidence AS m

UNION ALL

SELECT
      b.CaptureRunID
    , CONVERT(varchar(80),'BLOCKING_WAIT_CHAIN')
    , CONVERT(nvarchar(200),N'Blocking / wait-chain contention')
    , CASE
          WHEN SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>0
              THEN CONVERT(varchar(20),'PRIMARY')
          ELSE CONVERT(varchar(20),'CONTRIBUTING')
      END
    , CASE
          WHEN SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)>0
              THEN CONVERT(varchar(20),'HIGH')
          WHEN SUM(CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END)>0
              THEN CONVERT(varchar(20),'MEDIUM')
          ELSE CONVERT(varchar(20),'LOW')
      END
    , CONVERT(nvarchar(200),CONCAT(N'HEAD_BLOCKER:',b.HeadBlockerSessionID))
    , CONVERT(bigint,NULL)
    , b.HeadBlockerSessionID
    , COUNT(DISTINCT b.VictimSessionID)
    , MAX(b.BlockingDepth)
    , MAX(b.WaitDurationMs)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , SUM(b.SampleCount)
    , CONVERT(nvarchar(max),
      CONCAT(N'Head blocker session ',b.HeadBlockerSessionID,
      N' affected ',COUNT(DISTINCT b.VictimSessionID),
      N' distinct request(s). Maximum blocking depth=',MAX(b.BlockingDepth),
      N'; maximum observed wait=',MAX(b.WaitDurationMs),
      N' ms; total sampler observations=',SUM(b.SampleCount),N'.'))
    , CONVERT(nvarchar(4000),
      CONCAT(N'Investigate head blocker session ',b.HeadBlockerSessionID,
      N', identify the transaction retaining the required locks, and map the blocker host/application/login back to the owning workload.'))
FROM dbo.RCA_BlockingEvidence AS b
GROUP BY b.CaptureRunID,b.HeadBlockerSessionID

UNION ALL

SELECT
      c.CaptureRunID
    , CONVERT(varchar(80),'CPU_SCHEDULER_PRESSURE')
    , CONVERT(nvarchar(200),N'CPU / scheduler pressure')
    , c.RootCauseRole
    , c.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'EXEC:',c.PrimaryExecutionEvidenceID))
    , c.PrimaryExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , c.HighSqlCpuSampleCount+c.HighRunnableSampleCount
    , c.EvidenceSummary
    , CONVERT(nvarchar(4000),c.RecommendedAction)
FROM dbo.RCA_CPUSchedulerEvidence AS c

UNION ALL

SELECT
      i.CaptureRunID
    , CONVERT(varchar(80),'IO_STORAGE_PRESSURE')
    , CONVERT(nvarchar(200),N'I/O latency / storage pressure')
    , i.RootCauseRole
    , i.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'FILE:',i.DatabaseID,N':',i.FileID))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , i.SampleCount
    , i.EvidenceSummary
    , CONVERT(nvarchar(4000),i.RecommendedAction)
FROM dbo.RCA_IOStorageEvidence AS i
WHERE i.ReadLatencyPressure=1
   OR i.WriteLatencyPressure=1

UNION ALL

SELECT
      t.CaptureRunID
    , CONVERT(varchar(80),'TEMPDB_PRESSURE_CONTENTION')
    , CONVERT(nvarchar(200),N'TempDB pressure / contention')
    , t.RootCauseRole
    , t.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'TEMPDB:',t.PressureSubtype))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,CASE WHEN t.PeakLatchWaiters>0 THEN t.PeakLatchWaiters ELSE 1 END)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , t.SampleCount
    , t.EvidenceSummary
    , CONVERT(nvarchar(4000),t.RecommendedAction)
FROM dbo.RCA_TempDBEvidence AS t
WHERE t.PressureSubtype<>'TEMPDB_ACTIVITY_ONLY'

UNION ALL

SELECT
      mp.CaptureRunID
    , CONVERT(varchar(80),'INSTANCE_MEMORY_PRESSURE')
    , CONVERT(nvarchar(200),N'SQL Server memory / buffer pool pressure')
    , mp.RootCauseRole
    , mp.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'MEMORY:',mp.PressureSubtype))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , mp.SampleCount
    , mp.EvidenceSummary
    , CONVERT(nvarchar(4000),mp.RecommendedAction)
FROM dbo.RCA_MemoryPressureEvidence AS mp
WHERE mp.PressureSubtype<>'MEMORY_HEALTHY'

UNION ALL

SELECT
      l.CaptureRunID
    , CONVERT(varchar(80),'TRANSACTION_LOG_PRESSURE')
    , CONVERT(nvarchar(200),N'Transaction log pressure / log-write bottleneck')
    , l.RootCauseRole
    , l.Confidence
    , CONVERT(nvarchar(200),CONCAT(N'LOG:',l.DatabaseID,N':',l.FileID,N':',l.PressureSubtype))
    , CONVERT(bigint,NULL)
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , l.SampleCount
    , l.EvidenceSummary
    , CONVERT(nvarchar(4000),l.RecommendedAction)
FROM dbo.RCA_TransactionLogEvidence AS l
WHERE l.PressureSubtype<>'LOG_ACTIVITY_ONLY';
GO


/*==============================================================================
    7. HUMAN-FACING OUTPUT INTEGRATION

    Complete replacement with transaction-log support added.
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_WhyWasItSlow
      @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51300,N'Invalid CaptureRunID.',1;

    DECLARE
          @StartTimeUTC datetime2(3)
        , @EndTimeUTC datetime2(3)
        , @CaptureStatus varchar(30)
        , @CauseCategory varchar(80)
        , @CauseDisplayName nvarchar(4000)
        , @Confidence varchar(20)
        , @ImpactedExecutionEvidenceID bigint
        , @HeadBlockerSessionID int
        , @ImpactedRequestCount int
        , @EvidenceCount int
        , @PrimaryEvidence nvarchar(max)
        , @RecommendedAction nvarchar(max)
        , @AttributionType varchar(40)
        , @HumanAnswer nvarchar(max)
        , @AssessmentState varchar(20);

    SELECT
          @StartTimeUTC=StartTimeUTC
        , @EndTimeUTC=EndTimeUTC
        , @CaptureStatus=CaptureStatus
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    SET @AssessmentState=
        CASE WHEN @CaptureStatus IN ('RUNNING','RUN9C_STARTED')
             THEN 'PRELIMINARY'
             ELSE 'FINAL'
        END;

    SELECT TOP (1)
          @CauseCategory=r.CauseCategory
        , @CauseDisplayName=r.CauseDisplayName
        , @Confidence=r.Confidence
        , @ImpactedExecutionEvidenceID=r.ImpactedExecutionEvidenceID
        , @HeadBlockerSessionID=r.HeadBlockerSessionID
        , @ImpactedRequestCount=r.ImpactedRequestCount
        , @EvidenceCount=r.EvidenceCount
        , @PrimaryEvidence=r.PrimaryEvidence
        , @RecommendedAction=r.RecommendedAction
    FROM dbo.vw_RCA_FinalCauseRanking AS r
    WHERE r.CaptureRunID=@CaptureRunID
      AND r.RootCauseRole='PRIMARY'
      AND r.Confidence IN ('HIGH','MEDIUM')
    ORDER BY
          CASE r.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
        , r.EvidenceCount DESC;

    IF @CauseCategory IS NULL
    BEGIN
        SELECT
              ReportSection='1 - WHY WAS IT SLOW?'
            , Answer=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'NO ROOT CAUSE CONFIRMED YET'
                     ELSE 'NO ROOT CAUSE CONFIRMED'
                END
            , AssessmentState=@AssessmentState
            , Confidence='N/A'
            , CaptureStatus=@CaptureStatus
            , IncidentStartUTC=@StartTimeUTC
            , IncidentEndUTC=@EndTimeUTC
            , Summary=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'No SQL Server root cause has reached the required evidence threshold yet. Evidence collection is still in progress.'
                     ELSE 'The captured SQL Server evidence does not support a specific root cause strongly enough to explain the reported slowdown.'
                END;

        SELECT
              ReportSection='2 - WHAT DID SQL SERVER SHOW?'
            , Finding=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'No PRIMARY root cause has reached HIGH or MEDIUM confidence yet.'
                     ELSE 'No PRIMARY root cause reached HIGH or MEDIUM confidence.'
                END
            , Meaning=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'Evidence collection is still active. Do not make a SQL Server corrective change solely from this interim assessment.'
                     ELSE 'Do not make a SQL Server corrective change merely because the application was reported as slow.'
                END;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.RCA_TransactionLogEvidence
            WHERE CaptureRunID=@CaptureRunID
        )
        BEGIN
            SELECT TOP (1)
                  ReportSection='3 - WHAT DID WE RULE OUT?'
                , Hypothesis='Transaction log pressure / log-write bottleneck'
                , Assessment=
                    CASE WHEN PressureSubtype='LOG_ACTIVITY_ONLY'
                         THEN 'NOT SUPPORTED'
                         ELSE 'EVIDENCE EXISTS BUT DID NOT BECOME PRIMARY'
                    END
                , DatabaseName
                , PressureSubtype
                , PeakLogSpaceUsedPercent
                , AvgWriteLatencyMs
                , PeakWriteLogWaiters
                , DeltaWriteMB
            FROM dbo.RCA_TransactionLogEvidence
            WHERE CaptureRunID=@CaptureRunID
            ORDER BY
                  CASE Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
                , AvgWriteLatencyMs DESC;
        END;

        SELECT
              ReportSection='4 - WHAT SHOULD I DO?'
            , Step1=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'Allow the active evidence capture to continue.'
                     ELSE 'Confirm that the user-reported slowdown occurred inside this capture window.'
                END
            , Step2='Do not change SQL Server configuration, indexes, storage, memory, TempDB, transaction-log settings, or sessions without supporting evidence.'
            , Step3=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'Continue correlating the reported slowdown with the active capture window.'
                     ELSE 'If SQL Server evidence remains normal, investigate the application tier, API/web services, network latency, external dependencies, or client-side response time.'
                END
            , Step4=
                CASE WHEN @AssessmentState='PRELIMINARY'
                     THEN 'When capture completes, rerun the RCA analysis and use the FINAL assessment.'
                     ELSE 'If the slowdown recurs, capture the incident while it is actively occurring and rerun the RCA analysis.'
                END;
        RETURN;
    END;

    SET @AttributionType=
        CASE
            WHEN @CauseCategory='BLOCKING_WAIT_CHAIN' THEN 'BLOCKING CHAIN'
            WHEN @CauseCategory='IO_STORAGE_PRESSURE' THEN 'DATABASE FILE'
            WHEN @CauseCategory='CPU_SCHEDULER_PRESSURE' THEN 'CPU / SCHEDULER'
            WHEN @CauseCategory='TEMPDB_PRESSURE_CONTENTION' THEN 'TEMPDB'
            WHEN @CauseCategory='INSTANCE_MEMORY_PRESSURE' THEN 'SQL SERVER MEMORY'
            WHEN @CauseCategory='TRANSACTION_LOG_PRESSURE' THEN 'TRANSACTION LOG'
            WHEN @ImpactedExecutionEvidenceID IS NOT NULL THEN 'SQL EXECUTION'
            ELSE 'SYSTEM LEVEL'
        END;

    SET @HumanAnswer=
        CASE @CauseCategory
            WHEN 'BLOCKING_WAIT_CHAIN'
                THEN CONCAT('The slowdown was caused by blocking. SQL session ',
                            COALESCE(CONVERT(varchar(20),@HeadBlockerSessionID),'?'),
                            ' was identified as the head blocker and prevented other work from progressing normally.')
            WHEN 'IO_STORAGE_PRESSURE'
                THEN 'The slowdown was caused by elevated database-file I/O latency. Storage response time was high enough to support I/O/storage pressure as the primary cause.'
            WHEN 'CPU_SCHEDULER_PRESSURE'
                THEN 'The slowdown was caused by CPU / scheduler pressure. SQL Server had runnable work waiting for CPU resources.'
            WHEN 'TEMPDB_PRESSURE_CONTENTION'
                THEN 'The slowdown was caused by TempDB pressure or contention. TempDB showed sustained evidence strong enough to support it as a primary cause.'
            WHEN 'INSTANCE_MEMORY_PRESSURE'
                THEN 'The slowdown was caused by sustained SQL Server memory / buffer-pool pressure. Multiple memory-health signals corroborated the condition.'
            WHEN 'TRANSACTION_LOG_PRESSURE'
                THEN 'The slowdown was caused by transaction-log pressure. SQL Server showed sustained log-write latency, log-space pressure, or log-write queueing strong enough to affect transaction progress.'
            WHEN 'MEMORY_GRANT_SPILL'
                THEN 'The slowdown was caused by a query memory grant / spill problem.'
            WHEN 'PARAMETER_SENSITIVE_PLAN_REUSE'
                THEN 'The slowdown was caused by parameter-sensitive plan reuse.'
            WHEN 'STATISTICS_CARDINALITY_REGRESSION'
                THEN 'The slowdown was caused by a statistics / cardinality estimation problem.'
            ELSE CONCAT('The RCA engine identified ',COALESCE(@CauseDisplayName,@CauseCategory),' as the primary cause of the slowdown.')
        END;

    IF @AssessmentState='PRELIMINARY'
        SET @HumanAnswer=
            CONCAT('PRELIMINARY ASSESSMENT: ',@HumanAnswer,
                   ' Evidence collection is still in progress. This conclusion may change.');

    SELECT
          ReportSection='1 - WHY WAS IT SLOW?'
        , Answer=
            CASE WHEN @AssessmentState='PRELIMINARY'
                 THEN 'PRELIMINARY ROOT CAUSE IDENTIFIED'
                 ELSE 'ROOT CAUSE IDENTIFIED'
            END
        , AssessmentState=@AssessmentState
        , PrimaryCause=@CauseDisplayName
        , Confidence=@Confidence
        , ImpactedRequestCount=@ImpactedRequestCount
        , AttributionType=@AttributionType
        , CaptureStatus=@CaptureStatus
        , IncidentStartUTC=@StartTimeUTC
        , IncidentEndUTC=@EndTimeUTC
        , Summary=@HumanAnswer;

    IF @CauseCategory='TRANSACTION_LOG_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='TRANSACTION LOG PRESSURE'
            , l.DatabaseName
            , l.RecoveryModelDesc
            , l.LogicalFileName
            , l.PhysicalName
            , l.PressureSubtype
            , l.SampleCount
            , l.ObservationSeconds
            , l.PeakLogSpaceUsedPercent
            , l.AvgLogSpaceUsedPercent
            , l.HighLogSpaceSampleCount
            , l.DeltaWrites
            , l.DeltaWriteMB
            , l.DeltaWriteStallMs
            , l.AvgWriteLatencyMs
            , l.WriteThroughputMBps
            , l.PeakLogWaiters
            , l.PeakWriteLogWaiters
            , l.PeakLogRateGovernorWaiters
            , l.LogWaitPressureSampleCount
            , l.WriteLatencyPressure
            , l.LogSpacePressure
            , l.LogWaitPressure
            , l.HeavyLogGeneration
        FROM dbo.RCA_TransactionLogEvidence AS l
        WHERE l.CaptureRunID=@CaptureRunID
          AND l.RootCauseRole='PRIMARY'
          AND l.Confidence IN ('HIGH','MEDIUM')
        ORDER BY
              CASE l.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , l.AvgWriteLatencyMs DESC
            , l.PeakLogSpaceUsedPercent DESC;
    END
    ELSE IF @CauseCategory='BLOCKING_WAIT_CHAIN'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='BLOCKING'
            , b.HeadBlockerSessionID
            , b.VictimSessionID
            , b.ImmediateBlockerSessionID
            , b.BlockingDepth
            , b.WaitType
            , WaitSeconds=CONVERT(decimal(19,2),b.WaitDurationMs/1000.0)
            , b.SampleCount
            , b.FirstObservedUTC
            , b.LastObservedUTC
            , DatabaseName=b.VictimDatabaseName
            , HeadBlockerHost=b.HeadBlockerHostName
            , HeadBlockerApplication=b.HeadBlockerProgramName
            , HeadBlockerLogin=b.HeadBlockerLoginName
            , HeadBlockerStatement=b.HeadBlockerStatement
            , HeadBlockerOpenTransactions=b.HeadBlockerOpenTransactionCount
            , VictimHost=b.VictimHostName
            , VictimApplication=b.VictimProgramName
            , VictimLogin=b.VictimLoginName
            , VictimStatement=b.VictimStatement
        FROM dbo.RCA_BlockingEvidence AS b
        WHERE b.CaptureRunID=@CaptureRunID
          AND b.HeadBlockerSessionID=@HeadBlockerSessionID
        ORDER BY b.BlockingDepth DESC,b.WaitDurationMs DESC,b.SampleCount DESC;
    END
    ELSE IF @CauseCategory='IO_STORAGE_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='DATABASE FILE IO LATENCY'
            , i.DatabaseName
            , i.LogicalFileName
            , i.FileTypeDesc
            , i.PhysicalName
            , i.ObservationSeconds
            , i.DeltaReads
            , i.DeltaReadMB
            , i.AvgReadLatencyMs
            , i.ReadThroughputMBps
            , i.DeltaWrites
            , i.DeltaWriteMB
            , i.AvgWriteLatencyMs
            , i.WriteThroughputMBps
        FROM dbo.RCA_IOStorageEvidence AS i
        WHERE i.CaptureRunID=@CaptureRunID
          AND i.RootCauseRole='PRIMARY'
          AND i.Confidence IN ('HIGH','MEDIUM')
        ORDER BY
              CASE i.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
            , i.AvgReadLatencyMs DESC
            , i.AvgWriteLatencyMs DESC;
    END
    ELSE IF @CauseCategory='CPU_SCHEDULER_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='CPU / SCHEDULER PRESSURE'
            , c.PrimarySessionID
            , c.PrimaryHostName
            , c.PrimaryProgramName
            , c.PrimaryLoginName
            , c.PrimaryStatement
            , c.PeakSqlCpuPercent
            , c.AvgSqlCpuPercent
            , c.PeakOtherCpuPercent
            , c.LowestSystemIdlePercent
            , c.PeakRunnableTasks
            , c.AvgRunnableTasks
            , c.HighRunnableSampleCount
            , c.TopExecutionCPUms
            , c.TotalCapturedCPUms
            , c.TopExecutionCPUSharePercent
        FROM dbo.RCA_CPUSchedulerEvidence AS c
        WHERE c.CaptureRunID=@CaptureRunID
        ORDER BY CASE c.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 c.PeakRunnableTasks DESC;
    END
    ELSE IF @CauseCategory='TEMPDB_PRESSURE_CONTENTION'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='TEMPDB PRESSURE / CONTENTION'
            , t.PressureSubtype
            , t.SampleCount
            , t.ObservationSeconds
            , t.PeakUsedPercent
            , t.AvgUsedPercent
            , t.HighSpaceSampleCount
            , t.PeakInternalObjectMB
            , t.AvgInternalObjectMB
            , t.HighInternalSampleCount
            , t.PeakVersionStoreMB
            , t.PeakLatchWaiters
            , t.LatchPressureSampleCount
        FROM dbo.RCA_TempDBEvidence AS t
        WHERE t.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE t.RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END,
              CASE t.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
    END
    ELSE IF @CauseCategory='INSTANCE_MEMORY_PRESSURE'
    BEGIN
        SELECT TOP (1)
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause='SQL SERVER MEMORY / BUFFER POOL PRESSURE'
            , mp.PressureSubtype
            , mp.SampleCount
            , mp.ObservationSeconds
            , mp.PeakMemoryGrantsPending
            , mp.GrantPressureSampleCount
            , mp.MinAvailablePhysicalMemoryMB
            , mp.AvgAvailablePhysicalMemoryMB
            , mp.MinBufferCacheHitRatio
            , mp.AvgBufferCacheHitRatio
            , mp.MinPLESeconds
            , mp.AvgPLESeconds
            , mp.MaxPLESeconds
            , mp.MaxTargetMemoryDeficitMB
        FROM dbo.RCA_MemoryPressureEvidence AS mp
        WHERE mp.CaptureRunID=@CaptureRunID
        ORDER BY
              CASE mp.RootCauseRole WHEN 'PRIMARY' THEN 1 ELSE 2 END,
              CASE mp.Confidence WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
    END
    ELSE IF @ImpactedExecutionEvidenceID IS NOT NULL
    BEGIN
        SELECT
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause=@CauseDisplayName
            , e.ExecutionEvidenceID
            , e.DatabaseName
            , e.SessionID
            , e.ObjectName
            , e.HostName
            , e.ProgramName
            , e.LoginName
            , DurationSeconds=CONVERT(decimal(19,3),e.DurationMs/1000.0)
            , CPUSeconds=CONVERT(decimal(19,3),e.CPUms/1000.0)
            , e.LogicalReads
            , e.PhysicalReads
            , e.Writes
            , e.TotalRows
            , e.ParameterEvidenceStatus
            , e.ParameterText
            , e.SubmittedCommand
        FROM dbo.RCA_ExecutionEvidence AS e
        WHERE e.ExecutionEvidenceID=@ImpactedExecutionEvidenceID;
    END
    ELSE
    BEGIN
        SELECT
              ReportSection='2 - WHO / WHAT CAUSED IT?'
            , Cause=@CauseDisplayName
            , Attribution='SYSTEM LEVEL'
            , Explanation='The RCA evidence supports this root cause, but no more specific attribution is available from the captured evidence.';
    END;

    SELECT
          ReportSection='3 - WHY DO WE BELIEVE THIS?'
        , Confidence=@Confidence
        , EvidenceCount=@EvidenceCount
        , Evidence=@PrimaryEvidence;

    SELECT
          ReportSection='4 - WHAT SHOULD I DO?'
        , RecommendedAction=@RecommendedAction
        , AssessmentState=@AssessmentState
        , SafetyNote=
            CASE
                WHEN @AssessmentState='PRELIMINARY'
                    THEN 'This is a preliminary assessment. Do not make an irreversible production change solely from this interim conclusion.'
                WHEN @CauseCategory='TRANSACTION_LOG_PRESSURE'
                    THEN 'Do not shrink the log, change recovery model, increase log size, or move the log solely from this result. First establish whether latency, log reuse, active transactions, log backups, AG/replication, or workload generation is the actual mechanism.'
                WHEN @CauseCategory='BLOCKING_WAIT_CHAIN'
                    THEN 'Do not automatically kill the head-blocking session. Confirm transaction owner, business impact, rollback risk, and application context first.'
                WHEN @CauseCategory='IO_STORAGE_PRESSURE'
                    THEN 'Do not change SQL Server storage configuration solely from one latency observation.'
                WHEN @CauseCategory='CPU_SCHEDULER_PRESSURE'
                    THEN 'Do not treat scheduler queueing alone as the problem. Identify the workload responsible for CPU demand.'
                WHEN @CauseCategory='INSTANCE_MEMORY_PRESSURE'
                    THEN 'Do not change max server memory or add RAM solely because Buffer Cache Hit Ratio or PLE changed.'
                WHEN @CauseCategory='TEMPDB_PRESSURE_CONTENTION'
                    THEN 'Do not add TempDB files or grow TempDB solely from this result.'
                ELSE 'Validate the recommended action against the technical evidence before making a production change.'
            END;
END;
GO


/*==============================================================================
    8. DEPLOYMENT VALIDATION
==============================================================================*/

SELECT
      LogSnapshotTable=
        CASE WHEN OBJECT_ID(N'dbo.RCA_LogSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogSampler=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunLogSampler',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogEvidenceTable=
        CASE WHEN OBJECT_ID(N'dbo.RCA_TransactionLogEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogEvidenceView=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_TransactionLogEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , LogDetector=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildTransactionLogEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseIntegration=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , HumanOutputIntegration=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyWasItSlow',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO


/*==============================================================================
    9. EXISTING-DOMAIN REGRESSION MATRIX

    New transaction-log domain is deployed but NOT yet validated.
==============================================================================*/

;WITH TestRuns AS
(
    SELECT CONVERT(bigint,3) AS CaptureRunID,
           CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE') AS ExpectedCause
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 16, 'CPU_SCHEDULER_PRESSURE'
    UNION ALL SELECT 20, 'IO_STORAGE_PRESSURE'
    UNION ALL SELECT 26, 'TEMPDB_PRESSURE_CONTENTION'
    UNION ALL SELECT 29, 'INSTANCE_MEMORY_PRESSURE'
),
Ranked AS
(
    SELECT
          t.CaptureRunID
        , t.ExpectedCause
        , r.CauseCategory
        , r.CauseDisplayName
        , r.RootCauseRole
        , r.Confidence
        , rn=
            ROW_NUMBER() OVER
            (
                PARTITION BY t.CaptureRunID
                ORDER BY
                      r.RoleRank
                    , r.ConfidenceRank
                    , r.ImpactRank
                    , r.EvidenceStrengthRank
            )
    FROM TestRuns AS t
    LEFT JOIN dbo.vw_RCA_FinalCauseRanking AS r
      ON r.CaptureRunID=t.CaptureRunID
)
SELECT
      CaptureRunID
    , ExpectedCause
    , DetectedTopCause=CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , ValidationResult=
        CASE WHEN CauseCategory=ExpectedCause THEN 'PASS' ELSE 'REVIEW' END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO


/*==============================================================================
    NEXT VALIDATION
    ---------------
    After deployment returns all PASS:

      Run 12A - log-activity negative control
      Run 12B - live transaction-log workload attempt
      Run 12C - deterministic positive log-write latency control

    Run 12C expected:
        TRANSACTION_LOG_PRESSURE
        LOG_WRITE_LATENCY or LOG_PRESSURE_MIXED
        PRIMARY
        HIGH

    Human output must identify:
        database
        logical log file
        physical log path
        log-used %
        log-write latency
        log MB generated
        WRITELOG / log-governor wait evidence
==============================================================================*/
