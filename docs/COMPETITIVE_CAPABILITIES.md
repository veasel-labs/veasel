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
| Runtime and clients | V HTTP server, SQLite sessions/events, streaming provider turns, TypeScript OpenTUI client, and `veasel run` for non-interactive session turns. `veasel run --trace-file` opts in to ATIF v1.8 trajectories (success and partial failure/cancel). Credential redaction and PEM-block redaction run at encode time. Provider-reported input/output tokens persist on completed operations and appear on operation resources, `session.turn_completed` events, ChatExchange, `GET /v1/sessions/{id}/usage`, TUI `/usage`, `veasel run --json`, and the human `veasel run` stderr summary when adapters set `usage.reported`. When providers include cache fields, adapters also persist `cache_read_tokens` / `cache_creation_tokens` (`cache_reported`) and capability `sessions.usage.prompt_cache`; absent fields stay unreported and no % savings are invented. Cost is not calculated. Traces can still contain workspace content. Edits, shell and MCP still require approval, so this is not an unattended benchmark adapter. | Codex documents an app-server protocol; OpenCode documents a shared server, typed clients, and Models.dev-priced usage; OpenHands documents CLI, headless, web and session workflows. | Add a durable usage/cost dashboard only with pinned price schedules; keep sandboxed benchmark policy before adapter claims. |
| Providers | OpenAI Chat Completions, OpenAI Responses, Meta Responses, Anthropic Messages and Gemini streaming adapters with provider-native tool-call aggregation; exercised by deterministic HTTP fixtures and `scripts/api-smoke.sh`. The server-backed TUI catalog offers 210 endpoint presets and live model discovery across four protocols. Of these, 178 fixed-URL, single-credential OpenAI-compatible endpoints are generated from the pinned Models.dev snapshot and share Veasel's Chat Completions transport; presets do not imply provider-specific auth, tool-call compatibility, or equivalent model capability. OpenAI reasoning parameters are emitted only for supported model families; Meta uses encrypted reasoning replay for multi-step tool loops. Meta's one-million-token model context is not yet exposed by Veasel's 1 MiB input cap. | OpenCode documents 75+ providers using AI SDK and Models.dev, with provider-specific integrations; Gemini CLI, Claude Code and Codex expose their own vendor-native configurations. Support matrices and provider counts are not directly comparable. | Expand protocol/auth coverage only with endpoint fixtures or documented provider contracts; compare identical provider/model snapshots only where each harness truly supports them. |
| Tool execution and approvals | Bounded list/read/search; edits, shell and MCP calls persist exact proposals and require user approval by default (`ask`). Graduated `execution_policy` (`ask`/`auto-edit`/`sandbox-auto`) applies allow/deny/ask with ask→deny when non-interactive; shell auto-apply only under fail-closed OS sandbox; MCP denied under sandbox-auto. Approved shell uses Bubblewrap/Seatbelt/AppContainer+Job when available (honest capabilities; not Codex WFP/LPAC). MCP stdio remains unsandboxed. | OpenCode documents per-tool permissions; Gemini CLI documents allow/deny/ask policies and sandboxing; Claude Code documents permission modes; Harbor exposes adapter capabilities including tool and sandbox behavior. | Keep deepening MCP containment and OAuth UX; do not add LLM approval classifiers without a cost budget. |
| Context selection and caching | Provider histories are bounded by the 1 MiB UTF-8 request cap and a 64-message page. When measured payload bytes or message count cross a local pressure threshold, the runtime replaces older in-flight messages with an untrusted summary (default extractive; optional `native` structured local summary or `llm` one-shot completion via `VEASEL_SESSION_COMPACTION_SUMMARIZER`), keeps recent turns verbatim, preserves durable SQLite history, and emits `session.compaction` with measured bytes before/after, a conservative bytes/4 token bound, summarizer mode, and provider usage only when reported. Capability `session.compaction.summarizer` appears when native/llm is enabled. An extractive repository map ranks workspace paths/symbols under a measured UTF-8 byte budget, may inject into the system prompt, exposes `GET /v1/sessions/{id}/workspace/map`, and emits `session.repository_map` with measured sizes (not tree-sitter/PageRank parity or claimed token savings). Prompt-cache **accounting** surfaces provider-reported cache read/write tokens when present (`sessions.usage.prompt_cache`). Anthropic Messages emit request-side `cache_control` markers by default (`provider.anthropic.prompt_cache`; `VEASEL_ANTHROPIC_PROMPT_CACHE=off` disables). OpenAI Chat/Responses emit `prompt_cache_key` (optional `prompt_cache_retention`) by default for catalog `openai` / `openai-responses` (`provider.openai.prompt_cache`; `VEASEL_OPENAI_PROMPT_CACHE=off` disables). Markers/keys enable caching attempts; hits remain provider-reported only—no invented savings. Gemini may reference an explicit `cachedContent` resource via `VEASEL_GEMINI_CACHED_CONTENT` (`provider.gemini.prompt_cache` when set). No retrieval index yet. | Aider documents repository maps, history limits and prompt-cache-aware prompt ordering. OpenCode and Pi document LLM/native compaction with structured summaries. | Keep savings claims tied to measured bytes and provider-reported tokens; Gemini create/expire management remains open. |
| Parallelism and long tasks | Per-session turn serialization, bounded provider concurrency, async turn status/list/cancel, and durable `queued` Prefer: respond-async recovery are tested. Multi-tool rounds of workspace list/read/search run concurrently with ordered transcript append; skill/edit/shell/MCP stay sequential. Claimed mid-flight work stays fail-closed as `uncertain`. Multi-agent isolation remains open in `docs/IMPLEMENTATION_PLAN.md`. | Goose documents recipes and subagents; Codex and OpenHands document resumable/server-backed workflows; Harbor can run isolated benchmark jobs. | Keep restart tests; add multi-agent isolation only with idempotency and resource bounds. |
| Extensibility | Agent Plugin Skills and MCP have functional subsets with local fixtures; the documented conformance ledger is `docs/compatibility/agent-plugins.md`. Full v1.0 conformance remains open. | Agent Plugins defines a portable package format; OpenCode, Goose, Gemini CLI and Cursor document distinct extension/MCP surfaces. | Implement against the pinned normative spec and test permission/lifecycle boundaries, not just discovery. |
| Benchmark integration | A CLI process-startup runner and SQLite microbenchmarks exist. Opt-in ATIF v1.8 export validates against Harbor's trajectory model. `benchmarks/harbor/veasel_agent.py` is a custom Harbor 0.24.0 `BaseInstalledAgent` exercised by a disposable smoke task (reward 1.0 plumbing evidence only). Harbor Index / Terminal-Bench / SWE-bench evaluations have not been run or submitted; no leaderboard claim. | Harbor currently documents installed adapters for Claude Code, Codex, Cursor CLI, Gemini CLI, Goose, OpenCode, Pi and others, with trajectory capabilities. Harbor Index publishes common tasks and requires the submission procedure in its repository. | Keep the smoke adapter honest; authorize any paid same-model evaluation before claiming scores. |
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
