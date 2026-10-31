USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  79C_RCA_ParseCaptureRun_Execution_Statement_Source_Discovery_v1.sql

  PURPOSE
  -------
  Read-only discovery focused ONLY on the two unresolved parser branches:

      dbo.RCA_ExecutionEvidence
      dbo.RCA_StatementEvidence

  Script 79B proved:
      Execution INSERT line = 58
      Statement INSERT line = 330
      Plan INSERT line      = 462

  Script 79B also proved:
      Plan raw XE source is at line 437
      Execution raw XE source was not inside the forward search window
      Statement raw XE source was not inside the forward search window

  This strongly suggests the Execution and Statement INSERTs are fed by
  CTEs / derived rowsets / source blocks defined BEFORE the INSERT statements.

  THIS SCRIPT FINDS:
      1. All RCA_XERaw references in the parser.
      2. All CTE declarations before ExecutionEvidence INSERT.
      3. All CTE declarations before StatementEvidence INSERT.
      4. Exact source blocks immediately preceding each INSERT.
      5. The SELECT/FROM/WHERE chain feeding each INSERT.
      6. Candidate patch points for an XERawID anti-collision guard.

  SAFETY
  ------
  READ ONLY.
==============================================================================*/


/*==============================================================================
  0. PRE-FLIGHT
==============================================================================*/
DECLARE @Definition nvarchar(max);

SELECT @Definition = sm.definition
FROM sys.sql_modules AS sm
WHERE sm.object_id = OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun');

SELECT
      ValidationSection='0 - SCRIPT 79C PRE-FLIGHT'
    , ParseCaptureRun=
        CASE WHEN @Definition IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , DefinitionLength=LEN(@Definition)
    , ReadOnlyInvestigation='YES'
    , ParserModified='NO'
    , Capture20Modified='NO'
    , ExistingEvidenceModified='NO'
    , UniqueIndexesModified='NO'
    , NewCaptureStarted='NO';

IF @Definition IS NULL
    THROW 62990,N'Unable to read dbo.usp_RCA_ParseCaptureRun.',1;


/*==============================================================================
  1. PARSE PROCEDURE INTO NUMBERED LINES
==============================================================================*/
DECLARE @Normalized nvarchar(max);

SET @Normalized =
    REPLACE
    (
        REPLACE(@Definition,CHAR(13)+CHAR(10),CHAR(10)),
        CHAR(13),
        CHAR(10)
    );

IF OBJECT_ID('tempdb..#ParserLines') IS NOT NULL
    DROP TABLE #ParserLines;

CREATE TABLE #ParserLines
(
      LineNumber int NOT NULL PRIMARY KEY
    , LineText nvarchar(max) NULL
);

DECLARE
      @Pos int=1
    , @Next int
    , @Line int=1
    , @Len int=LEN(@Normalized);

WHILE @Pos<=@Len+1
BEGIN
    SET @Next=CHARINDEX(CHAR(10),@Normalized,@Pos);

    IF @Next=0
        SET @Next=@Len+1;

    INSERT #ParserLines(LineNumber,LineText)
    VALUES
    (
          @Line
        , SUBSTRING(@Normalized,@Pos,@Next-@Pos)
    );

    SET @Pos=@Next+1;
    SET @Line+=1;

    IF @Next>@Len BREAK;
END;


/*==============================================================================
  2. KNOWN INSERT LOCATIONS
==============================================================================*/
DECLARE
      @ExecutionInsertLine int
    , @StatementInsertLine int
    , @PlanInsertLine int;

SELECT TOP (1) @ExecutionInsertLine=LineNumber
FROM #ParserLines
WHERE UPPER(LTRIM(RTRIM(LineText))) LIKE N'INSERT%RCA_EXECUTIONEVIDENCE%'
ORDER BY LineNumber;

SELECT TOP (1) @StatementInsertLine=LineNumber
FROM #ParserLines
WHERE UPPER(LTRIM(RTRIM(LineText))) LIKE N'INSERT%RCA_STATEMENTEVIDENCE%'
ORDER BY LineNumber;

SELECT TOP (1) @PlanInsertLine=LineNumber
FROM #ParserLines
WHERE UPPER(LTRIM(RTRIM(LineText))) LIKE N'INSERT%RCA_PLANEVIDENCE%'
ORDER BY LineNumber;

SELECT
      ValidationSection='1 - KNOWN INSERT LOCATIONS'
    , ExecutionInsertLine=@ExecutionInsertLine
    , StatementInsertLine=@StatementInsertLine
    , PlanInsertLine=@PlanInsertLine
    , Result=
        CASE
          WHEN @ExecutionInsertLine=58
           AND @StatementInsertLine=330
           AND @PlanInsertLine=462
          THEN 'PASS'
          ELSE 'REVIEW'
        END;


/*==============================================================================
  3. ALL RCA_XERaw REFERENCES
==============================================================================*/
SELECT
      DiagnosticSection='2 - ALL RCA_XERAW REFERENCES'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE UPPER(LineText) LIKE N'%RCA_XERAW%'
ORDER BY LineNumber;


/*==============================================================================
  4. ALL CTE / SOURCE-SET DECLARATIONS
==============================================================================*/
SELECT
      DiagnosticSection='3 - CTE AND SOURCE DECLARATIONS'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE
       UPPER(LTRIM(LineText)) LIKE N';WITH %'
    OR UPPER(LTRIM(LineText)) LIKE N'WITH %'
    OR UPPER(LineText) LIKE N'% AS (%'
    OR UPPER(LineText) LIKE N'% AS%'
ORDER BY LineNumber;


/*==============================================================================
  5. EXECUTION BRANCH - FULL PRECEDING SOURCE REGION

  We deliberately look backward from the INSERT because 79B showed the
  RCA_XERaw FROM clause is not after line 58.
==============================================================================*/
SELECT
      DiagnosticSection='4 - EXECUTION PRE-INSERT SOURCE REGION'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @ExecutionInsertLine-55
                     AND @ExecutionInsertLine+55
ORDER BY LineNumber;


/*==============================================================================
  6. STATEMENT BRANCH - FULL PRECEDING SOURCE REGION
==============================================================================*/
SELECT
      DiagnosticSection='5 - STATEMENT PRE-INSERT SOURCE REGION'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @StatementInsertLine-80
                     AND @StatementInsertLine+70
ORDER BY LineNumber;


/*==============================================================================
  7. EXECUTION BRANCH - SOURCE / PREDICATE LINES ONLY
==============================================================================*/
SELECT
      DiagnosticSection='6 - EXECUTION SOURCE KEY LINES'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @ExecutionInsertLine-70
                     AND @ExecutionInsertLine+70
  AND
  (
       UPPER(LineText) LIKE N'%RCA_XERAW%'
    OR UPPER(LineText) LIKE N'%XERAWID%'
    OR UPPER(LTRIM(LineText)) LIKE N'%SELECT%'
    OR UPPER(LTRIM(LineText)) LIKE N'%FROM%'
    OR UPPER(LTRIM(LineText)) LIKE N'%JOIN%'
    OR UPPER(LTRIM(LineText)) LIKE N'%WHERE%'
    OR UPPER(LTRIM(LineText)) LIKE N'%AND %'
    OR UPPER(LTRIM(LineText)) LIKE N'%OR %'
    OR UPPER(LTRIM(LineText)) LIKE N';WITH %'
    OR UPPER(LTRIM(LineText)) LIKE N'WITH %'
  )
ORDER BY LineNumber;


/*==============================================================================
  8. STATEMENT BRANCH - SOURCE / PREDICATE LINES ONLY
==============================================================================*/
SELECT
      DiagnosticSection='7 - STATEMENT SOURCE KEY LINES'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @StatementInsertLine-100
                     AND @StatementInsertLine+90
  AND
  (
       UPPER(LineText) LIKE N'%RCA_XERAW%'
    OR UPPER(LineText) LIKE N'%XERAWID%'
    OR UPPER(LTRIM(LineText)) LIKE N'%SELECT%'
    OR UPPER(LTRIM(LineText)) LIKE N'%FROM%'
    OR UPPER(LTRIM(LineText)) LIKE N'%JOIN%'
    OR UPPER(LTRIM(LineText)) LIKE N'%WHERE%'
    OR UPPER(LTRIM(LineText)) LIKE N'%AND %'
    OR UPPER(LTRIM(LineText)) LIKE N'%OR %'
    OR UPPER(LTRIM(LineText)) LIKE N';WITH %'
    OR UPPER(LTRIM(LineText)) LIKE N'WITH %'
  )
ORDER BY LineNumber;


/*==============================================================================
  9. FIND THE NEAREST RCA_XERaw SOURCE BEFORE EACH INSERT
==============================================================================*/
DECLARE
      @ExecutionNearestRawLine int
    , @StatementNearestRawLine int;

SELECT TOP (1) @ExecutionNearestRawLine=LineNumber
FROM #ParserLines
WHERE LineNumber < @ExecutionInsertLine
  AND UPPER(LineText) LIKE N'%RCA_XERAW%'
ORDER BY LineNumber DESC;

SELECT TOP (1) @StatementNearestRawLine=LineNumber
FROM #ParserLines
WHERE LineNumber < @StatementInsertLine
  AND UPPER(LineText) LIKE N'%RCA_XERAW%'
ORDER BY LineNumber DESC;

SELECT
      ValidationSection='8 - NEAREST PRECEDING RCA_XERAW SOURCE'
    , ExecutionNearestRawLine=@ExecutionNearestRawLine
    , StatementNearestRawLine=@StatementNearestRawLine;


/*==============================================================================
  10. EXACT EXECUTION SOURCE BLOCK AROUND NEAREST RCA_XERaw
==============================================================================*/
SELECT
      DiagnosticSection='8A - EXECUTION NEAREST RAW BLOCK'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE @ExecutionNearestRawLine IS NOT NULL
  AND LineNumber BETWEEN @ExecutionNearestRawLine-25
                     AND @ExecutionNearestRawLine+35
ORDER BY LineNumber;


/*==============================================================================
  11. EXACT STATEMENT SOURCE BLOCK AROUND NEAREST RCA_XERaw
==============================================================================*/
SELECT
      DiagnosticSection='8B - STATEMENT NEAREST RAW BLOCK'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE @StatementNearestRawLine IS NOT NULL
  AND LineNumber BETWEEN @StatementNearestRawLine-35
                     AND @StatementNearestRawLine+40
ORDER BY LineNumber;


/*==============================================================================
  12. FIND THE NEAREST CTE START BEFORE EACH INSERT
==============================================================================*/
DECLARE
      @ExecutionNearestCTELine int
    , @StatementNearestCTELine int;

SELECT TOP (1) @ExecutionNearestCTELine=LineNumber
FROM #ParserLines
WHERE LineNumber < @ExecutionInsertLine
  AND
  (
       UPPER(LTRIM(LineText)) LIKE N';WITH %'
    OR UPPER(LTRIM(LineText)) LIKE N'WITH %'
  )
ORDER BY LineNumber DESC;

SELECT TOP (1) @StatementNearestCTELine=LineNumber
FROM #ParserLines
WHERE LineNumber < @StatementInsertLine
  AND
  (
       UPPER(LTRIM(LineText)) LIKE N';WITH %'
    OR UPPER(LTRIM(LineText)) LIKE N'WITH %'
  )
ORDER BY LineNumber DESC;

SELECT
      ValidationSection='9 - NEAREST CTE BEFORE INSERT'
    , ExecutionNearestCTELine=@ExecutionNearestCTELine
    , StatementNearestCTELine=@StatementNearestCTELine;


/*==============================================================================
  13. CURRENT ANTI-COLLISION LOGIC RECONFIRMATION
==============================================================================*/
SELECT
      ValidationSection='10 - CURRENT COLLISION LOGIC'
    , HasNotExists=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM #ParserLines
            WHERE UPPER(LineText) LIKE N'%NOT EXISTS%'
        ) THEN 'YES' ELSE 'NO' END
    , HasMerge=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM #ParserLines
            WHERE UPPER(LineText) LIKE N'%MERGE%'
        ) THEN 'YES' ELSE 'NO' END
    , HasIgnoreDupKeyText=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM #ParserLines
            WHERE UPPER(LineText) LIKE N'%IGNORE_DUP_KEY%'
        ) THEN 'YES' ELSE 'NO' END;


/*==============================================================================
  14. CAPTURE 20 / DUPLICATE OWNER RECONFIRMATION
==============================================================================*/
SELECT
      ValidationSection='11 - CAPTURE 20 STATE'
    , cr.CaptureRunID
    , cr.CaptureStatus
    , cr.StartTimeUTC
    , cr.EndTimeUTC
    , ExecutionRows=
        (SELECT COUNT_BIG(*) FROM dbo.RCA_ExecutionEvidence e
         WHERE e.CaptureRunID=cr.CaptureRunID)
    , StatementRows=
        (SELECT COUNT_BIG(*) FROM dbo.RCA_StatementEvidence s
         WHERE s.CaptureRunID=cr.CaptureRunID)
    , PlanRows=
        (SELECT COUNT_BIG(*) FROM dbo.RCA_PlanEvidence p
         WHERE p.CaptureRunID=cr.CaptureRunID)
FROM dbo.RCA_CaptureRun cr
WHERE cr.CaptureRunID=20;

SELECT
      ValidationSection='11A - XERAWID 8135 OWNER'
    , ExecutionEvidenceID
    , CaptureRunID
    , XERawID
    , EventName
    , EventTimeUTC
    , DatabaseName
    , SessionID
FROM dbo.RCA_ExecutionEvidence
WHERE XERawID=8135;


/*==============================================================================
  15. FINAL SAFETY
==============================================================================*/
SELECT
      ValidationSection='12 - SCRIPT 79C SAFETY'
    , ReadOnlyInvestigation='YES'
    , ParserModified='NO'
    , Capture20Modified='NO'
    , ExistingEvidenceModified='NO'
    , UniqueIndexesModified='NO'
    , RCA_XERawModified='NO'
    , SQLAgentJobsModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , NewCaptureStarted='NO'
    , NextStep=
        N'Use Sections 2, 6, 7, 8A, 8B and 9 to identify the actual source rowsets feeding ExecutionEvidence and StatementEvidence, then patch those source predicates structurally.';
GO
