# Current framework review — 2026-10-09

Research snapshot of official PyPI releases, their source distributions, and the official `langchain-ai/docs` repository. This is a capability and deployment review, not an enterprise integration test or agent quality benchmark. Mutable documentation can describe newer behavior; released source was checked for the material recommendations below.

## Current released Python packages

| Package | Version | Release timestamp UTC | Notes |
|---|---|---|---|
| `deepagents` | 0.7.23 | 2026-10-07 16:45 | MIT; Python >=3.11; PyPI development status **Beta** |
| `langchain` | 1.4.4 | 2026-10-08 22:14 | MIT; Python >=3.10; Production/Stable classifier |
| `langchain-core` | 1.6.9 | 2026-10-08 20:11 | Production/Stable classifier |
| `langgraph` | 1.2.14 | 2026-10-06 14:41 | MIT; Python >=3.10; Production/Stable classifier |
| `langgraph-checkpoint` | 4.2.0 | 2026-08-07 20:05 | Core checkpoint interfaces |
| `langgraph-checkpoint-postgres` | 3.1.2 | 2026-08-07 20:39 | Postgres checkpoint and store implementations |
| `langchain-google-genai` | 4.4.0 | 2026-09-01 20:15 | Current Gemini integration for Developer API **or Vertex AI** |
| `langchain-google-vertexai` | 3.2.4 | 2026-06-09 14:57 | `ChatVertexAI` deprecated since 3.2.0, slated removal in 4.0.0 |
| `langchain-mcp-adapters` | 0.3.2 | 2026-08-06 06:15 | Existing separate adapter package; now native adapter available |
| `langsmith` | 0.14.7 | 2026-10-09 16:32 | SDK can route OTel traces to alternate collectors; does not require using SaaS |

Sources: each package's authoritative release JSON, e.g. [Deep Agents](https://pypi.org/pypi/deepagents/json), [LangChain](https://pypi.org/pypi/langchain/json), [LangGraph](https://pypi.org/pypi/langgraph/json), [Google GenAI](https://pypi.org/pypi/langchain-google-genai/json), [Postgres checkpoint](https://pypi.org/pypi/langgraph-checkpoint-postgres/json), [LangSmith SDK](https://pypi.org/pypi/langsmith/json).

All are non-prerelease package versions; a non-prerelease version is not proof that every embedded API is stable. Use a complete dependency lock and Python 3.12 initially; validate the resulting lock in the actual enterprise CI. Deep Agents 0.7.23 requires LangChain >=1.4.3, core >=1.6.7, google-genai >=4.4.0 and LangSmith SDK >=0.14.4. LangChain 1.4.4 requires LangGraph >=1.2.11,<1.3.0. The versions above fit those declared requirements; no live LLM/backend testing was performed this round.

## Layers and resource implications

`Deep Agents → LangChain create_agent/middleware/model integrations → LangGraph execution/checkpoint/store` are Python layers in **one worker process**, not three required services. Declarative local subagents have separate contexts but normally run inside the same Kubernetes Job and share its workload identity. Separate pods/services are needed only for separate permission boundaries, independent scaling, or remote subagents.

Recommended initial deployment: OSS Deep Agents in Kubernetes Jobs on existing GKE, local specialist subagents, explicit trusted tool registry, private Cloud SQL PostgreSQL for run ledger plus `AsyncPostgresSaver`, GCS for immutable request objects and evidence/report blobs, Vertex AI for model calls, Secret Manager for backend credentials that cannot use federation, and OTel to existing/GCP telemetry. No GPU is needed when using managed models. No Redis, hosted Agent Server, commercial LangSmith, dedicated vector database, remote sandbox, or Filestore is required for this design.

## Deep Agents capabilities checked in 0.7.23

- `create_deep_agent` supports model, tools, middleware, declarative/compiled/remote subagents, skills, memory, filesystem permissions, response format, custom state/context schema, checkpointer, store and cache.
- Backends: `StateBackend`, `FilesystemBackend`, `LocalShellBackend`, `StoreBackend`, `CompositeBackend`, `ContextHubBackend` and `LangSmithSandbox`. GCS is **not a shipped built-in backend**; a GCS virtual filesystem needs a custom `BackendProtocol` implementation. GCS report/archive upload through explicit tools does not require that implementation.
- Default `StateBackend` stores virtual files in graph state, scoped to the thread. With a persistent checkpointer, the virtual filesystem can survive a Job restart by resuming the same thread. It is not cross-thread memory. Keep virtual files bounded; archive large raw evidence in GCS and expose paginated reads/search through tools.
- `StoreBackend` adapts a LangGraph `BaseStore` for persistent cross-thread files with a caller-supplied namespace factory. `PostgresStore` can share Cloud SQL with checkpoints under distinct tables/DB roles. Use it only when cross-run memory is actually wanted; do not silently let one environment consume another environment's history.
- `CompositeBackend` routes filesystem paths to different backends. Read-only reviewed skills/memory can be in the immutable image, while scratch files stay per run.
- Context compression offloads oversized tool inputs/results, summarizes history and isolates specialist contexts. Offloading threshold is documented as 20,000 tokens by default; summaries are working context, not a substitute for raw evidence retention.
- Current messages use `DeltaChannel` with snapshot frequency 50 to limit repeated checkpoint growth; a custom schema should subclass `DeepAgentState` to preserve this behavior.
- Model-aware `HarnessProfile` controls prompt assembly, tool descriptions, excluded tools/middleware, general-purpose subagent and extra middleware. Skills progressively disclose content and can disclose associated tools. `TodoListMiddleware` planning is now optional/profile-dependent, so add it explicitly if a persisted planning tool is required.
- Tools supplied through `tools=` are **additive**, not an allowlist that removes the built-in filesystem, `execute` or `task` tools. Configure `FilesystemMiddleware(tools=[...])` to omit shell and unwanted built-ins; a non-sandbox backend cannot execute shell commands. Do not give an initial read-only investigation agent a `LocalShellBackend`.
- Filesystem permission rules are first-match and default-allow. Declarative subagents may replace inherited rules; direct backend operations bypass these middleware rules. These are useful product controls but **not the enterprise authorization boundary**. Enforce backend operations/resource scope in trusted tools/MCP services and cloud/backend identities.
- `AsyncSubAgent` runs remote/background tasks on an Agent Protocol server, has launch/check/update/cancel/list tools, uses its own auth/config/tools and does not inherit parent interrupt settings. This is optional infrastructure and unnecessary for local specialist agents initially. Fork-mode subagents are marked experimental.
- Default model selection is deprecated; configure the approved model explicitly. Human interruption exists, but an unattended read-only design should not accidentally pause forever for MCP elicitation or tool approval; reject unsupported interactive calls or mark the run as blocked.

Sources: [Deep Agents repository README/security model](https://github.com/langchain-ai/deepagents), [released create_deep_agent source](https://github.com/langchain-ai/deepagents/blob/deepagents%3D%3D0.7.23/libs/deepagents/deepagents/graph.py), [backends](https://docs.langchain.com/oss/python/deepagents/backends), [context engineering](https://docs.langchain.com/oss/python/deepagents/context-engineering), [subagents](https://docs.langchain.com/oss/python/deepagents/subagents), [profiles](https://docs.langchain.com/oss/python/deepagents/profiles).

## LangGraph capabilities and durability limits

- Graph and Functional APIs support parallel work, streaming, interrupt/resume, retry policies and checkpoints. `thread_id` associates run state with its durable checkpoint history.
- `AsyncPostgresSaver`/`PostgresSaver` and `AsyncPostgresStore`/`PostgresStore` are official implementations. Cloud SQL PostgreSQL is a direct managed fit. In-memory saver is not production crash persistence. Firestore would need a compatible saver/store implementation; simply putting the dispatcher ledger in Firestore does not persist LangGraph state.
- Run `checkpointer.setup()` through a controlled migration/bootstrap identity; workers should not permanently have schema-admin rights. Official Postgres README recommends `LANGGRAPH_STRICT_MSGPACK=true` or an explicit `allowed_msgpack_modules` list to restrict checkpoint deserialization. Test custom schemas against the allowed types.
- Released `invoke`/`stream` APIs support durability `sync`, `async` (default), and `exit`. Recommend `sync` initially for worker recovery at step boundaries. `exit` loses in-flight progress on a crash; `async` can have a window of unpersisted progress.
- Checkpointing is **not a daemon that reschedules a failed Job**. The dispatcher/reconciler must observe failed/stale runs and create a replacement execution using the same thread ID and pinned code/config revision.
- Completed parallel node writes can avoid re-running successful siblings when another fails. Work inside an interrupted/incomplete node may still run again. External side effects need idempotency keys or task boundaries; do not promise exactly-once backend operations merely because checkpoints exist. Even read operations can be repeated after failure.
- Maintain pinned image, prompt/skills revision and configuration reference for each run. Replaying an old thread against arbitrary new graph code/schema can change behavior; drain or explicitly migrate when upgrading.
- Raw streaming modes include updates, values, messages, custom, checkpoints, tasks and debug; current source also supports typed event streaming projections. Progress can go to run state/logs, without deploying an interactive streaming server.

Sources: [persistence](https://docs.langchain.com/oss/python/langgraph/persistence), [checkpointers](https://docs.langchain.com/oss/python/langgraph/checkpointers), [stores](https://docs.langchain.com/oss/python/langgraph/stores), [graph re-execution and idempotency](https://docs.langchain.com/oss/python/langgraph/graph-api#re-execution-and-idempotency), [released durability source](https://github.com/langchain-ai/langgraph/blob/1.2.14/libs/langgraph/langgraph/pregel/main.py), [streaming](https://docs.langchain.com/oss/python/langgraph/streaming).

## Current LangChain additions relevant to the platform

- `create_agent` is the modern graph-backed agent factory; use it and its middleware through Deep Agents rather than older `AgentExecutor`-based patterns.
- Current middleware includes model/tool call limits, model/tool retries, model fallback, summarization/context editing, PII handling, tool selection, provider tool search, filesystem search and trace policies (`TracePolicy`, `omit_payload`, `configure_trace_policy`). Add per-run call/time/token budgets; total dollar budgets and fleet-wide quota enforcement still need application policy and metrics.
- `ToolRuntime` injects context, state, store, stream writer, execution IDs and retry info without exposing those dependencies as model-generated tool arguments. Put credential clients, immutable task policy and scope here; keep secret values out of messages/checkpoint state/traces.
- Model profiles describe supported tool/structured-output/context capabilities. `ProviderStrategy` versus `ToolStrategy` selects native schema output versus output tools; validate a typed final report that includes evidence references, completeness, unavailable sources and confidence/limitations. A valid schema does not prove factual correctness.
- Standard content blocks support text, reasoning, tool calls and multimodal content across providers. This does not require extra infrastructure for current API/log investigations. Do not provision vector search/embeddings unless retrieval needs justify them.
- **Native MCP arrived in LangChain >=1.4.0:** `langchain.mcp.MCPAdapter`, installed with `langchain[mcp]`, uses FastMCP for transports, protocol negotiation, auth and connection management. Current `langchain.mcp` API is explicitly **beta**; the separate `langchain-mcp-adapters` package remains available. Choose and lock one approach after compatibility tests, not both needlessly.
- Native adapter supports HTTP, stdio, in-process servers and grouped servers; `str` targets are constrained to HTTP(S) and explicit `Path`/transport is needed for subprocess servers. MCP elicitation maps to LangGraph interruption. Targets must remain deployment-controlled, not supplied by requests/model. Approve the discovered tool schema/allowlist before binding tools, and authenticate MCP caller separately from MCP server→backend credentials.

Sources: [LangChain MCP](https://docs.langchain.com/oss/python/langchain/mcp), [released adapter source](https://github.com/langchain-ai/langchain/blob/langchain%3D%3D1.4.4/libs/langchain/langchain/mcp/adapter.py), [middleware](https://docs.langchain.com/oss/python/langchain/middleware), [runtime](https://docs.langchain.com/oss/python/langchain/runtime), [structured output](https://docs.langchain.com/oss/python/langchain/structured-output), [models](https://docs.langchain.com/oss/python/langchain/models).

## Google model integration

`langchain-google-genai` >=4.0 supports both the Gemini Developer API and Vertex AI through `ChatGoogleGenerativeAI`. Use `vertexai=True`, explicit GCP project/location, ADC and the worker's federated GKE workload identity; no Gemini API key or downloaded service-account key is necessary. Set an explicit approved model and region rather than using the integration's global location default.

The separate `ChatVertexAI` class is deprecated since `langchain-google-vertexai` 3.2.0 and slated for removal in 4.0.0; use `ChatGoogleGenerativeAI` for new Gemini chat code. The vertexai package still provides other integrations, so do not describe the entire package as obsolete.

Sources: [Google GenAI docs](https://docs.langchain.com/oss/python/integrations/chat/google_generative_ai), [released GenAI source](https://github.com/langchain-ai/langchain-google/blob/langchain-google-genai%3D%3D4.4.0/libs/genai/langchain_google_genai/chat_models.py), [released Vertex source](https://github.com/langchain-ai/langchain-google/blob/langchain-google-vertexai%3D%3D3.2.4/libs/vertexai/langchain_google_vertexai/chat_models.py).

## Observability and optional commercial services

- Baseline: structured Cloud Logging, Managed Service for Prometheus/Cloud Monitoring and OTel spans to Cloud Trace or the existing trace backend. Correlate request ID, schedule occurrence, run/thread ID, Job, graph node, subagent, model and tool, with image/config revision.
- The LangSmith SDK's official OTel integration can send to a custom collector: `LANGSMITH_OTEL_ENABLED=true`, `LANGSMITH_TRACING=true`, `LANGSMITH_OTEL_ONLY=true`, and a configured OTel provider/endpoint. Thus use the SDK instrumentor without sending data to LangSmith SaaS. Flush exporters before a short-lived Job exits and verify actual span coverage in integration tests.
- Record queue age, accepted/rejected/deduplicated requests, active runs, checkpoint failures/latency, retries/resumes/stale leases, run completeness, tool denied/errors/latency/rate limits, model calls/tokens/latency, estimated cost and quota exhaustion. Do not treat agent prose as an audit record: trusted dispatcher/tools emit resource+operation+decision events.
- Prompts/tool results may include secrets, corporate logs, repository code and personal data. Redact before export, default to metadata-only operational telemetry, and set separate access/retention for evidence/checkpoints and traces. LangChain PII or middleware trace policy controls do not automatically cover every model/tool/custom span.
- LangSmith tracing/evaluation can be useful if an approved SaaS or self-hosted installation already exists, but is optional. Local CI regression datasets and graded completion/evidence checks can work without it.
- OSS LangGraph is MIT; **LangSmith Agent Server is a distinct deployment product**. Current standalone server docs require PostgreSQL + Redis, a LangSmith API key, production license key and license/usage egress unless air-gapped mode. Kubernetes is the recommended/tested production path; docs warn against standalone serverless scale-to-zero. It offers assistants/threads/runs, background queue, REST, streaming, auth and scheduling. Do not add these dependencies to the proposed Job-based OSS design unless those server APIs are intentionally selected.
- Full self-hosted LangSmith adds additional platform dependencies and operating/licensing costs beyond a standalone Agent Server; no reason to provision the entire platform for the initial architecture.

Sources: [OTel tracing and alternate provider support](https://docs.langchain.com/langsmith/trace-with-opentelemetry), [standalone Agent Server requirements](https://docs.langchain.com/langsmith/deploy-standalone-server), [Agent Server overview](https://docs.langchain.com/langsmith/agent-server-overview).

## Sizing implications (estimates, not benchmark results)

- Single API-bound worker Job: start 1 vCPU / 2 GiB RAM request, 2 vCPU / 4 GiB limit and 1–2 GiB bounded scratch. More memory may be needed for large logs/tool outputs; narrow server-side queries before raising memory.
- Local subagents: start <=3 active specialist/model calls per run and <=5 active runs fleet-wide. Provider/backend QPS/token quotas, rather than CPU, often limit throughput. Increase from observed per-run peak memory and quota metrics.
- Persistence: Cloud SQL PostgreSQL 2 vCPU / 8 GiB and 50–100 GiB SSD with auto growth is a reasonable first production envelope; regional HA if production availability is required. Use bounded pools, e.g. 2–5 connections per Job, and measure DB connections/checkpoint load before scaling concurrency.
- The queue consumer/dispatcher is lightweight (0.25–0.5 vCPU and 512 MiB–1 GiB per replica) but its run ledger must handle atomic leases and crash recovery. Scale workers by admitted backlog and quotas, not by each agent's existence.
- These sizes are proposed starting limits to validate, not vendor minimums or measured performance.
