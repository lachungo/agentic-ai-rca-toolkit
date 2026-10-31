USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
24_RCA_IO_Storage_Intelligence_v1.sql

PURPOSE
-------
Add a dedicated I/O latency / storage-pressure detector to the RCA engine.

WHY A SEPARATE IO SAMPLER?
--------------------------
The existing RCA_ServerSnapshot does not currently store file-level I/O
latency counters. Rather than changing the proven main sampler, this version
adds a small independent DMV sampler over sys.dm_io_virtual_file_stats.

NO XE CHANGES.
NO EXISTING SAMPLER CHANGES.
NO EXISTING DETECTOR CHANGES.

INPUT
-----
sys.dm_io_virtual_file_stats(NULL,NULL)
sys.master_files

OUTPUT
------
dbo.RCA_IOFileSnapshot
dbo.RCA_IOStorageEvidence
dbo.vw_RCA_IOStorageEvidence
dbo.usp_RCA_RunIOSampler
dbo.usp_RCA_BuildIOStorageEvidence

CAUSE CATEGORY
--------------
IO_STORAGE_PRESSURE

INTERPRETATION
--------------
The detector distinguishes:
- high read latency,
- high write latency,
- sustained file-level I/O pressure,
- concentration on a specific database/file,
- I/O as PRIMARY versus CONTRIBUTING when a stronger dedicated cause exists.

==============================================================================*/


/*==============================================================================
1. RAW FILE-IO SNAPSHOT TABLE
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_IOFileSnapshot',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_IOFileSnapshot
    (
          IOFileSnapshotID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_IOFileSnapshot PRIMARY KEY
        , CaptureRunID bigint NOT NULL
        , CaptureTimeUTC datetime2(3) NOT NULL
        , DatabaseID int NOT NULL
        , DatabaseName sysname NULL
        , FileID int NOT NULL
        , FileTypeDesc nvarchar(60) NULL
        , LogicalFileName sysname NULL
        , PhysicalName nvarchar(260) NULL
        , NumReads bigint NOT NULL
        , BytesRead bigint NOT NULL
        , IoStallReadMs bigint NOT NULL
        , NumWrites bigint NOT NULL
        , BytesWritten bigint NOT NULL
        , IoStallWriteMs bigint NOT NULL
        , IoStallMs bigint NOT NULL
        , SizeOnDiskBytes bigint NULL
    );

    CREATE INDEX IX_RCA_IOFileSnapshot_RunFileTime
        ON dbo.RCA_IOFileSnapshot
        (
            CaptureRunID,
            DatabaseID,
            FileID,
            CaptureTimeUTC
        );
END;
GO


/*==============================================================================
2. IO SAMPLER
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_RunIOSampler
      @CaptureRunID bigint
    , @DurationMinutes int = 3
    , @SampleSeconds int = 5
AS
BEGIN
    SET NOCOUNT ON;

    IF @DurationMinutes < 1
        THROW 51240,N'@DurationMinutes must be >= 1.',1;

    IF @SampleSeconds < 1
        THROW 51241,N'@SampleSeconds must be >= 1.',1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CaptureRun
        WHERE CaptureRunID=@CaptureRunID
    )
        THROW 51242,N'Invalid CaptureRunID.',1;

    DELETE FROM dbo.RCA_IOFileSnapshot
    WHERE CaptureRunID=@CaptureRunID;

    DECLARE
          @StopAt datetime2(3)=DATEADD(minute,@DurationMinutes,SYSUTCDATETIME())
        , @Delay time(0)=DATEADD(second,@SampleSeconds,CONVERT(time(0),'00:00:00'))
        , @Samples int=0;

    WHILE SYSUTCDATETIME() < @StopAt
    BEGIN
        INSERT dbo.RCA_IOFileSnapshot
        (
              CaptureRunID
            , CaptureTimeUTC
            , DatabaseID
            , DatabaseName
            , FileID
            , FileTypeDesc
            , LogicalFileName
            , PhysicalName
            , NumReads
            , BytesRead
            , IoStallReadMs
            , NumWrites
            , BytesWritten
            , IoStallWriteMs
            , IoStallMs
            , SizeOnDiskBytes
        )
        SELECT
              @CaptureRunID
            , SYSUTCDATETIME()
            , vfs.database_id
            , DB_NAME(vfs.database_id)
            , vfs.file_id
            , mf.type_desc
            , mf.name
            , mf.physical_name
            , vfs.num_of_reads
            , vfs.num_of_bytes_read
            , vfs.io_stall_read_ms
            , vfs.num_of_writes
            , vfs.num_of_bytes_written
            , vfs.io_stall_write_ms
            , vfs.io_stall
            , vfs.size_on_disk_bytes
        FROM sys.dm_io_virtual_file_stats(NULL,NULL) AS vfs
        LEFT JOIN sys.master_files AS mf
          ON mf.database_id=vfs.database_id
         AND mf.file_id=vfs.file_id;

        SET @Samples += 1;

        WAITFOR DELAY @Delay;
    END;

    SELECT
          CaptureRunID=@CaptureRunID
        , IOSamplesCaptured=@Samples
        , SampleSeconds=@SampleSeconds
        , DurationMinutes=@DurationMinutes;
END;
GO


/*==============================================================================
3. EVIDENCE TABLE
==============================================================================*/

IF OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RCA_IOStorageEvidence
    (
          IOStorageEvidenceID bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_RCA_IOStorageEvidence PRIMARY KEY
        , CaptureRunID bigint NOT NULL
        , DatabaseID int NULL
        , DatabaseName sysname NULL
        , FileID int NULL
        , LogicalFileName sysname NULL
        , FileTypeDesc nvarchar(60) NULL
        , PhysicalName nvarchar(260) NULL

        , SampleCount int NOT NULL
        , DeltaReads bigint NULL
        , DeltaReadMB decimal(19,2) NULL
        , DeltaReadStallMs bigint NULL
        , AvgReadLatencyMs decimal(19,4) NULL

        , DeltaWrites bigint NULL
        , DeltaWriteMB decimal(19,2) NULL
        , DeltaWriteStallMs bigint NULL
        , AvgWriteLatencyMs decimal(19,4) NULL

        , ObservationSeconds decimal(19,2) NULL
        , ReadThroughputMBps decimal(19,4) NULL
        , WriteThroughputMBps decimal(19,4) NULL

        , ReadLatencyPressure bit NOT NULL
        , WriteLatencyPressure bit NOT NULL
        , HeavyReadVolume bit NOT NULL
        , HeavyWriteVolume bit NOT NULL

        , UpstreamCauseCategory varchar(80) NULL
        , RootCauseRole varchar(20) NOT NULL
        , Confidence varchar(20) NOT NULL
        , EvidenceSummary nvarchar(max) NOT NULL
        , RecommendedAction nvarchar(max) NOT NULL
        , CreatedTimeUTC datetime2(3) NOT NULL
            CONSTRAINT DF_RCA_IOStorageEvidence_CreatedTimeUTC
            DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_RCA_IOStorageEvidence_Run
        ON dbo.RCA_IOStorageEvidence
        (
            CaptureRunID,
            RootCauseRole,
            Confidence
        );
END;
GO


/*==============================================================================
4. EVIDENCE VIEW
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_IOStorageEvidence
AS
SELECT *
FROM dbo.RCA_IOStorageEvidence;
GO


/*==============================================================================
5. DETECTOR
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_RCA_BuildIOStorageEvidence
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM dbo.RCA_IOStorageEvidence
    WHERE CaptureRunID=@CaptureRunID;

    /* Stronger already-proven causes */
    DECLARE @UpstreamCauseCategory varchar(80)=NULL;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_ParameterSensitivePlanEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='PARAMETER_SENSITIVE_PLAN_REUSE';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_StatisticsCardinalityEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='STATISTICS_CARDINALITY_REGRESSION';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_MemorySpillEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='MEMORY_GRANT_SPILL';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_BlockingEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='BLOCKING_WAIT_CHAIN';

    ELSE IF EXISTS
    (
        SELECT 1
        FROM dbo.RCA_CPUSchedulerEvidence
        WHERE CaptureRunID=@CaptureRunID
          AND RootCauseRole='PRIMARY'
          AND Confidence='HIGH'
    )
        SET @UpstreamCauseCategory='CPU_SCHEDULER_PRESSURE';


    ;WITH Bounded AS
    (
        SELECT
              s.*
            , rnFirst =
                ROW_NUMBER() OVER
                (
                    PARTITION BY s.CaptureRunID,s.DatabaseID,s.FileID
                    ORDER BY s.CaptureTimeUTC
                )
            , rnLast =
                ROW_NUMBER() OVER
                (
                    PARTITION BY s.CaptureRunID,s.DatabaseID,s.FileID
                    ORDER BY s.CaptureTimeUTC DESC
                )
            , SampleCount =
                COUNT(*) OVER
                (
                    PARTITION BY s.CaptureRunID,s.DatabaseID,s.FileID
                )
        FROM dbo.RCA_IOFileSnapshot AS s
        WHERE s.CaptureRunID=@CaptureRunID
    ),
    FirstLast AS
    (
        SELECT
              CaptureRunID
            , DatabaseID
            , DatabaseName=MAX(DatabaseName)
            , FileID
            , LogicalFileName=MAX(LogicalFileName)
            , FileTypeDesc=MAX(FileTypeDesc)
            , PhysicalName=MAX(PhysicalName)
            , SampleCount=MAX(SampleCount)

            , FirstTime=MAX(CASE WHEN rnFirst=1 THEN CaptureTimeUTC END)
            , LastTime =MAX(CASE WHEN rnLast =1 THEN CaptureTimeUTC END)

            , FirstReads=MAX(CASE WHEN rnFirst=1 THEN NumReads END)
            , LastReads =MAX(CASE WHEN rnLast =1 THEN NumReads END)
            , FirstReadBytes=MAX(CASE WHEN rnFirst=1 THEN BytesRead END)
            , LastReadBytes =MAX(CASE WHEN rnLast =1 THEN BytesRead END)
            , FirstReadStall=MAX(CASE WHEN rnFirst=1 THEN IoStallReadMs END)
            , LastReadStall =MAX(CASE WHEN rnLast =1 THEN IoStallReadMs END)

            , FirstWrites=MAX(CASE WHEN rnFirst=1 THEN NumWrites END)
            , LastWrites =MAX(CASE WHEN rnLast =1 THEN NumWrites END)
            , FirstWriteBytes=MAX(CASE WHEN rnFirst=1 THEN BytesWritten END)
            , LastWriteBytes =MAX(CASE WHEN rnLast =1 THEN BytesWritten END)
            , FirstWriteStall=MAX(CASE WHEN rnFirst=1 THEN IoStallWriteMs END)
            , LastWriteStall =MAX(CASE WHEN rnLast =1 THEN IoStallWriteMs END)
        FROM Bounded
        GROUP BY
              CaptureRunID
            , DatabaseID
            , FileID
    ),
    Deltas AS
    (
        SELECT
              *
            , DeltaReads = LastReads-FirstReads
            , DeltaReadBytes = LastReadBytes-FirstReadBytes
            , DeltaReadStallMs = LastReadStall-FirstReadStall
            , DeltaWrites = LastWrites-FirstWrites
            , DeltaWriteBytes = LastWriteBytes-FirstWriteBytes
            , DeltaWriteStallMs = LastWriteStall-FirstWriteStall
            , ObservationSeconds =
                CONVERT(decimal(19,2),DATEDIFF_BIG(millisecond,FirstTime,LastTime)/1000.0)
        FROM FirstLast
    ),
    Metrics AS
    (
        SELECT
              *
            , AvgReadLatencyMs =
                CONVERT
                (
                    decimal(19,4),
                    CASE WHEN DeltaReads>0
                         THEN (DeltaReadStallMs*1.0)/DeltaReads
                    END
                )
            , AvgWriteLatencyMs =
                CONVERT
                (
                    decimal(19,4),
                    CASE WHEN DeltaWrites>0
                         THEN (DeltaWriteStallMs*1.0)/DeltaWrites
                    END
                )
            , DeltaReadMB =
                CONVERT(decimal(19,2),DeltaReadBytes/1048576.0)
            , DeltaWriteMB =
                CONVERT(decimal(19,2),DeltaWriteBytes/1048576.0)
            , ReadThroughputMBps =
                CONVERT
                (
                    decimal(19,4),
                    CASE WHEN ObservationSeconds>0
                         THEN (DeltaReadBytes/1048576.0)/ObservationSeconds
                    END
                )
            , WriteThroughputMBps =
                CONVERT
                (
                    decimal(19,4),
                    CASE WHEN ObservationSeconds>0
                         THEN (DeltaWriteBytes/1048576.0)/ObservationSeconds
                    END
                )
        FROM Deltas
    )
    INSERT dbo.RCA_IOStorageEvidence
    (
          CaptureRunID
        , DatabaseID
        , DatabaseName
        , FileID
        , LogicalFileName
        , FileTypeDesc
        , PhysicalName
        , SampleCount
        , DeltaReads
        , DeltaReadMB
        , DeltaReadStallMs
        , AvgReadLatencyMs
        , DeltaWrites
        , DeltaWriteMB
        , DeltaWriteStallMs
        , AvgWriteLatencyMs
        , ObservationSeconds
        , ReadThroughputMBps
        , WriteThroughputMBps
        , ReadLatencyPressure
        , WriteLatencyPressure
        , HeavyReadVolume
        , HeavyWriteVolume
        , UpstreamCauseCategory
        , RootCauseRole
        , Confidence
        , EvidenceSummary
        , RecommendedAction
    )
    SELECT
          @CaptureRunID
        , m.DatabaseID
        , m.DatabaseName
        , m.FileID
        , m.LogicalFileName
        , m.FileTypeDesc
        , m.PhysicalName
        , m.SampleCount
        , m.DeltaReads
        , m.DeltaReadMB
        , m.DeltaReadStallMs
        , m.AvgReadLatencyMs
        , m.DeltaWrites
        , m.DeltaWriteMB
        , m.DeltaWriteStallMs
        , m.AvgWriteLatencyMs
        , m.ObservationSeconds
        , m.ReadThroughputMBps
        , m.WriteThroughputMBps

        , ReadLatencyPressure =
            CASE
                WHEN ISNULL(m.DeltaReads,0)>=100
                 AND ISNULL(m.AvgReadLatencyMs,0)>=20
                THEN 1 ELSE 0
            END

        , WriteLatencyPressure =
            CASE
                WHEN ISNULL(m.DeltaWrites,0)>=100
                 AND ISNULL(m.AvgWriteLatencyMs,0)>=20
                THEN 1 ELSE 0
            END

        , HeavyReadVolume =
            CASE WHEN ISNULL(m.DeltaReadMB,0)>=512 THEN 1 ELSE 0 END

        , HeavyWriteVolume =
            CASE WHEN ISNULL(m.DeltaWriteMB,0)>=512 THEN 1 ELSE 0 END

        , @UpstreamCauseCategory

        , RootCauseRole =
            CASE
                WHEN @UpstreamCauseCategory IS NOT NULL
                    THEN 'CONTRIBUTING'

                WHEN
                    (
                        ISNULL(m.DeltaReads,0)>=100
                        AND ISNULL(m.AvgReadLatencyMs,0)>=20
                    )
                    OR
                    (
                        ISNULL(m.DeltaWrites,0)>=100
                        AND ISNULL(m.AvgWriteLatencyMs,0)>=20
                    )
                    THEN 'PRIMARY'

                ELSE 'CONTRIBUTING'
            END

        , Confidence =
            CASE
                WHEN
                    (
                        ISNULL(m.DeltaReads,0)>=100
                        AND ISNULL(m.AvgReadLatencyMs,0)>=40
                    )
                    OR
                    (
                        ISNULL(m.DeltaWrites,0)>=100
                        AND ISNULL(m.AvgWriteLatencyMs,0)>=40
                    )
                    THEN 'HIGH'

                WHEN
                    (
                        ISNULL(m.DeltaReads,0)>=100
                        AND ISNULL(m.AvgReadLatencyMs,0)>=20
                    )
                    OR
                    (
                        ISNULL(m.DeltaWrites,0)>=100
                        AND ISNULL(m.AvgWriteLatencyMs,0)>=20
                    )
                    THEN 'MEDIUM'

                WHEN ISNULL(m.DeltaReadMB,0)>=512
                  OR ISNULL(m.DeltaWriteMB,0)>=512
                    THEN 'LOW'

                ELSE 'LOW'
            END

        , EvidenceSummary =
            CONCAT
            (
                N'File ',COALESCE(m.DatabaseName,N'?'),N'.',
                COALESCE(m.LogicalFileName,N'?'),
                N' observed for ',
                COALESCE(CONVERT(varchar(30),m.ObservationSeconds),'NULL'),
                N' sec. Reads=',COALESCE(CONVERT(varchar(30),m.DeltaReads),'NULL'),
                N' (',COALESCE(CONVERT(varchar(30),m.DeltaReadMB),'NULL'),
                N' MB), avg read latency=',
                COALESCE(CONVERT(varchar(30),m.AvgReadLatencyMs),'NULL'),
                N' ms, read throughput=',
                COALESCE(CONVERT(varchar(30),m.ReadThroughputMBps),'NULL'),
                N' MB/s. Writes=',COALESCE(CONVERT(varchar(30),m.DeltaWrites),'NULL'),
                N' (',COALESCE(CONVERT(varchar(30),m.DeltaWriteMB),'NULL'),
                N' MB), avg write latency=',
                COALESCE(CONVERT(varchar(30),m.AvgWriteLatencyMs),'NULL'),
                N' ms, write throughput=',
                COALESCE(CONVERT(varchar(30),m.WriteThroughputMBps),'NULL'),
                N' MB/s.'
            )

        , RecommendedAction =
            CASE
                WHEN ISNULL(m.AvgReadLatencyMs,0)>=20
                    THEN N'Investigate read latency on the affected database file: correlate high-read queries, file placement, storage tier, host/cache state, and concurrent backup/checkpoint/maintenance activity before changing SQL settings.'
                WHEN ISNULL(m.AvgWriteLatencyMs,0)>=20
                    THEN N'Investigate write latency on the affected database file: correlate transaction-log/data-file writes, checkpoint activity, storage tier, host contention, and backup/maintenance activity.'
                ELSE
                    N'High I/O volume was observed without strong latency evidence. Correlate the busiest files with query logical/physical reads and confirm whether storage latency was actually user-impacting.'
            END
    FROM Metrics AS m
    WHERE
           ISNULL(m.DeltaReads,0)>0
        OR ISNULL(m.DeltaWrites,0)>0;

    SELECT
          CaptureRunID=@CaptureRunID
        , IOCases=COUNT(*)
        , PrimaryCases=
            SUM(CASE WHEN RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)
        , HighConfidence=
            SUM(CASE WHEN Confidence='HIGH' THEN 1 ELSE 0 END)
        , MediumConfidence=
            SUM(CASE WHEN Confidence='MEDIUM' THEN 1 ELSE 0 END)
    FROM dbo.RCA_IOStorageEvidence
    WHERE CaptureRunID=@CaptureRunID;
END;
GO


/*==============================================================================
6. FINAL CAUSE INTEGRATION
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
    , RecommendedAction=CONVERT(nvarchar(4000),
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
    , CONVERT(nvarchar(4000),m.RecommendedAction)
FROM dbo.RCA_MemorySpillEvidence AS m

UNION ALL

SELECT
      b.CaptureRunID
    , CONVERT(varchar(80),'BLOCKING_WAIT_CHAIN')
    , CONVERT(nvarchar(200),N'Blocking / wait-chain contention')
    , CASE WHEN SUM(CASE WHEN b.RootCauseRole='PRIMARY' THEN 1 ELSE 0 END)>0
           THEN CONVERT(varchar(20),'PRIMARY')
           ELSE CONVERT(varchar(20),'CONTRIBUTING') END
    , CASE WHEN SUM(CASE WHEN b.Confidence='HIGH' THEN 1 ELSE 0 END)>0
           THEN CONVERT(varchar(20),'HIGH')
           WHEN SUM(CASE WHEN b.Confidence='MEDIUM' THEN 1 ELSE 0 END)>0
           THEN CONVERT(varchar(20),'MEDIUM')
           ELSE CONVERT(varchar(20),'LOW') END
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
WHERE
       i.ReadLatencyPressure=1
    OR i.WriteLatencyPressure=1;
GO


/*==============================================================================
7. INSTALL VALIDATION
==============================================================================*/

SELECT
      IOFileSnapshotTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOFileSnapshot',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOSampler =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_RunIOSampler',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageEvidenceTable =
        CASE WHEN OBJECT_ID(N'dbo.RCA_IOStorageEvidence',N'U') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageEvidenceView =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_IOStorageEvidence',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , IOStorageDetector =
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_BuildIOStorageEvidence',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , FinalCauseIntegration =
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates',N'V') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END;
GO
