# Generic harness runtime and agent design

## Kernel and capability boundary

The kernel accepts a goal and constraints, resolves an immutable capability release, executes a bounded investigation and produces an evidence-backed result. It understands task lifecycle, tool contracts, budgets, model invocation, state and reporting. It contains no branches such as `if task_is_argocd_incident`.

A capability pack contains reviewed skills/runbooks, analyst descriptions, typed tool descriptions, query templates or builders, evidence types, report schema and evaluations. Adding a capability follows the same CI, review and image-promotion path as code. The first pack is `pipeline-observability`; later ADO/JFrog/Argo metadata capabilities reuse the kernel.

| Extension | Contract | Enforcement |
|---|---|---|
| Task request | `TaskRequest/v1`: request ID, goal, capability version, parameters, time bounds, requested budgets | Dispatcher validates source registration and schema; requests can narrow configured behavior, not grant privileges |
| Capability | Manifest, skills, role descriptions, tool/schema versions and supported report kinds | Release-time validation; immutable pack bundled into an image initially |
| Tool | Name/version, typed input/output, supported resource aliases, read semantics and cost category | Gateway/connector, independently of agent prompts |
| Source inventory | Aliases to approved backend, tenant and actual ingestion scope; cadence and coverage | Environment-owned trusted configuration; unknown sources are denied |
| Model adapter | Explicit model/region, context/output limits, usage reporting and allowed fallbacks | Trusted runtime with aggregate token/call budget |
| Report | `InvestigationReport/v1`: findings, observations, evidence, limits, recommendations and outcome | Schema validation plus evidence-reference validation |

Pack selection does not change Google service identity permissions. All workers of an environment/class have the same gateway authorization; narrowed task parameters are execution intent. Mutually untrusted tasks or hard per-run data permissions require a later identity design decision.

## Processes and ownership

- Dispatcher: request/schedule admission, release resolution, run ledger, global worker slots, Job creation, cancellation and reconciliation. Two replicas coordinate in SQL.
- Worker: one parent Deep Agent plus bounded local specialists, LangGraph state/checkpoints, model calls, typed tool clients and artifact/report publication.
- Gateway: validate Google worker ID tokens, filter tool catalog by static class policy, validate requests, route calls and audit decisions. Optional OPA evaluates normalized policy facts.
- Connector: validate gateway ID tokens; enforce fixed source/operation policy; compile typed requests; coordinate backend query admission; call backend and normalize evidence.
- Migration Job: versioned schema migrations with a separate identity and DDL role. Runtime identities do not run `checkpointer.setup()` or create schemas at startup.

No generic remote code execution, host filesystem browsing, arbitrary HTTP proxy, runtime package installation or model-created plugin is exposed. Typed LangChain clients call private HTTPS JSON services. An MCP facade can expose the same handlers later without changing identity or policy. Remote/background subagents require a separate execution server and are deferred.

## Request and schedule lifecycle

Ad-hoc path: reviewed request file → Terraform immutable GCS object → `OBJECT_FINALIZE` notification → Pub/Sub pull → dispatcher. Fetch the exact object generation, validate its digest/schema and registration path, then transactionally insert the run and pending-launch outbox before acknowledging Pub/Sub. The source bucket/prefix determines allowed configuration; request metadata cannot attest its uploader or grant access.

Pub/Sub notification retries, duplicate objects and concurrent dispatcher replicas must converge on one logical admission. `UNIQUE(request_id)` stores the admitted payload digest. Same ID/same content is a duplicate; same ID/different content is rejected. A deliberate rerun gets a new ID. A deterministic Job name and SQL outbox/reconciler recover crashes between SQL commit and Kubernetes creation. Verify an existing Job's recorded UID/template after create conflicts.

Scheduled path: Terraform publishes an immutable schedule-registry generation and current pointer. Dispatcher imports a newer revision with compare-and-set into SQL. One UTC minute heartbeat wakes due-time evaluation; tick publish time is not the occurrence identity. In one transaction against the current active registry, admit `UNIQUE(schedule_id, nominal_due_utc)` and advance its cursor. An old tick or registry replay cannot undo a disable. Periodic SQL reconciliation covers lost ticks.

Default scheduled behavior: no overlap for the same schedule; latest eligible occurrence only; skip older missed occurrences outside a declared grace. Record skipped/coalesced occurrences. Disabling prevents future admissions; cancellation separately stops a current Job. Introduce local-time/DST schedules only with explicit tested semantics.

Proposed run states: `ADMITTED → LAUNCH_PENDING → RUNNING → FINALIZING → SUCCEEDED | PARTIAL | FAILED | CANCELLED`. Capture `EXPIRED` before launch and `INTERRUPTED` when execution is lost. SQL is the execution ledger. GCS immutable report objects are the published result, with their generation/hash referenced by the ledger. Use compare-and-set for terminal publication so stale attempts cannot replace the result.

If a worker dies before reporting, the dispatcher/finalizer publishes a machine-generated interrupted/partial report from known ledger/artifact metadata. It lists the failure and available references without inventing completed analysis. Report-object creation and SQL finalization are separate idempotent steps; reconcile orphan/candidate objects, and make the canonical result/index refer only to the accepted terminal generation. A stale worker may leave a candidate object but cannot win the terminal compare-and-set. Grant the finalizer scoped report creation/lookup rights, not backend-query credentials.

The dispatcher pins image digest, capability/skill version, requested source-map revision, tool catalog/API version, model ID/region and task parameters at admission. It records the policy revision observed at admission for reproducibility, not as a frozen permission grant. Current server-side class restrictions and shared ceilings always apply to every worker, including already admitted tasks. Tool results identify the actual source/policy revision used. If the requested inventory/API version is no longer compatible, return an explicit limitation rather than silently remapping sources. New runtime/skill/model/checkpoint settings affect future admissions; old tasks finish under compatible services or stop explicitly.

## Persistent data contracts

| Entity | Key fields and invariants |
|---|---|
| Request admission | Unique request ID, canonical payload hash, exact source object generation; compact replay tombstone outlives payload |
| Run | Run ID, immutable normalized task/release snapshot, trigger identity, state, deadline, active attempt, result generation/hash |
| Attempt | Run/attempt IDs, Kubernetes Job name/UID, execution generation, state, heartbeat/lease and failure classification |
| Launch outbox | Unique run/attempt pending action; reconciliation marks the recorded Kubernetes effect |
| Schedule registry/cursor | Authoritative imported GCS pointer generation, enabled template, nominal due cursor; unique schedule/occurrence |
| Query reservation | Backend scope, verified caller class, source/operator fingerprint, slot/expiry, completion/cancellation and usage |
| Model usage | Run/call IDs, model/price revision, reserved and observed tokens, retry/fallback state; aggregate specialists share budget |
| Artifact manifest | Run/evidence IDs, allowed bucket/key, object generation/hash, source/time/coverage/redaction revision and expiry |
| Checkpoints | Official saver tables and migrations in a separately authorized schema; never assume its columns match the run ledger |

Do not hold database transactions open while waiting for model/backend HTTP calls. Admission/finalization/budget reservations use short atomic operations and idempotent reconciliations. Authenticate service classes at API boundaries; execution IDs in this data model are not new security principals.

Artifacts use immutable names such as `evidence/<environment>/<run>/<attempt>/<evidence-id>.jsonl` and `reports/<environment>/<run>/<report-id>.json`. Write with create-only generation preconditions and publish object generation/hash in the manifest. A small bounded report index makes reports discoverable through existing GCS access; it is not a new UI or automatic knowledge store. Cleanup removes expired artifacts and index references consistently.

## Planning and agentic behavior

The parent chooses relevant skills, decomposes the question into hypotheses and bounded evidence requests, delegates where useful, reconciles contradictory evidence and validates the final result. A multi-agent feature does not require spawning every specialist on every task.

For the telemetry pack, metrics analyst and logs analyst may run concurrently; an evidence reviewer runs after collection. Initially allow two simultaneous specialist/model calls per Job and three named specialist roles. Local specialists have separate contexts but share Pod identity and common budgets. Role/tool visibility helps relevance; it is not a security boundary.

The parent must decide whether additional evidence can change the conclusion. Stop on supported answer, exhausted data coverage, tool/model budget, deadline, repeated nonproductive queries or unavailable dependencies. A schema-valid output is not proof of correct analysis. Findings need source references, limitations and an explicit distinction between observation, supported explanation and unproven hypothesis.

No interactive approval path is enabled. If clarification is essential, publish `needs_input` with the precise missing information and partial evidence, then terminate the Job. A subsequent reviewed task can reference the prior report. Do not leave a LangGraph interrupt waiting indefinitely in an expensive Kubernetes Job.

## Context, filesystem and memory

| Layer | Initial implementation | Rules |
|---|---|---|
| Working context | LangGraph state and Deep Agents summarization | Structured facts, current plan, hypotheses and compact evidence references; cap messages/tool payloads |
| Durable per-run state | Cloud SQL PostgreSQL official checkpointer | Stable thread per run; runtime/serializer version pinned; controlled migrations and safe deserialization |
| Virtual working files | Deep Agents `StateBackend` | Bounded virtual files; store skill content at declared virtual paths; no OS-token/certificate mounts exposed |
| Large evidence | GCS objects and an evidence manifest | Stream bounded sanitized content; reference exact generation/hash; paginated bounded evidence reads |
| Reviewed knowledge | Git skill/runbook files packaged in release | Read-only and versioned; distinguish operating instructions from retrieved log text |
| Retained reports | Searchable evidence metadata | Cite original run/coverage/age; previous conclusions are not automatically current facts |
| Cross-run learning | Disabled | Later bounded PostgresStore with provenance, scope, TTL, deletion and review policy if justified |
| Semantic/vector memory | Deferred | No vector database or embeddings required for the first release |

Deep Agents' `memory=` loads memory instruction files into the prompt; it is not a substitute for a durable checkpointer or a governed cross-run knowledge store. Its skills and memory files also consume context and must be versioned/bounded. GCS is used through explicit artifact tools, not assumed to be a built-in filesystem backend.

Route reviewed skill/runbook/memory paths through an immutable read-only backend wrapper; reject writes there independently of model instructions and tool-level permission configuration. Only per-run scratch paths are writable. Skill-source paths and override ordering are deployment-owned, so a writable scratch directory cannot shadow a reviewed skill. The wrapper is a small backend adapter, not a replacement agent loop, and needs framework-version compatibility tests.

Current Deep Agents exposes default filesystem and delegation tools; `tools=` adds tools. Explicitly disable/remove unnecessary defaults using supported profile/tool filtering and test the resulting catalog. Use a non-sandbox backend; an unusable `execute` tool is less clear than excluding it. Filesystem permission rules currently apply at tool level, are first-match/default-allow and can be replaced by a subagent override. Server-side tool policy remains the enterprise boundary.

Proposed initial model budgets: at most 20 model calls, 80,000 aggregate input tokens and 12,000 output tokens per run; at most two in flight. Fit each individual context to the approved model and a smaller operational ceiling, initially 24,000 tokens where feasible. These are pilot settings to tune with representative tasks. Reserve budgets before calls, account actual usage afterward, and include in-flight reservations. Retry/fallback cannot reset budgets. Model pricing, unavailable token accounting and in-flight work mean a dollar estimate is not an exact instantaneous billing cap.

Sanitize logs before model input and storage; avoid copying whole returned data sets into prompts. Summaries retain source references and uncertainty. Never persist hidden chain-of-thought as evidence. No access tokens, SDK credential clients, private keys or authentication headers may enter messages, checkpoints, tool outputs or traces.

## Recovery and checkpoint ownership

LangGraph persistence does not itself fence multiple processes writing one thread. SQL execution leases and a deterministic Job name also do not automatically protect the stock Postgres saver. Kubernetes can briefly duplicate Pods or leave a partitioned old process running.

Pilot default: `restartPolicy: Never`, `backoffLimit: 0`; an interrupted run publishes an explicit incomplete/interrupted outcome. Retain checkpoints, but do not automatically launch another writer against the same thread. A new investigation may reference the prior evidence under a new run ID.

Automatic resume is a separately gated feature. Before enabling retries/resume, implement and test a checkpoint adapter that validates the execution generation/lease in the same database transaction as every checkpoint/blob/pending-write mutation, or choose another demonstrated exclusive-writer mechanism. A lock held on one pooled connection while writes occur on others is insufficient. Stale writers and stale final-result publishers must fail. Migrations must cover the saver's actual tables and serializer format; do not assume a process-local saver lock is distributed fencing.

Model/tool reads may repeat after recovery; count cost and preserve duplicate evidence provenance. Never promise exactly-once external reads or model billing.

## Tool/result contract

The model supplies typed domain intent. Trusted clients add bearer credentials, correlation IDs and deadlines outside the tool schema. Gateway/connector URLs, tenant headers, secret references and credentials are deployment configuration.

Return `ok | partial | denied | unavailable | invalid_request | budget_exhausted` with bounded data, source/config revision, effective time interval, collection time, freshness, warnings, pagination/truncation and evidence IDs. An empty result is not a healthy-system conclusion. Tool content remains untrusted data for every subsequent call.

Every tool has a schema and read-semantics review, test fixtures, timeouts, retry policy, maximum output and cost/admission category. Backend redirects and arbitrary URLs are rejected. Bind tool API versions explicitly; new tools require deployment and evaluation rather than agent-generated execution code.
