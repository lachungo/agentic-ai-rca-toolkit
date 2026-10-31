# Agentic AI RCA Toolkit for SQL Server

![Agentic AI RCA Toolkit for SQL Server](assets/article/sql-server-flight-recorder-cover.png)

> **Functional consulting portfolio edition**

This repository contains the working SQL source, operational layer, controlled acceptance workloads, certification record, and sanitized report output for a seven-domain SQL Server root-cause analysis system designed and built by **Louis Achungo**.

It is both a technical portfolio and a retained consulting asset. The code is available for review and controlled evaluation, but no license is granted to deploy, redistribute, sell, or create derivative implementations.

## What it does

The toolkit acts as a database flight recorder. It captures an incident window, correlates Extended Events with sampled server evidence, builds independent cause candidates, applies deterministic cross-domain arbitration, and produces a compact HTML incident report.

It analyzes:

1. CPU and scheduler pressure
2. Blocking and wait chains
3. I/O and storage latency
4. Memory pressure and grant spills
5. TempDB pressure
6. Transaction-log pressure
7. Connectivity pressure

The report can preserve more than one supported culprit. It also links a selected transaction to captured runtime parameters and its matching actual execution plan.

## Functional source included

| Area | Location | Purpose |
|---|---|---|
| Core engine | [`sql/engine`](sql/engine) | Cumulative schema, capture, parser, evidence-builder, synthesis, and reporting scripts |
| Operations | [`sql/operations`](sql/operations) | Front door, business-hours XE/sampling, target scoping, TLS-aware HTML writer, and final renderer |
| Acceptance | [`sql/acceptance`](sql/acceptance) | Release gate and controlled parameter/plan and multi-culprit workloads |
| Evidence | [`examples`](examples) | Sanitized HTML reports produced by the working system |
| Deployment | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Lab-first installation and verification guidance |

The `sql/engine` directory intentionally preserves the cumulative numbered development chain. Later scripts repair or supersede earlier objects. It is engineering history as well as source; do not execute the folder alphabetically without following the deployment guide.

## Demonstrated result

The certified multi-culprit report demonstrates:

- PRIMARY blocking/wait-chain contention;
- PRIMARY memory grant/spill pressure;
- CONTRIBUTING CPU/scheduler pressure;
- multiple impacted requests;
- a winning execution with strict execution-to-plan lineage;
- runtime and compiled parameter values; and
- captured actual execution-plan XML.

Open [`examples/RCA_Incident_Certified_Multi_Culprit.html`](examples/RCA_Incident_Certified_Multi_Culprit.html).

## One business question starts the investigation

The public front door accepts a database name and the local incident window. The toolkit resolves the matching capture internally, preserving `CaptureRunID` as an evidence-lineage key rather than requiring it from the investigator.

```sql
EXEC dbamaint.dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
     @DatabaseName   = N'YourDatabase',
     @BeginTimeLocal = '2026-08-23T13:56:00',
     @EndTimeLocal   = '2026-08-23T13:59:00';
```

For lab acceptance, the repository uses the disposable database name `RCA_Demo`. Replace it through an environment-specific configuration review; do not point the positive controls at a production database.

## Important operating boundary

This is real SQL Server instrumentation, not a toy package. It uses Extended Events, SQL Agent, server DMVs, and—only for file output—the SQL Server service/proxy identity and `bcp`. Controlled workload scripts deliberately create pressure. Run them only in an isolated non-production lab after reading their headers.

The repository excludes captured `.xel` files, credentials, machine-specific secrets, and personal server identities. Paths, database names, schedules, permissions, certificates, and service identities must be reviewed for each environment.

## How to evaluate the work

- Recruiter overview: [`docs/RECRUITER_WALKTHROUGH.md`](docs/RECRUITER_WALKTHROUGH.md)
- LinkedIn technical article: [`docs/LINKEDIN_ARTICLE.md`](docs/LINKEDIN_ARTICLE.md)
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Deployment and safety: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)
- Certification: [`docs/CERTIFICATION.md`](docs/CERTIFICATION.md)
- Interview talk track: [`docs/TECHNICAL_TALK_TRACK.md`](docs/TECHNICAL_TALK_TRACK.md)
- Publication boundaries: [`docs/PUBLICATION_SCOPE.md`](docs/PUBLICATION_SCOPE.md)

## Ownership

Copyright © 2026 Louis Achungo. All rights reserved. Source availability is not an open-source license. See [`LICENSE`](LICENSE).

## Author

**Louis Achungo**  
Principal SQL Server Architect  
[Portfolio](https://sql-it-techsolutions.com/) · [LinkedIn](https://www.linkedin.com/in/louis-achungo/) · [GitHub](https://github.com/lachungo)
