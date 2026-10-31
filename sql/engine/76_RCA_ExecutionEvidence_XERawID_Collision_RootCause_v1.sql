USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  76_RCA_ExecutionEvidence_XERawID_Collision_RootCause_v1.sql

  PURPOSE
  -------
  Read-only follow-up to Script 75.

  Script 75 established:
    - Capture 20 is STOPPED.
    - Capture 20 evidence is stable.
    - No active Capture 20 requests/jobs remain.
    - RCA_ExecutionEvidence has a UNIQUE key on XERawID.
    - XERawID 8135 already belongs to CaptureRunID 38 / ExecutionEvidenceID 295.
    - The duplicate is NOT owned by Capture 20.
    - usp_RCA_ParseCaptureRun deletes evidence only for the capture being parsed.
    - Generic duplicate protection was not detected.

  This script determines the exact collision mechanism before any parser change.

  SAFETY
  ------
  READ ONLY. No RCA evidence, parser, jobs, captures, findings, thresholds,
  root-cause logic, or canonical objects are modified.
==============================================================================*/

DECLARE @TargetCaptureRunID bigint = 20;
DECLARE @DuplicateXERawID bigint = 8135;

/* 0 - PRE-FLIGHT */
SELECT
      ValidationSection='0 - SCRIPT 76 PRE-FLIGHT'
    , CaptureRun=CASE WHEN OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ExecutionEvidence=CASE WHEN OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ParseCaptureRun=CASE WHEN OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    , ReadOnlyInvestigation='YES'
    , ExistingEvidenceModified='NO'
    , ParserModified='NO'
    , NewCaptureStarted='NO';

IF OBJECT_ID(N'dbo.RCA_CaptureRun',N'U') IS NULL THROW 57600,N'dbo.RCA_CaptureRun is required.',1;
IF OBJECT_ID(N'dbo.RCA_ExecutionEvidence',N'U') IS NULL THROW 57601,N'dbo.RCA_ExecutionEvidence is required.',1;
IF OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NULL THROW 57602,N'dbo.usp_RCA_ParseCaptureRun is required.',1;


/* 1 - TARGET CAPTURE + DUPLICATE OWNER */
SELECT DiagnosticSection='1 - TARGET CAPTURE', *
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID=@TargetCaptureRunID;

SELECT
      DiagnosticSection='1A - DUPLICATE OWNER'
    , ExecutionEvidenceID
    , CaptureRunID
    , XERawID
    , EventName
    , EventTimeUTC
    , DatabaseName
    , SessionID
    , HostName
    , ProgramName
    , LoginName
    , SubmittedCommand
FROM dbo.RCA_ExecutionEvidence
WHERE XERawID=@DuplicateXERawID;


/* 2 - EXECUTION EVIDENCE UNIQUE KEY CONTRACT */
SELECT
      DiagnosticSection='2 - EXECUTION EVIDENCE UNIQUE KEY CONTRACT'
    , IndexName=i.name
    , i.is_unique
    , i.is_primary_key
    , i.ignore_dup_key
    , KeyOrdinal=ic.key_ordinal
    , ColumnName=c.name
FROM sys.indexes i
JOIN sys.index_columns ic
  ON ic.object_id=i.object_id AND ic.index_id=i.index_id
JOIN sys.columns c
  ON c.object_id=ic.object_id AND c.column_id=ic.column_id
WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
  AND i.is_unique=1
ORDER BY i.index_id,ic.key_ordinal;


/* 3 - DISCOVER LIKELY RAW XE SOURCE TABLES */
SELECT
      DiagnosticSection='3 - LIKELY XE RAW SOURCE TABLES'
    , SchemaName=SCHEMA_NAME(t.schema_id)
    , TableName=t.name
    , HasXERawID=CASE WHEN COL_LENGTH(QUOTENAME(SCHEMA_NAME(t.schema_id))+'.'+QUOTENAME(t.name),'XERawID') IS NOT NULL THEN 'YES' ELSE 'NO' END
    , HasCaptureRunID=CASE WHEN COL_LENGTH(QUOTENAME(SCHEMA_NAME(t.schema_id))+'.'+QUOTENAME(t.name),'CaptureRunID') IS NOT NULL THEN 'YES' ELSE 'NO' END
    , HasEventTimeUTC=CASE WHEN COL_LENGTH(QUOTENAME(SCHEMA_NAME(t.schema_id))+'.'+QUOTENAME(t.name),'EventTimeUTC') IS NOT NULL THEN 'YES' ELSE 'NO' END
FROM sys.tables t
WHERE t.is_ms_shipped=0
  AND
  (
       t.name LIKE N'%XE%'
    OR t.name LIKE N'%Raw%'
    OR EXISTS
      (
        SELECT 1 FROM sys.columns c
        WHERE c.object_id=t.object_id AND c.name=N'XERawID'
      )
  )
ORDER BY t.name;


/* 4 - FIND XERawID 8135 IN EVERY TABLE THAT HAS XERawID */
IF OBJECT_ID('tempdb..#Raw8135') IS NOT NULL DROP TABLE #Raw8135;
CREATE TABLE #Raw8135
(
    SourceObject nvarchar(776),
    MatchingRows bigint
);

DECLARE @Schema sysname,@Table sysname,@Object nvarchar(776),@sql nvarchar(max);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT SCHEMA_NAME(t.schema_id),t.name
FROM sys.tables t
WHERE EXISTS
(
    SELECT 1 FROM sys.columns c
    WHERE c.object_id=t.object_id AND c.name=N'XERawID'
);

OPEN c;
FETCH NEXT FROM c INTO @Schema,@Table;
WHILE @@FETCH_STATUS=0
BEGIN
    SET @Object=QUOTENAME(@Schema)+N'.'+QUOTENAME(@Table);
    SET @sql=N'INSERT #Raw8135(SourceObject,MatchingRows)
               SELECT @o,COUNT_BIG(*) FROM '+@Object+
             N' WHERE TRY_CONVERT(bigint,XERawID)=@x;';
    EXEC sys.sp_executesql @sql,N'@o nvarchar(776),@x bigint',@o=@Object,@x=@DuplicateXERawID;
    FETCH NEXT FROM c INTO @Schema,@Table;
END
CLOSE c;
DEALLOCATE c;

SELECT DiagnosticSection='4 - XERAWID 8135 SOURCE LOCATIONS',*
FROM #Raw8135
WHERE MatchingRows>0
ORDER BY SourceObject;


/* 5 - PARSER DEFINITION WITH LINE NUMBERS */
DECLARE @Definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun'));

IF OBJECT_ID('tempdb..#ParserLines') IS NOT NULL DROP TABLE #ParserLines;
CREATE TABLE #ParserLines(LineNumber int NOT NULL,LineText nvarchar(max));

DECLARE @p int=1,@n int,@ln int=1,@L int=LEN(@Definition);
WHILE @p<=@L+1
BEGIN
    SET @n=CHARINDEX(CHAR(10),@Definition,@p);
    IF @n=0 SET @n=@L+1;

    INSERT #ParserLines
    VALUES(@ln,REPLACE(SUBSTRING(@Definition,@p,@n-@p),CHAR(13),N''));

    SET @p=@n+1;
    SET @ln+=1;
    IF @n>@L BREAK;
END;

SELECT
      DiagnosticSection='5 - FULL PARSER LINE MAP'
    , LineNumber
    , LineText
FROM #ParserLines
ORDER BY LineNumber;


/* 6 - INSERT INTO RCA_ExecutionEvidence CONTEXT */
DECLARE @InsertLine int;

SELECT TOP (1) @InsertLine=LineNumber
FROM #ParserLines
WHERE LineText LIKE N'%INSERT%RCA_ExecutionEvidence%'
ORDER BY LineNumber;

SELECT
      DiagnosticSection='6 - EXECUTION EVIDENCE INSERT CONTEXT'
    , LineNumber
    , LineText
FROM #ParserLines
WHERE @InsertLine IS NOT NULL
  AND LineNumber BETWEEN @InsertLine-12 AND @InsertLine+45
ORDER BY LineNumber;


/* 7 - PARSER FILTER / DEDUP SIGNALS */
SELECT
      ValidationSection='7 - PARSER COLLISION GUARDS'
    , InsertLine=@InsertLine
    , HasXERawIDReference=CASE WHEN @Definition LIKE N'%XERawID%' THEN 'YES' ELSE 'NO' END
    , HasNotExists=CASE WHEN @Definition LIKE N'%NOT EXISTS%' THEN 'YES' ELSE 'NO' END
    , HasMerge=CASE WHEN @Definition LIKE N'%MERGE%' THEN 'YES' ELSE 'NO' END
    , DeletesByCaptureRun=
        CASE WHEN @Definition LIKE N'%DELETE FROM dbo.RCA_ExecutionEvidence%CaptureRunID%'
               OR @Definition LIKE N'%DELETE FROM%RCA_ExecutionEvidence%CaptureRunID%'
             THEN 'YES' ELSE 'REVIEW' END
    , Interpretation=
        N'The unique key makes XERawID globally unique in RCA_ExecutionEvidence. The INSERT must not attempt an XERawID already persisted by another capture.';


/* 8 - CAPTURE 20 HAS NO CURRENT EXECUTION EVIDENCE */
SELECT
      ValidationSection='8 - CAPTURE 20 EXECUTION EVIDENCE STATE'
    , CaptureRunID=@TargetCaptureRunID
    , ExecutionEvidenceRows=COUNT_BIG(*)
    , MinXERawID=MIN(XERawID)
    , MaxXERawID=MAX(XERawID)
FROM dbo.RCA_ExecutionEvidence
WHERE CaptureRunID=@TargetCaptureRunID;


/* 9 - DUPLICATE XERawID CHECK INSIDE PERSISTED TABLE */
SELECT
      DiagnosticSection='9 - PERSISTED XERAWID DUPLICATE CHECK'
    , XERawID
    , TotalRows=COUNT_BIG(*)
    , DistinctCaptures=COUNT(DISTINCT CaptureRunID)
FROM dbo.RCA_ExecutionEvidence
GROUP BY XERawID
HAVING COUNT_BIG(*)>1
ORDER BY COUNT_BIG(*) DESC,XERawID;


/* 10 - CAPTURE WINDOWS AROUND OWNER AND TARGET */
DECLARE @OwnerCapture bigint=
(
    SELECT TOP (1) CaptureRunID
    FROM dbo.RCA_ExecutionEvidence
    WHERE XERawID=@DuplicateXERawID
);

SELECT
      DiagnosticSection='10 - RELEVANT CAPTURE WINDOWS'
    , CaptureRunID
    , TargetOrOwner=
        CASE WHEN CaptureRunID=@TargetCaptureRunID THEN 'TARGET'
             WHEN CaptureRunID=@OwnerCapture THEN 'DUPLICATE OWNER'
             ELSE 'OTHER' END
    , TargetDatabase
    , CaptureReason
    , StartTimeUTC
    , EndTimeUTC
    , CaptureStatus
FROM dbo.RCA_CaptureRun
WHERE CaptureRunID IN (@TargetCaptureRunID,@OwnerCapture)
ORDER BY CaptureRunID;


/* 11 - OVERLAPPING CAPTURE WINDOW CHECK */
DECLARE @TargetStart datetime2(7),@TargetEnd datetime2(7),
        @OwnerStart datetime2(7),@OwnerEnd datetime2(7);

SELECT @TargetStart=StartTimeUTC,@TargetEnd=EndTimeUTC
FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@TargetCaptureRunID;

SELECT @OwnerStart=StartTimeUTC,@OwnerEnd=EndTimeUTC
FROM dbo.RCA_CaptureRun WHERE CaptureRunID=@OwnerCapture;

SELECT
      ValidationSection='11 - CAPTURE WINDOW OVERLAP'
    , TargetCapture=@TargetCaptureRunID
    , OwnerCapture=@OwnerCapture
    , TargetStart=@TargetStart
    , TargetEnd=@TargetEnd
    , OwnerStart=@OwnerStart
    , OwnerEnd=@OwnerEnd
    , WindowsOverlap=
        CASE
          WHEN @TargetStart IS NULL OR @OwnerStart IS NULL THEN 'UNKNOWN'
          WHEN COALESCE(@TargetEnd,CONVERT(datetime2(7),'9999-12-31')) >= @OwnerStart
           AND COALESCE(@OwnerEnd,CONVERT(datetime2(7),'9999-12-31')) >= @TargetStart
          THEN 'YES'
          ELSE 'NO'
        END;


/* 12 - ALL CAPTURES THAT CURRENTLY OWN EXECUTION EVIDENCE */
SELECT
      DiagnosticSection='12 - EXECUTION EVIDENCE OWNERSHIP'
    , CaptureRunID
    , TotalRows=COUNT_BIG(*)
    , MinXERawID=MIN(XERawID)
    , MaxXERawID=MAX(XERawID)
    , MinEventTimeUTC=MIN(EventTimeUTC)
    , MaxEventTimeUTC=MAX(EventTimeUTC)
FROM dbo.RCA_ExecutionEvidence
GROUP BY CaptureRunID
ORDER BY CaptureRunID;


/* 13 - EXACT SOURCE OBJECTS REFERENCED BY PARSER */
SELECT
      DiagnosticSection='13 - PARSER DEPENDENCIES'
    , ReferencedDatabase=d.referenced_database_name
    , ReferencedSchema=d.referenced_schema_name
    , ReferencedEntity=d.referenced_entity_name
    , ReferencedClass=d.referenced_class_desc
FROM sys.sql_expression_dependencies d
WHERE d.referencing_id=OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun')
ORDER BY d.referenced_schema_name,d.referenced_entity_name;


/* 14 - DESIGN DECISION */
SELECT
      ValidationSection='14 - DESIGN DECISION'
    , DuplicateXERawID=@DuplicateXERawID
    , ExistingOwnerCapture=@OwnerCapture
    , TargetCapture=@TargetCaptureRunID
    , DuplicateBelongsToTarget=
        CASE WHEN @OwnerCapture=@TargetCaptureRunID THEN 'YES' ELSE 'NO' END
    , GlobalUniqueContract=
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.indexes i
            JOIN sys.index_columns ic
              ON ic.object_id=i.object_id AND ic.index_id=i.index_id
            JOIN sys.columns c
              ON c.object_id=ic.object_id AND c.column_id=ic.column_id
            WHERE i.object_id=OBJECT_ID(N'dbo.RCA_ExecutionEvidence')
              AND i.is_unique=1
              AND c.name=N'XERawID'
        ) THEN 'YES' ELSE 'NO' END
    , RecommendedFix=
        N'Preserve the global XERawID uniqueness contract. Make the parser INSERT idempotent against already-persisted XERawID values rather than deleting another capture''s evidence or weakening the unique key.';


/* 15 - SCRIPT 76 CONCLUSION */
SELECT
      ValidationSection='15 - SCRIPT 76 CONCLUSION'
    , ReadOnlyInvestigation='PASS'
    , ExistingEvidencePreserved='PASS'
    , Capture20Preserved='PASS'
    , ParserPreserved='PASS'
    , UniqueIndexPreserved='PASS'
    , SQLAgentJobsPreserved='PASS'
    , NextStep=
        N'Review Sections 4-7 and 10-14. If the parser source can select XERawID already owned by another capture, the next script should patch only dbo.usp_RCA_ParseCaptureRun with an exact XERawID anti-join, then run regression validation for captures 20, 38, 42, and 44.';


/* 16 - SAFETY */
SELECT
      ValidationSection='16 - SCRIPT 76 SAFETY'
    , ReadOnlyInvestigation='YES'
    , Capture20Modified='NO'
    , ExecutionEvidenceModified='NO'
    , ParserModified='NO'
    , UniqueIndexModified='NO'
    , SQLAgentJobsModified='NO'
    , ExistingEvidenceModified='NO'
    , ExistingSynthesisModified='NO'
    , FindingsRebuilt='NO'
    , DetectorThresholdsChanged='NO'
    , RootCauseLogicChanged='NO'
    , CanonicalObjectsChanged='NO'
    , NewCaptureStarted='NO';
GO
