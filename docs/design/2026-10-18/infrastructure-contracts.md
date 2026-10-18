# Terraform modules and cloud deployment contracts

The dedicated module repository provides reusable resource modules. Infra-live selects immutable revisions and supplies approved environment inputs. Application and query logic remain in runtime/GitOps releases.

## Module interfaces

| Module | Inputs | Outputs / invariants |
|---|---|---|
| `identities` | GKE workload-pool project, identity project, environment, exact namespace/KSA map, allowed hosting resources | GSA emails and numeric subjects, exact WIF bindings; no KSA creation and no keys |
| `storage` | Region, classification, bucket purposes, lifecycle/retention and writer/reader identities | Separate request/config/evidence/report bucket identifiers; public access prevention, uniform IAM; no expiration of still-managed requests |
| `messaging` | Request bucket/prefix, topics, subscriber identities, DLQ/retention/retry settings | Storage notification, request/tick subscriptions, DLQ and triage; publication identities are explicit |
| `database` | Approved engine/version, region/network, HA/size/PITR, IAM database identities | Private SQL instance, databases and IAM DB users; private routing and bootstrap/migrations are separate prerequisites |
| `scheduling` | Same-project tick topic and heartbeat cadence | Native Pub/Sub Cloud Scheduler job; no investigator execution and no HTTP/OIDC adapter |
| `request-registration` | Versioned request schema, canonical validated payload, immutable ID, request bucket | Create-only desired request object and content hash; reused ID with changed payload is rejected |
| `control-registration` | Operator-approved cancel/pause intent, separate operations source/writer | Immutable idempotent control object; ordinary request writers and model tools cannot invoke it |
| `schedule-registry` | Validated schedule templates, revision contents, registry bucket | Immutable registry object plus current pointer; import ordering uses pointer generation |
| `secret-bindings` | Approved credential references and existing producer-module inputs | Explicit versions/IAM/ESO references using the established producer/rollover process; no agent credential minting |

Use standard labels: application, environment, owner, data classification and cost center. Do not use individual request/run IDs as cloud metric/resource labels merely for tracing. Module interfaces validate region/environment/naming and destructive-change protection. Identity and shared platform changes require separate plan review from routine task registration.

## Identity and managed-service details

Native GKE WIF already exists. Verify eligible nodes use the metadata server. For worker/gateway identity links, grant `roles/iam.workloadIdentityUser` on the selected GSA to `serviceAccount:GKE_PROJECT_ID.svc.id.goog[NAMESPACE/KSA]`. The GSA project may differ from the GKE project. Argo owns KSA annotations. The [reference identity module](reference/terraform/identities/main.tf) illustrates the contract; live root configuration must pin providers and module revisions.

Relevant APIs include IAM, IAM Service Account Credentials, STS and the selected GKE/SQL/storage/Pub/Sub/Scheduler/Vertex/Secret Manager services. Reuse the existing platform's API-management owner and quota-project conventions. Do not create the same `google_project_service` in another state or disable a platform API on destroy.

Explicitly include managed-service permissions:

- The Storage service agent of the request-bucket project publishes object notifications to the request topic. Grant only topic publisher and establish the topic/IAM before the notification.
- Preserve the automatically provisioned Cloud Scheduler service agent role. A native Pub/Sub target uses this managed identity; it does not attach a custom caller GSA. Keep the target topic in the Scheduler project.
- Pub/Sub's managed service agent requires the documented subscription consumption and DLQ topic publication permissions for forwarding. DLQ delivery attempts are approximate, not an exactly-once retry count. Triage uses a separate subscription.
- Dispatcher reads only approved request/config buckets and subscribes only to its intake/tick subscriptions. Requests contain references and small parameters, not log payloads.
- A worker's model, checkpoint and artifact permissions are separate from gateway invocation policy. Grant only the resource scopes needed by that hosting function. Service-account ID tokens are minted at runtime; Terraform never stores them.

External pipeline WIF is separate from native GKE WIF. Reuse the enterprise's approved GitHub/ADO issuer and repository/environment conditions. Provisioner authority to create resources or edit IAM is not transferred to application GSAs.

## State and registration semantics

Split environment state by module boundaries. Keep infrastructure bootstrap, credentials and request registration separately permissioned, with state locking and reviewed plans. Use the enterprise state backend with restricted readers, encryption, versioning and audit. Goals/parameters can be sensitive even without secrets. Credential modules that accept ordinary secret payload fields also place them in protected state unless a supported write-only mechanism is deliberately used.

Routine request registration can use a restricted pipeline identity with request-bucket object-create and required metadata-read rights; it does not need SQL, IAM or GKE administration. Terraform should see immutable object identities. Changing content under an existing request ID is an error, not a replacement-based rerun.

Do not lifecycle-delete live desired request objects: Terraform drift repair would recreate them and emit new events. Retire through an explicit process after admission/retention policy, using supported `PREVENT`/`ABANDON` semantics as appropriate to the pinned provider. Preserve compact SQL admission tombstones. Deleting a request object/file is not task cancellation.

Schedule configuration differs: registry payloads are immutable, while an explicitly managed versioned current-pointer object is updated. Dispatcher reads the authoritative pointer generation and imports only a newer active revision. Disables become effective after confirmed runtime reconciliation; alert on lag. Neither topic updates nor old tick messages execute/re-enable a schedule by themselves.

## Database initialization and privileges

Terraform creates Cloud SQL, databases and IAM DB identities through Google APIs. That alone does not create application schema roles or grant table privileges. Use the enterprise's approved database bootstrap automation. If no existing mechanism exists, define a one-time reviewed bootstrap Job with an administrator credential delivered through TF/GSM/ESO into an isolated migration namespace. It creates schemas/roles and grants the migration identity; remove the bootstrap mount afterward and retain administrator access only through the enterprise break-glass process.

Ordinary runtime uses IAM DB authentication. Split SQL rights: dispatcher lifecycle/schedule/outbox, worker checkpoints/artifacts/accounting, query service budget procedures, and migration DDL. A dev query service may execute shared-backend reservation procedures but cannot read production run/checkpoint databases. Revoke unintended PUBLIC database/schema rights as part of bootstrap.

Initial saver/store schema setup belongs to migrations. If automatic checkpoint resume is later enabled, its ownership adapter and database enforcement must be part of the same versioned migration/test contract. Runtime Pod success cannot substitute for stale-writer tests.

## Nonsecret deployment output

Produce a validated environment contract consumed by the reviewed GitOps promotion workflow: environment, projects/region, GSA emails/subjects, SQL identifiers, bucket/subscription names, model allowlist references, source-inventory revision and Kubernetes Secret references. It carries no secret payload or temporary credential. Argo does not obtain Terraform state credentials.

The GitOps change pins this contract with image/capability/policy versions. CI checks missing fields, wildcard subjects, mismatched namespaces/audiences, stale API versions and image/reference inconsistencies. Terraform and Argo never both own the same KSA, Deployment or application configuration object.

The module catalog creates harness infrastructure. Shared-cluster networking/node-pool changes, observability settings and enterprise backend authorization stay with their existing owners. Consumer-only telemetry does not imply permission to alter them.
