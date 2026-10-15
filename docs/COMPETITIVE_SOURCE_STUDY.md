# Competitive coding-agent source study

**Reviewed:** 2026-10-12; clone inventory and selected rechecks 2026-10-15.
This document records implementation observations from the pinned upstream
commits below. It is an engineering input, not a feature or performance claim
about Veasel. Recheck upstream before using these references to make
compatibility decisions. Local read-only clones live under
`~/.cache/veasel-reference-research` (28/28 present on 2026-10-15).

## Source revisions

| Project | Inspected revision | License / scope |
|---|---|---|
| [OpenCode](https://github.com/anomalyco/opencode/tree/37df62f4a1b6d89187a1169187a6cef10557c0ca) | `37df62f4a1b6d89187a1169187a6cef10557c0ca` (`dev`) | MIT; session runner, max-steps, usage accounting |
| [Codex CLI](https://github.com/openai/codex/tree/160b2b1ef62114eeb41e41e5e3be0000d944b713) | `160b2b1ef62114eeb41e41e5e3be0000d944b713` | Apache-2.0; turn orchestration and sandbox boundary |
| [mini-SWE-agent](https://github.com/SWE-agent/mini-SWE-agent/tree/04d809ceab9df28f9adaed044884180159172930) | `04d809ceab9df28f9adaed044884180159172930` | MIT; minimal loop, model/environment boundary |
| [Goose](https://github.com/aaif-goose/goose/tree/dd17bf2021f3fb3b326c471593c352e1b0d62bbd) | `dd17bf2021f3fb3b326c471593c352e1b0d62bbd` | Apache-2.0; agent state machine and effects |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli/tree/06d329873703ddabe8a842d962342ac4ad779e83) | `06d329873703ddabe8a842d962342ac4ad779e83` | Apache-2.0; telemetry, redaction, and checkpointing |
| [Aider](https://github.com/Aider-AI/aider/tree/5dc9490bb35f9729ef2c95d00a19ccd30c26339c) | `5dc9490bb35f9729ef2c95d00a19ccd30c26339c` | Apache-2.0; syntax-aware repository map and cache |
| [Cline](https://github.com/cline/cline/tree/789f79e46d3ba579717e8dc8be35fe28af935b06) | `789f79e46d3ba579717e8dc8be35fe28af935b06` | Apache-2.0; shared agent/session and CLI runtime |
| [OpenHands](https://github.com/OpenHands/OpenHands/tree/1c75a05d587bcb502cd3f63d7e13eaa98ca84d53) | `1c75a05d587bcb502cd3f63d7e13eaa98ca84d53` | MIT; web client; pair with software-agent-sdk |
| [software-agent-sdk](https://github.com/OpenHands/software-agent-sdk/tree/8efff8d3cf1a5a3fcf7ce5e3b97c7f00684d9547) | `8efff8d3cf1a5a3fcf7ce5e3b97c7f00684d9547` | MIT; Agent Server REST/WebSocket lifecycle |
| [Continue](https://github.com/continuedev/continue/tree/5522c6f44ca0ac3528b37244818fbfa39b5af470) | `5522c6f44ca0ac3528b37244818fbfa39b5af470` | Apache-2.0; context-provider and repository-map interfaces |
| [Crush](https://github.com/charmbracelet/crush/tree/f49b28113b3bab3fcfe193676cc3f7fb858d6411) | `f49b28113b3bab3fcfe193676cc3f7fb858d6411` | MIT; Bubble Tea TUI status/diff presentation |
| [Pi](https://github.com/earendil-works/pi/tree/b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6) | `b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6` | Apache-2.0; session forks and compaction |
| [Harbor](https://github.com/harbor-framework/harbor/tree/f17ded80e938bccfd43bcf271f225f9dcaba5283) | `f17ded80e938bccfd43bcf271f225f9dcaba5283` | Upstream integration contract and installed-agent adapters |

Proprietary Claude Code and Cursor were evaluated only through public product
documentation and observable workflows; no proprietary source was inspected or
copied. No implementation below is copied into Veasel.

## Findings and decisions

### OpenCode — streamed execution with explicit permission enforcement

The core runner in
[`step.ts`](https://github.com/anomalyco/opencode/blob/3e78cd58e001a9b89ddbde53bb889190a934b649/packages/core/src/session/runner/step.ts)
streams provider events, starts tool executions as scoped fibers, publishes
tool lifecycle events, and joins those fibers before settling the assistant
turn. The turn path handles context overflow before output, interrupted
streams, unknown finish reasons, retry classification, and incomplete tool
calls. Its context builder filters tools and instructions based on agent and
session permissions, while the tool boundary performs its own authorization;
discovery filtering is not treated as the security check.

**Useful principle:** keep user-visible event publication, execution lifetime,
and side-effect authorization explicit. Concurrent read-only calls are a
possible Veasel optimization, but require profiling and ordering/cancellation
tests first. Veasel currently executes provider tool calls sequentially and
does not have equivalent user-facing recovery/permission breadth. Preserve the
existing approval boundary while improving event lifecycles; don't copy its
TypeScript/Effect stack into V.

Rechecked the session runner on 2026-10-15 at
`37df62f4a1b6d89187a1169187a6cef10557c0ca` (`dev`), in
`packages/core/src/session/runner/llm.ts` and `max-steps.ts`. When an agent
reaches its step limit, that runner keeps the tool definitions for the cached
prefix but sets tool choice to none and asks for a text-only status. The rest
of the 2026-10-12 OpenCode notes above were not re-audited at this commit.
Veasel still executes tools one at a time. Its own tool-round cap now spends
the blocked round on one tools-disabled completion and keeps that text when it
is non-empty. The pending tool calls are not executed. This does not copy
OpenCode's prompt, compaction, or permission model.

Rechecked usage accounting on 2026-10-15 at the same OpenCode commit in
[`packages/core/src/session/usage.ts`](https://github.com/anomalyco/opencode/blob/37df62f4a1b6d89187a1169187a6cef10557c0ca/packages/core/src/session/usage.ts).
That module normalizes provider token fields and multiplies them by Models.dev
price tiers to produce USD cost. Veasel deliberately does not calculate cost
without a pinned authoritative price schedule. It now persists adapter-reported
input/output token totals on completed operations, completion events, ChatExchange,
`veasel run` JSON, and the TUI status line when `usage.reported` is true.

### Codex CLI — concurrent work, ordered transcript, independent sandbox policy

In [`stream_events_utils.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/stream_events_utils.rs)
and [`turn.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/session/turn.rs),
tool-call items are recorded before dispatch and asynchronous tool work is
collected while preserving request order in transcript processing. Sandbox
policy has separate implementations under
[`core/src/tools/sandboxing.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tools/sandboxing.rs)
and platform sandbox modules; user approval and OS enforcement are separate
concerns.

**Useful principle:** persist intent before effects; preserve deterministic
history even when execution is concurrent; distinguish authorization from
containment. Veasel persists proposed changes and operation state. Manually
approved shell still runs without an OS sandbox; autonomous Linux shell uses a
Bubblewrap mount/network namespace and fails closed if it cannot start. This is
best-effort containment and does not provide Codex-level sandbox guarantees;
platform-specific escape testing and stronger workspace isolation remain open.

### mini-SWE-agent — a baseline small enough to falsify complexity

[`DefaultAgent`](https://github.com/SWE-agent/mini-SWE-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/agents/default.py)
keeps the loop close to query → execute → append messages, with explicit step,
cost, wall-time, and consecutive-format-error limits. Model and environment
are separate interfaces; the Docker environment owns command execution and
captures return codes. Trajectories are emitted during execution, including
when a step fails.

**Useful principle:** maintain a minimal Veasel runtime/agent baseline and
measure each additional context, planning, or orchestration layer against it.
Veasel's headless command now reuses its production session runtime, but it
does not yet auto-apply edits or produce benchmark-ready trajectories. Keep
that limitation visible; add richer policies only with isolated tests and
task-level evidence.

Rechecked `environments/extra/bubblewrap.py` at the same commit
`04d809ceab9df28f9adaed044884180159172930` on 2026-10-15. That optional
environment bind-mounts the host `/usr`, `/bin`, `/lib`, `/etc`, and the
working directory, and it does not unshare the network. Veasel's autonomous
Linux path in `shell_commands.v` is stricter: `--unshare-all`, a read-only
host root, hidden home and removable mounts, a writable workspace only, a
filtered environment, and a hard failure when `bwrap` is missing or the
workspace root is too broad. Do not relax that path to match mini-swe-agent.
It is still not a Codex-level sandbox, and manually approved shell commands
remain unsandboxed.

### Goose — state machine and runtime effects

[`machine.rs`](https://github.com/aaif-goose/goose/blob/4617040c7b650b37d599bdaa08d3790572c19ae8/crates/goose-agent/src/machine.rs)
models steps as operations or inference, loads session state through a
`SessionLoader`, applies effects through an `EffectHandler`, and exposes
continuing/yielded/cancelled outcomes. It checks cancellation around each step
and records which step was interrupted. This leaves storage and runtime effects
replaceable without putting provider execution into a presentation layer.

**Useful principle:** represent lifecycle outcomes and effects explicitly.
Veasel's API already has durable operation states and separate transport/core
modules; next improvement is a stable internal event/trace contract shared by
TUI, headless execution, and benchmark exports. The state-machine abstraction
is useful only if it reduces branching or enables another runtime; avoid a
parallel abstraction over the current loop without such evidence.

### Gemini CLI — telemetry should be typed, sanitized, and testable

The inspected core includes separate telemetry modules for semantic events,
metrics, exporters, rate limiting, redaction, and startup/memory monitors; see
[`telemetry/`](https://github.com/google-gemini/gemini-cli/tree/9b6e0265d16bbd29ca51e33c9e0c01dc4cec5e83/packages/core/src/telemetry)
and its tests. Checkpointing is documented in
[`checkpointing.md`](https://github.com/google-gemini/gemini-cli/blob/9b6e0265d16bbd29ca51e33c9e0c01dc4cec5e83/docs/cli/checkpointing.md)
and its utilities have dedicated tests.

**Useful principle:** telemetry privacy is an implementation property: redact
before export, bound/rate-limit high-volume events, and test the sanitizer.
Checkpoints should capture recoverable state, not replay uncertain external
effects. Veasel currently lacks a versioned trace schema and token/cost
accounting; introduce those as opt-in machine-readable outputs before adding
an exporter or dashboard. OTel is not a substitute for durable session state.

### Aider — repository structure under an explicit token budget

[`RepoMap`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/repomap.py)
uses language parsers and tree-sitter queries to collect symbol tags, caches
tags/maps in SQLite, ranks repository information against mentioned files and
identifiers, and sizes the map against a token budget. It can expand the budget
when no files are already in context and disables itself on recursion failure
rather than crashing the agent.

**Useful principle:** context selection should be syntax-aware, bounded,
incremental, and observable. Veasel currently exposes bounded list/read/search,
not a symbol map or retrieval cache. First benchmark search and context
assembly on fixed repositories; then evaluate a V-native symbol index or an
optional parser adapter against grep-only retrieval. Do not build an index
whose token/latency benefit has not been measured.

### Cline — one runtime for CLI and interactive surfaces

Cline's CLI has separate interactive and headless entry points under
[`apps/cli/src/runtime/`](https://github.com/cline/cline/tree/8eba11b2703f5b12d3f415544be37ffc0ca03be1/apps/cli/src/runtime).
Its SDK runtime orchestrator is under
[`sdk/packages/core/src/runtime/orchestration/`](https://github.com/cline/cline/tree/8eba11b2703f5b12d3f415544be37ffc0ca03be1/sdk/packages/core/src/runtime/orchestration),
with an agent-runtime provider seam in
[`sdk/packages/agents/src/`](https://github.com/cline/cline/tree/8eba11b2703f5b12d3f415544be37ffc0ca03be1/sdk/packages/agents/src).
The CLI's `run-agent.ts` consumes that SDK runtime and emits session and usage
events, rather than implementing an unrelated agent loop.

**Useful principle:** Veasel's `veasel run`, API, and TUI should keep sharing
the V runtime and persisted operations. The new headless CLI follows this
boundary; it still needs completion trajectories, budget controls, and
benchmark-safe execution policies. Cline's larger extension surface also has
more lifecycle complexity; adopt only interfaces needed by real clients.

### OpenHands — typed remote execution and session identity

The OpenHands web client at
`1c75a05d587bcb502cd3f63d7e13eaa98ca84d53` still routes commands through a
typed runtime-service client. The separately maintained Agent Server in
[`software-agent-sdk`](https://github.com/OpenHands/software-agent-sdk/tree/8efff8d3cf1a5a3fcf7ce5e3b97c7f00684d9547)
at `8efff8d3cf1a5a3fcf7ce5e3b97c7f00684d9547` was inspected in
`openhands-agent-server/openhands/agent_server/event_service.py`: conversation
leases, pub/sub event fan-out, goal controllers, and resume prompts keep a
durable remote session distinct from the UI. That is a much larger distributed
runtime than Veasel's loopback server.

**Useful principle:** runtime APIs need explicit session identity, bounded
timeouts, typed results, and cursor/reconnect behavior. Veasel already has
operation IDs, SSE replay, and uncertain-on-restart classification. Adopt
leases or remote workspaces only when a real multi-client product need appears;
keep the V loopback core for local TUI/headless use.

### Continue — context providers compose without owning retrieval policy

[`RepoMapContextProvider`](https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/context/providers/RepoMapContextProvider.ts)
implements a small context-provider contract: discover workspace folders,
allow selection of a folder or full project, request a generated map, and
optionally include signatures depending on indexing/configuration. Other
context sources implement the same provider seam.

**Useful principle:** keep context sources replaceable and explicit, and let
users scope what enters a request. Veasel's current provider prompts contain
bounded, tool-requested repository data; a future retrieval layer should have
an inspectable budget and source provenance. Avoid porting Continue's IDE
context catalog into a terminal agent without matching user workflows.

### Roo Code — archived mode personas, not a performance baseline

At archived commit `b867ec9145750d0ae1ff7f02d35406e9bf2a0b16`, Roo Code's
product surface centers on Code / Architect / Ask / Debug modes plus custom
mode prompts (`src/` custom-modes migration and README). Those personas are a
workflow UX pattern, not evidence of superior task success. Veasel should keep
task-oriented slash commands and Skills rather than cloning mode menus, and
must not treat this archived tree as a latency or quality baseline.

### Kilo Code — cost visibility without forcing priced estimates

At `a72ad30628fd6583fb492a84badf36bd9dba0aee`, Kilo's multisurface product
surfaces model/provider switching and cost visibility as part of session UX.
Veasel now exposes honest provider-reported token totals per turn and per
session (`GET /v1/sessions/{id}/usage`, TUI `/usage`) while keeping cost marked
unavailable until a pinned price schedule exists. Do not invent USD figures from
unauthenticated catalogs.

### Crush — status chrome and interaction-tested TUI surfaces

At `f49b28113b3bab3fcfe193676cc3f7fb858d6411`, Crush's Bubble Tea UI under
`internal/ui/model/status.go` and `internal/ui/chat/` keeps mode badges, help
hints, and message rendering as separate models with golden/bench tests. Veasel
keeps OpenTUI Core renderables and now surfaces provider-reported token counts
in the footer after a turn completes. Richer markdown/diff chrome remains open;
do not port Crush's Lip Gloss stack into the TypeScript client.

### Pi — session forks without forcing compaction into the core loop

At `b06c1f2cf1dea6af8748ddeee18c23587d2cb7c6`, Pi's durable session layer in
`packages/durable/src/session/forks.ts` copies conversation-scoped documents
under explicit `asOf`/`current` fork policies. Compaction is a separate
conversation task. Veasel sessions are linear SQLite histories today; add
forking only with a clear user workflow and restore tests. OpenCode-style
automatic compaction is still deferred until token/task measurements justify it.

## Benchmark integration implications

Harbor documentation currently recommends a `BaseInstalledAgent` adapter when
the CLI should run in the task environment; external agents are for loops that
must remain in Harbor and control `BaseEnvironment`. The upstream implementation
in [`installed/base.py`](https://github.com/harbor-framework/harbor/blob/dc933be707feafbb9efcdf092cb8a0e391332617/src/harbor/agents/installed/base.py)
provides install/run plumbing, configuration mapping, error classification,
and trajectory hooks. Existing adapters such as
[`opencode.py`](https://github.com/harbor-framework/harbor/blob/dc933be707feafbb9efcdf092cb8a0e391332617/src/harbor/agents/installed/opencode.py)
and [`mini_swe_agent.py`](https://github.com/harbor-framework/harbor/blob/dc933be707feafbb9efcdf092cb8a0e391332617/src/harbor/agents/installed/mini_swe_agent.py)
parse native machine-readable events and provider usage into ATIF; merely
starting a CLI and returning an exit code is not a complete adapter.

Harbor Index currently documents 80 tasks, at least five public trials per
task, a pinned judge-verifier config, and a leaderboard PR after a public job
upload. Veasel has not run this evaluation. The current headless runner is a
useful prerequisite, not a Harbor integration: it does not yet make approved
workspace edits automatically under a sandboxed unattended policy. It can emit
ATIF trajectories with provider-reported token totals when adapters supply them,
but cost remains unavailable and the adapter contract for public tasks is not
satisfied. Paid model calls and public uploads remain separate authorized
steps.

## What to measure before changing the harness

1. Add a deterministic baseline for process startup, file search, context
   assembly, tool dispatch, session restore, and cancellation.
2. Extend the opt-in ATIF v1.8 successful-turn trace with failed/cancelled
   trajectories, request counts, actual provider usage when available, tool
   timings, and lifecycle transitions; redact secrets and source by default.
   The present trace includes model-visible system/session context and raw
   tool I/O and must be treated as sensitive.
3. Profile large-repository search/context workloads and compare simple
   traversal with syntax-aware maps before selecting an index design.
4. Compare sequential and bounded parallel read-only tool execution with
   ordered transcript replay and cancellation tests.
5. Build Harbor ATIF conversion from the trace contract; validate trajectory
   schemas and exit status locally on a small permitted fixture before a public
   benchmark run.

These are implementation gates, not claims that the measurements or
integrations already exist. For current verified feature status, see
[`COMPETITIVE_CAPABILITIES.md`](COMPETITIVE_CAPABILITIES.md) and
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).
