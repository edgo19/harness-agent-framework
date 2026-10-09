# harness-agent-framework

## Architecture

The proposed enterprise multi-agent harness runs on GCP, with Deep Agents, LangGraph and LangChain executing read-oriented investigations against CI/CD backend systems. Deployment follows the existing JFrog and Argo CD flow; Terragrunt/Terraform registers ad-hoc requests and scheduled-task configuration.

- [GCP architecture specification](docs/architecture/harness-gcp-architecture-2026-10-09.md): resource sizing, scaling, IAM, networking, recovery and observability.
- [Architecture diagram (PNG)](docs/architecture/harness-gcp-architecture-2026-10-09.png) and [SVG](docs/architecture/harness-gcp-architecture-2026-10-09.svg). Editable sources: [Mermaid](docs/architecture/harness-gcp-architecture-2026-10-09.mmd) and [Graphviz](docs/architecture/harness-gcp-architecture-2026-10-09.dot).
- [Framework research](docs/architecture/framework-current-2026-10-09.md): current Deep Agents, LangGraph, LangChain and MCP capabilities.
- [IAM review](docs/architecture/gcp-iam-review-2026-10-09.md): workload identities, service-agent grants and backend permissions.
- [Capacity and observability review](docs/architecture/gcp-capacity-observability-2026-10-09.md).

These documents reflect research on 9 October 2026. Infrastructure has not been deployed; proposed sizes and integrations require validation against enterprise workloads.
