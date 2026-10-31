# Recruiter and Hiring-Manager Walkthrough

## Thirty-second explanation

I designed a SQL Server flight-recorder and root-cause analysis framework that captures an incident window and evaluates seven performance domains. Instead of reporting isolated symptoms, it correlates transactions, parameters, waits, resource pressure, blocking relationships, and actual execution-plan evidence, then ranks primary and contributing causes through deterministic cross-domain arbitration.

## Why the project matters

SQL Server incidents rarely remain inside one subsystem. Blocking can appear as I/O latency. CPU pressure can amplify memory and TempDB problems. A memory spill can be caused by data skew, parameter sensitivity, or incorrect cardinality estimates rather than insufficient server memory.

The toolkit was designed to prevent premature conclusions and configuration changes. It preserves the evidence chain and produces a report that tells the DBA what was observed, why it was classified, which transaction was involved, and where investigation should begin.

## Capabilities demonstrated

- Enterprise SQL Server architecture
- Extended Events and DMV-based observability
- Query and execution-plan analysis
- Parameter-sensitive workload investigation
- Blocking-chain and blast-radius analysis
- CPU, memory, I/O, TempDB, transaction-log, and connectivity diagnostics
- Evidence normalization and cross-domain causal reasoning
- SQL Agent orchestration and safe cleanup
- Rollback-safe testing and certification gates
- Executive and junior-DBA reporting
- Change control through frozen object hashes

## Demonstrated controlled incident

The strongest retained report identified blocking and a memory grant spill as primary causes, with CPU/scheduler pressure contributing. It linked the winner to an exact captured plan and showed different runtime and compiled parameter values—evidence that matters when investigating parameter-sensitive behavior.

## What I would build next

The next layer would expose the certified evidence model through MCP so an AI assistant can answer follow-up questions, compare incidents, and generate investigation plans without changing the deterministic SQL evidence and arbitration foundation.

## Repository boundary

This repository demonstrates the system without publishing deployable source code. Detailed implementation can be discussed in an interview or private technical review.

