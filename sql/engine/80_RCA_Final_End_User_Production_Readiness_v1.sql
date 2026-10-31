USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  80_RCA_Final_End_User_Production_Readiness_v1.sql

  PURPOSE
  -------
  Final read-only milestone validation for the RCA end-user experience.

  This script intentionally does NOT pursue the deferred Capture 20 parser
  idempotency enhancement. It validates the current product surface.

  EXPECTED CONTROL OUTCOMES
  -------------------------
  Capture 38 : uncertainty / no supported primary root cause
  Capture 42 : BLOCKING_WAIT_CHAIN / PRIMARY / HIGH
  Capture 44 : CPU_SCHEDULER / PRIMARY / HIGH
  Capture 20 : IO_STORAGE_LATENCY / PRIMARY / MEDIUM

  SAFETY
  ------
  READ ONLY.
==============================================================================*/


/* 0 - REQUIRED END USER OBJECTS */
SELECT
      ValidationSection='0 - END USER OBJECTS'
    , StartProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Start',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , StatusProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Status',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , StopProcedure=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_Stop',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CanonicalAnswer=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias1=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlow',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , FriendlyAlias2=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ExplainDatabaseSlowness',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , CrossDomainSummary=
        CASE WHEN OBJECT_ID(N'dbo.vw_RCA_CrossDomainCauseSummary',N'V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;


/* 1 - CONTROL CAPTURE STATES */
SELECT
      ValidationSection='1 - CONTROL CAPTURE STATES'
    , CaptureRunID
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID IN (20,38,42,44)
ORDER BY CaptureRunID;


/* 2 - NORMALIZED ROOT-CAUSE SUMMARY */
SELECT
      ValidationSection='2 - NORMALIZED ROOT CAUSE SUMMARY'
    , CaptureRunID
    , PrimaryCauseCategory
    , PrimaryCauseDisplayName
    , PrimaryCauseRole
    , PrimaryConfidence
    , PrimaryEvidenceObject
    , PrimaryEvidenceID
    , PrimaryExecutionEvidenceID
    , PrimarySessionID
    , SupportedCauseCount
    , PrimaryCauseCount
    , ArbitrationStatus
FROM dbo.vw_RCA_CrossDomainCauseSummary
WHERE CaptureRunID IN (20,38,42,44)
ORDER BY CaptureRunID;


/* 3 - CONTROL EXPECTATION MATRIX */
SELECT
      ValidationSection='3 - CONTROL EXPECTATION MATRIX'
    , v.CaptureRunID
    , ExpectedCause=
        CASE v.CaptureRunID
          WHEN 20 THEN 'IO_STORAGE_LATENCY'
          WHEN 38 THEN NULL
          WHEN 42 THEN 'BLOCKING_WAIT_CHAIN'
          WHEN 44 THEN 'CPU_SCHEDULER'
        END
    , ActualCause=v.PrimaryCauseCategory
    , ExpectedRole=
        CASE WHEN v.CaptureRunID IN (20,42,44) THEN 'PRIMARY' ELSE NULL END
    , ActualRole=v.PrimaryCauseRole
    , ExpectedConfidence=
        CASE v.CaptureRunID
          WHEN 20 THEN 'MEDIUM'
          WHEN 38 THEN NULL
          WHEN 42 THEN 'HIGH'
          WHEN 44 THEN 'HIGH'
        END
    , ActualConfidence=v.PrimaryConfidence
    , Result=
        CASE
          WHEN v.CaptureRunID=20
           AND v.PrimaryCauseCategory='IO_STORAGE_LATENCY'
           AND v.PrimaryCauseRole='PRIMARY'
           AND v.PrimaryConfidence='MEDIUM'
           AND v.PrimaryExecutionEvidenceID IS NULL
           AND v.PrimarySessionID IS NULL
            THEN 'PASS'
          WHEN v.CaptureRunID=38
           AND ISNULL(v.PrimaryCauseCount,0)=0
            THEN 'PASS'
          WHEN v.CaptureRunID=42
           AND v.PrimaryCauseCategory='BLOCKING_WAIT_CHAIN'
           AND v.PrimaryCauseRole='PRIMARY'
           AND v.PrimaryConfidence='HIGH'
            THEN 'PASS'
          WHEN v.CaptureRunID=44
           AND v.PrimaryCauseCategory='CPU_SCHEDULER'
           AND v.PrimaryCauseRole='PRIMARY'
           AND v.PrimaryConfidence='HIGH'
            THEN 'PASS'
          ELSE 'REVIEW'
        END
FROM dbo.vw_RCA_CrossDomainCauseSummary v
WHERE v.CaptureRunID IN (20,38,42,44)
ORDER BY v.CaptureRunID;


/* 4 - EVIDENCE INTEGRITY */
SELECT
      ValidationSection='4 - XERAWID DUPLICATE INTEGRITY'
    , EvidenceObject='RCA_ExecutionEvidence'
    , DuplicateGroups=COUNT_BIG(*)
FROM
(
    SELECT XERawID
    FROM dbo.RCA_ExecutionEvidence
    WHERE XERawID IS NOT NULL
    GROUP BY XERawID
    HAVING COUNT_BIG(*)>1
) d
UNION ALL
SELECT
      '4 - XERAWID DUPLICATE INTEGRITY'
    , 'RCA_StatementEvidence'
    , COUNT_BIG(*)
FROM
(
    SELECT XERawID
    FROM dbo.RCA_StatementEvidence
    WHERE XERawID IS NOT NULL
    GROUP BY XERawID
    HAVING COUNT_BIG(*)>1
) d
UNION ALL
SELECT
      '4 - XERAWID DUPLICATE INTEGRITY'
    , 'RCA_PlanEvidence'
    , COUNT_BIG(*)
FROM
(
    SELECT XERawID
    FROM dbo.RCA_PlanEvidence
    WHERE XERawID IS NOT NULL
    GROUP BY XERawID
    HAVING COUNT_BIG(*)>1
) d;


/* 5 - CANONICAL ANSWER: I/O */
SELECT ValidationSection='5 - END USER ANSWER - IO',CaptureRunID=20;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=20;


/* 6 - CANONICAL ANSWER: UNCERTAINTY */
SELECT ValidationSection='6 - END USER ANSWER - UNCERTAINTY',CaptureRunID=38;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=38;


/* 7 - CANONICAL ANSWER: BLOCKING */
SELECT ValidationSection='7 - END USER ANSWER - BLOCKING',CaptureRunID=42;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=42;


/* 8 - CANONICAL ANSWER: CPU */
SELECT ValidationSection='8 - END USER ANSWER - CPU',CaptureRunID=44;
EXEC dbo.usp_RCA_DBAAnswer @CaptureRunID=44;


/* 9 - FRIENDLY ENTRY POINT CHECK */
SELECT
      ValidationSection='9 - FRIENDLY ENTRY POINTS'
    , PrimaryCommand='EXEC DBA.dbo.usp_RCA_DBAAnswer @CaptureRunID = <id>;'
    , FriendlyCommand1='EXEC DBA.dbo.usp_RCA_WhyIsDatabaseSlow @CaptureRunID = <id>;'
    , FriendlyCommand2='EXEC DBA.dbo.usp_RCA_ExplainDatabaseSlowness @CaptureRunID = <id>;'
    , OperationalPrinciple=
        'End user supplies a CaptureRunID and receives an evidence-backed human-readable RCA answer.';


/* 10 - RELEASE DECISION */
DECLARE @ControlPass int=0;

SELECT @ControlPass=COUNT(*)
FROM dbo.vw_RCA_CrossDomainCauseSummary v
WHERE
       (v.CaptureRunID=20
        AND v.PrimaryCauseCategory='IO_STORAGE_LATENCY'
        AND v.PrimaryCauseRole='PRIMARY'
        AND v.PrimaryConfidence='MEDIUM'
        AND v.PrimaryExecutionEvidenceID IS NULL
        AND v.PrimarySessionID IS NULL)
    OR (v.CaptureRunID=38
        AND ISNULL(v.PrimaryCauseCount,0)=0)
    OR (v.CaptureRunID=42
        AND v.PrimaryCauseCategory='BLOCKING_WAIT_CHAIN'
        AND v.PrimaryCauseRole='PRIMARY'
        AND v.PrimaryConfidence='HIGH')
    OR (v.CaptureRunID=44
        AND v.PrimaryCauseCategory='CPU_SCHEDULER'
        AND v.PrimaryCauseRole='PRIMARY'
        AND v.PrimaryConfidence='HIGH');

SELECT
      ValidationSection='10 - RELEASE DECISION'
    , ProvenControlOutcomes=@ControlPass
    , ExpectedControlOutcomes=4
    , EndUserEntryPoint=
        CASE WHEN OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END
    , ReleaseStatus=
        CASE WHEN @ControlPass=4
                  AND OBJECT_ID(N'dbo.usp_RCA_DBAAnswer',N'P') IS NOT NULL
             THEN 'READY - CORE RCA END USER MILESTONE'
             ELSE 'REVIEW'
        END
    , DeferredEnhancement=
        'Historical overlapping-capture parser idempotency / XERawID ownership handling.'
    , ProductPrinciple=
        'Ship the working evidence-driven RCA experience; harden edge cases incrementally.';


/* 11 - SAFETY */
SELECT
      ValidationSection='11 - SCRIPT 80 SAFETY'
    , ValidationOnly='YES'
    , CapturesModified='NO'
    , EvidenceModified='NO'
    , ParserModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseDomainsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , SQLAgentJobsModified='NO'
    , NewCaptureStarted='NO';
GO
