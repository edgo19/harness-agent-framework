# Design-session verification

Date: 18 October 2026. These checks validate documentation and reference wiring. They are not application, model-quality, load, GCP IAM or enterprise integration tests.

| Check | Result |
|---|---|
| Kustomize dev overlay | Passed with verified official v5.7.1 CLI; 7 resources rendered |
| Kustomize production overlay | Passed with the same CLI; 7 resources rendered |
| Rendered environment namespaces/audiences | Passed for dev and production |
| Dispatcher image → worker-release ConfigMap replacement | Passed; immutable digest references match |
| Environment replica counts | Passed: one dev dispatcher/gateway, two production replicas |
| No investigation Job/CronJob in Argo illustration | Passed |
| Gateway default Kubernetes API token mount disabled | Passed |
| Rendered authentication subject list has no wildcard | Passed; replacement values remain intentional placeholders |
| Reference YAML parsing | Passed: 19 files containing 23 YAML documents |
| Mermaid source matches embedded diagrams | Passed |
| Graphviz architecture | SVG/PNG generated; SVG XML/PNG format and visual readability checked |
| Local Markdown targets and code fences | Passed during final validation |
| Framework candidate dependency resolution | Passed wheel-only Python 3.12 dry run: 60 distributions; no packages installed |
| Released Deep Agents/Postgres source inspection | Downloaded distributions verified against published PyPI SHA256 before inspection |
| Terraform provider/module validation | Not run; HCL is an illustrative contract without a production root/provider lock |
| Argo server-side schema/ApplicationSet reconciliation | Not run; installed Argo/cluster unavailable |
| Actual metadata tokens, backend queries, rotation and load | Not run; enterprise deployment inputs/access unavailable |
| Agent incident evaluations and recovery/fencing | Not run; runtime is designed, not implemented in this branch |

Kustomize tests verify an important deployment invariant: runtime-created workers receive the promoted image through configuration, while GitOps does not launch investigations. They do not prove that the placeholder images/CLI, TLS secret, policy values or missing bootstrap resources form a runnable application.

The dependency resolver validates declared requirements on this local Linux x86-64/Python platform. The [snapshot](framework-candidates.json) is not a complete hashed lock or proof of behavior. Runtime and production target-platform tests remain implementation gates.

Unresolved operational inputs remain listed in the [implementation plan](../implementation-plan.md). Environment/SLO defaults and the shared query-budget database are proposals for review. Shared observability configuration has not been changed.
