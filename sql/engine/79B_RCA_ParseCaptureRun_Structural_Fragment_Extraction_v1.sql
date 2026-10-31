USE DBA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  79B_RCA_ParseCaptureRun_Structural_Fragment_Extraction_v1.sql

  PURPOSE
  -------
  Read-only structural extraction of the three vulnerable parser branches in
  dbo.usp_RCA_ParseCaptureRun after Script 79 safely aborted because an exact
  whitespace-sensitive predicate match was not found.

  This script does NOT modify the parser.

  It identifies the INSERT locations structurally, then returns:
      - the exact ExecutionEvidence branch;
      - the exact StatementEvidence branch;
      - the exact PlanEvidence branch;
      - the exact FROM dbo.RCA_XERaw / WHERE predicates;
      - nearby statement boundaries;
      - current duplicate-guard state.

  SAFETY
  ------
  READ ONLY.
==============================================================================*/

DECLARE @Definition nvarchar(max);

SELECT @Definition = sm.definition
FROM sys.sql_modules AS sm
WHERE sm.object_id = OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun');

SELECT
      ValidationSection='0 - SCRIPT 79B PRE-FLIGHT'
    , ParseCaptureRun=CASE WHEN @Definition IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , DefinitionLength=LEN(@Definition)
    , ReadOnlyInvestigation='YES'
    , ParserModified='NO'
    , Capture20Modified='NO'
    , ExistingEvidenceModified='NO'
    , UniqueIndexesModified='NO'
    , NewCaptureStarted='NO';

IF @Definition IS NULL
    THROW 62980,N'Unable to read dbo.usp_RCA_ParseCaptureRun.',1;

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
    , StartChar int NOT NULL
    , EndChar int NOT NULL
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

    INSERT #ParserLines(LineNumber,StartChar,EndChar,LineText)
    VALUES
    (
          @Line
        , @Pos
        , @Next-1
        , SUBSTRING(@Normalized,@Pos,@Next-@Pos)
    );

    SET @Pos=@Next+1;
    SET @Line+=1;

    IF @Next>@Len BREAK;
END;

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
      ValidationSection='1 - STRUCTURAL INSERT LOCATIONS'
    , ExecutionInsertLine=@ExecutionInsertLine
    , StatementInsertLine=@StatementInsertLine
    , PlanInsertLine=@PlanInsertLine
    , Result=
        CASE
          WHEN @ExecutionInsertLine IS NOT NULL
           AND @StatementInsertLine IS NOT NULL
           AND @PlanInsertLine IS NOT NULL
          THEN 'PASS'
          ELSE 'FAIL'
        END;

IF @ExecutionInsertLine IS NULL
    THROW 62981,N'Could not structurally locate INSERT into RCA_ExecutionEvidence.',1;
IF @StatementInsertLine IS NULL
    THROW 62982,N'Could not structurally locate INSERT into RCA_StatementEvidence.',1;
IF @PlanInsertLine IS NULL
    THROW 62983,N'Could not structurally locate INSERT into RCA_PlanEvidence.',1;

SELECT
      DiagnosticSection='2 - EXECUTION BRANCH EXACT TEXT'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @ExecutionInsertLine AND @ExecutionInsertLine+80
ORDER BY LineNumber;

SELECT
      DiagnosticSection='3 - STATEMENT BRANCH EXACT TEXT'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @StatementInsertLine AND @StatementInsertLine+80
ORDER BY LineNumber;

SELECT
      DiagnosticSection='4 - PLAN BRANCH EXACT TEXT'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @PlanInsertLine-20 AND @PlanInsertLine+90
ORDER BY LineNumber;

DECLARE
      @ExecutionFromLine int
    , @StatementFromLine int
    , @PlanFromLine int;

SELECT TOP (1) @ExecutionFromLine=LineNumber
FROM #ParserLines
WHERE LineNumber BETWEEN @ExecutionInsertLine AND @ExecutionInsertLine+100
  AND UPPER(LineText) LIKE N'%FROM DBO.RCA_XERAW%'
ORDER BY LineNumber;

SELECT TOP (1) @StatementFromLine=LineNumber
FROM #ParserLines
WHERE LineNumber BETWEEN @StatementInsertLine AND @StatementInsertLine+100
  AND UPPER(LineText) LIKE N'%FROM DBO.RCA_XERAW%'
ORDER BY LineNumber;

SELECT TOP (1) @PlanFromLine=LineNumber
FROM #ParserLines
WHERE LineNumber BETWEEN @PlanInsertLine-30 AND @PlanInsertLine+100
  AND UPPER(LineText) LIKE N'%FROM DBO.RCA_XERAW%'
ORDER BY LineNumber;

SELECT
      ValidationSection='5 - RCA_XERAW SOURCE LOCATIONS'
    , ExecutionFromLine=@ExecutionFromLine
    , StatementFromLine=@StatementFromLine
    , PlanFromLine=@PlanFromLine
    , Result=
        CASE
          WHEN @ExecutionFromLine IS NOT NULL
           AND @StatementFromLine IS NOT NULL
           AND @PlanFromLine IS NOT NULL
          THEN 'PASS'
          ELSE 'REVIEW'
        END;

SELECT
      DiagnosticSection='5A - EXECUTION SOURCE PREDICATE'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE @ExecutionFromLine IS NOT NULL
  AND LineNumber BETWEEN @ExecutionFromLine AND @ExecutionFromLine+12
ORDER BY LineNumber;

SELECT
      DiagnosticSection='5B - STATEMENT SOURCE PREDICATE'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE @StatementFromLine IS NOT NULL
  AND LineNumber BETWEEN @StatementFromLine AND @StatementFromLine+12
ORDER BY LineNumber;

SELECT
      DiagnosticSection='5C - PLAN SOURCE PREDICATE'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE @PlanFromLine IS NOT NULL
  AND LineNumber BETWEEN @PlanFromLine AND @PlanFromLine+15
ORDER BY LineNumber;

SELECT
      DiagnosticSection='6 - EXECUTION BRANCH BOUNDARIES'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @ExecutionFromLine-3 AND @ExecutionFromLine+25
  AND
  (
       LineText LIKE N'%;%'
    OR UPPER(LineText) LIKE N'%WHERE%'
    OR UPPER(LineText) LIKE N'%FROM%'
    OR UPPER(LineText) LIKE N'%SELECT%'
    OR UPPER(LineText) LIKE N'%INSERT%'
  )
ORDER BY LineNumber;

SELECT
      DiagnosticSection='6A - STATEMENT BRANCH BOUNDARIES'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @StatementFromLine-3 AND @StatementFromLine+25
  AND
  (
       LineText LIKE N'%;%'
    OR UPPER(LineText) LIKE N'%WHERE%'
    OR UPPER(LineText) LIKE N'%FROM%'
    OR UPPER(LineText) LIKE N'%SELECT%'
    OR UPPER(LineText) LIKE N'%INSERT%'
  )
ORDER BY LineNumber;

SELECT
      DiagnosticSection='6B - PLAN BRANCH BOUNDARIES'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE LineNumber BETWEEN @PlanFromLine-5 AND @PlanFromLine+30
  AND
  (
       LineText LIKE N'%;%'
    OR LineText LIKE N'%)%'
    OR UPPER(LineText) LIKE N'%WHERE%'
    OR UPPER(LineText) LIKE N'%FROM%'
    OR UPPER(LineText) LIKE N'%SELECT%'
    OR UPPER(LineText) LIKE N'%INSERT%'
  )
ORDER BY LineNumber;

SELECT
      ValidationSection='7 - CURRENT COLLISION GUARD STATE'
    , ExecutionHasGuard=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM #ParserLines
            WHERE LineNumber BETWEEN @ExecutionInsertLine AND @ExecutionInsertLine+100
              AND UPPER(LineText) LIKE N'%NOT EXISTS%'
        ) THEN 'YES' ELSE 'NO' END
    , StatementHasGuard=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM #ParserLines
            WHERE LineNumber BETWEEN @StatementInsertLine AND @StatementInsertLine+100
              AND UPPER(LineText) LIKE N'%NOT EXISTS%'
        ) THEN 'YES' ELSE 'NO' END
    , PlanHasGuard=
        CASE WHEN EXISTS
        (
            SELECT 1 FROM #ParserLines
            WHERE LineNumber BETWEEN @PlanInsertLine-30 AND @PlanInsertLine+100
              AND UPPER(LineText) LIKE N'%NOT EXISTS%'
        ) THEN 'YES' ELSE 'NO' END
    , ExpectedBeforePatch='NO / NO / NO';

SELECT
      ValidationSection='8 - XERAWID 8135 OWNER'
    , ExecutionEvidenceID
    , CaptureRunID
    , XERawID
    , EventName
    , EventTimeUTC
    , DatabaseName
    , SessionID
FROM dbo.RCA_ExecutionEvidence
WHERE XERawID=8135;

SELECT
      ValidationSection='9 - CAPTURE 20 STATE'
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
      ValidationSection='10 - PARSER FINGERPRINT'
    , ProcedureName=N'dbo.usp_RCA_ParseCaptureRun'
    , ModifyDate=p.modify_date
    , DefinitionLength=LEN(sm.definition)
    , DefinitionSHA256=
        CONVERT(varchar(64),
                HASHBYTES('SHA2_256',CONVERT(varbinary(max),sm.definition)),2)
FROM sys.procedures p
JOIN sys.sql_modules sm
  ON sm.object_id=p.object_id
WHERE p.object_id=OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun');

SELECT
      ValidationSection='11 - SCRIPT 79B SAFETY'
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
        N'Use Sections 5A, 5B and 5C to build the structural parser patch without whitespace-sensitive full-predicate matching.';
GO
