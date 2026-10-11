# harness-agent-framework

## Architecture

The proposed enterprise multi-agent harness runs in the existing GKE observability cluster, with Deep Agents, LangGraph and LangChain executing read-only investigations of enterprise CI/CD infrastructure and tools. Target GKE/AKS/other Kubernetes clusters receiving user application deployments are outside the investigation scope, including their telemetry. Deployment follows the existing JFrog and Argo CD flow; Terragrunt/Terraform registers ad-hoc requests and scheduled-task configuration.

- [Phase 1 design scope](docs/architecture/harness-phase1-scope-2026-10-11.md): authoritative scope, tool access, execution flows, existing-cluster placement and initial concurrency.
- [Phase 1 diagram (PNG)](docs/architecture/harness-phase1-scope-2026-10-11.png) and [SVG](docs/architecture/harness-phase1-scope-2026-10-11.svg). Editable sources: [Mermaid](docs/architecture/harness-phase1-scope-2026-10-11.mmd) and [Graphviz](docs/architecture/harness-phase1-scope-2026-10-11.dot).
- [Phase 1 credentials and ESO review](docs/architecture/phase1-eso-security-2026-10-11.md): existing Terraform → GSM → ESO delivery, ADO certificate authentication and rollover.
- [Phase 1 Loki/Mimir review](docs/architecture/phase1-observability-access-2026-10-11.md): internal query routes, CI/CD source isolation, shared-cluster protection and harness observability. No Grafana API access is required initially.

The following 9 October documents retain baseline platform and research detail. The 11 October phase-1 scope takes precedence over their broader backend matrices, credential delivery, cluster placement, observability destinations and concurrency recommendations.

- [Baseline GCP architecture specification](docs/architecture/harness-gcp-architecture-2026-10-09.md): resource sizing, scaling, IAM, networking and recovery.
- [Baseline resource diagram (PNG)](docs/architecture/harness-gcp-architecture-2026-10-09.png) and [SVG](docs/architecture/harness-gcp-architecture-2026-10-09.svg). Editable sources: [Mermaid](docs/architecture/harness-gcp-architecture-2026-10-09.mmd) and [Graphviz](docs/architecture/harness-gcp-architecture-2026-10-09.dot).
- [Framework research](docs/architecture/framework-current-2026-10-09.md): current Deep Agents, LangGraph, LangChain and MCP capabilities.
- [IAM review](docs/architecture/gcp-iam-review-2026-10-09.md): workload identities, service-agent grants and backend permissions.
- [Capacity and observability review](docs/architecture/gcp-capacity-observability-2026-10-09.md).

These documents reflect research and scope decisions on 9–11 October 2026. Infrastructure has not been deployed; proposed sizes and integrations require validation against enterprise workloads.
