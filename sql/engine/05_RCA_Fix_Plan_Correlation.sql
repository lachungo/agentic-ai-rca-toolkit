USE DBA;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  05_RCA_Fix_Plan_Correlation.sql

  Replaces the complete parser procedure.
  Key correction:
      PLAN -> matching completed statement -> parent execution

  This avoids the old +/-30 second "nearest completed batch" attribution.
  It also retains the prior SQL Server XQuery spill-detection fix.

  No tables are dropped.
  No XE session is changed.
  Existing raw XE evidence is preserved.
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
    -- D. LINK CHILD STATEMENTS TO THEIR PARENT RPC/BATCH EXECUTION
    --
    -- The completed outer RPC/batch occurs at or after the child statement.
    -- We deliberately choose the first completed parent in the same session.
    -------------------------------------------------------------------------
    UPDATE s
       SET LinkedExecutionEvidenceID = m.ExecutionEvidenceID
    FROM dbo.RCA_StatementEvidence s
    CROSS APPLY
    (
        SELECT TOP(1)
            e.ExecutionEvidenceID
        FROM dbo.RCA_ExecutionEvidence e
        WHERE e.CaptureRunID = @CaptureRunID
          AND e.SessionID = s.SessionID
          AND e.EventTimeUTC >= s.EventTimeUTC
          AND DATEDIFF_BIG(second,s.EventTimeUTC,e.EventTimeUTC) <= 120
        ORDER BY
            e.EventTimeUTC,
            e.ExecutionEvidenceID
    ) m
    WHERE s.CaptureRunID = @CaptureRunID;


    -------------------------------------------------------------------------
    -- E. LINK ACTUAL PLAN -> MATCHING COMPLETED STATEMENT -> PARENT EXECUTION
    --
    -- Run 3 proved that query_post_execution_showplan and the corresponding
    -- sp_statement_completed event are normally only 0-10 ms apart.
    --
    -- We therefore correlate by:
    --      same CaptureRunID
    --      same SessionID
    --      statement completion at/after plan event
    --      tight 10-second ceiling
    --      nearest statement completion
    --
    -- IMPORTANT:
    -- If no matching statement exists, the plan is intentionally left
    -- unlinked rather than risking attribution to the wrong execution.
    -------------------------------------------------------------------------
    UPDATE pe
       SET LinkedExecutionEvidenceID = m.LinkedExecutionEvidenceID
    FROM dbo.RCA_PlanEvidence pe
    CROSS APPLY
    (
        SELECT TOP(1)
            s.LinkedExecutionEvidenceID
        FROM dbo.RCA_StatementEvidence s
        WHERE s.CaptureRunID = @CaptureRunID
          AND s.SessionID = pe.SessionID
          AND s.LinkedExecutionEvidenceID IS NOT NULL
          AND s.EventTimeUTC >= pe.EventTimeUTC
          AND DATEDIFF_BIG
              (
                  millisecond,
                  pe.EventTimeUTC,
                  s.EventTimeUTC
              ) <= 10000
        ORDER BY
            DATEDIFF_BIG
            (
                millisecond,
                pe.EventTimeUTC,
                s.EventTimeUTC
            ),
            s.StatementEvidenceID
    ) m
    WHERE pe.CaptureRunID = @CaptureRunID;


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
                    './/RunTimeCountersPerThread[@SpillLevel or @SpilledThreadCount]'
                  ) = 1
                  OR op.r.exist('.//SpillToTempDb') = 1
                  OR op.r.exist('.//HashSpillDetails') = 1
                  OR op.r.exist('.//SortSpillDetails') = 1
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
GO


/*==============================================================================
  RE-PARSE RUN 3
==============================================================================*/
EXEC dbo.usp_RCA_ParseCaptureRun
     @CaptureRunID = 3;
GO

/*==============================================================================
  VERIFY PLAN CORRELATION
==============================================================================*/
SELECT
      e.ExecutionEvidenceID
    , e.EventTimeUTC
    , e.CPUms
    , e.DurationMs
    , e.LogicalReads
    , e.Writes
    , LEFT(e.ParameterText,300) AS ParameterText
    , COUNT(pe.PlanEvidenceID) AS LinkedActualPlans
FROM dbo.RCA_ExecutionEvidence e
LEFT JOIN dbo.RCA_PlanEvidence pe
    ON pe.LinkedExecutionEvidenceID = e.ExecutionEvidenceID
   AND pe.CaptureRunID = e.CaptureRunID
WHERE e.CaptureRunID = 3
GROUP BY
      e.ExecutionEvidenceID
    , e.EventTimeUTC
    , e.CPUms
    , e.DurationMs
    , e.LogicalReads
    , e.Writes
    , e.ParameterText
ORDER BY e.EventTimeUTC;
GO

/* Expected Run 3 workload grouping:
      Execution 97 = Narrow     -> Plans 73-81  = 9 plans
      Execution 99 = Heavy #1   -> Plans 82-92  = 11 plans
      Execution 96 = Heavy #2   -> Plans 93-103 = 11 plans

   The trivial "USE RCA" execution should have 0 linked plans.
*/


/*==============================================================================
  VERIFY NO PLAN IS MISATTRIBUTED / UNACCOUNTED FOR
==============================================================================*/
SELECT
      TotalPlans =
        COUNT(*)
    , LinkedPlans =
        SUM(CASE WHEN LinkedExecutionEvidenceID IS NOT NULL THEN 1 ELSE 0 END)
    , UnlinkedPlans =
        SUM(CASE WHEN LinkedExecutionEvidenceID IS NULL THEN 1 ELSE 0 END)
FROM dbo.RCA_PlanEvidence
WHERE CaptureRunID = 3;
GO


/*==============================================================================
  SHOW PLAN GROUPS
==============================================================================*/
SELECT
      pe.PlanEvidenceID
    , pe.EventTimeUTC AS PlanTimeUTC
    , pe.LinkedExecutionEvidenceID
    , LEFT(e.ParameterText,220) AS ParentParameters
    , pe.RequestedMemoryKB
    , pe.GrantedMemoryKB
    , pe.MaxUsedMemoryKB
    , pe.ActualDOP
FROM dbo.RCA_PlanEvidence pe
LEFT JOIN dbo.RCA_ExecutionEvidence e
    ON e.ExecutionEvidenceID = pe.LinkedExecutionEvidenceID
WHERE pe.CaptureRunID = 3
ORDER BY pe.PlanEvidenceID;
GO
