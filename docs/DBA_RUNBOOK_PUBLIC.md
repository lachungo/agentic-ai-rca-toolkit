# DBA Runbook Example

## Business question

Why was the `RCA_Demo` database slow during the reported incident window?

## Public front door

```sql
EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
     @DatabaseName   = N'RCA_Demo',
     @BeginTimeLocal = '2026-08-23T13:56:00',
     @EndTimeLocal   = '2026-08-23T13:59:00';
```

The operator does not enter an internal capture identifier. The wrapper resolves the matching evidence window and renders the timestamped HTML report.

## Investigation order

1. Read the executive verdict and confidence.
2. Review every PRIMARY and CONTRIBUTING cause.
3. Follow the winning execution to its runtime parameters and matching actual plan.
4. Review affected sessions and the seven-domain evidence.
5. Apply only recommendations supported by the captured evidence.

If the evidence is insufficient, the correct conclusion is `ROOT CAUSE NOT CONFIRMED`.
