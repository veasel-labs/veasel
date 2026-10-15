# Coding agent capability comparison

**Research snapshot:** 2026-10-12  
**Purpose:** identify tested architectural capabilities worth learning from and
separate product documentation from evidence about task performance. This is
not a ranking. A documented feature is not evidence that one agent completes
more work, uses fewer resources, or is more reliable.

## Evidence rules

- **Verified in Veasel** means the behavior is implemented and has a named
  local test or CI workflow in the current repository. It does not imply an
  independent performance result.
- **Documented upstream** means an official source describes the capability;
  this document did not independently validate every platform or mode.
- **Not measured** means there is no comparable, controlled Veasel experiment
  supporting a performance or quality claim.
- Refresh moving upstream sources and the pinned Veasel evidence when a related
  implementation or public comparison begins. Record model, harness, dataset,
  environment, and revision separately.

## Capability matrix

| Area | Veasel Code evidence | Competitive designs documented upstream | Next engineering question |
|---|---|---|---|
| Runtime and clients | V HTTP server, SQLite sessions/events, streaming provider turns, TypeScript OpenTUI client, and `veasel run` for non-interactive session turns. `veasel run --trace-file` opts in to ATIF v1.8 trajectories (success and partial failure/cancel). Credential redaction and PEM-block redaction run at encode time. Provider-reported input/output tokens persist on completed operations and appear on operation resources, `session.turn_completed` events, ChatExchange, `GET /v1/sessions/{id}/usage`, TUI `/usage`, `veasel run --json`, and the human `veasel run` stderr summary when adapters set `usage.reported`. Cost is not calculated. Traces can still contain workspace content. Edits, shell and MCP still require approval, so this is not an unattended benchmark adapter. | Codex documents an app-server protocol; OpenCode documents a shared server, typed clients, and Models.dev-priced usage; OpenHands documents CLI, headless, web and session workflows. | Add a durable usage/cost dashboard only with pinned price schedules; keep sandboxed benchmark policy before adapter claims. |
| Providers | OpenAI Chat Completions, OpenAI Responses, Meta Responses, Anthropic Messages and Gemini streaming adapters with provider-native tool-call aggregation; exercised by deterministic HTTP fixtures and `scripts/api-smoke.sh`. The server-backed TUI catalog offers 210 endpoint presets and live model discovery across four protocols. Of these, 178 fixed-URL, single-credential OpenAI-compatible endpoints are generated from the pinned Models.dev snapshot and share Veasel's Chat Completions transport; presets do not imply provider-specific auth, tool-call compatibility, or equivalent model capability. OpenAI reasoning parameters are emitted only for supported model families; Meta uses encrypted reasoning replay for multi-step tool loops. Meta's one-million-token model context is not yet exposed by Veasel's 1 MiB input cap. | OpenCode documents 75+ providers using AI SDK and Models.dev, with provider-specific integrations; Gemini CLI, Claude Code and Codex expose their own vendor-native configurations. Support matrices and provider counts are not directly comparable. | Expand protocol/auth coverage only with endpoint fixtures or documented provider contracts; compare identical provider/model snapshots only where each harness truly supports them. |
| Tool execution and approvals | Bounded list/read/search; edits, shell and MCP calls persist exact proposals and require user approval; recovery avoids replay. See `agent_runtime_test.v`, `workspace_tools_test.v`, `plugins_test.v` and `plugin_mcp_*_test.v`. Commands currently run with host-user privileges and are not sandboxed. | OpenCode documents per-tool permissions; Gemini CLI documents allow/deny/ask policies and sandboxing; Claude Code documents permission modes; Harbor exposes adapter capabilities including tool and sandbox behavior. | Keep approval semantics explicit; add a non-interactive policy only when its trust boundary and sandbox are enforced by the runtime. |
| Context selection and caching | Provider histories are bounded by the request limit; workspace tools cap results. No repository map, retrieval index, prompt-cache accounting, or adaptive compaction is evidenced yet. | Aider documents repository maps, history limits and prompt-cache-aware prompt ordering. Pi documents a small composable core and append-only session history. | Measure task success, tokens, cache hits and prompt stability before adding indexing or compaction. |
| Parallelism and long tasks | Per-session turn serialization, bounded provider concurrency, async turn status and cancellation are tested. Async workers are process-local; queued-job recovery and multi-agent isolation remain open in `docs/IMPLEMENTATION_PLAN.md`. | Goose documents recipes and subagents; Codex and OpenHands document resumable/server-backed workflows; Harbor can run isolated benchmark jobs. | Add durable jobs/checkpoints only with idempotency, bounded resource use and restart tests. |
| Extensibility | Agent Plugin Skills and MCP have functional subsets with local fixtures; the documented conformance ledger is `docs/compatibility/agent-plugins.md`. Full v1.0 conformance remains open. | Agent Plugins defines a portable package format; OpenCode, Goose, Gemini CLI and Cursor document distinct extension/MCP surfaces. | Implement against the pinned normative spec and test permission/lifecycle boundaries, not just discovery. |
| Benchmark integration | A CLI process-startup runner and one local baseline are available from [merged PR #48](https://github.com/veasel-labs/veasel/pull/48). It measures only local `--version`/`--help` process runs. Headless successful-turn ATIF export now passes Harbor's trajectory validator, but no Harbor installed-agent adapter or task evaluation exists yet. Harbor, Terminal-Bench and SWE-bench task evaluations have not been run or submitted. | Harbor currently documents installed adapters for Claude Code, Codex, Cursor CLI, Gemini CLI, Goose, OpenCode, Pi and others, with trajectory capabilities. Harbor Index publishes common tasks and requires the submission procedure in its repository. | Design a sandboxed policy that safely handles Veasel's proposed edit/shell tools; then implement and test the Harbor adapter. |
| Performance claims | No task-resolution, cost-per-solved-task, memory, CPU, or harness-isolated results are available. Deterministic process-startup and SQLite session-store microbenchmarks are local-runtime measurements, not agent-quality comparisons. | Public documentation describes features and configuration, but cross-agent performance cannot be inferred from feature presence. | Publish task results only with pinned tasks, models, budgets, repetitions, raw trajectories and uncertainty. |

## Current source set

The links below point to official documentation or source repositories. Product
documentation is evidence that a feature is supported by that product; it is
not independent performance evidence. Repository `main` links move over time.

| Project | Official source reviewed | Useful design to evaluate |
|---|---|---|
| Claude Code | [Overview and configuration](https://code.claude.com/docs/en/overview) | Permission boundaries, project instructions, interactive workflow. Implementation is proprietary; no source reuse. |
| Codex CLI | [CLI documentation](https://developers.openai.com/codex/cli) · [repository](https://github.com/openai/codex) | App-server/client boundary, explicit approvals, typed lifecycle. |
| OpenCode | [Agents](https://opencode.ai/docs/agents/) · [Tools](https://opencode.ai/docs/tools/) · [repository](https://github.com/anomalyco/opencode) | Permissioned tools, configured agents and shared server architecture. |
| Cursor CLI | [Using the CLI](https://docs.cursor.com/en/cli/using) · [Headless mode](https://docs.cursor.com/en/cli/headless) | Non-interactive output modes, repository instructions and MCP integration. |
| Gemini CLI | [Policy engine](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/policy-engine.md) · [Sandbox](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/sandbox.md) | Per-tool allow/deny/ask policy and explicit sandbox modes. |
| Aider | [Prompt caching](https://aider.chat/docs/usage/caching.html) · [Options](https://aider.chat/docs/config/options.html) | Stable prompt prefixes, repository maps, history limits and model roles. |
| Goose | [Official project documentation](https://block.github.io/goose/index.html) | CLI/desktop/API surfaces, MCP, recipes and subagents. |
| OpenHands | [CLI quick start](https://github.com/OpenHands/docs/blob/main/openhands/usage/cli/quick-start.mdx) · [Custom sandbox](https://github.com/OpenHands/docs/blob/main/openhands/usage/advanced/custom-sandbox-guide.mdx) | Headless and resumable use, isolated execution environments. |
| SWE-agent | [Usage tutorial](https://github.com/SWE-agent/SWE-agent/blob/main/docs/usage/cl_tutorial.md) · [mini-SWE-agent](https://github.com/SWE-agent/mini-swe-agent) | Issue-to-patch workflows and a deliberately small agent loop. The upstream project points new users toward mini-SWE-agent; evaluate both as distinct harnesses. |
| Harbor | [Custom agents](https://docs.harborframework.com/agents/custom-agents) · [Pre-integrated agents](https://docs.harborframework.com/agents/pre-integrated-agents) | Installed-agent contract, execution metadata, capabilities and ATIF trajectories. |

## Benchmark status

| Evaluation | Dataset/version policy | Veasel status |
|---|---|---|
| Harbor Index | Follow the exact dataset revision and [submission guide](https://github.com/harbor-framework/harbor-index/blob/main/leaderboard/SUBMIT.md), including all tasks, trial count, execution defaults and public artifacts. | Not run; not submitted; no leaderboard claim. |
| Terminal-Bench | Pin a released dataset version; the reviewed release was 4.0.0. Do not treat an open milestone as a release. | Not run; not submitted. |
| SWE-bench | Use the official evaluator and pin the selected variant/dataset commit. Keep Verified, Multilingual and Multimodal results separate. | Not run; not submitted. |
| Agent runtime microbenchmarks | Fixed synthetic fixtures, documented host, cold/warm conditions, repetitions and raw samples. | PR #48 provides a process-startup baseline. The SQLite in-memory session round-trip benchmark measures create-session, persist-exchange, and read-message/event paths; it runs two warmups plus 21 measured samples and reports raw samples and p50/p90/p95. It does not measure agent task quality, external storage, CPU/RSS, or cross-agent performance. |

Before any metered evaluation, record an authorized budget and enforce a hard
run-level cap. Local adapter tests and synthetic workloads should not call
external model APIs.

## Sources and scope

This snapshot is a research index, not a complete audit of every platform,
release, model, or operating system. The linked pages are the starting points
for implementation and should be rechecked at the time of a contribution.
Veasel evidence is tied to repository tests and the implementation plan; no
comparative task success or cost claim is made here.
