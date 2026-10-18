# Reference contracts and renderable GitOps illustration

These files describe interfaces and deployment wiring. They do not implement the runtime and must not be applied as production manifests. `REPLACE_*`, `example.invalid` and sample digests are intentional nonfunctional placeholders.

- [Capability manifest](contracts/capability.yaml), [ad-hoc request](contracts/task-request.yaml), [schedule registry](contracts/schedule-registry.yaml), [source inventory](contracts/source-inventory.yaml) and [query budgets](contracts/query-budget.yaml) are application data, not Kubernetes CRDs. A production implementation validates them against versioned schemas.
- [Typed query examples](contracts/typed-queries.yaml) illustrate composable intent without raw query text. The [report example](contracts/report.yaml) illustrates evidence and uncertainty fields; it contains no enterprise observations.
- [Control request](contracts/control-request.yaml) is operator-only registered intent, validated from a separate trusted source; it is not a model-visible tool or an ordinary task request.
- [GitOps example](gitops/apps/control/base/kustomization.yaml) demonstrates a single-namespace control application, dev/prod overlays, immutable image configuration and copying the rendered runtime image to the worker-release ConfigMap. It does not include the foundation/workers/telemetry applications described in the full repository design.
- [ApplicationSet](gitops/argocd/applicationset.yaml) and [AppProject](gitops/argocd/project.yaml) show the controlled source/destination pattern. Existing Argo controller/repo/cluster registration is a prerequisite.
- [Terraform identity module](terraform/identities/main.tf) illustrates exact native GKE KSA/GSA links and nonsecret outputs. It intentionally leaves provider locking and hosting grants to the live configuration; it has not been applied.

Kustomize deploys no investigation Job or CronJob in this illustration. The dispatcher creates those at runtime. Namespace creation, actual GSAs and output values, application CLI/images, serving certificates/CA trust, bootstrap migrations, complete policy/admission and backend connectivity are implementation prerequisites.

## Local verification commands

```sh
kustomize build docs/design/2026-10-18/reference/gitops/apps/control/overlays/dev
kustomize build docs/design/2026-10-18/reference/gitops/apps/control/overlays/prod
```

Verification in this design session uses the official Kustomize v5.7.1 Linux release, downloaded with its published SHA256 verified. This checks reference syntax/transform behavior; it is not a decision to change Argo's embedded version. Production CI must render with the deployed Argo-compatible tool version, validate resource schemas and run the implementation acceptance suite.

Expected rendered invariants: all control resources have the correct environment namespace; gateway audience matches that environment Service; dispatcher image equals worker-release image; digests are pinned; authentication allowlists contain no wildcard; no investigation Jobs, plaintext backend credentials or broad Kubernetes roles are introduced by this example.

See [verification results](verification.md) for the actual checks performed and limitations.
