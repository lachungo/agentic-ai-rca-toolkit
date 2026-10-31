# Architecture

## Evidence pipeline

| Layer | Responsibility |
|---|---|
| Capture | Record the incident window and target database |
| Sampling | Persist blocking, CPU, I/O, memory, TempDB, log, and connectivity observations |
| Extended Events | Capture completed statements, RPC/batch activity, parameters, and post-execution plans |
| Parsing and correlation | Associate raw XE events with one capture and target database |
| Evidence builders | Transform telemetry into domain-specific evidence rows |
| Plan intelligence | Persist query/plan hashes, actual-plan XML, parameters, operators, statistics, and findings |
| Normalization | Convert domain output into a common cause vocabulary |
| Cross-domain arbitration | Rank PRIMARY and CONTRIBUTING causes while honoring certified causal precedence |
| DBA narration | Produce operational findings and guarded investigative actions |
| HTML renderer | Present all supported causes, impacted requests, transaction lineage, parameters, and plans |

## Certified causal topology

| Upstream | Downstream | Classification |
|---|---|---|
| CPU scheduler | I/O latency | Certified causal |
| Blocking | I/O latency | Certified causal |
| CPU scheduler | Memory pressure | Certified causal |
| Blocking | Memory pressure | Certified causal |
| CPU scheduler | TempDB pressure | Certified causal |
| Blocking | TempDB pressure | Certified causal |
| I/O latency | TempDB pressure | Reference only |

The reference-only I/O-to-TempDB relationship must not be promoted to causality without additional evidence.

## Evidence-lineage rule

An actual plan or parameter list is displayed only when it is directly linked to the same `ExecutionEvidenceID` and `CaptureRunID`. If the winner emitted no runtime parameters, the report may display a separately labeled same-capture example with its own directly linked plan. It must never attach an unrelated plan or parameter list to the winner.

