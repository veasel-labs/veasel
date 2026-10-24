# Competitive source audit — 2026-10-24

This audit refreshes the older, narrower [`COMPETITIVE_SOURCE_STUDY.md`](COMPETITIVE_SOURCE_STUDY.md).
Each repository was cloned with `--depth 1 --filter=blob:none` into an isolated
research directory. The table pins the inspected revision and names the actual
implementation and test/contract paths reviewed. The source study is design
input only: no competitor code was copied, no performance comparison was run,
and no benchmark result is claimed.

## Coding agents and harnesses

| Project and inspected revision | Implementation inspected | Test or contract inspected | Implication for Veasel |
|---|---|---|---|
| [OpenCode](https://github.com/anomalyco/opencode/tree/5e4aa55cda2b7fad4e6e4e83c51944bb1b4d02fd) `5e4aa55` | `packages/core/src/session/runner/step.ts` | `packages/core/test/session-step.test.ts` | The runner represents completion, retry, continuation, context recovery, compaction, and output-limit outcomes explicitly. Keep lifecycle, event publication, and permission checks independently testable in the V runtime. |
| [Codex](https://github.com/openai/codex/tree/970111f6cb62cc02fe36a82ea7d71b37a2889c97) `970111f` | `codex-rs/core/src/stream_events_utils.rs`; `codex-rs/core/src/agent/registry.rs` | `codex-rs/core/src/agent/registry_tests.rs` | Agent identity/configuration and tool dispatch have distinct seams. Any Veasel parallel tool work must preserve deterministic transcript order and keep OS containment separate from approval. |
| [Pi](https://github.com/earendil-works/pi/tree/f321e5bdd26b3624bfb2ab182a334d0a5edb698a) `f321e5b` | `packages/agent/src/agent-loop.ts` | `packages/agent/test/agent-loop.test.ts`; `packages/agent/test/e2e.test.ts` | The small loop exposes an abort signal and pluggable stream function; tests exercise abort during streaming. Veasel's durable cancellation flags need a real worker that stops provider/tool work. |
| [mini-SWE-agent](https://github.com/SWE-agent/mini-swe-agent/tree/04d809ceab9df28f9adaed044884180159172930) `04d809c` | `src/minisweagent/agents/default.py` | `tests/agents/test_default.py` | A compact loop makes step, wall-time, cost, and repeated-format-error limits explicit and emits trajectories. Keep any delegated worker bounded and measurable. |
| [Aider](https://github.com/Aider-AI/aider/tree/5dc9490bb35f9729ef2c95d00a19ccd30c26339c) `5dc9490` | `aider/repomap.py` | `tests/basic/test_repomap.py` | Tree-sitter tags and SQLite caching feed a token-budgeted ranked map with refresh policy. Veasel's bounded V extractor is simpler; a persistent parser/index is justified only by controlled retrieval and task results. |
| [Goose](https://github.com/aaif-goose/goose/tree/0276d567aa00d426161c51e9c0f52baabe5958ea) `0276d56` | `crates/goose-agent/src/machine.rs`; `crates/goose-agent/src/subagent.rs` | `crates/goose-agent/tests/cancellation.rs`; `crates/goose-agent/tests/subagent.rs` | State-machine steps separate inference, operations, session loading, and effects; cancellation and subagents have focused tests. Avoid a parallel Veasel abstraction until a real child worker consumes it. |
| [OpenHands](https://github.com/OpenHands/OpenHands/tree/fee10e3d2909ebbf9950578575b1ee011492171e) `fee10e3` | `src/api/conversation-service/agent-server-conversation-service.api.ts` | `tests/e2e/conversation-markdown-render-performance.spec.ts` | The UI uses a typed Agent Server client and has browser-grounded conversation rendering checks. Keep Veasel clients behind its HTTP contract and exercise actual terminal rendering. |
| [OpenHands Software Agent SDK](https://github.com/OpenHands/software-agent-sdk/tree/acd96e6fa424c02432304395b9208f99be24b54d) `acd96e6` | `openhands-agent-server/openhands/agent_server/sub_agents_router.py` | `tests/agent_server/stress/test_parallel_subagents.py`; `tests/tools/task/test_sub_agent_scope.py` | Subagent definitions expose typed profile, tool, skill, permission, and budget fields; stress tests cover parallel subagents. Veasel must authorize a selected profile and isolate its tool grants before adding a model-callable delegate. |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli/tree/cd1b45c2db0a5ea7b7fc3b67c1ba5879601d6005) `cd1b45c` | `packages/core/src/agent/agent-session.ts` | `packages/core/src/agent/agent-session.test.ts` | The protocol wrapper yields events by stream ID and supports abort. Preserve correlated run/session IDs and cancellation outcomes in Veasel's SSE stream. |
| [Cline](https://github.com/cline/cline/tree/40c5d99031fe1128189c5b52e40638d2b7787754) `40c5d99` | `sdk/packages/core/src/runtime/safety/loop-detection.ts` | `sdk/packages/core/src/runtime/orchestration/session-runtime-orchestrator.test.ts` | Repeated-call detection canonicalizes structured arguments and tracks consecutive calls. Veasel should detect non-progress loops without rejecting legitimate repeated reads. |
| [Continue](https://github.com/continuedev/continue/tree/5522c6f44ca0ac3528b37244818fbfa39b5af470) `5522c6f` | `extensions/cli/src/services/FileIndexService.ts` | `extensions/cli/src/services/FileIndexService.test.ts` | Its fuzzy file index filters supported extensions and manages updates. Veasel search/map improvements must retain freshness and bounded memory. |
| [Crush](https://github.com/charmbracelet/crush/tree/136d4a6914395bd44ca153917ea2eb2f36cdd7c6) `136d4a6` | `internal/agent/agent.go` | `internal/agent/loop_detection_test.go` | Provider streaming, tools, session state, and summarization are coordinated outside presentation code; loop detection has dedicated coverage. Keep Veasel's V runtime independent of Solid/OpenTUI. |
| [Kilo Code](https://github.com/Kilo-Org/kilocode/tree/9723be621429771ea47a2614b0ac433448023cec) `9723be6` | `packages/tui/src/keymap.tsx` | `packages/tui/test/cli/tui/use-event.test.tsx` | Keymaps use shared modes/layers and command metadata. Keep Veasel keyboard behavior discoverable through its existing command model instead of scattering handlers. |
| [Qwen Code](https://github.com/QwenLM/qwen-code/tree/395c7a820a47d623105ab591e099f9c430160836) `395c7a8` | `packages/cli/src/external-agents/codex-subagent-executor.ts` | `packages/cli/src/external-agents/codex-subagent-executor.test.ts` | External execution distinguishes cancellation from timeout and sanitizes inherited environment; tests exercise process cleanup. Veasel must stop real child work and avoid leaking ambient credentials. |
| [SWE-agent](https://github.com/SWE-agent/SWE-agent/tree/3ea751c087f32b16e039a2233dd6eefecef325d5) `3ea751c` | `sweagent/agent/agents.py` | `tests/test_agent.py`; `tests/test_env.py` | The task loop composes history processors, hooks, retry/review logic, limits, and a separate environment. Keep Veasel's effect approvals explicit in richer patch workflows. |

## Frameworks, standards, quality, and internal ecosystem

| Project and inspected revision | Implementation inspected | Test or contract inspected | Implication for Veasel |
|---|---|---|---|
| [OpenTUI](https://github.com/anomalyco/opentui/tree/341d728b40ee2d1b34f1ea1eaaf3ee0ef801ec69) `341d728` | `packages/core/src/renderables/Markdown.ts` | `packages/core/src/renderables/__tests__/Markdown.test.ts`; renderer scheduling tests | Markdown, code, tables, links, and highlighting belong to renderer primitives. Use the pinned public API and profile Veasel's component tree rather than duplicating them. |
| [models.dev](https://github.com/anomalyco/models.dev/tree/71e5bbbfed017b63bf9c1abf8570520263470202) `71e5bbb` | `packages/core/src/schema-v2.ts` | `packages/core/test/schema.test.ts` | Public model enums are forward-compatible while catalog linting remains strict. Preserve unfamiliar model metadata without weakening endpoint or credential validation. |
| [V](https://github.com/vlang/v/tree/991ef1daf81566f05d233b58b0fcbbb82f66a100) `991ef1d` | `vlib/db/tx.v`; `vlib/db/sqlite/sqlite.c.v` | `vlib/db/tx_test.v`; `vlib/db/sqlite/sqlite_test.v` | The current upstream tree was cloned for survey; Veasel's compiler/API contract remains the exact local pin `ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f`, which matches the local V checkout. Check new code against that pin, not moving `master`. |
| [Agent Skills](https://github.com/agentskills/agentskills/tree/69ef37e9424c0a7ea9dd2293b559e43ec8176379) `69ef37e` | `skills-ref/src/skills_ref/parser.py` | `skills-ref/tests/test_parser.py` | The reference parser separates YAML-frontmatter parse/validation failures. Veasel should keep discovery bounded and fail closed while treating skill bodies as untrusted instructions. |
| [Agent Plugins spec](https://github.com/agentplugins/agent-plugins-spec/tree/ff8ab5e392cc87bd88d87c060815a87490e51003) `ff8ab5e` | `schemas/1.0.0/plugin.schema.json`; `schemas/1.1.0/plugin.schema.json`; `spec/` | Normative schema/spec only; no host implementation suite | JSON Schema checks structure; semantic/runtime requirements stay in the normative spec. Veasel's own fixtures must cover permission and lifecycle semantics. |
| [Harbor](https://github.com/harbor-framework/harbor/tree/6099b8cf2bfbbb3e7ff1eb2163bfc4524dbd9ba5) `6099b8c` | `src/harbor/cli/adapters.py`; adapter wizard | `tests/unit/test_adapter_wizard.py` | An adapter is an explicit integration with capabilities and task/environment metadata. Veasel's passing deterministic smoke proves plumbing, not coding-task efficacy. |
| [Harbor Index](https://github.com/harbor-framework/harbor-index/tree/5399ea1026fb2c7fc384cf8acd91a7d10fc943f3) `5399ea1` | `tasks/featurebench-add-feature-lightning-hooks/{README.md,task.toml,instruction.md}` | `tasks/featurebench-add-feature-lightning-hooks/tests/test.sh`; pinned setup/test patches | Benchmark tasks pin upstream state and test identity, mask solutions, and record environment adaptations. Veasel evaluations need leak checks, pinned data, raw trajectories, and an authorized budget. |
| [SWE-bench](https://github.com/SWE-bench/SWE-bench/tree/02e7a74ffd0b707aab73d203fe87bdc7c76afc8e) `02e7a74` | `swebench/cli/evaluate.py` | `tests/test_grading_spoofed_output.py`; evaluator tests | Official evaluation separates dataset selection, predictions, instance IDs, workers, and grading. Keep dataset variants distinct and use the pinned evaluator for any claim. |
| [HorneroOS QA](https://github.com/HorneroOS/qa/tree/c84961ed71ab84c4fe535459d6bca1348d062a73) `c84961e` | `src/hornero_qa/runner.py` | `tests/test_matrix.py`; evidence tests | The runner separates actions from observation, supports independent repeats, classifies failures, and preserves evidence. Veasel journeys should report platform and artifacts, not only unit tests. |
| [Agent Toolkit](https://github.com/ulises-jeremias/agent-toolkit/tree/12a3f833e76c4816f0b2bac75b7b656c25a86426) `12a3f83` | `modules/agent_toolkit_core/context_budget.v` | `tests/test_packs_390.py`; module tests | The toolkit documents its character-budget parity explicitly. Veasel's measured byte budgets are more honest than presenting bytes/4 as exact provider tokens. |
| [HorneroOS website](https://github.com/HorneroOS/website/tree/7ba2c584c33534b17dc96c2bf14625dcab78ece3) `7ba2c58` | `src/pages/greeter.astro`; `src/data/product` | Captured responsive/interaction evidence in `output/playwright/` | The product preview labels browser recreation and offline/local boundaries. Veasel's demo should likewise distinguish real backend behavior from illustration. |

## Veasel comparison and remaining work

The audited Veasel `main` is `38ea5b59e1baff1537af77b1c6362703cd8ab171`,
with release `v0.64.7-next.0`. Its implementation plan and current source
show these open gaps:

1. **Model-callable subagents:** the local worktree stack has durable parent /
   child ownership, read-only profiles, isolated workspaces, recovery, and
   once-only result delivery. It still has no real child worker/tool path.
   Cancellation and deadline flags must stop provider/tool work, child
   environments must not inherit secrets, and end-to-end deterministic tests
   must pass before exposing delegation to a model.
2. **Broader retrieval proof:** the bounded extractive repository map has
   curated recall cases and active allocation/ranking PRs. Semantic retrieval
   or a persistent index remains unproven until task success, prompt bytes,
   latency, and memory improve on a fixed corpus.
3. **Task effectiveness:** the Harbor adapter smoke validates integration
   plumbing. Same-model Harbor/SWE-bench comparisons, trajectories, success,
   cost, latency, and memory have not been measured. No paid evaluation is
   authorized by this audit.
4. **TUI quality and performance:** core visual work is in review; wider
   real-backend journeys and macOS/Windows performance baselines remain open.
   Use browser/terminal evidence and exact-head cross-platform CI.

These are engineering priorities, not claims that any competitor performs
better. Respect each upstream license and record compatibility decisions before
reusing contracts or code.
