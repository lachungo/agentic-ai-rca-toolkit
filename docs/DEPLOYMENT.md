# Deployment and Verification

## Read this first

This repository preserves a working system and its cumulative development chain. It is not a universal one-click installer. Validate it on an isolated SQL Server lab before adapting it to a consulting environment.

## Prerequisites

- SQL Server with Extended Events and SQL Server Agent
- A dedicated repository database (the certified environment used `dbamaint`/`DBA` naming during different stages)
- `sysadmin` for initial lab deployment, followed by least-privilege review
- A writable XE target directory
- For HTML file output: `bcp.exe`, TLS trust appropriate to the server, and a directory writable by the SQL Server service or proxy identity
- A disposable target database for positive controls

## Source layout

1. `sql/engine` contains the numbered cumulative build and hardening history.
2. `sql/operations` contains the final operational access and presentation layer.
3. `sql/acceptance` contains controlled verification and release gates.

The engine files contain multiple versions because later migrations document and correct earlier behavior. Preserve the numerical prefix ordering and select the highest version for scripts sharing the same prefix unless a script header explicitly says it is a prerequisite, rollback, diagnostic, or validation harness.

## Recommended lab workflow

1. Create backups and use a dedicated non-production SQL Server instance.
2. Review every `USE`, database name, filesystem path, Agent owner, XE target, and permission statement.
3. Start with `01_RCA_Lab_Build.sql`, then apply the numbered engine migrations in ascending numeric order, retaining the highest applicable version per prefix.
4. Deploy the operational scripts in this order:
   - one-call front door (`111B v1.2`)
   - business-hours XE allowlist (`111D`)
   - seven-domain sampling (`111E`)
   - historical front door (`111F v1.1`)
   - target-scoped I/O/log correction (`111I v1.4`)
   - TLS-aware writer (`111K5`)
   - statement/plan association fallback (`111L3`)
   - multi-culprit renderer (`111N v1.3`)
   - end-user wrapper (`01_Deploy_RCA_V1_End_User_Wrapper.sql`)
5. Run read-only checks before controlled workloads.
6. Use the `111L v1.2` parameter/plan control and `111O v1.1` multi-request control only in the disposable lab database.
7. Run `110L v1.3` as the release acceptance gate.
8. Validate the public database-and-time-window front door. Use an explicit internal capture identifier only in forensic or acceptance scripts that require exact replay.

## Safety rules

- Never run a positive-control script in production.
- Do not reuse the example `RCA_Demo`, `C:\RCA`, schedule, or XE path without review.
- Keep raw XE files and generated incident reports out of Git.
- Confirm cleanup of temporary Agent jobs and lab objects after acceptance tests.
- Treat parameter values, SQL text, plans, login names, host names, and database names as sensitive evidence.

## Portability caveat

The included code is the certified source history, not a promise that every SQL Server build, collation, security model, or filesystem layout will work unchanged. A consulting deployment should begin with a discovery pass and a client-specific configuration layer rather than editing causal logic in place.
