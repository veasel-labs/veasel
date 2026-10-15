# Competitive coding-agent source study

**Reviewed:** 2026-10-12. This document records implementation observations from
the pinned upstream commits below. It is an engineering input, not a feature or
performance claim about Veasel. Recheck upstream before using these references
to make compatibility decisions.

## Source revisions

| Project | Inspected revision | License / scope |
|---|---|---|
| [OpenCode](https://github.com/anomalyco/opencode/tree/3e78cd58e001a9b89ddbde53bb889190a934b649) | `3e78cd58e001a9b89ddbde53bb889190a934b649` | MIT; core session runner and tool policy |
| [Codex CLI](https://github.com/openai/codex/tree/a9b0815167c27ab13719dd12d13b63e02b70d221) | `a9b0815167c27ab13719dd12d13b63e02b70d221` | Apache-2.0; turn orchestration and sandbox boundary |
| [mini-SWE-agent](https://github.com/SWE-agent/mini-SWE-agent/tree/04d809ceab9df28f9adaed044884180159172930) | `04d809ceab9df28f9adaed044884180159172930` | MIT; minimal loop, model/environment boundary |
| [Goose](https://github.com/aaif-goose/goose/tree/4617040c7b650b37d599bdaa08d3790572c19ae8) | `4617040c7b650b37d599bdaa08d3790572c19ae8` | Apache-2.0; agent state machine and effects |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli/tree/9b6e0265d16bbd29ca51e33c9e0c01dc4cec5e83) | `9b6e0265d16bbd29ca51e33c9e0c01dc4cec5e83` | Apache-2.0; telemetry, redaction, and checkpointing |
| [Aider](https://github.com/Aider-AI/aider/tree/5dc9490bb35f9729ef2c95d00a19ccd30c26339c) | `5dc9490bb35f9729ef2c95d00a19ccd30c26339c` | Apache-2.0; syntax-aware repository map and cache |
| [Cline](https://github.com/cline/cline/tree/8eba11b2703f5b12d3f415544be37ffc0ca03be1) | `8eba11b2703f5b12d3f415544be37ffc0ca03be1` | Apache-2.0; shared agent/session and CLI runtime |
| [OpenHands](https://github.com/All-Hands-AI/OpenHands/tree/0f1b6f62507f1ccdb4e63f61cf3dc48356a0d4fa) | `0f1b6f62507f1ccdb4e63f61cf3dc48356a0d4fa` | MIT; inspected the web client/runtime API boundary only, not the separately maintained agent-server implementation |
| [Continue](https://github.com/continuedev/continue/tree/5522c6f44ca0ac3528b37244818fbfa39b5af470) | `5522c6f44ca0ac3528b37244818fbfa39b5af470` | Apache-2.0; context-provider and repository-map interfaces |
| [Harbor](https://github.com/harbor-framework/harbor/tree/dc933be707feafbb9efcdf092cb8a0e391332617) | `dc933be707feafbb9efcdf092cb8a0e391332617` | Upstream integration contract and installed-agent adapters |

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

The inspected repository revision is the OpenHands web client, not the
separately maintained agent-server runtime. In
[`agent-server-runtime-service.ts`](https://github.com/All-Hands-AI/OpenHands/blob/0f1b6f62507f1ccdb4e63f61cf3dc48356a0d4fa/src/api/runtime-service/agent-server-runtime-service.ts),
commands and file access go through typed SDK clients using a per-conversation
runtime URL and session credential; timeout units are deliberately handled at
the request boundary. Session frames and sequence cursors are typed and tested.

**Useful principle:** runtime APIs need explicit session identity, bounded
timeouts, typed results, and cursor/reconnect behavior. Veasel has a loopback
API and operation IDs but no remote runtime or distributed session model. The
web-client snapshot cannot support claims about OpenHands' container
enforcement or internal agent loop; study those in the agent-server repository
before any direct comparison.

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
workspace edits automatically, provide a complete ATIF trajectory, expose
provider token/cost usage, or satisfy the adapter's execution and artifact
contract. Paid model calls and public uploads remain separate authorized
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
