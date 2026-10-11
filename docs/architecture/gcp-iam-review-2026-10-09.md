# GCP IAM and workload identity review — 2026-10-09

> Baseline research. The [11 October phase-1 scope](harness-phase1-scope-2026-10-11.md) and [ESO/credential review](phase1-eso-security-2026-10-11.md) govern current grants: ESO reads the explicit GSM secrets; connectors use mounted credentials; ADO uses its SP certificate; Loki/Mimir use internal read endpoints. Application deployment target clusters and their telemetry are excluded; broad cloud investigation roles and Grafana access are deferred. GCP permissions for operating the harness remain separate.

Scope: architecture review only. No GCP tenant, project, cluster, Azure tenant or enterprise backend credentials were available; no IAM grant or deployment was made. Official Google/GitHub sources and Terraform provider sources were inspected. Direct Google Cloud documentation and IAM API requests were blocked by the research environment's egress proxy, so source citations distinguish verified code examples from role-reference recommendations that must be confirmed during implementation.

## Proposed topology and assumptions

- Existing enterprise CI builds immutable image digests into private JFrog; Argo CD deploys the harness onto GKE from the CD repository.
- Terraform/Terragrunt provisions infrastructure and append-only ad-hoc request objects in GCS. `OBJECT_FINALIZE` notifications publish into an ad-hoc Pub/Sub topic.
- Cloud Scheduler publishes native Pub/Sub wakeup messages into a **separate schedule-ticks topic**, in the same GCP project as its Scheduler job. The dispatcher uses deployed cron/timezone configuration and a durable SQL `next_due` cursor to create logical occurrences identified by `(schedule_id, nominal_due_utc)`; it does not infer occurrence identity from Pub/Sub message IDs or assume static Scheduler payloads are unique.
- Separate pull subscriptions and a dead-letter topic feed a GKE dispatcher. No HTTP submission adapter or public runtime endpoint is required.
- The dispatcher stores accepted runs in PostgreSQL, then creates Kubernetes Jobs from fixed templates. Reconciler/outbox logic bridges the SQL transaction to Job creation; Pub/Sub is acknowledged after durable acceptance, not after an arbitrarily long investigation.
- Cloud SQL PostgreSQL holds the run ledger, LangGraph checkpoints, and optional LangGraph store in separate databases/schemas and SQL roles. GCS holds request objects, evidence and reports. Firestore is not needed initially.
- Only read operations against enterprise backends are allowed. Writing runtime state, reports and telemetry is of course required.
- Secrets are read by the actual connector/MCP workload; the LLM never receives token values. Using a separate backend gateway/MCP deployment keeps secrets and broad backend API capabilities out of the agent Job.

## Runtime identity and permission matrix

| Principal | Minimum role / permission | Grant scope and reason |
|---|---|---|
| Dedicated request-submission pipeline GSA | Custom `storage.objects.create`, `storage.objects.get`; optionally `storage.objects.list` if module tooling requires enumeration | Request bucket only, preferably a separate bucket per environment. Alternatively combine `roles/storage.objectCreator` and `roles/storage.objectViewer`; the latter grants enumeration. No delete means existing object names cannot be overwritten. |
| Infrastructure/CD pipeline GSA | Resource-specific provisioner roles; see provisioning section | Dedicated harness project, narrowly scoped host-project grants for Shared VPC. Do not reuse this identity for ordinary request registration. |
| Cloud Storage service agent `service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com` | `roles/pubsub.publisher` | Ad-hoc notifications topic only. Grant before creating the bucket notification. Use `google_storage_project_service_account` to initialize/obtain the exact agent email. |
| Cloud Scheduler service agent `service-PROJECT_NUMBER@gcp-sa-cloudscheduler.iam.gserviceaccount.com` | Keep automatically provisioned `roles/cloudscheduler.serviceAgent` | Scheduler project. It publishes native Pub/Sub targets; the managed agent role includes necessary publishing capability. Keep the tick topic in that same project. There is no configured OIDC caller GSA for a native Pub/Sub target. |
| Dispatcher KSA → dedicated dispatcher GSA | `roles/pubsub.subscriber` | Only the ad-hoc and schedule-ticks subscriptions; no project-wide publisher or subscriber grant. |
| Dispatcher GSA | `roles/storage.objectViewer` | Request/configuration buckets only; validate bucket/name/object generation and configured task scope. |
| Dispatcher GSA | `roles/cloudsql.client`, `roles/cloudsql.instanceUser` | Harness Cloud SQL instance/project with IAM Conditions restricting instance if using project bindings. IAM DB user plus SQL privileges are also required. |
| Agent worker KSA → worker GSA for a specific environment/data boundary | `roles/cloudsql.client`, `roles/cloudsql.instanceUser` | Same instance (or its separate environment instance), SQL user restricted to checkpoints/store for that boundary. Worker must not be ledger/schedule administrator. |
| Agent worker GSA | `roles/storage.objectCreator`; add object read only if evidence reuse requires it | Evidence/report bucket or run-specific permitted prefix. Write unique immutable names. No report delete permission. If a workspace requires overwrite, give a separate workspace bucket narrowly scoped `roles/storage.objectUser`, not the immutable reports bucket. |
| Agent worker GSA | `roles/aiplatform.user` as documented practical starting role, or a tested custom model-invocation role centered on `aiplatform.endpoints.predict` | Dedicated Vertex AI project; the predefined role is broader than just inference. Validate the exact selected Gemini/publisher model, token-counting/streaming and embedding APIs before claiming a minimal custom permission set. No Vertex model training/deployment IAM should be needed for managed model APIs. |
| Backend gateway/MCP KSA → connector GSA per environment/system where useful | `roles/secretmanager.secretAccessor` | Individual backend token/certificate secrets only. Workers and dispatcher do not need this if all backend calls pass through the gateway. |
| Connector GSA for GCP tools | Service-specific read permissions | Target project/database/log view/cluster scope; examples below. These are separate from harness infrastructure permissions. |
| Pub/Sub service agent `service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com` | `roles/pubsub.publisher` and `roles/pubsub.subscriber` | Publisher on the DLQ topic; subscriber on each source subscription with dead-letter policy. Both are needed for forwarding to function correctly. |
| OTel collector KSA → telemetry GSA | Native OTLP: `roles/telemetry.writer` (current official LangGraph sample), plus `roles/monitoring.metricWriter`, `roles/logging.logWriter` as that sample specifies | Observability destination project. For a traces-only OTLP exporter, official GKE sample verifies narrower `roles/telemetry.tracesWriter` (`telemetry.traces.write`). Validate selected signal/API combination during implementation. |
| GKE node GSA | `roles/container.defaultNodeServiceAccount` | Cluster project for current minimum node operation/telemetry baseline. Never give the node SA enterprise backend credentials. Additional managed metrics/resource metadata grants depend on actual enabled agents; do not copy an entire module's optional grants blindly. |
| Secret-to-Kubernetes image-pull credential controller, if used | `roles/secretmanager.secretAccessor` | JFrog pull-token secret only. It also needs tightly scoped Kubernetes Secret write permissions for the designated pull Secret. |
| Operator/report-reader groups under existing enterprise access control | `roles/monitoring.viewer`, `roles/logging.viewer` or `roles/logging.viewAccessor`, `roles/cloudtrace.user`, `roles/storage.objectViewer` | Only harness metrics, logs/views/traces and report buckets. Reserve `roles/logging.privateLogViewer` for authorized access to private/Data Access audit logs. Human observation is through existing corporate systems, no harness SSO app is required. |

Do not grant `roles/iam.serviceAccountTokenCreator` globally to runtime service accounts. It is **not** required just to use the GKE KSA → GSA mapping below. Do not give `roles/pubsub.serviceAgent`, `roles/cloudscheduler.serviceAgent`, or other managed service-agent roles to application GSAs.

## Workload Identity Federation for GKE

Use a dedicated KSA for dispatcher, each worker environment boundary, connector and telemetry collector. Cloud SQL IAM authentication and the Google-issued assertion for Entra make mapping selected KSAs to explicit Google SAs the easiest initial consistent pattern:

1. Enable the GKE workload pool `PROJECT_ID.svc.id.goog` and metadata server.
2. On the chosen GSA grant `roles/iam.workloadIdentityUser` to `serviceAccount:PROJECT_ID.svc.id.goog[NAMESPACE/KSA]`.
3. Annotate the KSA `iam.gke.io/gcp-service-account: GSA_EMAIL`.
4. Libraries use ADC/metadata-derived short-lived credentials. No downloaded GSA JSON key.

For services accepting direct WIF principals, grants can instead target:

`principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/NAMESPACE/sa/KSA`

The current Google Secret Manager CSI provider example verifies this direct-principal pattern. Direct KSA access and GSA impersonation are alternatives, not requirements to configure both for every service.

Avoid same namespace/KSA names across mutually untrusted clusters sharing one workload pool/project: identity is generally project/pool plus namespace/SA, not automatically one particular cluster. Use distinct projects, namespaces/KSAs or appropriate identity constraints where cluster separation must form a trust boundary.

External enterprise pipeline WIF is a separate trust configuration (GitHub/ADO issuer, repository/branch/environment conditions). Bind its federated subject to `roles/iam.workloadIdentityUser` on the particular pipeline GSA. It must not be able to impersonate all runtime GSAs.

## Kubernetes RBAC is an additional boundary

Dispatcher namespace Role needs `create/get/list/watch` Jobs in `batch`, and `get/list/watch` Pods as required for reconciliation. Grant `delete` Jobs only if cancellation/cleanup is implemented; Kubernetes TTL controllers can perform normal retention. Grant pod-log read only if actually used; prefer central Logging. Dispatcher has no permission to change KSAs, RoleBindings, deployments, secrets or config maps. Worker KSA has no Kubernetes API roles and ordinarily `automountServiceAccountToken: false`.

**Job-create permission is privileged.** A creator can select an arbitrary `serviceAccountName`, image, command, volume or secret inside its namespace; ordinary Kubernetes RBAC does not restrict those Job spec fields. Enforce fixed allowed image digests, KSAs, commands, volume types and security settings with ValidatingAdmissionPolicy/Gatekeeper/Policy Controller or an equivalent admission control. Isolate execution identities/namespaces by environment and data sensitivity. The dispatcher is trusted control-plane code; the model must never get the dispatcher's API client or a `kubectl`/Job-create tool.

Apply Pod Security restrictions, non-root/read-only container root filesystem, resource limits, no host namespaces/host mounts, and namespace NetworkPolicies. Keep Deep Agents virtual filesystem separate from mounted credential files. Disable shell/code execution initially; if later needed, use a separate sandbox without privileged worker credentials or Kubernetes API access. Logical subagents in the same process are not independently protected identities.

## Cloud SQL authentication and database rights

Cloud SQL Connector/Auth Proxy uses ADC and needs `roles/cloudsql.client` (`cloudsql.instances.connect`, `cloudsql.instances.get`). Automatic IAM DB auth additionally needs `roles/cloudsql.instanceUser`, IAM auth enabled on the instance, and a registered `CLOUD_IAM_SERVICE_ACCOUNT` user. PostgreSQL username is the GSA email with `.gserviceaccount.com` removed.

Use IAM auth plus an application SQL role scoped to required schemas. Google IAM permission to connect does not grant PostgreSQL table access. Dispatcher ledger user, agent checkpoint/store user, migration user and human break-glass user must be separate. Run LangGraph saver/store setup/schema migrations from the reviewed deployment migration Job, not every worker startup; runtime users should not own unrestricted databases. Use TLS via connector/proxy and **private IP connectivity**, which must already exist; the connector does not create network routes.

If IAM auth integration with psycopg pool/selected LangGraph Postgres saver is not straightforward, a restricted database password in Secret Manager is a workable fallback, with rotation; do not put credentials in graph state.

## Enterprise backend authorization

| Backend | Workload authentication | Authorization required |
|---|---|---|
| GCP resource APIs | Connector GSA ADC | Custom get/list permissions or selected viewer roles on relevant projects/resources, e.g. `roles/compute.viewer`, `roles/container.clusterViewer` for cluster discovery, `roles/datastore.viewer` only for explicitly permitted Firestore database data. Do not treat a generic Viewer role as sufficient or appropriately narrow for all data. |
| GKE Kubernetes API data | GSA/KSA identity authorized by target cluster | Namespace-specific Kubernetes Role for read deployments, pods, events, Jobs and relevant workloads; no Secrets read, exec, patch, create or delete. Cloud IAM cluster visibility alone is not the entire authorization model. |
| Cloud Logging investigation | ADC | Prefer `roles/logging.viewAccessor` on an approved filtered Log View. Project `roles/logging.viewer` is wider; private/Data Access audit logs need explicit additional authority. |
| Cloud Monitoring investigation | ADC | `roles/monitoring.viewer` in the monitored target project(s), separate from telemetry writer identity. |
| Azure resource APIs | Entra application credential via Google → Entra WIF | Azure `Reader` on specific resource groups/subscriptions/resources, plus explicitly needed data-plane permissions. No Directory.Read.All or user directory synchronization is needed. |
| AKS workload data | Entra workload identity token and AKS supported auth | Appropriate Azure Kubernetes Service RBAC Reader on selected namespace where Azure RBAC enabled, or Kubernetes namespace Role if Kubernetes RBAC. Avoid admin kubeconfigs. |
| Azure DevOps API/Git | Entra service principal via WIF; token for `https://app.vssps.visualstudio.com/.default` | Service principal added to ADO organization, correct access level (Basic for private Azure Repos) and explicit read permissions on selected projects/repositories/builds. ADO does not authorize using Entra application API permissions. |
| Self-hosted JFrog APIs | Supported deployed token-exchange mechanism if configured, otherwise dedicated scoped read token in Secret Manager | Repository/path/purpose read scopes, no upload/delete/promote/admin capabilities. Image-pull identity is distinct from investigative API identity. |
| Argo CD API | Supported released machine federation mechanism if enterprise instance provides it, otherwise restricted project-role/local API token | `applications,get` and needed `logs,get` restricted to intended projects/apps. No sync/update/delete/override/exec, no admin token. Verify installed Argo CD/Dex release support before claiming exchange available. |
| Grafana/monitoring | Supported service-account token or configured federation | Folder/dashboard/datasource query permissions sufficient for selected analysis; source log/metric backend has its own permissions. Viewer access in the UI does not automatically mean API/data source access is correctly scoped. |

Google → Entra WIF authenticates the mapped Google SA with a Google-issued ID token whose issuer is `https://accounts.google.com`, subject is the GSA numeric unique ID and audience matches the configured federated credential (typically `api://AzureADTokenExchange`). Entra trust and backend resource permissions are separate. Separate application registrations per major environment/data boundary avoid one federated caller acquiring another environment's aggregate permissions. There is no user SSO application or Microsoft Graph resolver in this design.

Tool policy must allow named operations and approved resource identifiers, not simply allow all HTTP GET or block all POST: read-only query APIs can legitimately use POST. Scope validation is server-side, including delegated subagent calls. Report credentials, user prompts, arbitrary URLs and supplied SQL must not become unchecked backend operations.

## Provisioning and deployment privileges

These are potential **provisioner** roles, not runtime grants; exact modules/project topology determine final custom roles. Use dedicated reviewed infrastructure identity:

- `roles/serviceusage.serviceUsageAdmin` when Terraform enables APIs.
- `roles/container.admin` for new GKE cluster/node-pool creation; cluster application deployment itself belongs to Argo CD and a namespace-scoped Kubernetes Role.
- `roles/compute.networkAdmin`, `roles/compute.securityAdmin` if it creates VPC/subnet/NAT/firewalls; `roles/dns.admin` if it creates zones/records; `roles/servicenetworking.networksAdmin` for private service access. Shared VPC requires separate narrowly scoped host-project grants, often `roles/compute.networkUser` for the appropriate service identities/subnets.
- `roles/cloudsql.admin`, `roles/storage.admin`, `roles/pubsub.admin`, `roles/cloudscheduler.admin`, `roles/secretmanager.admin` limited to the harness project/managed resources.
- `roles/iam.serviceAccountAdmin`, `roles/iam.roleAdmin` if creating GSAs/custom roles; `roles/resourcemanager.projectIamAdmin` if changing project bindings. Prefer bootstrap IAM changes separated from routine CD, with controlled grants instead of permanent project-wide IAM administration.
- `roles/monitoring.editor` for dashboards/alerts, `roles/logging.configWriter` for buckets/sinks/views. Runtime collectors only need writer roles.
- `roles/cloudkms.admin` only if provisioning new CMEK keys; Google-managed encryption is an acceptable default if corporate policy allows it.
- `roles/iam.serviceAccountUser` (`actAs`) only on specific GSAs a deployment API needs to attach. Native Scheduler Pub/Sub targets do not require an attached caller GSA or its actAs grant.

Avoid Owner/Editor convenience roles. A pipeline able to edit project IAM inherently has privilege-expansion power; label and govern it as bootstrap/provisioning, not as a narrowly authorized task publisher.

Terraform config/state contains request content, goals and parameters: treat the state bucket as sensitive, enable uniform access/public access prevention, versioning and appropriately controlled retention. No secret payloads in ordinary Terraform fields. Current provider's `google_storage_bucket_object` supports `deletion_policy = "PREVENT"` or `"ABANDON"`; ABANDON removes state without remote deletion. Append-only object names plus lack of delete/update rights prevent accidental replacements. Retention/lifecycle must not delete live desired objects that Terraform would later recreate and emit again; SQL request-ID dedupe must outlive retained request objects.

## Network and image-pull implications

- Private GKE nodes and private SQL IP in the same/connected VPC; private Google API access or approved PSC/private API DNS routes. SQL private service access/PSC must be provisioned consistently with Shared VPC design.
- Controlled outbound paths to Entra token endpoints, ADO SaaS, JFrog, Azure/AKS, Grafana and optional model vendors/LangSmith. Cloud NAT provides egress but is not an application-layer URL allowlist; use existing corporate proxy/egress controls where needed.
- Existing GCP ↔ Azure/VPN/Interconnect connectivity is reused where backend APIs are private. DNS/private CA certificates must be distributed to tools; never disable TLS validation to make access work.
- Direct GKE image pulls from private JFrog need network reachability and a **registry credential usable by kubelet**. Workload Identity ADC inside the application does not itself make Docker registry authentication to JFrog work. Use scoped robot/read token delivered via controlled Kubernetes `imagePullSecret`/credential controller; rotate it. `roles/artifactregistry.reader` is not applicable unless an approved Artifact Registry mirror/remote delivery is introduced.
- Native Scheduler → Pub/Sub avoids private GKE HTTP ingress. Cloud Scheduler ordinarily cannot directly reach a VPC-internal GKE HTTP endpoint without a deliberately supported architecture; there is no generic Scheduler VPC connector to assume.

## Observability and security audit

Prefer standard OTLP from application instrumentation → in-cluster OTel collector → `telemetry.googleapis.com`/native Google ingestion, with stdout structured logs collected by GKE logging as the simple initial logging path. Official Google Go exporter repository now deprecates its proprietary Trace/Monitoring exporters and says archive after January 1, 2027; Python migration recommends native OTLP traces/metrics/logs and W3C trace context. Do not design a fresh dependency around legacy GCP exporters.

Separate writing observability from reading target monitoring/logs. Correlate request ID, scheduled occurrence ID, run ID, LangGraph thread/checkpoint ID, image digest, prompt/tool-policy configuration hash, tool identity and trace IDs. Audit tool selection, permitted scope, backend response status, policy denials, retries, resume and result completeness. Do not put run IDs/application names with unbounded cardinality into every Prometheus metric; use logs/traces for detailed identifiers.

Enable appropriate GCP Data Access audit logging for Secret Manager, request/report storage and other sensitive reads where corporate policy requires it. Pub/Sub/Storage infrastructure audit logging does not by itself prove an individual model tool call stayed within scope; keep an application tool-call audit stream. Cloud SQL schema grants and separate backend identities provide enforceable controls.

Configure collector redaction/drop rules for Authorization headers, cookies, credentials, personally identifying raw logs and sensitive prompt/output fields. Observability traces can contain much of the investigation data; match retention/access to the evidence classification. LangSmith, if approved, is an additional system requiring SaaS data-egress approval or its own supported self-hosted infrastructure, not an automatic hidden service in this GCP design.

## Sources inspected

1. Scheduler target API (Google official): [PubsubTarget same-project requirement, OAuth vs OIDC comments](https://github.com/googleapis/googleapis/blob/master/google/cloud/scheduler/v1/target.proto).
2. Scheduler service-agent role reference (canonical documentation; direct fetch blocked): [Cloud Scheduler IAM roles](https://cloud.google.com/iam/docs/roles-permissions/cloudscheduler).
3. GCS notification Terraform source: [notification needs Storage service agent publisher](https://github.com/hashicorp/terraform-provider-google/blob/main/website/docs/r/storage_notification.html.markdown).
4. Google-maintained Pub/Sub module: [dead-letter service-agent publisher and source subscription subscriber grants](https://github.com/terraform-google-modules/terraform-google-pubsub/blob/master/main.tf).
5. Google-maintained GKE WIF module: [KSA mapping and workloadIdentityUser grant](https://github.com/terraform-google-modules/terraform-google-kubernetes-engine/blob/master/modules/workload-identity/main.tf).
6. Google GKE module: [current node SA roles](https://github.com/terraform-google-modules/terraform-google-kubernetes-engine/blob/master/sa.tf).
7. Google Cloud SQL Auth Proxy: [client permissions, IAM DB user and private connectivity](https://github.com/GoogleCloudPlatform/cloud-sql-proxy/blob/main/README.md).
8. Cloud SQL Python connector: [ADC, client role, optional IAM DB auth](https://github.com/GoogleCloudPlatform/cloud-sql-python-connector/blob/main/README.md).
9. SQL IAM user Terraform: [CLOUD_IAM_SERVICE_ACCOUNT username](https://github.com/hashicorp/terraform-provider-google/blob/main/website/docs/r/sql_user.html.markdown).
10. Google Secret Manager CSI provider: [direct WIF principal and secretAccessor per secret](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/main/README.md).
11. Storage object Terraform: [deletion_policy PREVENT/ABANDON, content state and retention](https://github.com/hashicorp/terraform-provider-google/blob/main/website/docs/r/storage_bucket_object.html.markdown).
12. Official OTel exporter deprecation: [Google operations Go README](https://github.com/GoogleCloudPlatform/opentelemetry-operations-go/blob/main/README.md), [migration guide](https://github.com/GoogleCloudPlatform/opentelemetry-operations-go/blob/main/MIGRATION.md).
13. Current Python native OTLP migration: [Google operations Python migration](https://github.com/GoogleCloudPlatform/opentelemetry-operations-python/blob/main/MIGRATION.md).
14. Official Google LangGraph telemetry sample: [roles and API enablement](https://github.com/GoogleCloudPlatform/opentelemetry-samples/blob/main/python/langgraph-sql-agent/README.md).
15. Official Google GKE OTLP trace sample: [telemetry.tracesWriter direct KSA grant](https://github.com/GoogleCloudPlatform/opentelemetry-samples/blob/main/java/otlp-spring/README.md).
16. Legacy collector role mapping (for legacy exporter path only): [googlecloudexporter README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/googlecloudexporter/README.md).
17. Current collector Google ADC auth: [googleclientauthextension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/googleclientauthextension/README.md).
18. Microsoft official ADO service principals source inspected earlier: [application identities, access level, ADO resource permissions and scope](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity?view=azure-devops).

Most source links point to upstream main/master, reflecting current development docs and examples. Production must pin released provider/library/collector versions and verify the role catalog and APIs against the target project; current-source documentation alone is not proof of an installed release's feature compatibility.
