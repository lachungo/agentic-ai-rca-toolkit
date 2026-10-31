USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
24_RCA_IO_Storage_Intelligence_v1_1_IntegrationPatch.sql

PURPOSE
-------
Safely integrate the already-installed I/O detector into the proven unified
cause-candidate view without changing any existing detector schema.

WHY THIS PATCH EXISTS
---------------------
The first v1 integration incorrectly assumed RCA_MemorySpillEvidence exposed
RecommendedAction. It does not.

This patch is based on the deployed schemas and preserves the already-proven
candidate logic for:

- PARAMETER_SENSITIVE_PLAN_REUSE
- STATISTICS_CARDINALITY_REGRESSION
- MEMORY_GRANT_SPILL
- BLOCKING_WAIT_CHAIN
- CPU_SCHEDULER_PRESSURE

It only appends:

- IO_STORAGE_PRESSURE

NO TABLE CHANGES.
NO COLLECTOR CHANGES.
NO XE CHANGES.
NO SAMPLER CHANGES.
NO DETECTOR REBUILDS.
==============================================================================*/


/*==============================================================================
1. REBUILD THE INTEGRATION CONTRACT USING DEPLOYED COLUMN NAMES
==============================================================================*/

CREATE OR ALTER VIEW dbo.vw_RCA_FinalCauseCandidates
AS

/*--------------------------------------------------------------------------
A. PARAMETER-SENSITIVE PLAN REUSE
--------------------------------------------------------------------------*/
SELECT
      p.CaptureRunID
    , CauseCategory =
        CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    , CauseDisplayName =
        CONVERT(nvarchar(200),N'Parameter-sensitive plan reuse')
    , RootCauseRole =
        CONVERT(varchar(20),'PRIMARY')
    , Confidence =
        p.Confidence
    , CorrelationKey =
        CONVERT
        (
            nvarchar(200),
            CONCAT(N'EXEC:',p.ImpactedExecutionEvidenceID)
        )
    , ImpactedExecutionEvidenceID =
        p.ImpactedExecutionEvidenceID
    , HeadBlockerSessionID =
        CONVERT(int,NULL)
    , ImpactedRequestCount =
        CONVERT(int,1)
    , BlockingDepth =
        CONVERT(int,NULL)
    , MaxObservedWaitMs =
        CONVERT(bigint,NULL)
    , DurationRatio =
        p.DurationRatio
    , CPURatio =
        p.CPURatio
    , LogicalReadRatio =
        p.LogicalReadRatio
    , EvidenceCount =
        p.SharedStatementPlanCount
    , PrimaryEvidence =
        p.EvidenceSummary
    , RecommendedAction =
        CONVERT
        (
            nvarchar(4000),
            N'Validate the distinct parameter distributions with measured plan alternatives and re-test the identical runtime parameter values.'
        )
FROM dbo.RCA_ParameterSensitivePlanEvidence AS p


UNION ALL


/*--------------------------------------------------------------------------
B. STATISTICS / CARDINALITY REGRESSION
--------------------------------------------------------------------------*/
SELECT
      s.CaptureRunID
    , CONVERT(varchar(80),'STATISTICS_CARDINALITY_REGRESSION')
    , CONVERT(nvarchar(200),N'Statistics / cardinality regression')
    , CONVERT(varchar(20),'PRIMARY')
    , s.Confidence
    , CONVERT
      (
          nvarchar(200),
          CONCAT(N'EXEC:',s.ImpactedExecutionEvidenceID)
      )
    , s.ImpactedExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , s.DurationRatio
    , s.CPURatio
    , s.LogicalReadRatio
    , s.CardinalityMismatchCount
      + s.StatisticsRiskCount
      + s.LargeScanCount
    , s.EvidenceSummary
    , CONVERT
      (
          nvarchar(4000),
          N'Review the statistics used by the affected operators, validate estimate-versus-actual row counts, and re-test after the least invasive corrective change.'
      )
FROM dbo.RCA_StatisticsCardinalityEvidence AS s


UNION ALL


/*--------------------------------------------------------------------------
C. MEMORY GRANT / SPILL

IMPORTANT:
RCA_MemorySpillEvidence does NOT expose RecommendedAction.
Preserve the proven constant recommendation from the existing integration.
--------------------------------------------------------------------------*/
SELECT
      m.CaptureRunID
    , CONVERT(varchar(80),'MEMORY_GRANT_SPILL')
    , CONVERT(nvarchar(200),N'Memory grant / spill')
    , m.RootCauseRole
    , m.Confidence
    , CONVERT
      (
          nvarchar(200),
          CONCAT(N'EXEC:',m.ImpactedExecutionEvidenceID)
      )
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
    , CONVERT
      (
          nvarchar(4000),
          N'Review requested, granted, and used query memory together with spill operators; correct upstream estimate problems first when they are stronger causal evidence.'
      )
FROM dbo.RCA_MemorySpillEvidence AS m


UNION ALL


/*--------------------------------------------------------------------------
D. BLOCKING / WAIT CHAIN
--------------------------------------------------------------------------*/
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
    , CONVERT
      (
          nvarchar(200),
          CONCAT(N'HEAD_BLOCKER:',b.HeadBlockerSessionID)
      )
    , CONVERT(bigint,NULL)
    , b.HeadBlockerSessionID
    , COUNT(DISTINCT b.VictimSessionID)
    , MAX(b.BlockingDepth)
    , MAX(b.WaitDurationMs)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , SUM(b.SampleCount)
    , CONVERT
      (
          nvarchar(max),
          CONCAT
          (
              N'Head blocker session ',b.HeadBlockerSessionID,
              N' affected ',COUNT(DISTINCT b.VictimSessionID),
              N' distinct request(s). Maximum blocking depth=',
              MAX(b.BlockingDepth),
              N'; maximum observed wait=',
              MAX(b.WaitDurationMs),
              N' ms; total sampler observations=',
              SUM(b.SampleCount),N'.'
          )
      )
    , CONVERT
      (
          nvarchar(4000),
          CONCAT
          (
              N'Investigate head blocker session ',
              b.HeadBlockerSessionID,
              N', identify the transaction retaining the required locks, and map the blocker host/application/login back to the owning workload.'
          )
      )
FROM dbo.RCA_BlockingEvidence AS b
GROUP BY
      b.CaptureRunID
    , b.HeadBlockerSessionID


UNION ALL


/*--------------------------------------------------------------------------
E. CPU / SCHEDULER PRESSURE

RCA_CPUSchedulerEvidence DOES expose RecommendedAction.
--------------------------------------------------------------------------*/
SELECT
      c.CaptureRunID
    , CONVERT(varchar(80),'CPU_SCHEDULER_PRESSURE')
    , CONVERT(nvarchar(200),N'CPU / scheduler pressure')
    , c.RootCauseRole
    , c.Confidence
    , CONVERT
      (
          nvarchar(200),
          CONCAT(N'EXEC:',c.PrimaryExecutionEvidenceID)
      )
    , c.PrimaryExecutionEvidenceID
    , CONVERT(int,NULL)
    , CONVERT(int,1)
    , CONVERT(int,NULL)
    , CONVERT(bigint,NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , CONVERT(decimal(19,4),NULL)
    , c.HighSqlCpuSampleCount
      + c.HighRunnableSampleCount
    , c.EvidenceSummary
    , CONVERT(nvarchar(4000),c.RecommendedAction)
FROM dbo.RCA_CPUSchedulerEvidence AS c


UNION ALL


/*--------------------------------------------------------------------------
F. I/O LATENCY / STORAGE PRESSURE

Only latency-pressure rows enter causal ranking.
High volume alone remains evidence, not an asserted storage root cause.
--------------------------------------------------------------------------*/
SELECT
      i.CaptureRunID
    , CONVERT(varchar(80),'IO_STORAGE_PRESSURE')
    , CONVERT(nvarchar(200),N'I/O latency / storage pressure')
    , i.RootCauseRole
    , i.Confidence
    , CONVERT
      (
          nvarchar(200),
          CONCAT
          (
              N'FILE:',
              i.DatabaseID,
              N':',
              i.FileID
          )
      )
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
2. INTEGRATION VALIDATION
==============================================================================*/

SELECT
      FinalCauseCandidates =
        CASE
            WHEN OBJECT_ID
                 (
                     N'dbo.vw_RCA_FinalCauseCandidates',
                     N'V'
                 ) IS NOT NULL
            THEN 'PASS'
            ELSE 'FAIL'
        END
    , IOStorageCandidateSupport =
        CASE
            WHEN COL_LENGTH
                 (
                     N'dbo.RCA_IOStorageEvidence',
                     N'RecommendedAction'
                 ) IS NOT NULL
             AND COL_LENGTH
                 (
                     N'dbo.RCA_IOStorageEvidence',
                     N'ReadLatencyPressure'
                 ) IS NOT NULL
             AND COL_LENGTH
                 (
                     N'dbo.RCA_IOStorageEvidence',
                     N'WriteLatencyPressure'
                 ) IS NOT NULL
            THEN 'PASS'
            ELSE 'FAIL'
        END;
GO


/*==============================================================================
3. PROVE THE VIEW'S OUTPUT CONTRACT
==============================================================================*/

SELECT
      c.column_id
    , ColumnName=c.name
    , DataType=TYPE_NAME(c.user_type_id)
FROM sys.columns AS c
WHERE c.object_id=OBJECT_ID(N'dbo.vw_RCA_FinalCauseCandidates')
ORDER BY c.column_id;
GO


/*==============================================================================
4. REGRESSION MATRIX - PREVIOUSLY PROVEN RUNS

No I/O run is included yet because Run 9 has not been executed.
==============================================================================*/

;WITH TestRuns AS
(
    SELECT CaptureRunID=CONVERT(bigint,3),
           ExpectedCause=CONVERT(varchar(80),'PARAMETER_SENSITIVE_PLAN_REUSE')
    UNION ALL SELECT 5,  'STATISTICS_CARDINALITY_REGRESSION'
    UNION ALL SELECT 6,  'MEMORY_GRANT_SPILL'
    UNION ALL SELECT 7,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 8,  'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 13, 'BLOCKING_WAIT_CHAIN'
    UNION ALL SELECT 16, 'CPU_SCHEDULER_PRESSURE'
),
Ranked AS
(
    SELECT
          t.CaptureRunID
        , t.ExpectedCause
        , c.CauseCategory
        , c.CauseDisplayName
        , c.RootCauseRole
        , c.Confidence
        , rn =
            ROW_NUMBER() OVER
            (
                PARTITION BY t.CaptureRunID
                ORDER BY
                      c.RoleRank
                    , c.ConfidenceRank
                    , c.ImpactRank
                    , c.EvidenceStrengthRank
            )
    FROM TestRuns AS t
    JOIN dbo.RCA_CaptureRun AS r
      ON r.CaptureRunID=t.CaptureRunID
    LEFT JOIN dbo.vw_RCA_FinalCauseRanking AS c
      ON c.CaptureRunID=t.CaptureRunID
)
SELECT
      CaptureRunID
    , ExpectedCause
    , DetectedTopCause=CauseCategory
    , CauseDisplayName
    , RootCauseRole
    , Confidence
    , ValidationResult =
        CASE
            WHEN CauseCategory=ExpectedCause
                THEN 'PASS'
            ELSE 'REVIEW'
        END
FROM Ranked
WHERE rn=1
ORDER BY CaptureRunID;
GO


/*==============================================================================
EXPECTED
--------
FinalCauseCandidates        PASS
IOStorageCandidateSupport   PASS

Regression:
3   PASS
5   PASS
6   PASS
7   PASS
8   PASS
13  PASS
16  PASS

After those pass, proceed to 25_RCA_Run9_IO_Storage_Validation.sql.
==============================================================================*/
