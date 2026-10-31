# RCA V1 Certification and Freeze Record

## Final status

**RCA V1 is certified and release-frozen.**

- Certification gate: `SCRIPT 110L v1.3`
- Result: `PASS`
- Repository: `dbamaint`
- Certified server: `PORTFOLIO-SQL\INSTANCE`
- Certification execution: 2026-08-23
- Certified DBA-answer path: `CANONICAL SUMMARY -> FINAL TRANSITIVE PATH`

## Certified RCA domains

| Order | Domain |
|---:|---|
| 1 | `CPU_SCHEDULER` |
| 2 | `BLOCKING_WAIT_CHAIN` |
| 3 | `IO_STORAGE_LATENCY` |
| 4 | `MEMORY_PRESSURE` |
| 5 | `TEMPDB_PRESSURE` |
| 6 | `TRANSACTION_LOG_PRESSURE` |
| 7 | `CONNECTIVITY_PRESSURE` |

Every domain produced builder evidence, one normalized `PRIMARY/HIGH` candidate, and exactly one final `PRIMARY/HIGH` winner. No control produced a contradictory high-confidence contributor.

## Certified cross-domain topology

| Upstream | Downstream | Classification | Certification |
|---|---|---|---|
| `CPU_SCHEDULER` | `IO_STORAGE_LATENCY` | `CERTIFIED_CAUSAL` | SCRIPT 109B |
| `BLOCKING_WAIT_CHAIN` | `IO_STORAGE_LATENCY` | `CERTIFIED_CAUSAL` | SCRIPT 110B |
| `CPU_SCHEDULER` | `MEMORY_PRESSURE` | `CERTIFIED_CAUSAL` | SCRIPT 110C |
| `BLOCKING_WAIT_CHAIN` | `MEMORY_PRESSURE` | `CERTIFIED_CAUSAL` | SCRIPT 110D |
| `CPU_SCHEDULER` | `TEMPDB_PRESSURE` | `CERTIFIED_CAUSAL` | SCRIPT 110E |
| `BLOCKING_WAIT_CHAIN` | `TEMPDB_PRESSURE` | `CERTIFIED_CAUSAL` | SCRIPT 110F |
| `IO_STORAGE_LATENCY` | `TEMPDB_PRESSURE` | `REFERENCE_ONLY` | SCRIPT 110G1 |

Topology totals: six certified causal edges, one reference-only relationship, and zero unresolved relationships.

## Final acceptance evidence

SCRIPT 110L v1.3 certified:

- 7 of 7 domains passed the complete builder-to-normalized-to-final path.
- 7 of 7 DBA-answer executions passed semantic domain alignment.
- Final arbitration retained deterministic `PRIMARY` versus `CONTRIBUTING` behavior.
- Canonical summary role, confidence, supported-cause count, primary count, and arbitration status reconciled with final arbitration.
- All six synthetic captures were enclosed in the protected certification transaction.
- Post-rollback synthetic capture residue: 0.
- Post-rollback synthetic snapshot residue: 0.
- Post-rollback synthetic evidence residue: 0.
- Capture, snapshot, evidence, final-view, and summary-view row counts were unchanged.
- SQL Agent job count and Extended Events session count were unchanged.

The final certification used persistent blocking CaptureRunID 12 and transactionally recreated synthetic captures for CPU, I/O, memory, TempDB, transaction log, and connectivity. All synthetic rows were rolled back.

## Interpretation of the final correction

SCRIPT 110L v1.2 demonstrated that all seven detectors and final arbitration outputs were correct. Its remaining failures were caused by certification expectations that required literal display-text equality across layers where certified taxonomy transformations intentionally rename categories.

SCRIPT 110L v1.3 retained every causal, arbitration, execution, topology, and safety gate while validating semantic domain identity. No production RCA object was changed or weakened to obtain the final PASS.

## Frozen programmable-object scope

The release freeze covers:

- `dbo.usp_RCA_AnalyzeCaptureRun`
- All seven `dbo.usp_RCA_Build*Evidence` procedures
- `dbo.vw_RCA_NormalizedCauseCandidates`
- `dbo.vw_RCA_FinalCauseCandidates`
- `dbo.vw_RCA_CrossDomainCauseSummary`
- `dbo.usp_RCA_DBAAnswer`

The exact deployed definitions and SHA-256 hashes are emitted by section 19 of SCRIPT 110L v1.3 and section 4 of SCRIPT 110M v1.0.

## Change-control rule

Any modification to a frozen programmable object invalidates the existing hash baseline for that object. The affected domain and cross-domain certifications must be rerun before the modified build can be promoted as RCA V1-certified.

At minimum:

1. Compare the new object hash to the frozen manifest.
2. Rerun the affected individual-domain certification.
3. Rerun every affected causal-edge certification.
4. Rerun SCRIPT 110H topology certification.
5. Rerun SCRIPT 110K DBA-answer/final-arbitration certification when the consumer path is affected.
6. Rerun SCRIPT 110L end-to-end release acceptance.
7. Replace the freeze manifest only after SCRIPT 110L returns `PASS` with zero synthetic residue.

## Operational handoff

- Use the normal RCA capture workflow for operational investigations.
- Treat `vw_RCA_FinalCauseCandidates` as the deterministic final arbitration layer.
- Treat `vw_RCA_CrossDomainCauseSummary` as the canonical summary consumed transitively by `usp_RCA_DBAAnswer`.
- Preserve the six causal edges and the IO-to-TempDB `REFERENCE_ONLY` classification.
- Do not infer causality from a reference-only relationship.
- Retain the failed and successful certification result sets with the release evidence.
- Run SCRIPT 110M v1.1 after deployment or before a release review to obtain a read-only object and hash inventory using the certified transitive dependency path.

## Release decision

**Authorized state: `RCA V1 FROZEN`**

Future functional work should begin as an RCA V1.x or RCA V2 change and must not silently alter the certified V1 baseline.
