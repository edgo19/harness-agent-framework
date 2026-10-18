# Implementation, verification and rollout plan

This plan produces a generic framework and one initial capability. It does not begin with a telemetry-specific hard-coded agent loop. Work is sequenced by dependency and acceptance evidence, not fixed calendar estimates.

## Milestones

| Stage | Deliverable | Exit evidence |
|---|---|---|
| 0. Inventory and decisions | Four repository owners; approved model/region; source map; actual backend/Argo/Kustomize versions; TLS path; environment/SLO review | Approved source selectors exclude target telemetry; sample freshness and installed limits verified; no secret values collected in design |
| 1. Contracts and core | Task/capability/tool/evidence/report schemas; immutable releases; ledger and migration design | Schema compatibility/negative tests; duplicate request/hash conflict behavior; capability registration without kernel changes |
| 2. Cloud/GitOps foundation | Terraform modules/live configuration; scoped identities; state/storage/messaging/SQL; Kustomize/ApplicationSet deployment | Reviewed plans; dev apply; server-version-compatible rendering; exact IAM subjects; HTTP JWT negative tests; owner boundaries verified |
| 3. Safe telemetry tools | Typed builders/templates, source policy, query semaphore/budgets, result normalization | No raw-query/tenant/URL bypass; target-source denials; high-cardinality load tests meet backend-impact envelope; timeout doesn't flood replacements |
| 4. Generic worker and memory | Deep Agents assembly, context limits, per-run checkpointer, skills, model budgets, GCS evidence/reporting | Explicit safe tool catalog; prompt-injection fixtures; valid referenced findings; no secrets in state/traces; interrupted execution is honest |
| 5. End-to-end triggers | Terraform request registration; runtime execution; registry-based schedules; reconciliation and cancellation | CI/CD only registers/deploys; duplicate events/ticks/imports converge; disabled schedules stay disabled; report discovery works with enterprise GCS access |
| 6. Production pilot | Two production Jobs maximum, strict telemetry concurrency, canary schedules, restore/rollback exercises | Representative incident and healthy checks; actual shared-stack latency/resource impact; operator dashboards/runbooks; verified retention and recovery objectives |
| 7. Optional expansion | Tested automatic resume, more templates/capabilities, metadata connectors, curated search | Each extension passes unchanged generic contracts, source policy and workload tests; no implicit credential or permission expansion |

Keep telemetry client fixtures and deterministic policy/compiler tests separate from LLM evaluations. They establish different properties. Do not use a plausible model narrative as evidence that query scoping, authorization or load protection works.

## Acceptance scenarios

Delivery: immutable JFrog digest reaches the rendered Deployment and worker-release config; an Argo deployment never runs an investigation. Terraform objects trigger runtime admission exactly by object finalization/reconciliation. A Pub/Sub topic update alone creates no task. Preview and deploy render with compatible Kustomize versions. Migration prerequisites exist before the hook runs.

Identity: approved worker GSA is accepted; wrong issuer/audience/expiry/subject is denied; worker cannot call a connector using its own subject even with that connector's audience. Gateway never forwards the worker token to the backend. Neither custom Pod token projection nor TokenReview permissions are accidentally reintroduced. Run IDs change correlation only, never class policy.

Query safety: every operator/template maintains all source constraints, including metadata routes. Tenant aliases, source labels, offsets, groupings and pattern parameters cannot expand scope. Unknown mappings fail closed. Saturated output remains partial. Cancellation and client timeout do not immediately free a slot for another expensive query while the old backend work may continue.

Load: exercise high active-series count, histogram bucket fan-out, selector expansion, Loki stream churn, dynamic parsed fields and many small concurrent requests. Measure upstream query latency/work and the impact on normal enterprise queries. Demonstrate global limits across replicas and environments. If backend input limits are unavailable, restrict the template set and document the residual ceiling instead of claiming returned-result caps solve the problem.

Analysis: known incident found with cited evidence; healthy conclusion requires coverage; missing/stale/quiet data is handled correctly; counters and histogram units are correct; contradictory evidence is retained; target-cluster state is never asserted as independently verified. Evidence redaction preserves enough meaning and source references to review a finding.

State: crash after SQL admission/before Job creation, duplicate controller reconciliation, duplicate Job Pods, lost Pub/Sub tick, schedule disable race, registry rollback, restore replay, interrupted worker and stale finalizer. Automatic checkpoint resume remains disabled until a stale writer cannot mutate any checkpoint/blob/pending-write table under a replacement generation.

Operations: test DLQ replay, SQL restore/PITR and roles, ingress/TLS/key refresh, redaction on exception paths, evidence expiry, credential reload for future backend connectors and release rollback with active old-version Jobs. No real credential data belongs in fixtures.

## Current framework research snapshot

Authoritative PyPI metadata checked on 18 October 2026:

| Package | Candidate release | Published UTC |
|---|---|---|
| Deep Agents | 0.7.28 | 16 October |
| LangChain | 1.4.6 | 14 October |
| LangGraph | 1.2.16 | 16 October |
| Postgres checkpoint package | 3.2.0 | 14 October |
| Google GenAI integration | 4.4.2 | 13 October |
| LangSmith SDK, optional | 0.14.11 | 16 October |

These candidates resolved together in a Python 3.12 wheel-only pip dry run, selecting 60 distributions, including LangChain core 1.6.12 and checkpoint core 4.3.0. This checks declared dependency compatibility, not imports, framework behavior or enterprise integrations. The [candidate snapshot](reference/framework-candidates.json) records the selected versions. Produce a complete production lock with hashes, then run framework assembly, checkpoint migration/resume, serialization, model/tool and security tests. Pin the same release for a run's lifetime. Adopt updates through dev evaluation and promotion, not `latest` installs. Deep Agents' framework maturity/operational fit must be demonstrated with these tests, not inferred from release recency.

Released Deep Agents and Postgres saver source distributions were checksum-verified and inspected for the material contracts. Current Deep Agents supports summarization, profiles, skills, prompt memory, local/remote subagents and explicit tool filtering; default tools are additive, and its documented permission checks are not backend-wide authorization. The Postgres saver uses a local lock/connection management, not a documented run-fencing protocol. No real model/backend/cluster integration was exercised during this design.

OSS LangGraph/Deep Agents do not require a LangSmith server, Redis or a remote Agent Server for this Job model. LangSmith/OTel instrumentation is optional and subject to data policy. First release uses typed HTTPS tool clients; do not mix incompatible MCP library major versions just to add a protocol not yet needed. If MCP is adopted, resolve and test its current server/client version set independently.

## Inputs still required before deployment

| Input | Proposed handling |
|---|---|
| Exact new repository names, owners, host and pipeline conventions | Use the four logical repositories; create through enterprise provisioning |
| Dev/prod topology and SLO/RTO/RPO | Review proposed defaults in the overview; don't promise shared-cluster independence |
| GKE region/node pools and metadata/network mode | Reuse existing platform; inspect actual eligible pools and private paths |
| Approved regional model and sanitization policy | Explicit allowlist; no global endpoint or vendor fallback |
| Loki/Mimir versions/routes/tenants/retention/limits/scale | User has not supplied these; source onboarding and load tests are a deployment gate |
| Actual stable labels and CI/CD source inventory | Require trustworthy selectors/component mapping before enabling a source |
| Existing internal PKI/mesh and signing-key egress | Use supported integration; no fabricated certificate authority |
| Enterprise GCS reader/audit/retention policy | Use existing corporate IAM; no harness human-login feature |
| Administrative drain/cancel operating path | Restricted Git/TF control registration proposed; review operator-only source and writer grants |

## Decision checkpoints after the first draft

The user confirmed: a dedicated Terraform module repository; regional Vertex AI with sanitized excerpts; both trigger types; GCS-only output; consumer-only telemetry; typed builders/templates; per-run memory and reviewed runbooks. Remaining platform details refine this design rather than reopening those decisions.

A second design review should decide the environment/SLO defaults, identity/project placement and source inventory. An implementation review should then approve actual module/provider/framework locks, rendered manifests and rollout evidence. No infrastructure deployment or modification of shared observability is implied by accepting this document.

## Sources and local checks

- [Deep Agents PyPI metadata](https://pypi.org/pypi/deepagents/json), [LangChain](https://pypi.org/pypi/langchain/json), [LangGraph](https://pypi.org/pypi/langgraph/json), [Postgres saver](https://pypi.org/pypi/langgraph-checkpoint-postgres/json), [Google integration](https://pypi.org/pypi/langchain-google-genai/json).
- [Argo CD Kustomize integration](https://github.com/argoproj/argo-cd/blob/master/docs/user-guide/kustomize.md), [ApplicationSet progressive sync caveats](https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/applicationset/Progressive-Syncs.md).
- [Google-maintained native GKE WIF module](https://github.com/terraform-google-modules/terraform-google-kubernetes-engine/blob/master/modules/workload-identity/main.tf), [ESO GSM identity delivery](https://github.com/external-secrets/external-secrets/blob/main/docs/provider/google-secrets-manager.md).
- [Loki limits](https://github.com/grafana/loki/blob/main/pkg/validation/limits.go), [Mimir limits](https://github.com/grafana/mimir/blob/main/pkg/util/validation/limits.go). Source inspection describes upstream capabilities, not installed enterprise configuration.

Local documentation/example verification results are recorded in [reference verification](reference/README.md). They are not deployment, backend-load or model-quality test results.
