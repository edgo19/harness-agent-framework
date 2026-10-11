# Phase 1: Terraform → GSM → existing ESO → connector Secrets

This review adopts the user's actual enterprise pattern: existing Terraform modules supply and rotate Google Secret Manager payloads; the existing External Secrets Operator (ESO) in the shared observability GKE cluster authenticates using its own Workload Identity and delivers Kubernetes Secrets. No separate connector-side Secret Manager client, CSI installation, interactive harness access or alternative bootstrap process is proposed. No live infrastructure was changed. The [phase-1 scope](harness-phase1-scope-2026-10-11.md) limits investigations to enterprise CI/CD tools and infrastructure; application deployment target clusters and their telemetry are excluded.

Latest scope clarification: Loki and Mimir are existing **internal-only services in the same cluster**. Harness read tools call their approved internal query endpoints directly using the existing deployment's access model. No new backend authentication gateway, cloud viewer role, credential broker or independent rotation service is introduced for them. NetworkPolicy, configured query/tenant scope, query limits and named read-operation enforcement remain necessary. If they use a static tenant header such as X-Scope-OrgID, it comes from trusted deployed configuration, not arbitrary model arguments. Backend connectors do not need GSA/ADC/WIF just to use mounted credentials or internal HTTP; retain GCP runtime identities only where a component actually uses SQL IAM, Vertex AI, Pub/Sub, GCS, Google-signed service tokens or other hosting APIs.

## Delivery and identity

```text
Enterprise Terraform/Terragrunt modules
  → GSM secret versions (ADO client certificate, JFrog token, separate Argo credentials)
  → existing ESO controller, existing WIF identity
  → explicit ExternalSecret mappings in approved harness namespaces
  → Kubernetes Secret read-only volumes in the corresponding connector Pods
  → backend API calls
```

Current official ESO GCPSM documentation explicitly supports “Authorizing the Core Controller Pod”: grant the ESO controller's workload identity access to the intended GSM secrets and omit explicit authentication from SecretStore/ClusterSecretStore. The provider uses ADC/GKE metadata credentials. Specify `projectID` explicitly to prevent accidental project inference; no Google SA JSON-key Secret is needed.

Minimal store example (use the API version supported by the **installed** operator/CRDs; current upstream uses v1):

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: harness-gsm
  namespace: harness-tools-prod
spec:
  provider:
    gcpsm:
      projectID: enterprise-secrets-project
```

Example explicit JFrog mapping:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: harness-jfrog-reader
  namespace: harness-tools-prod
spec:
  refreshPolicy: Periodic
  refreshInterval: 1m
  secretStoreRef:
    kind: SecretStore
    name: harness-gsm
  target:
    name: harness-jfrog-reader
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: token
      remoteRef:
        key: harness-prod-jfrog-reader-token
        version: latest
```

The 1-minute interval is a reasonable initial choice; match the existing operator's scale/corporate refresh convention. `Periodic` is important for source-only updates. `OnChange` would require an ExternalSecret metadata/spec change; `CreatedOnce` and refreshInterval zero do not continuously follow rotations. `Owner` means deleting the ExternalSecret can garbage-collect the target; `Retain` controls provider-deletion behavior, not Argo resource deletion. Do not conflate those two lifecycle controls.

Use explicit mappings for phase 1:

| GSM source | Target Kubernetes Secret / keys | Consumer |
|---|---|---|
| ADO Entra SP certificate credential | `harness-ado-client-certificate`, key `client-certificate.pem` or binary PFX plus password if used | ADO connector only |
| JFrog read token | `harness-jfrog-reader`, key `token` | JFrog connector only |
| Argo endpoint A credential | `harness-argocd-a-reader`, key `token` | Endpoint A connector only |
| Argo endpoint B credential | `harness-argocd-b-reader`, key `token` | Endpoint B connector only |

ADO tenant/client IDs and fixed backend URLs can be ordinary deployed configuration; they are not private key material. If corporate modules store a JSON credential object, ESO `remoteRef.property` can map its exact fields. JSON property selection is a mapping convenience, not separate GSM IAM field isolation. ESO handles Kubernetes Secret encoding; configure decoding only where the source deliberately contains encoded binary data, such as base64 PFX. Do not double-base64 PEM/plain tokens.

## Permissions to retain/remove

- Add `roles/secretmanager.secretAccessor` on the **individual intended GSM secrets** to the existing ESO GSA/direct WIF principal. `secretmanager.versions.access` is the core payload permission. No project-wide accessor or admin is required just for these new mappings. Retain its existing KSA/GSA workloadIdentityUser mapping; do not change unrelated corporate ESO grants.
- ESO already needs Kubernetes privileges to reconcile ExternalSecrets and create/update target Secrets. Its existing deployment is the trusted shared credential controller; verify its namespace scope, available providers and store controls with the platform owner. Do not silently reinstall or globally reconfigure it.
- Remove GSM accessor from agent worker, tool gateway and connector GSAs for the phase-1 credentials. Remove connector GSM API clients, credential polling, CSI and custom secret-to-Kubernetes controllers from the proposed harness resources.
- No cloud-backend Viewer roles are required in phase 1 for ADO certificate auth, JFrog/Argo mounted tokens or internal Loki/Mimir query tools. Grant only the separate GCP **hosting** permissions needed by each actual runtime component.
- Kubernetes volume delivery is performed by kubelet: connector KSA does **not** need `secrets.get/list/watch` merely to mount its configured Secret. Its process watches/rereads the mounted file rather than reading Kubernetes API Secrets.
- A connector that only uses mounted backend credentials and validates incoming Google tokens may need only a KSA, not its own GSA/WIF mapping. Retain a GSA where it also needs Cloud SQL IAM authentication, Google APIs or another cloud identity function. Gateway GSA still supports Google-signed connector authentication; worker GSAs still support Vertex/SQL/GCS where used.
- Terraform secret payload permissions remain those required by the existing authorized modules. This proposal does not replace their established payload insertion/rotation mechanism. Ordinary provider `secret_data` is stored in protected Terraform state; current `secret_data_wo` can avoid state persistence when supported by their pinned toolchain and module. Use the enterprise-approved module pattern.
- Backend permissions are unchanged: read-only ADO project/repository/build access, scoped JFrog read access and separate Argo project/application read tokens. No Microsoft Graph directory permission, user credential or Entra WIF exchange is required for the phase-1 ADO **certificate** flow.

## Shared-cluster boundaries

A namespaced SecretStore/ExternalSecret cannot reference another namespaced store directly. It does **not** narrow the GCP permissions of the existing controller identity. Anyone able to create arbitrary ExternalSecrets using that store can request other GSM keys available to that operator unless additional controls prevent it.

Restrict (Cluster)SecretStore and ExternalSecret changes to the approved Argo/deployment identity; workers/gateway/connectors cannot edit them. Admission rules should permit only approved store references, remoteRef keys/property/version selectors and target Secret names for each harness namespace. Avoid `dataFrom.find`, arbitrary provider/generator references or PushSecret for this read-delivery use case. If an existing ClusterSecretStore is reused, apply/verify its namespace match conditions; conditions OR-match namespace lists/selectors and do not themselves restrict individual remote keys. Namespace label changes can affect selectors, so control those changes too.

Anyone able to create arbitrary Pods/Jobs in a connector namespace can generally mount its Secrets or select a privileged KSA. Prevent this through namespace RBAC plus enforced Pod/Job admission templates. Keep the agent Job namespace distinct from connector Secret namespaces. Mount only the required Secret into its connector container; model-visible filesystem tools, shell tools and agent sidecars must not share backend credential volumes. A Pod's service identity remains shared across its containers, so putting a model beside a privileged connector is not a hard identity boundary.

Use normal read-only Secret volumes rather than environment variables or `subPath`. Env values remain fixed until restart; subPath mounts do not receive updates. Use file permissions compatible with non-root security context and mount only required keys. The shared GKE cluster's existing Secret-at-rest encryption, operator security and access controls remain part of the trust boundary; adding GSM does not remove Kubernetes Secret copies.

## Certificate/token reload and rotation

Current Azure Python `CertificateCredential` accepts PEM or PKCS12 **including the RSA private key** and reads the certificate file at construction. A later Kubernetes Secret-volume update does not reload that object. Implement one of the following in the ADO connector:

- Watch/reopen the projected files and construct a new CertificateCredential/client when their generation changes, with safe in-flight-request handoff; or
- Use the existing approved secret-change rollout mechanism to restart connector replicas.

Do not rely on old open file descriptors to follow atomic Secret-volume replacement. If cert/password must change together, load a consistent generation before building the credential. JFrog/Argo HTTP clients likewise must update/rebuild cached authentication headers after the token file changes. None of this requires a new image build for each token refresh.

For ADO rotation, the new public certificate must already be registered on the correct Entra application before the private credential is promoted through TF/GSM/ESO. Acquire ADO app-only tokens using the certificate and scope `https://app.vssps.visualstudio.com/.default`; ADO authorization still requires the SP's organization membership/access level and selected resource read permissions. Existing access tokens are cached in memory and can remain valid until expiry; removing an old application certificate does not necessarily invalidate tokens already issued.

Keep backend old/new credentials valid through the ESO polling interval, Kubernetes volume propagation, connector reload/rollout and in-flight token/session overlap. Verify new credential uptake before revoking the old backend token/certificate registration. Disabling/destroying a GSM version does not invalidate the old Kubernetes Secret value or tokens already loaded into process memory.

Using remoteRef `version: latest` naturally follows newly created TF versions without changing an application manifest. It means the newest **created** version, not newest tested/enabled. A pinned numeric selector requires a manifest/config update; a promoted custom alias can also be used if it is part of the established corporate rotation pattern. Do not add a separate promotion workflow merely because aliases exist.

Current upstream GCPSM optionally supports `secretVersionSelectionPolicy` with default `LatestOrFail` and alternative `LatestOrFetch`; the alternative can silently fall back to an older enabled version and requires version discovery. For controlled phase-1 rotation, preserve fail behavior rather than introducing fallback/discovery privileges. Verify installed ESO support before relying on that newer field. On sync failure/provider removal, ESO may retain the last Kubernetes Secret value; alert on stale refresh/error and enforce explicit credential validity/readiness policy, rather than claiming that source deletion guarantees immediate revocation.

## Observability and verification

Reuse existing observability cluster tooling to monitor ExternalSecret Ready/SecretSyncedError status and status.refreshTime age, ESO errors/refresh latency, connector credential reload results, backend 401/403, ADO certificate expiry and readiness. Log credential reference/version where known and public certificate thumbprint, never the private key, token, password or raw Secret data. Redact HTTP Authorization/cookies and SDK/MSAL failure details before OTel/LangSmith export. Backend credentials remain outside agent tool arguments/results/checkpoints.

Implementation checks: ESO syncs each explicitly allowed key; unauthorized ExternalSecret mappings are rejected; worker/gateway cannot read/mount connector Secrets; changed source versions reach the target Secret and connector; CertificateCredential is actually rebuilt; backend calls remain read-only; stale sync/revoked credential fails appropriately; logs/traces/checkpoints contain no payloads. No live cluster, Entra or backend credentials were available to perform these checks in this review.

## Sources inspected

1. [ESO GCPSM provider authentication and version selection](https://github.com/external-secrets/external-secrets/blob/main/docs/provider/google-secrets-manager.md).
2. [ESO operator-identity SecretStore example](https://github.com/external-secrets/external-secrets/blob/main/docs/snippets/gcpsm-wif-core-controller-secret-store.yaml).
3. [ESO explicit ExternalSecret GCPSM example](https://github.com/external-secrets/external-secrets/blob/main/docs/snippets/gcpsm-wif-externalsecret.yaml).
4. [ESO ExternalSecret refresh policies](https://github.com/external-secrets/external-secrets/blob/main/docs/api/externalsecret.md).
5. [ESO ownership and deletion lifecycle](https://github.com/external-secrets/external-secrets/blob/main/docs/guides/ownership-deletion-policy.md).
6. [ESO security: namespace/store restrictions, operator privileges, admission and remoteRef policy](https://github.com/external-secrets/external-secrets/blob/main/docs/guides/security-best-practices.md).
7. [ESO ClusterSecretStore namespace condition example](https://github.com/external-secrets/external-secrets/blob/main/docs/snippets/full-cluster-secret-store.yaml).
8. [Azure CertificateCredential source: constructor loading, formats and private key](https://github.com/Azure/azure-sdk-for-python/blob/main/sdk/identity/azure-identity/azure/identity/_credentials/certificate.py).
9. [Kubernetes Secret update/env/subPath behavior](https://github.com/kubernetes/website/blob/main/content/en/docs/concepts/configuration/secret.md).
10. [Terraform GSM secret version: payload/write-only state behavior](https://github.com/hashicorp/terraform-provider-google/blob/main/website/docs/r/secret_manager_secret_version.html.markdown).

Sources primarily use upstream main and must be compared with the enterprise's installed ESO/CRDs and Azure SDK versions before implementation. No upgrade or additional ESO feature is assumed necessary for the basic established WIF → explicit ExternalSecret → mounted Secret flow.
