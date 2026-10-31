USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  03_RCA_Parse_Correlate_Analyze.sql
  PURPOSE
  -------
  Parse the already-captured raw XE evidence into an RCA model that answers:

      What ran?
      With what parameters?
      From where / which account?
      How much CPU / reads / writes / rows?
      What actual execution plan ran?
      What memory grant and DOP were used?
      What indexes/operators were used?
      Were actual vs estimated rows far apart?
      Which statistics were used and how old were they?
      What was SQL Server memory/cache state at the time?

  This script DOES NOT alter the XE session.
  It works against the existing RCA_XERaw + server/live snapshots.
==============================================================================*/


/*==============================================================================
  1. CHILD STATEMENT EVIDENCE
==============================================================================*/
DROP TABLE IF EXISTS dbo.RCA_StatementEvidence;
GO

CREATE TABLE dbo.RCA_StatementEvidence
(
      StatementEvidenceID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_StatementEvidence PRIMARY KEY
    , CaptureRunID bigint NOT NULL
    , XERawID bigint NOT NULL
    , EventTimeUTC datetime2(7) NOT NULL
    , DatabaseName sysname NULL
    , SessionID int NULL
    , ObjectName nvarchar(512) NULL
    , StatementText nvarchar(max) NULL
    , CPUms decimal(19,3) NULL
    , DurationMs decimal(19,3) NULL
    , LogicalReads bigint NULL
    , PhysicalReads bigint NULL
    , Writes bigint NULL
    , TotalRows bigint NULL
    , QueryHash varbinary(8) NULL
    , QueryPlanHash varbinary(8) NULL
    , PlanHandle varbinary(64) NULL
    , HostName nvarchar(256) NULL
    , ProgramName nvarchar(256) NULL
    , LoginName nvarchar(256) NULL
    , LinkedExecutionEvidenceID bigint NULL
    , CONSTRAINT UQ_RCA_StatementEvidence_XERaw UNIQUE(XERawID)
);
GO

CREATE INDEX IX_RCA_StatementEvidence_Run
ON dbo.RCA_StatementEvidence(CaptureRunID,SessionID,EventTimeUTC);
GO


/*==============================================================================
  2. RUNTIME PARAMETER EVIDENCE FROM ACTUAL PLAN
==============================================================================*/
DROP TABLE IF EXISTS dbo.RCA_RuntimeParameter;
GO

CREATE TABLE dbo.RCA_RuntimeParameter
(
      RuntimeParameterID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_RuntimeParameter PRIMARY KEY
    , CaptureRunID bigint NOT NULL
    , PlanEvidenceID bigint NOT NULL
    , ExecutionEvidenceID bigint NULL
    , ParameterName nvarchar(256) NULL
    , ParameterDataType nvarchar(256) NULL
    , ParameterCompiledValue nvarchar(max) NULL
    , ParameterRuntimeValue nvarchar(max) NULL
    , EvidenceSource varchar(40) NOT NULL
    , CONSTRAINT FK_RCA_RuntimeParameter_Plan
        FOREIGN KEY(PlanEvidenceID)
        REFERENCES dbo.RCA_PlanEvidence(PlanEvidenceID)
        ON DELETE CASCADE
);
GO

CREATE INDEX IX_RCA_RuntimeParameter_Run
ON dbo.RCA_RuntimeParameter(CaptureRunID,ExecutionEvidenceID,PlanEvidenceID);
GO


/*==============================================================================
  3. PLAN OPERATOR EVIDENCE
==============================================================================*/
DROP TABLE IF EXISTS dbo.RCA_PlanOperator;
GO

CREATE TABLE dbo.RCA_PlanOperator
(
      PlanOperatorID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_PlanOperator PRIMARY KEY
    , CaptureRunID bigint NOT NULL
    , PlanEvidenceID bigint NOT NULL
    , ExecutionEvidenceID bigint NULL
    , NodeID int NULL
    , PhysicalOp nvarchar(128) NULL
    , LogicalOp nvarchar(128) NULL
    , EstimateRows float NULL
    , ActualRows decimal(38,4) NULL
    , ActualRowsRead decimal(38,4) NULL
    , ActualExecutions decimal(38,4) NULL
    , EstimatedSubtreeCost float NULL
    , Parallel bit NULL
    , DatabaseName nvarchar(256) NULL
    , SchemaName nvarchar(256) NULL
    , TableName nvarchar(512) NULL
    , IndexName nvarchar(512) NULL
    , IndexKind nvarchar(128) NULL
    , Storage nvarchar(128) NULL
    , HasSpillWarning bit NOT NULL
        CONSTRAINT DF_RCA_PlanOperator_Spill DEFAULT 0
    , HasImplicitConversion bit NOT NULL
        CONSTRAINT DF_RCA_PlanOperator_Convert DEFAULT 0
    , EstimateActualRatio decimal(38,4) NULL
    , CONSTRAINT FK_RCA_PlanOperator_Plan
        FOREIGN KEY(PlanEvidenceID)
        REFERENCES dbo.RCA_PlanEvidence(PlanEvidenceID)
        ON DELETE CASCADE
);
GO

CREATE INDEX IX_RCA_PlanOperator_Run
ON dbo.RCA_PlanOperator(CaptureRunID,ExecutionEvidenceID,PlanEvidenceID);
GO


/*==============================================================================
  4. STATISTICS USED BY THE PLAN
==============================================================================*/
DROP TABLE IF EXISTS dbo.RCA_PlanStatistics;
GO

CREATE TABLE dbo.RCA_PlanStatistics
(
      PlanStatisticsID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_PlanStatistics PRIMARY KEY
    , CaptureRunID bigint NOT NULL
    , PlanEvidenceID bigint NOT NULL
    , ExecutionEvidenceID bigint NULL
    , DatabaseName nvarchar(256) NULL
    , SchemaName nvarchar(256) NULL
    , TableName nvarchar(512) NULL
    , StatisticsName nvarchar(512) NULL
    , LastUpdate datetime2(3) NULL
    , ModificationCount bigint NULL
    , SamplingPercent decimal(19,6) NULL
    , StatsAgeHours decimal(19,2) NULL
    , CONSTRAINT FK_RCA_PlanStatistics_Plan
        FOREIGN KEY(PlanEvidenceID)
        REFERENCES dbo.RCA_PlanEvidence(PlanEvidenceID)
        ON DELETE CASCADE
);
GO

CREATE INDEX IX_RCA_PlanStatistics_Run
ON dbo.RCA_PlanStatistics(CaptureRunID,ExecutionEvidenceID,PlanEvidenceID);
GO


/*==============================================================================
  5. PLAN FINDINGS / "THEN WHAT?"
==============================================================================*/
DROP TABLE IF EXISTS dbo.RCA_PlanFinding;
GO

CREATE TABLE dbo.RCA_PlanFinding
(
      PlanFindingID bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RCA_PlanFinding PRIMARY KEY
    , CaptureRunID bigint NOT NULL
    , PlanEvidenceID bigint NOT NULL
    , ExecutionEvidenceID bigint NULL
    , Severity varchar(10) NOT NULL
    , FindingType varchar(60) NOT NULL
    , FindingText nvarchar(2000) NOT NULL
    , RecommendedAction nvarchar(2000) NULL
    , CONSTRAINT FK_RCA_PlanFinding_Plan
        FOREIGN KEY(PlanEvidenceID)
        REFERENCES dbo.RCA_PlanEvidence(PlanEvidenceID)
        ON DELETE CASCADE
);
GO

CREATE INDEX IX_RCA_PlanFinding_Run
ON dbo.RCA_PlanFinding(CaptureRunID,ExecutionEvidenceID,Severity);
GO


/*==============================================================================
  6. COMPLETE PARSER / CORRELATOR
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ParseCaptureRun
    @CaptureRunID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @StartUTC datetime2(3),
            @EndUTC   datetime2(3);

    SELECT
        @StartUTC = StartTimeUTC,
        @EndUTC   = COALESCE(EndTimeUTC,SYSUTCDATETIME())
    FROM dbo.RCA_CaptureRun
    WHERE CaptureRunID=@CaptureRunID;

    IF @StartUTC IS NULL
        THROW 62000,N'Invalid CaptureRunID.',1;

    -------------------------------------------------------------------------
    -- Clear only derived rows for this run.
    -------------------------------------------------------------------------
    DELETE FROM dbo.RCA_PlanFinding
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_PlanStatistics
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_PlanOperator
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_RuntimeParameter
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_StatementEvidence
    WHERE CaptureRunID=@CaptureRunID;

    /* Existing parser attempts can also be safely rebuilt for this run. */
    DELETE FROM dbo.RCA_PlanEvidence
    WHERE CaptureRunID=@CaptureRunID;

    DELETE FROM dbo.RCA_ExecutionEvidence
    WHERE CaptureRunID=@CaptureRunID;

    -------------------------------------------------------------------------
    -- A. EXECUTION-LEVEL COMPLETED EVENTS
    -------------------------------------------------------------------------
    INSERT dbo.RCA_ExecutionEvidence
    (
          CaptureRunID
        , XERawID
        , EventName
        , EventTimeUTC
        , DatabaseName
        , SessionID
        , ObjectName
        , SubmittedCommand
        , ParameterText
        , ParameterEvidenceStatus
        , HostName
        , ProgramName
        , LoginName
        , CPUms
        , DurationMs
        , LogicalReads
        , PhysicalReads
        , Writes
        , TotalRows
        , QueryHash
        , QueryPlanHash
        , PlanHandle
    )
    SELECT
          @CaptureRunID
        , r.XERawID
        , r.EventName
        , r.EventTimeUTC

        , NULLIF
          (
              r.EventXML.value
              (
                  '(/event/action[@name="database_name"]/value/text())[1]',
                  'nvarchar(128)'
              ),
              N''
          )

        , TRY_CONVERT
          (
              int,
              r.EventXML.value
              (
                  '(/event/action[@name="session_id"]/value/text())[1]',
                  'nvarchar(20)'
              )
          )

        , NULLIF
          (
              r.EventXML.value
              (
                  '(/event/data[@name="object_name"]/value/text())[1]',
                  'nvarchar(512)'
              ),
              N''
          )

        , NULLIF
          (
              COALESCE
              (
                  NULLIF
                  (
                      r.EventXML.value
                      (
                          '(/event/data[@name="statement"]/value/text())[1]',
                          'nvarchar(max)'
                      ),
                      N''
                  ),
                  NULLIF
                  (
                      r.EventXML.value
                      (
                          '(/event/data[@name="batch_text"]/value/text())[1]',
                          'nvarchar(max)'
                      ),
                      N''
                  ),
                  NULLIF
                  (
                      r.EventXML.value
                      (
                          '(/event/action[@name="sql_text"]/value/text())[1]',
                          'nvarchar(max)'
                      ),
                      N''
                  )
              ),
              N''
          )

        , CASE
              WHEN r.EventName=N'rpc_completed'
              THEN NULLIF
                   (
                       r.EventXML.value
                       (
                           '(/event/data[@name="statement"]/value/text())[1]',
                           'nvarchar(max)'
                       ),
                       N''
                   )

              WHEN r.EventName=N'sql_batch_completed'
              THEN NULLIF
                   (
                       r.EventXML.value
                       (
                           '(/event/data[@name="batch_text"]/value/text())[1]',
                           'nvarchar(max)'
                       ),
                       N''
                   )
          END

        , CASE
              WHEN r.EventName=N'rpc_completed'
                  THEN N'RPC_SUBMITTED_TEXT'
              WHEN r.EventName=N'sql_batch_completed'
                  THEN N'BATCH_SUBMITTED_TEXT'
              ELSE N'UNKNOWN'
          END

        , NULLIF
          (
              r.EventXML.value
              (
                  '(/event/action[@name="client_hostname"]/value/text())[1]',
                  'nvarchar(256)'
              ),
              N''
          )

        , NULLIF
          (
              r.EventXML.value
              (
                  '(/event/action[@name="client_app_name"]/value/text())[1]',
                  'nvarchar(256)'
              ),
              N''
          )

        , NULLIF
          (
              r.EventXML.value
              (
                  '(/event/action[@name="server_principal_name"]/value/text())[1]',
                  'nvarchar(256)'
              ),
              N''
          )

        , TRY_CONVERT
          (
              decimal(19,3),
              r.EventXML.value
              (
                  '(/event/data[@name="cpu_time"]/value/text())[1]',
                  'nvarchar(50)'
              )
          )/1000.0

        , TRY_CONVERT
          (
              decimal(19,3),
              r.EventXML.value
              (
                  '(/event/data[@name="duration"]/value/text())[1]',
                  'nvarchar(50)'
              )
          )/1000.0

        , TRY_CONVERT
          (
              bigint,
              r.EventXML.value
              (
                  '(/event/data[@name="logical_reads"]/value/text())[1]',
                  'nvarchar(50)'
              )
          )

        , COALESCE
          (
              TRY_CONVERT
              (
                  bigint,
                  r.EventXML.value
                  (
                      '(/event/data[@name="physical_reads"]/value/text())[1]',
                      'nvarchar(50)'
                  )
              ),
              TRY_CONVERT
              (
                  bigint,
                  r.EventXML.value
                  (
                      '(/event/data[@name="reads"]/value/text())[1]',
                      'nvarchar(50)'
                  )
              )
          )

        , TRY_CONVERT
          (
              bigint,
              r.EventXML.value
              (
                  '(/event/data[@name="writes"]/value/text())[1]',
                  'nvarchar(50)'
              )
          )

        , TRY_CONVERT
          (
              bigint,
              r.EventXML.value
              (
                  '(/event/data[@name="row_count"]/value/text())[1]',
                  'nvarchar(50)'
              )
          )

        , TRY_CONVERT
          (
              varbinary(8),
              r.EventXML.value
              (
                  '(/event/action[@name="query_hash"]/value/text())[1]',
                  'nvarchar(34)'
              ),
              1
          )

        , TRY_CONVERT
          (
              varbinary(8),
              r.EventXML.value
              (
                  '(/event/action[@name="query_plan_hash"]/value/text())[1]',
                  'nvarchar(34)'
              ),
              1
          )

        , TRY_CONVERT
          (
              varbinary(64),
              r.EventXML.value
              (
                  '(/event/action[@name="plan_handle"]/value/text())[1]',
                  'nvarchar(130)'
              ),
              1
          )

    FROM dbo.RCA_XERaw r
    WHERE r.EventTimeUTC>=@StartUTC
      AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)
      AND r.EventName IN(N'rpc_completed',N'sql_batch_completed');


    -------------------------------------------------------------------------
    -- B. CHILD STATEMENT COMPLETED EVENTS
    -------------------------------------------------------------------------
    INSERT dbo.RCA_StatementEvidence
    (
          CaptureRunID
        , XERawID
        , EventTimeUTC
        , DatabaseName
        , SessionID
        , ObjectName
        , StatementText
        , CPUms
        , DurationMs
        , LogicalReads
        , PhysicalReads
        , Writes
        , TotalRows
        , QueryHash
        , QueryPlanHash
        , PlanHandle
        , HostName
        , ProgramName
        , LoginName
    )
    SELECT
          @CaptureRunID
        , r.XERawID
        , r.EventTimeUTC

        , NULLIF(r.EventXML.value(
            '(/event/action[@name="database_name"]/value/text())[1]',
            'nvarchar(128)'),N'')

        , TRY_CONVERT(int,r.EventXML.value(
            '(/event/action[@name="session_id"]/value/text())[1]',
            'nvarchar(20)'))

        , NULLIF(r.EventXML.value(
            '(/event/data[@name="object_name"]/value/text())[1]',
            'nvarchar(512)'),N'')

        , NULLIF
          (
              COALESCE
              (
                  NULLIF(r.EventXML.value(
                    '(/event/data[@name="statement"]/value/text())[1]',
                    'nvarchar(max)'),N''),
                  NULLIF(r.EventXML.value(
                    '(/event/action[@name="sql_text"]/value/text())[1]',
                    'nvarchar(max)'),N'')
              ),
              N''
          )

        , TRY_CONVERT(decimal(19,3),r.EventXML.value(
            '(/event/data[@name="cpu_time"]/value/text())[1]',
            'nvarchar(50)'))/1000.0

        , TRY_CONVERT(decimal(19,3),r.EventXML.value(
            '(/event/data[@name="duration"]/value/text())[1]',
            'nvarchar(50)'))/1000.0

        , TRY_CONVERT(bigint,r.EventXML.value(
            '(/event/data[@name="logical_reads"]/value/text())[1]',
            'nvarchar(50)'))

        , COALESCE
          (
              TRY_CONVERT(bigint,r.EventXML.value(
                  '(/event/data[@name="physical_reads"]/value/text())[1]',
                  'nvarchar(50)')),
              TRY_CONVERT(bigint,r.EventXML.value(
                  '(/event/data[@name="reads"]/value/text())[1]',
                  'nvarchar(50)'))
          )

        , TRY_CONVERT(bigint,r.EventXML.value(
            '(/event/data[@name="writes"]/value/text())[1]',
            'nvarchar(50)'))

        , TRY_CONVERT(bigint,r.EventXML.value(
            '(/event/data[@name="row_count"]/value/text())[1]',
            'nvarchar(50)'))

        , TRY_CONVERT(varbinary(8),r.EventXML.value(
            '(/event/action[@name="query_hash"]/value/text())[1]',
            'nvarchar(34)'),1)

        , TRY_CONVERT(varbinary(8),r.EventXML.value(
            '(/event/action[@name="query_plan_hash"]/value/text())[1]',
            'nvarchar(34)'),1)

        , TRY_CONVERT(varbinary(64),r.EventXML.value(
            '(/event/action[@name="plan_handle"]/value/text())[1]',
            'nvarchar(130)'),1)

        , NULLIF(r.EventXML.value(
            '(/event/action[@name="client_hostname"]/value/text())[1]',
            'nvarchar(256)'),N'')

        , NULLIF(r.EventXML.value(
            '(/event/action[@name="client_app_name"]/value/text())[1]',
            'nvarchar(256)'),N'')

        , NULLIF(r.EventXML.value(
            '(/event/action[@name="server_principal_name"]/value/text())[1]',
            'nvarchar(256)'),N'')

    FROM dbo.RCA_XERaw r
    WHERE r.EventTimeUTC>=@StartUTC
      AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)
      AND r.EventName=N'sp_statement_completed';


    -------------------------------------------------------------------------
    -- C. ACTUAL EXECUTION PLANS
    -------------------------------------------------------------------------
    ;WITH P AS
    (
        SELECT
              r.XERawID
            , r.EventTimeUTC
            , r.EventXML
            , PlanXML =
                r.EventXML.query
                (
                    '(/event/data[@name="showplan_xml"]/value/*)[1]'
                )
        FROM dbo.RCA_XERaw r
        WHERE r.EventTimeUTC>=@StartUTC
          AND r.EventTimeUTC<=DATEADD(second,5,@EndUTC)
          AND r.EventName=N'query_post_execution_showplan'
    )
    INSERT dbo.RCA_PlanEvidence
    (
          CaptureRunID
        , XERawID
        , EventTimeUTC
        , DatabaseName
        , SessionID
        , SQLText
        , QueryHash
        , QueryPlanHash
        , PlanHandle
        , ActualExecutionPlanXML
        , RequestedMemoryKB
        , GrantedMemoryKB
        , MaxUsedMemoryKB
        , ActualDOP
    )
    SELECT
          @CaptureRunID
        , p.XERawID
        , p.EventTimeUTC

        , NULLIF(p.EventXML.value(
            '(/event/action[@name="database_name"]/value/text())[1]',
            'nvarchar(128)'),N'')

        , TRY_CONVERT(int,p.EventXML.value(
            '(/event/action[@name="session_id"]/value/text())[1]',
            'nvarchar(20)'))

        , NULLIF(p.EventXML.value(
            '(/event/action[@name="sql_text"]/value/text())[1]',
            'nvarchar(max)'),N'')

        , TRY_CONVERT(varbinary(8),p.EventXML.value(
            '(/event/action[@name="query_hash"]/value/text())[1]',
            'nvarchar(34)'),1)

        , TRY_CONVERT(varbinary(8),p.EventXML.value(
            '(/event/action[@name="query_plan_hash"]/value/text())[1]',
            'nvarchar(34)'),1)

        , TRY_CONVERT(varbinary(64),p.EventXML.value(
            '(/event/action[@name="plan_handle"]/value/text())[1]',
            'nvarchar(130)'),1)

        , p.PlanXML

        , TRY_CONVERT
          (
              bigint,
              p.PlanXML.value
              (
                'declare default element namespace
                 "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 (//MemoryGrantInfo/@RequestedMemory)[1]',
                'nvarchar(50)'
              )
          )

        , TRY_CONVERT
          (
              bigint,
              p.PlanXML.value
              (
                'declare default element namespace
                 "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 (//MemoryGrantInfo/@GrantedMemory)[1]',
                'nvarchar(50)'
              )
          )

        , TRY_CONVERT
          (
              bigint,
              p.PlanXML.value
              (
                'declare default element namespace
                 "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 (//MemoryGrantInfo/@MaxUsedMemory)[1]',
                'nvarchar(50)'
              )
          )

        , TRY_CONVERT
          (
              int,
              p.PlanXML.value
              (
                'declare default element namespace
                 "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 (//QueryPlan/@DegreeOfParallelism)[1]',
                'nvarchar(20)'
              )
          )

    FROM P p
    WHERE CONVERT(nvarchar(max),p.PlanXML)<>N'';


    -------------------------------------------------------------------------
    -- D. LINK ACTUAL PLAN TO NEAREST CHILD STATEMENT FIRST
    -------------------------------------------------------------------------
    UPDATE pe
       SET LinkedExecutionEvidenceID = m.ExecutionEvidenceID
    FROM dbo.RCA_PlanEvidence pe
    CROSS APPLY
    (
        SELECT TOP(1)
            e.ExecutionEvidenceID
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
          AND e.SessionID=pe.SessionID
          AND ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,pe.EventTimeUTC))
              <=30000
        ORDER BY
            CASE
                WHEN e.QueryHash=pe.QueryHash
                 AND pe.QueryHash IS NOT NULL
                THEN 0 ELSE 1
            END,
            ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,pe.EventTimeUTC))
    ) m
    WHERE pe.CaptureRunID=@CaptureRunID;


    -------------------------------------------------------------------------
    -- E. LINK CHILD STATEMENTS TO PARENT RPC/BATCH EXECUTION
    -------------------------------------------------------------------------
    UPDATE s
       SET LinkedExecutionEvidenceID = m.ExecutionEvidenceID
    FROM dbo.RCA_StatementEvidence s
    CROSS APPLY
    (
        SELECT TOP(1)
            e.ExecutionEvidenceID
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID=@CaptureRunID
          AND e.SessionID=s.SessionID
          AND e.EventTimeUTC>=s.EventTimeUTC
          AND DATEDIFF_BIG(second,s.EventTimeUTC,e.EventTimeUTC)<=120
        ORDER BY e.EventTimeUTC
    ) m
    WHERE s.CaptureRunID=@CaptureRunID;


    -------------------------------------------------------------------------
    -- F. PARAMETER VALUES FROM ACTUAL PLAN
    -------------------------------------------------------------------------
    ;WITH XMLNAMESPACES
    (
        DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
    )
    INSERT dbo.RCA_RuntimeParameter
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , ParameterName
        , ParameterDataType
        , ParameterCompiledValue
        , ParameterRuntimeValue
        , EvidenceSource
    )
    SELECT
          @CaptureRunID
        , pe.PlanEvidenceID
        , pe.LinkedExecutionEvidenceID
        , p.n.value('@Column','nvarchar(256)')
        , p.n.value('@ParameterDataType','nvarchar(256)')
        , p.n.value('@ParameterCompiledValue','nvarchar(max)')
        , p.n.value('@ParameterRuntimeValue','nvarchar(max)')
        , N'ACTUAL_PLAN_PARAMETER_LIST'
    FROM dbo.RCA_PlanEvidence pe
    CROSS APPLY pe.ActualExecutionPlanXML.nodes
    (
        '//ParameterList/ColumnReference[@Column]'
    ) p(n)
    WHERE pe.CaptureRunID=@CaptureRunID;


    -------------------------------------------------------------------------
    -- G. PLAN OPERATORS + ACTUAL ROW COUNTERS
    -------------------------------------------------------------------------
    ;WITH XMLNAMESPACES
    (
        DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
    )
    INSERT dbo.RCA_PlanOperator
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , NodeID
        , PhysicalOp
        , LogicalOp
        , EstimateRows
        , ActualRows
        , ActualRowsRead
        , ActualExecutions
        , EstimatedSubtreeCost
        , Parallel
        , DatabaseName
        , SchemaName
        , TableName
        , IndexName
        , IndexKind
        , Storage
        , HasSpillWarning
        , HasImplicitConversion
        , EstimateActualRatio
    )
    SELECT
          @CaptureRunID
        , pe.PlanEvidenceID
        , pe.LinkedExecutionEvidenceID
        , op.r.value('@NodeId','int')
        , op.r.value('@PhysicalOp','nvarchar(128)')
        , op.r.value('@LogicalOp','nvarchar(128)')
        , TRY_CONVERT(float,op.r.value('@EstimateRows','nvarchar(80)'))

        , rc.ActualRows
        , rc.ActualRowsRead
        , rc.ActualExecutions

        , TRY_CONVERT(float,
            op.r.value('@EstimatedTotalSubtreeCost','nvarchar(80)'))

        , TRY_CONVERT(bit,op.r.value('@Parallel','nvarchar(10)'))

        , obj.DatabaseName
        , obj.SchemaName
        , obj.TableName
        , obj.IndexName
        , obj.IndexKind
        , obj.Storage

        , CONVERT
          (
              bit,
              CASE
                  WHEN op.r.exist(
                    './/RunTimeCountersPerThread[@SpillLevel or @SpilledThreadCount]
                     | .//SpillToTempDb
                     | .//HashSpillDetails
                     | .//SortSpillDetails')=1
                  THEN 1 ELSE 0
              END
          )

        , CONVERT
          (
              bit,
              CASE
                  WHEN op.r.exist(
                    './/Convert[@Implicit="1"]')=1
                  THEN 1 ELSE 0
              END
          )

        , CASE
              WHEN TRY_CONVERT(float,
                     op.r.value('@EstimateRows','nvarchar(80)')) IS NULL
                OR TRY_CONVERT(float,
                     op.r.value('@EstimateRows','nvarchar(80)'))=0
                OR rc.ActualRows IS NULL
              THEN NULL
              ELSE CONVERT
                   (
                       decimal(38,4),
                       rc.ActualRows /
                       NULLIF
                       (
                           TRY_CONVERT(float,
                             op.r.value('@EstimateRows','nvarchar(80)')),
                           0
                       )
                   )
          END

    FROM dbo.RCA_PlanEvidence pe

    CROSS APPLY pe.ActualExecutionPlanXML.nodes('//RelOp') op(r)

    OUTER APPLY
    (
        SELECT
              ActualRows =
                  SUM(TRY_CONVERT(decimal(38,4),
                      x.c.value('@ActualRows','nvarchar(80)')))

            , ActualRowsRead =
                  SUM(TRY_CONVERT(decimal(38,4),
                      x.c.value('@ActualRowsRead','nvarchar(80)')))

            , ActualExecutions =
                  SUM(TRY_CONVERT(decimal(38,4),
                      x.c.value('@ActualExecutions','nvarchar(80)')))
        FROM op.r.nodes('.//RunTimeCountersPerThread') x(c)
    ) rc

    OUTER APPLY
    (
        SELECT TOP(1)
              DatabaseName =
                  o.c.value('@Database','nvarchar(256)')
            , SchemaName =
                  o.c.value('@Schema','nvarchar(256)')
            , TableName =
                  o.c.value('@Table','nvarchar(512)')
            , IndexName =
                  o.c.value('@Index','nvarchar(512)')
            , IndexKind =
                  o.c.value('@IndexKind','nvarchar(128)')
            , Storage =
                  o.c.value('@Storage','nvarchar(128)')
        FROM op.r.nodes('.//Object') o(c)
    ) obj

    WHERE pe.CaptureRunID=@CaptureRunID;


    -------------------------------------------------------------------------
    -- H. STATISTICS USED BY OPTIMIZER
    -------------------------------------------------------------------------
    ;WITH XMLNAMESPACES
    (
        DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
    )
    INSERT dbo.RCA_PlanStatistics
    (
          CaptureRunID
        , PlanEvidenceID
        , ExecutionEvidenceID
        , DatabaseName
        , SchemaName
        , TableName
        , StatisticsName
        , LastUpdate
        , ModificationCount
        , SamplingPercent
        , StatsAgeHours
    )
    SELECT
          @CaptureRunID
        , pe.PlanEvidenceID
        , pe.LinkedExecutionEvidenceID
        , s.n.value('@Database','nvarchar(256)')
        , s.n.value('@Schema','nvarchar(256)')
        , s.n.value('@Table','nvarchar(512)')
        , s.n.value('@Statistics','nvarchar(512)')

        , TRY_CONVERT
          (
              datetime2(3),
              s.n.value('@LastUpdate','nvarchar(80)')
          )

        , TRY_CONVERT
          (
              bigint,
              s.n.value('@ModificationCount','nvarchar(80)')
          )

        , TRY_CONVERT
          (
              decimal(19,6),
              s.n.value('@SamplingPercent','nvarchar(80)')
          )

        , CASE
              WHEN TRY_CONVERT(datetime2(3),
                  s.n.value('@LastUpdate','nvarchar(80)')) IS NULL
              THEN NULL
              ELSE CONVERT
                   (
                       decimal(19,2),
                       DATEDIFF_BIG
                       (
                           minute,
                           TRY_CONVERT(datetime2(3),
                             s.n.value('@LastUpdate','nvarchar(80)')),
                           pe.EventTimeUTC
                       ) / 60.0
                   )
          END

    FROM dbo.RCA_PlanEvidence pe
    CROSS APPLY pe.ActualExecutionPlanXML.nodes
    (
        '//OptimizerStatsUsage/StatisticsInfo'
    ) s(n)
    WHERE pe.CaptureRunID=@CaptureRunID;


    -------------------------------------------------------------------------
    -- I. AUTOMATIC FINDINGS
    -------------------------------------------------------------------------

    /* Severe estimate / actual differences. */
    INSERT dbo.RCA_PlanFinding
    (
        CaptureRunID,PlanEvidenceID,ExecutionEvidenceID,
        Severity,FindingType,FindingText,RecommendedAction
    )
    SELECT DISTINCT
        @CaptureRunID,
        o.PlanEvidenceID,
        o.ExecutionEvidenceID,
        CASE
            WHEN o.EstimateActualRatio>=100
              OR o.EstimateActualRatio<=0.01
            THEN 'HIGH'
            ELSE 'MEDIUM'
        END,
        'CARDINALITY_MISMATCH',
        CONCAT
        (
            'Operator ',COALESCE(o.PhysicalOp,N'UNKNOWN'),
            ' estimated ',CONVERT(varchar(40),o.EstimateRows),
            ' row(s) but processed ',CONVERT(varchar(50),o.ActualRows),
            '. Estimate/actual ratio=',CONVERT(varchar(50),o.EstimateActualRatio),'.'
        ),
        N'Review runtime parameter values, statistics quality, data skew, and parameter-sensitive plan behavior.'
    FROM dbo.RCA_PlanOperator o
    WHERE o.CaptureRunID=@CaptureRunID
      AND o.EstimateActualRatio IS NOT NULL
      AND (o.EstimateActualRatio>=10 OR o.EstimateActualRatio<=0.10);


    /* Spills. */
    INSERT dbo.RCA_PlanFinding
    (
        CaptureRunID,PlanEvidenceID,ExecutionEvidenceID,
        Severity,FindingType,FindingText,RecommendedAction
    )
    SELECT DISTINCT
        @CaptureRunID,
        o.PlanEvidenceID,
        o.ExecutionEvidenceID,
        'HIGH',
        'TEMPDB_SPILL',
        CONCAT
        (
            'Runtime spill detected on ',
            COALESCE(o.PhysicalOp,N'plan operator'),
            ' NodeId ',COALESCE(CONVERT(varchar(20),o.NodeID),'?'),'.'
        ),
        N'Check cardinality estimates and memory grant sizing before increasing server memory.'
    FROM dbo.RCA_PlanOperator o
    WHERE o.CaptureRunID=@CaptureRunID
      AND o.HasSpillWarning=1;


    /* Implicit conversions. */
    INSERT dbo.RCA_PlanFinding
    (
        CaptureRunID,PlanEvidenceID,ExecutionEvidenceID,
        Severity,FindingType,FindingText,RecommendedAction
    )
    SELECT DISTINCT
        @CaptureRunID,
        o.PlanEvidenceID,
        o.ExecutionEvidenceID,
        'MEDIUM',
        'IMPLICIT_CONVERSION',
        CONCAT
        (
            'Implicit conversion detected in or below ',
            COALESCE(o.PhysicalOp,N'plan operator'),
            ' NodeId ',COALESCE(CONVERT(varchar(20),o.NodeID),'?'),'.'
        ),
        N'Review parameter/column data types because conversions can prevent seeks and distort cardinality estimates.'
    FROM dbo.RCA_PlanOperator o
    WHERE o.CaptureRunID=@CaptureRunID
      AND o.HasImplicitConversion=1;


    /* Large scans. */
    INSERT dbo.RCA_PlanFinding
    (
        CaptureRunID,PlanEvidenceID,ExecutionEvidenceID,
        Severity,FindingType,FindingText,RecommendedAction
    )
    SELECT DISTINCT
        @CaptureRunID,
        o.PlanEvidenceID,
        o.ExecutionEvidenceID,
        CASE WHEN o.ActualRowsRead>=1000000 THEN 'HIGH' ELSE 'MEDIUM' END,
        'LARGE_SCAN',
        CONCAT
        (
            COALESCE(o.PhysicalOp,N'Scan'),
            ' read approximately ',
            CONVERT(varchar(50),o.ActualRowsRead),
            ' row(s) from ',
            COALESCE(o.TableName,N'unknown table'),
            CASE WHEN o.IndexName IS NULL THEN N'' ELSE N' using '+o.IndexName END,
            '.'
        ),
        N'Validate whether the scan is appropriate; review predicates, index selectivity, covering strategy, and statistics before adding an index.'
    FROM dbo.RCA_PlanOperator o
    WHERE o.CaptureRunID=@CaptureRunID
      AND o.PhysicalOp LIKE '%Scan%'
      AND COALESCE(o.ActualRowsRead,o.ActualRows)>=100000;


    /* Low sampled / old statistics from the plan. */
    INSERT dbo.RCA_PlanFinding
    (
        CaptureRunID,PlanEvidenceID,ExecutionEvidenceID,
        Severity,FindingType,FindingText,RecommendedAction
    )
    SELECT DISTINCT
        @CaptureRunID,
        s.PlanEvidenceID,
        s.ExecutionEvidenceID,
        CASE
            WHEN COALESCE(s.SamplingPercent,100)<1
             AND COALESCE(s.ModificationCount,0)>=100000
            THEN 'HIGH'
            ELSE 'MEDIUM'
        END,
        'STATISTICS_RISK',
        CONCAT
        (
            'Statistics ',COALESCE(s.StatisticsName,N'UNKNOWN'),
            ' on ',COALESCE(s.TableName,N'UNKNOWN'),
            ' were sampled at ',
            COALESCE(CONVERT(varchar(30),s.SamplingPercent),'unknown'),
            '% with ',
            COALESCE(CONVERT(varchar(30),s.ModificationCount),'unknown'),
            ' modifications. Last update: ',
            COALESCE(CONVERT(varchar(30),s.LastUpdate,121),'unknown'),
            '.'
        ),
        N'Compare estimated vs actual rows first. If estimates are poor, test a targeted statistics update in a controlled environment.'
    FROM dbo.RCA_PlanStatistics s
    WHERE s.CaptureRunID=@CaptureRunID
      AND
      (
          COALESCE(s.SamplingPercent,100)<5
          OR COALESCE(s.ModificationCount,0)>=100000
      );


    -------------------------------------------------------------------------
    -- J. STATUS
    -------------------------------------------------------------------------
    UPDATE dbo.RCA_CaptureRun
    SET CaptureStatus=N'ANALYZED'
    WHERE CaptureRunID=@CaptureRunID;

    SELECT
          CaptureRunID=@CaptureRunID
        , Executions=
            (SELECT COUNT(*) FROM dbo.RCA_ExecutionEvidence
             WHERE CaptureRunID=@CaptureRunID)

        , Statements=
            (SELECT COUNT(*) FROM dbo.RCA_StatementEvidence
             WHERE CaptureRunID=@CaptureRunID)

        , ActualPlans=
            (SELECT COUNT(*) FROM dbo.RCA_PlanEvidence
             WHERE CaptureRunID=@CaptureRunID)

        , RuntimeParameters=
            (SELECT COUNT(*) FROM dbo.RCA_RuntimeParameter
             WHERE CaptureRunID=@CaptureRunID)

        , PlanOperators=
            (SELECT COUNT(*) FROM dbo.RCA_PlanOperator
             WHERE CaptureRunID=@CaptureRunID)

        , StatisticsUsed=
            (SELECT COUNT(*) FROM dbo.RCA_PlanStatistics
             WHERE CaptureRunID=@CaptureRunID)

        , Findings=
            (SELECT COUNT(*) FROM dbo.RCA_PlanFinding
             WHERE CaptureRunID=@CaptureRunID);
END;
GO


/*==============================================================================
  7. ELITE CORRELATED VIEW
==============================================================================*/
CREATE OR ALTER VIEW dbo.vw_RCA_EliteExecution
AS
SELECT
      e.CaptureRunID
    , e.ExecutionEvidenceID
    , e.EventTimeUTC
    , e.DatabaseName
    , e.SessionID
    , e.ObjectName

    , e.CPUms
    , e.DurationMs
    , e.LogicalReads
    , e.PhysicalReads
    , e.Writes
    , e.TotalRows

    , e.HostName
    , e.ProgramName
    , e.LoginName

    , e.ParameterEvidenceStatus
    , e.ParameterText
    , e.SubmittedCommand

    , QueryMemoryRequestedMB =
        CONVERT(decimal(19,2),pe.RequestedMemoryKB/1024.0)

    , QueryMemoryGrantedMB =
        CONVERT(decimal(19,2),pe.GrantedMemoryKB/1024.0)

    , QueryMemoryMaxUsedMB =
        CONVERT(decimal(19,2),pe.MaxUsedMemoryKB/1024.0)

    , pe.ActualDOP

    , HasActualExecutionPlan =
        CONVERT(bit,CASE WHEN pe.PlanEvidenceID IS NULL THEN 0 ELSE 1 END)

    , pe.ActualExecutionPlanXML

    , RuntimeParameterCount =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_RuntimeParameter rp
            WHERE rp.ExecutionEvidenceID=e.ExecutionEvidenceID
        )

    , PlanFindingCount =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding pf
            WHERE pf.ExecutionEvidenceID=e.ExecutionEvidenceID
        )

    , SevereFindingCount =
        (
            SELECT COUNT(*)
            FROM dbo.RCA_PlanFinding pf
            WHERE pf.ExecutionEvidenceID=e.ExecutionEvidenceID
              AND pf.Severity='HIGH'
        )

    , ServerSnapshotUTC = ss.CaptureTimeUTC
    , ss.SqlCpuPercent
    , ss.BufferCacheHitRatio
    , ss.PageLifeExpectancySeconds
    , ss.TotalServerMemoryMB
    , ss.TargetServerMemoryMB
    , ss.AvailablePhysicalMemoryMB
    , ss.MemoryGrantsPending
    , ss.MemoryGrantsOutstanding
    , ss.RunnableTasks
    , ss.ServerMaxDOP

FROM dbo.RCA_ExecutionEvidence e

OUTER APPLY
(
    SELECT TOP(1) p.*
    FROM dbo.RCA_PlanEvidence p
    WHERE p.LinkedExecutionEvidenceID=e.ExecutionEvidenceID
    ORDER BY
        ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,p.EventTimeUTC))
) pe

OUTER APPLY
(
    SELECT TOP(1) s.*
    FROM dbo.RCA_ServerSnapshot s
    WHERE s.CaptureRunID=e.CaptureRunID
    ORDER BY
        ABS(DATEDIFF_BIG(millisecond,e.EventTimeUTC,s.CaptureTimeUTC))
) ss;
GO


/*==============================================================================
  8. READABLE RCA REPORT
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_RCA_ShowEliteReport
    @CaptureRunID bigint,
    @Top int=25
AS
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------------
    -- RESULT 1: Top executions
    -------------------------------------------------------------------------
    SELECT TOP(@Top)
          CaptureRunID
        , ExecutionEvidenceID
        , EventTimeUTC
        , SessionID
        , DatabaseName
        , ObjectName
        , CPUms
        , DurationMs
        , LogicalReads
        , PhysicalReads
        , Writes
        , TotalRows
        , QueryMemoryRequestedMB
        , QueryMemoryGrantedMB
        , QueryMemoryMaxUsedMB
        , ActualDOP
        , HostName
        , ProgramName
        , LoginName
        , RuntimeParameterCount
        , ParameterText
        , HasActualExecutionPlan
        , PlanFindingCount
        , SevereFindingCount
        , SqlCpuPercent
        , BufferCacheHitRatio
        , PageLifeExpectancySeconds
        , AvailablePhysicalMemoryMB
        , MemoryGrantsPending
        , RunnableTasks
        , ServerMaxDOP
        , ActualExecutionPlanXML
    FROM dbo.vw_RCA_EliteExecution
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY
          CPUms DESC
        , LogicalReads DESC
        , DurationMs DESC;


    -------------------------------------------------------------------------
    -- RESULT 2: Actual runtime parameters
    -------------------------------------------------------------------------
    SELECT
          rp.ExecutionEvidenceID
        , e.SessionID
        , e.ObjectName
        , rp.ParameterName
        , rp.ParameterDataType
        , rp.ParameterCompiledValue
        , rp.ParameterRuntimeValue
        , rp.EvidenceSource
    FROM dbo.RCA_RuntimeParameter rp
    LEFT JOIN dbo.RCA_ExecutionEvidence e
      ON e.ExecutionEvidenceID=rp.ExecutionEvidenceID
    WHERE rp.CaptureRunID=@CaptureRunID
    ORDER BY
          rp.ExecutionEvidenceID
        , rp.RuntimeParameterID;


    -------------------------------------------------------------------------
    -- RESULT 3: What indexes/operators actually ran
    -------------------------------------------------------------------------
    SELECT
          o.ExecutionEvidenceID
        , e.SessionID
        , e.ObjectName
        , o.NodeID
        , o.PhysicalOp
        , o.LogicalOp
        , o.TableName
        , o.IndexName
        , o.EstimateRows
        , o.ActualRows
        , o.ActualRowsRead
        , o.ActualExecutions
        , o.EstimateActualRatio
        , o.EstimatedSubtreeCost
        , o.Parallel
        , o.HasSpillWarning
        , o.HasImplicitConversion
    FROM dbo.RCA_PlanOperator o
    LEFT JOIN dbo.RCA_ExecutionEvidence e
      ON e.ExecutionEvidenceID=o.ExecutionEvidenceID
    WHERE o.CaptureRunID=@CaptureRunID
      AND
      (
          o.TableName IS NOT NULL
          OR o.HasSpillWarning=1
          OR o.HasImplicitConversion=1
      )
    ORDER BY
          o.ExecutionEvidenceID
        , o.NodeID;


    -------------------------------------------------------------------------
    -- RESULT 4: Statistics used by the optimizer
    -------------------------------------------------------------------------
    SELECT
          s.ExecutionEvidenceID
        , e.SessionID
        , e.ObjectName
        , s.DatabaseName
        , s.SchemaName
        , s.TableName
        , s.StatisticsName
        , s.LastUpdate
        , s.ModificationCount
        , s.SamplingPercent
        , s.StatsAgeHours
    FROM dbo.RCA_PlanStatistics s
    LEFT JOIN dbo.RCA_ExecutionEvidence e
      ON e.ExecutionEvidenceID=s.ExecutionEvidenceID
    WHERE s.CaptureRunID=@CaptureRunID
    ORDER BY
          s.ExecutionEvidenceID
        , s.TableName
        , s.StatisticsName;


    -------------------------------------------------------------------------
    -- RESULT 5: "THEN WHAT?" findings
    -------------------------------------------------------------------------
    SELECT
          f.ExecutionEvidenceID
        , e.SessionID
        , e.ObjectName
        , f.Severity
        , f.FindingType
        , f.FindingText
        , f.RecommendedAction
    FROM dbo.RCA_PlanFinding f
    LEFT JOIN dbo.RCA_ExecutionEvidence e
      ON e.ExecutionEvidenceID=f.ExecutionEvidenceID
    WHERE f.CaptureRunID=@CaptureRunID
    ORDER BY
        CASE f.Severity
            WHEN 'HIGH' THEN 1
            WHEN 'MEDIUM' THEN 2
            ELSE 3
        END,
        f.ExecutionEvidenceID,
        f.PlanFindingID;


    -------------------------------------------------------------------------
    -- RESULT 6: Server memory/cache trajectory
    -------------------------------------------------------------------------
    SELECT
          CaptureTimeUTC
        , SqlCpuPercent
        , BufferCacheHitRatio
        , PageLifeExpectancySeconds
        , TotalServerMemoryMB
        , TargetServerMemoryMB
        , AvailablePhysicalMemoryMB
        , MemoryGrantsPending
        , MemoryGrantsOutstanding
        , RunnableTasks
        , ServerMaxDOP
    FROM dbo.RCA_ServerSnapshot
    WHERE CaptureRunID=@CaptureRunID
    ORDER BY CaptureTimeUTC;
END;
GO


/*==============================================================================
  9. VALIDATE INSTALL
==============================================================================*/
SELECT
      StatementEvidence =
        IIF(OBJECT_ID(N'dbo.RCA_StatementEvidence',N'U') IS NULL,N'FAIL',N'PASS')
    , RuntimeParameter =
        IIF(OBJECT_ID(N'dbo.RCA_RuntimeParameter',N'U') IS NULL,N'FAIL',N'PASS')
    , PlanOperator =
        IIF(OBJECT_ID(N'dbo.RCA_PlanOperator',N'U') IS NULL,N'FAIL',N'PASS')
    , PlanStatistics =
        IIF(OBJECT_ID(N'dbo.RCA_PlanStatistics',N'U') IS NULL,N'FAIL',N'PASS')
    , PlanFinding =
        IIF(OBJECT_ID(N'dbo.RCA_PlanFinding',N'U') IS NULL,N'FAIL',N'PASS')
    , Parser =
        IIF(OBJECT_ID(N'dbo.usp_RCA_ParseCaptureRun',N'P') IS NULL,N'FAIL',N'PASS')
    , EliteView =
        IIF(OBJECT_ID(N'dbo.vw_RCA_EliteExecution',N'V') IS NULL,N'FAIL',N'PASS')
    , EliteReport =
        IIF(OBJECT_ID(N'dbo.usp_RCA_ShowEliteReport',N'P') IS NULL,N'FAIL',N'PASS');
GO


/*==============================================================================
  10. RUN AGAINST OUR PRESERVED RUN 2
==============================================================================*/
/*
USE DBA;
GO

EXEC dbo.usp_RCA_ParseCaptureRun
     @CaptureRunID=2;
GO

EXEC dbo.usp_RCA_ShowEliteReport
     @CaptureRunID=2,
     @Top=25;
GO

IMPORTANT:
In the first result set, click ActualExecutionPlanXML to open the graphical
ACTUAL execution plan in SSMS.
*/
