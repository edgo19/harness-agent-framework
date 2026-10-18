# GCP platform, authentication and operations

## Placement and initial capacity

Reuse the existing observability GKE cluster; first inspect its location, topology, quotas, node allocatable capacity, metadata-enabled node pools and network enforcement. Do not create a duplicate monitoring stack or assume a dedicated new cluster. Dev and production have separate namespaces, identities, state and resource budgets. A shared cluster is a shared failure domain.

| Resource | Production proposal | Dev / scaling |
|---|---|---|
| Dispatcher | 2 replicas, each 250m CPU / 512 MiB | 1 dev; 2–4 prod when admission backlog justifies it; SQL still caps Jobs |
| Worker Job | 1 vCPU / 2 GiB requested, up to 2 vCPU / 4 GiB; 2–5 GiB scratch | 1 dev / 2 prod active; raise only after load test; no local GPU |
| Gateway | 2 replicas, each 500m CPU / 1 GiB | 1 dev; scale on latency/in-flight calls without multiplying backend budget |
| Telemetry connector | 2 replicas, each initially 500m CPU / 512 MiB | 1 dev; bounded parsing and response buffers; global backend slots |
| Optional OPA | Local sidecar; reserve separately, initially about 100m CPU / 128–256 MiB | Validate actual policy memory; not a new central auth service |
| Cloud SQL PostgreSQL | Explicit Enterprise edition, supported approved PostgreSQL 17 or validated alternative; 2 vCPU / 8 GiB, 50 GiB SSD, regional HA, growth cap 200 GiB | Zonal smaller dev instance around 1 vCPU / 4 GiB where supported; separate DB roles and budgets |
| Connection pools | Worker 2–4; dispatcher/gateway/connector small bounded pools; initial total under 50 plus maintenance reserve | Proxy is not a connection pool; avoid a permanently running sidecar keeping a completed Job alive |
| Pub/Sub | Separate request and tick subscriptions plus DLQ/triage; 7-day retention; bounded backoff | Managed; acknowledge after SQL admission, not after the investigation |
| Cloud Scheduler | One same-project native Pub/Sub heartbeat, initially every minute UTC | SQL decides due occurrences; no OIDC caller identity for this native target |
| GCS | Separate request/config/evidence/report buckets, regional, uniform access and public access prevention | Retention/lifecycle by data class; no GCS FUSE requirement |
| Vertex AI | Approved explicit regional model, consumption-based pilot, token/concurrency budgets | No automatic model/region fallback; quotas and availability constrain concurrency |

Requests/limits are estimates, not observed cluster headroom. Account for all replicas, OPA/SQL proxies, system overhead and dev/prod together. Begin with namespace quotas and lower worker priority than essential observability services. A dedicated autoscaling node pool is a later platform-owner decision if isolation/headroom requires it, not an initial prerequisite. Do not raise worker count simply because CPU is free while backend/model quotas are saturated.

## Simplified authentication and authorization

Worker KSA → worker GSA through native GKE WIF → metadata-issued Google ID token with exact gateway audience → gateway validates signature/Google issuer/time/audience and allowed numeric GSA `sub` → fixed CI/CD tool/resource policy.

Gateway KSA → gateway GSA → another Google ID token for the specific connector audience → connector validates the gateway subject → operation/resource checks → backend request. Each receiver performs application middleware validation; a private Service is not an automatic JWT verifier. Tokens are obtained and refreshed by supported libraries, not Terraform or the model.

All workers sharing a GSA share its gateway authority. A `run_id` is audit/accounting context; it cannot securely select a narrower or broader permission set. There is no TokenReview integration or per-Pod authorization mapping. The execution ledger and checkpoint ownership controls address lifecycle/reliability, not new caller permissions.

OPA, if used, evaluates trusted validated identity plus normalized tool/source/operator facts. It does not issue tokens, discover run ownership, keep atomic counters or safely parse arbitrary query strings. Default deny; gateway enforces decisions and connector compilers enforce the actual query scope. Kubernetes admission/Gatekeeper is a separate use for image/SA/volume constraints.

## Terraform GCP identity and resource ownership

| Principal/resource | Required configuration |
|---|---|
| Worker GSA per environment | Exact KSA member has `roles/iam.workloadIdentityUser` on that GSA; worker hosting grants separately |
| Gateway GSA per environment | Its own exact KSA member has the same binding; permitted subject in connector configuration |
| Dispatcher/finalizer GSA | Narrow Pub/Sub subscriber, request/config read, SQL connection/IAM login, lifecycle SQL rights and scoped report creation/lookup for reconciliation/interrupted reports |
| Migration GSA | SQL connection/login and separately controlled schema migration rights; absent from worker namespace |
| Connector KSA | No GSA solely for JWT verification or mounted credentials; add a GSA only for an actual Google function, such as budget SQL |
| Budget-service identity | SQL connection/IAM login plus budget procedures only where gateway/connector coordinates quotas in SQL |
| Existing ESO identity | `roles/secretmanager.secretAccessor` on the individual approved secrets; preserve platform-owned WIF configuration |
| GKE workload pool and metadata server | Reuse `GKE_PROJECT_ID.svc.id.goog`; verify eligible node pools; no generic new WIF pool/provider |
| APIs | Verify IAM, IAM Credentials, STS and hosting APIs through their existing Terraform owner; do not manage one API resource in two states |

Worker hosting permissions: approved Vertex invocation (`roles/aiplatform.user` only as a reviewed starting role or a tested narrower custom role), `roles/cloudsql.client` and `roles/cloudsql.instanceUser` plus checkpoint SQL grants, and scoped evidence/report object creation/read as required. Google IAM login is not SQL table authorization. Runtime does not have unrestricted schema ownership.

The proposed shared-backend query coordinator uses a dedicated budget database/schema on the production HA SQL instance. Dev and prod telemetry service identities can execute only its reservation procedures; no dev process receives production run/checkpoint schema privileges. This is separate from gateway identity verification. Dev uses offline fixtures until that cross-environment budget path is provisioned and tested. Coordinate SQL instance connection privileges with database-level CONNECT/schema grants, not only GCP IAM.

For GSA linkage, use `google_service_account` and `google_service_account_iam_member`. Bind `roles/iam.workloadIdentityUser` to `serviceAccount:GKE_PROJECT_ID.svc.id.goog[NAMESPACE/KSA]`; Argo creates the matching KSA annotation. Pass GSA email and `unique_id` into reviewed CD configuration. No downloaded GSA key or additional broad TokenCreator grant is required for this metadata path. GCP roles such as Cloud Run invoker do not protect the custom GKE HTTP services.

Cloud SQL, GCS, messaging, heartbeat and model permissions are harness hosting resources, not CI/CD infrastructure investigation access. No broad Azure/GCP viewer or target-cluster role is added for the first capability.

## TLS, network and workload controls

Serve gateway/connector HTTPS using approved enterprise PKI or an existing mesh; certificates must match the configured service names and clients trust the approved CA. If no existing mechanism is available, certificate provisioning is an explicit platform prerequisite. Google ID tokens are independent of server certificates. Do not silently fall back to HTTP or skip validation. Internal Loki/Mimir retain their existing agreed protocol/access model.

Reuse existing Shared VPC/private routing, Private Google Access or approved private API connectivity, DNS and controlled signing-key egress. A Cloud SQL connector authenticates/transports the connection but does not create private network routes. New NAT, PSC endpoints, VPN or CA services are conditional platform changes, not automatic harness dependencies. Use enterprise encryption-at-rest standards; reference existing CMEK keys if required rather than introducing an application token-signing key. Validate image architecture and dependency wheels against the actual execution node pools.

Default-deny NetworkPolicy plus exact allowed paths: workers to gateway, model/checkpoint/artifact services, metadata and DNS; gateway to connectors and required token/key/budget endpoints; telemetry connector to the existing query services. Workers cannot bypass to Loki/Mimir or credential-bearing connectors. Allow the documented metadata path for the installed GKE dataplane and Google signing-key retrieval. Standard NetworkPolicy filters network selectors, not JWT identity or URL paths.

Protect workload creation: dispatcher has namespace-scoped Job create/get/list/watch and necessary Pod observation; deletion only for implemented cancellation. It cannot change Secrets/KSAs/RoleBindings. Job-create authority can select privileged identities/volumes, so admission fixes allowed image digests, worker KSA, command, security context and volume types. Worker namespace contains no connector Secrets. All processes are non-root, no host mounts/namespaces/privileged/exec tools, bounded scratch and restrictive filesystem permissions.

## Secrets and data handling

Reuse corporate TF → GSM → existing ESO → explicit Kubernetes Secret → connector volume. Workers/gateway do not mount backend credentials. A connector needs no Kubernetes Secrets get/list/watch merely to consume a mounted Secret. Restrict ExternalSecret/store editors: a namespaced store does not narrow the shared ESO identity's GSM authority.

The telemetry-only release needs no ADO/JFrog/Argo credential mount. Their extension interfaces and approved rotation path are designed now; enable mappings only when the corresponding connector is deployed. ADO uses its SP certificate and ADO authorization, not Google-to-Entra federation. Separate Argo instances never implicitly share credentials.

Normal Secret volumes update eventually; environment variables and `subPath` do not hot-reload. Rebuild Azure certificate credentials/clients on rotation and replace cached token headers safely. Monitor ESO refresh age and actual new-credential uptake; source version disablement does not revoke previously issued access tokens or in-memory copies. Ordinary Terraform secret payload fields persist in protected state; use the existing approved module pattern and write-only fields only when supported by the pinned toolchain.

Sanitize before model input, evidence storage and telemetry export. Preserve redaction-policy revision and original source/time references. Treat goals, logs, reports, checkpoints and Terraform state as potentially sensitive. GCS output access uses existing enterprise IAM; the harness does not add a human authentication portal. Do not put signed URLs/tokens in broadly visible logs.

## Harness observability without adding cardinality

Reuse Alloy and the existing logs/metrics stack. Expose bounded `/metrics` endpoints and structured stdout. Confirm collection includes the harness namespaces; deployment does not assume a collector automatically discovers them. Detailed tracing is optional through an existing approved OTel backend; neither LangSmith SaaS nor a new trace database is required.

Metrics: queue age, admission/launch latency, active/terminal runs, schedule reconciliation lag, model tokens/cost estimate, query admission wait, in-flight backend queries, duration, returned/scanned bytes where available, rejection/429/timeouts, coverage freshness, evidence/report failures, SQL pool wait and credential reload errors.

Allowed metric labels are bounded dimensions such as environment, service, backend, approved operation class and outcome. Run/request/thread/query IDs, raw tool names from arbitrary input, SQL text, URLs, model responses and exception messages belong in scrubbed logs, not labels. Distinguish `source_id` inventory growth from an unlimited free-form label; cap/review it or keep it in logs. Error codes are a finite enum. Never attach full queries/excerpts to trace attributes by default.

Short-lived Jobs can finish between scrapes. Persist terminal accounting in SQL and expose cumulative metrics from a long-running service. Restart-safe monotonic accounting avoids a Pushgateway dependency and misleading loss of completed runs. Report both query result size and backend work where measurable; one does not substitute for the other.

Alert on backlog age, repeated admission failure/DLQ, missed schedule import, backend saturation/circuit-open, stale source coverage, checkpoint errors, model quota/cost anomalies and shared-cluster contention. Provision alert rules through the existing owners; runtime agents do not edit them. If collection changes require approval, production acceptance waits for verified harness collection rather than inventing a second stack.

## Retention, recovery and operational procedures

Proposed evidence 30 days, reports 90 days, checkpoints 30 days after terminal state and audit metadata 365 days. Delete associated state/artifacts using an explicit cleanup job and record outcome. Keep opaque request-ID/digest tombstones beyond any replay horizon; do not retain full prompts forever just for deduplication. Terraform-managed request objects are deliberately retired before lifecycle expiry. Backups have separate retention and deletion semantics.

Regional HA SQL, tested backups and 7-day PITR are proposed production defaults. Exercise restore into a new instance and reconstruct IAM users, SQL roles, configuration and artifact references. GCS versions/retention protect report recovery but do not restore compute. A regional outage remains an approved manual recovery process with region/data-policy review; do not advertise automatic multi-region recovery.

Operational runbooks cover admission pause/drain, cancellation, DLQ replay with ID/hash checks, backend circuit reset, model outage, SQL restore, expired evidence, credential rollout and release rollback. For ordinary noninteractive cancel/pause, reviewed infra-live control files create `ControlRequest/v1` objects in a separate operator-writable source; the dispatcher validates, deduplicates and executes them. Restore/credential break-glass retains the enterprise platform process. Cancellation stops a Job and prevents ordinary terminal publication; the gateway's class identity model does not revoke a single run token. Already authorized in-flight queries may finish and are still bounded by backend/global controls.

Suggested objectives: production admission availability 99.5% monthly; accepted requests start within 2 minutes under the validated pilot workload; normal targeted report within 15 minutes. Dependency outages/insufficient data yield explicit partial/unavailable outcomes. Platform RTO 4 hours and restore RPO 15 minutes are objectives to validate, not guarantees inferred from HA settings.
