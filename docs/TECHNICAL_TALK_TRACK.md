# Technical Interview Talk Track

## 1. Start with the design goal

“I wanted the system to behave like a flight recorder. A DBA provides the database and incident window. The framework preserves what happened across multiple SQL Server subsystems and produces a correlated, evidence-backed answer.”

## 2. Explain why seven independent builders matter

Each domain has different source telemetry and thresholds. I separated the builders so CPU, blocking, I/O, memory, TempDB, transaction-log, and connectivity evidence could be tested independently before being normalized into one arbitration model. This prevented one noisy metric from dominating the result.

## 3. Explain normalization and arbitration

Domain builders produce different evidence shapes. The normalization layer converts them into a common cause contract containing category, role, confidence, evidence identity, impacted execution, affected-request count, and correlation key.

The arbitration layer then applies certified causal precedence. Blocking can be upstream of I/O, memory, or TempDB symptoms. I/O-to-TempDB remains reference-only because correlation alone did not justify a causal claim.

## 4. Explain lineage

The report never attaches an arbitrary cached plan to a transaction. Plans and runtime parameters must be directly linked through the same capture and execution-evidence identity.

If the winning execution emitted no runtime parameter list, the report labels that honestly. It may show a separate parameterized example from the same capture, but it never presents that example as the winner.

## 5. Explain the controlled multi-cause result

The final test created a head blocker, multiple victims, and concurrent CPU/memory activity. Acceptance required at least three blocking victims, three impacted requests, CPU or memory evidence, a linked actual plan, and the expected runtime parameters.

The report showed blocking and memory grant/spill as PRIMARY, with CPU/scheduler pressure CONTRIBUTING. The winner ran for approximately 70.9 seconds. Its runtime parameters differed from compiled values, demonstrating why parameter and plan lineage mattered.

## 6. Explain safety engineering

- Synthetic certification data was enclosed in protected transactions.
- Certification verified zero residue after rollback.
- Job and XE session counts were checked before and after tests.
- Temporary jobs and workload objects were removed after execution.
- The framework produced investigative guidance, not automatic remediation.
- Frozen object definitions were hashed for change control.

## 7. Explain the word “agentic” accurately

The system autonomously coordinates specialized evidence builders and selects which supported causes survive into the final narrative. The reasoning is deterministic and auditable. The first version is not an LLM embedded in SQL Server.

An MCP layer can be added later so an AI agent can interrogate the certified evidence while causal truth remains in the database engine.

## Likely technical questions

### Why not rely only on Query Store?

Query Store is excellent for historical query and plan performance, but it does not independently preserve every blocking chain, file-level I/O delta, memory-pressure sample, log-space condition, or connectivity event required by this model.

### Why Extended Events?

XE supplied event-level execution, parameter, and actual-plan evidence with a bounded event allowlist. The design correlated that evidence with sampled subsystem telemetry.

### How did you avoid false causality?

By distinguishing observations, supported candidates, normalized causes, contributing conditions, certified causal edges, and reference-only relationships.

### Why show runtime and compiled values?

They can reveal parameter sensitivity, data skew, or a plan compiled for a materially different input. That evidence is more useful than simply labeling a procedure “slow.”

### Why not automate fixes?

A correct diagnosis does not automatically imply one safe remediation. The report guides the DBA but does not change MAXDOP, memory, TempDB, log growth, indexes, statistics, or running sessions.

