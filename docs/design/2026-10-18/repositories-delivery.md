# Repository architecture and delivery ownership

## Four repositories

Names below are proposed; hosting organization and enterprise branch protections are deployment inputs. These directories describe new repositories, not folders to deploy from the runtime repository.

```text
harness-agent-framework/             # existing application repository
  src/harness/
    dispatcher/                     # intake, scheduling, outbox, Jobs, reconciliation
    worker/                         # generic execution, model budgets and reporting
    gateway/                        # authentication, schemas, catalog and routing
    connectors/telemetry/           # typed query compilation/admission/results
    contracts/                      # versioned task/tool/evidence/report schemas
    state/                          # SQL clients, checkpoints and ownership adapter
  capabilities/pipeline-observability/
    capability.yaml
    skills/logs-analysis/SKILL.md
    skills/metrics-analysis/SKILL.md
    skills/evidence-review/SKILL.md
    query-templates/
    runbooks/
    report-schema.json
    evals/                          # versioned sanitized incidents and expected claims
  policies/                         # static worker-class authorization, optional Rego
  migrations/                       # application-owned versioned SQL migrations
  tests/                            # integration, negative policy, recovery, load/evals
  containers/                       # runtime, gateway and connector Dockerfiles
  release/                          # release manifest schema and compatibility rules
  docs/

harness-terraform-modules/           # new reusable module repository
  modules/
    identities/                     # KSAs' GSA links and hosting IAM interfaces
    storage/                        # request/config/evidence/report buckets
    messaging/                      # notifications, Pub/Sub, DLQ
    database/                       # Cloud SQL and distinct IAM database users
    scheduling/                     # heartbeat infrastructure, not investigations
    request-registration/           # immutable request object + digest
    control-registration/           # restricted cancel/pause intent, not model tools
    schedule-registry/              # versioned schedule configuration
    secret-bindings/                # wrappers around established credential modules
  examples/
  tests/
  docs/                             # input/output and upgrade contracts

harness-infra-live/                  # new Terragrunt/live repository
  root.hcl
  environments/
    dev/region/                     # actual approved region substituted
      identities/terragrunt.hcl
      storage/terragrunt.hcl
      messaging/terragrunt.hcl
      database/terragrunt.hcl
      scheduling/terragrunt.hcl
      secrets/terragrunt.hcl
      schedules/terragrunt.hcl
      requests/terragrunt.hcl
      requests/manifests/<request-id>.yaml
    prod/region/                    # same shape, independent state and identities
  schedules/<environment>/*.yaml
  operations/<environment>/*.yaml   # separately authorized control requests
  dependency-locks/
  deployment-contracts/             # nonsecret cloud outputs for GitOps promotion

harness-gitops/                      # new Argo CD/Kustomize repository
  argocd/projects/harness.yaml
  argocd/applicationsets/harness.yaml
  clusters/<environment>.yaml       # registered cluster name and approved environment
  apps/
    foundation/base/                # namespaces, admission and environment guardrails
    foundation/overlays/{dev,prod}/
    workers/base/                   # KSA, quota, limits and worker-network policy
    workers/overlays/{dev,prod}/
    control/base/                   # dispatcher/gateway, release config, roles, metrics
    control/overlays/{dev,prod}/
    telemetry/base/                 # connector, endpoint/source map and query policy
    telemetry/overlays/{dev,prod}/
    connectors/                    # ADO/JFrog/Argo bases added when enabled
  releases/{dev,prod}/              # promoted digests, contract versions and identifiers
  policies/                        # environment policy data; application policy code reviewed upstream
  checks/                          # render, schema, security and cross-file consistency
```

Use one single-namespace base per component. Namespace sets are `harness-control-<env>`, `harness-workers-<env>`, and `harness-tools-<env>`. A single global namespace transformer across a mixed-namespace base can silently move Roles, KSAs or credentials to the wrong namespace; avoid that structure. Protect cross-namespace RoleBinding subjects explicitly.

## Ownership matrix

| Resource | Authoritative owner |
|---|---|
| Existing GKE, node pools, ESO, Alloy, Loki/Mimir and Argo controllers | Existing platform/observability repositories |
| GCP GSAs, IAM bindings, buckets, notifications, Pub/Sub, SQL and Scheduler | Harness Terraform modules instantiated by infra-live |
| Backend credential values/rollover | Established corporate Terraform modules, invoked through approved configuration |
| KSAs and GSA annotations, namespaces, Deployments, Services, quotas, NetworkPolicy and ExternalSecrets | Harness GitOps repository / Argo CD |
| SQL schema migrations and application contracts | Runtime repo release; deployment migration Job has a separate identity |
| Immutable request and schedule configuration objects | Terraform registration modules / infra-live |
| Individual investigation Jobs | Dispatcher only, based on the promoted fixed template |
| Run state, evidence and reports | Deployed harness runtime |

Argo does not own dynamic investigation Jobs. Terraform does not deploy application workloads. A task registration is desired configuration submitted for runtime processing, not a pipeline action that performs analysis.

## Release and promotion contracts

Application CI performs dependency/security/license checks, unit/integration tests, policy tests, sanitized incident evaluations and image builds. Publish immutable images to JFrog with a release manifest containing runtime/gateway/connector digests, pack/skills/query-policy digests, schema/API versions, migration version and a compatibility matrix. Secrets are absent from images and release manifests.

Promote the same digests from dev to production through reviewed GitOps changes; do not rebuild production. Kustomize `images` pins each image by digest. Policies and capability content are immutable release inputs, not mutable remote files downloaded by the model. Environment source mappings, endpoints and allowed GSA subjects are reviewed GitOps configuration.

The dispatcher creates worker Jobs dynamically. Therefore `images` cannot directly rewrite a Job that does not yet exist. Copy the rendered dispatcher/runtime image into an explicit worker-release ConfigMap using a tested Kustomize replacement, or promote a separately declared worker digest in that ConfigMap. Validate that both identify the same compatible release. Resolve it into the run ledger and copy it into the new Job at admission. Never depend on a mutable registry tag or a ConfigMap changing an already running Job.

The reference overlay demonstrates the replacement approach. A production release may use separate dispatcher and worker images; then the release manifest supplies both digests explicitly rather than copying one image.

Infrastructure CI validates module/provider locks, Terraform plans and resource ownership. The approved Terragrunt apply workflow provisions resources and writes request/config objects; it does not run the agent. The existing enterprise pipeline is the executor; GitHub Actions can be used for non-GKE CD where enterprise policy permits, without making workflow dispatch the runtime investigation trigger.

Module releases are immutable tags plus resolved commit hashes. Live configuration pins module revisions and provider lockfiles. State is split by environment and module boundary in the enterprise secured remote backend. Identity/storage/database bootstrap state is separate from frequently changing request registration state. Serialize applies to each state; do not use `-target` as the ordinary dependency workflow.

## Cloud outputs to GitOps

Terraform publishes a nonsecret deployment contract: project/region, GSA email and numeric unique ID, SQL instance identifier, bucket/topic/subscription names, model-region allowlist references and credential Secret references. The approved delivery workflow updates the GitOps environment configuration through review. Argo does not read Terraform state. Secret payloads and Google access/ID tokens are never copied into Git.

For worker and gateway KSAs, Argo sets `iam.gke.io/gcp-service-account`. Terraform binds each exact namespace/KSA to its own GSA using `roles/iam.workloadIdentityUser`. No generic external WIF pool/provider is created for native GKE federation. External pipeline authentication is a separate existing enterprise trust.

## ApplicationSet and Kustomize strategy

An ApplicationSet combines registered environment/cluster records with a fixed component list: foundation, workers, control and telemetry. Every generated Application has an explicit AppProject, repository/path, destination and namespace. Use Go templates with `missingkey=error`; no tenant/model input can select repoURL, cluster destination or Kustomize path. Restrict AppProject source repositories, destinations and allowed resource kinds; credentials are in the established Argo integration.

Render each component/environment with the Kustomize version supported by the deployed Argo release. Do not rely on a newer local CLI feature without server compatibility testing. Avoid remote unpinned bases, executable plugins and implicit Helm inflation. Base manifests carry defaults; overlays hold namespace, image digests, replicas, resources, source mappings and nonsecret identity data. ConfigMap hash changes trigger the intended Pod rollout; credentials use explicit reload/rollout behavior instead of embedding secret values in generated config.

Bootstrap and upgrade order is explicit:

1. Terraform creates required APIs, identities, SQL/storage/messaging and approved secret versions/bindings.
2. Bootstrap foundation and worker configuration; establish KSAs/admission/RBAC before any investigation can launch.
3. Establish migration identity and prerequisites. Run additive SQL migrations with the release's migration Job.
4. Deploy compatible telemetry/gateway services, verify TLS/identity and query limits, then deploy dispatcher/worker release configuration.
5. Verify readiness and enable schedule/request admission for that environment.

ApplicationSet creation order or sync-wave annotations on Application objects alone are not a cross-Application dependency guarantee. Use explicit bootstrap stages and health gates, or an already supported/tested Argo progressive-sync mechanism. Do not introduce experimental progressive sync solely for initial deployment.

Within a runtime Application, use a Sync hook migration Job after prerequisite KSAs/configuration are healthy and before the new Deployments, with retained failure diagnostics and bounded cleanup. A first-install PreSync hook cannot depend on ordinary resources that the same sync has not created yet. Custom ExternalSecret health checks/readiness may be needed; verify installed ESO/Argo integration.

## Safe change and rollback

Gateway/connector APIs support the previous active worker release during promotion. Deploy server-compatible additions before clients. SQL migrations use expand/contract: add compatible fields first, migrate/backfill separately, remove only after old Jobs/releases are drained. Reverting an image is not a database down-migration strategy.

Record a release compatibility hash in every run/report. Existing Jobs keep their pinned release; pause new admissions if the gateway or model configuration cannot support them. Automated sync rollback follows a reviewed Git revert with compatible data contracts. A bad query policy can be disabled independently, with current global ceilings taking immediate precedence over old client requests.

Terraform-managed request objects must not be expired while still desired in state: a later apply would recreate them and emit another event. Use immutable names and appropriate `PREVENT`/`ABANDON` lifecycle semantics, retain SQL ID/hash tombstones, and retire requests deliberately before storage expiry. Deleting a request file is not a cancellation protocol. Schedule disable and run cancellation have explicit runtime semantics.

The initial public-facing output is GCS artifacts. Administrative cancel/pause intent uses reviewed `ControlRequest/v1` files in infra-live, registered as immutable objects under a separate operations bucket/prefix with an operator-only pipeline writer. The dispatcher validates that trusted source and executes `cancel_run` or `pause_admission` without involving the model. Ordinary task registration cannot submit control operations, and workers cannot write that source. Include operation-ID/hash deduplication and audit. This preserves the noninteractive Git/Terraform registration model and is distinct from executing investigations inside CI/CD.
