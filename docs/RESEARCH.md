# Ecosystem and repository research

**Snapshot date:** 2026-10-09
**Purpose:** Record what was inspected, distinguish local evidence from moving
upstream references, and turn useful practices into concrete Veasel decisions.
This is an architecture input, not a claim that Veasel already implements the
listed capabilities.

## Repository inventory and evidence

| Source | Inspection location / revision | What it contributes |
|---|---|---|
| V compiler and `vlib` | Local checkout `/home/ulisesjcf/Projects/github.com/vlang/v`, updated with `v up` to `407c52edddca9715fb57e6571afeef0d193f2465` on 2026-10-09. | V 0.5.2 compiled successfully from this upstream master revision. `.v-version` pins the same inspected revision for CI; recheck APIs when updating it. |
| `awesome-v` | Upstream [repository](https://github.com/vlang/awesome-v), CC0 list. No local checkout. | Discovery index for V libraries, CLI/TUI projects, databases, HTTP and terminal packages; listings are leads, not a quality or maintenance guarantee. |
| `v-mascot` | Upstream [repository](https://github.com/vlang/v-mascot), branch `add-mascot`. No local checkout. | Official Veasel mascot source. The startup pixel adaptation is included with attribution under CC BY-NC 4.0; commercial use requires separate permission. |
| VSL | `~/.vmodules/vsl`, commit `a27f8ececf35ba91e58e71e3f6e707d2b609fc8e`, branch `main`. No tracked edits; two untracked V compiler cache directories were present and left untouched. | V-native modules, optional numerical/native backends, APIs with explicit backend expectations, module docs, examples, bounded local/CI testing. |
| VTL | `~/.vmodules/vtl`, commit `1236453e7c3a5cfdded43aa71d4d1c1f2fb492d1`, branch `perf/in-place-autograd-grad-accumulation`. Clean at inspection. | Public pure-V API over a lower-level VSL compute library; stable API separated from experimental CUDA/Vulkan paths; lightweight local test workflow. |
| RxV | Upstream [repository](https://github.com/ulises-jeremias/rxv), `main`. No local checkout. | V-native, dependency-free, channel-oriented asynchronous stream operators; informs event abstractions, but does not remove the need to own cancellation and shutdown semantics. |
| setup-v | Upstream [repository](https://github.com/vlang/setup-v), `main`. No local checkout. | CI compiler selection by version/tag/SHA, architecture, cache, and cleanup; use a deliberate V version policy in Veasel CI. |
| agent-toolkit | Local `/home/ulisesjcf/.ai-workspace/repos/github.com/ulises-jeremias/agent-toolkit`. | Veb transport adapters calling typed core operations; bind validation, auth and mutation checks; install transactions with path guards, atomic writes and rollback. |
| agentic-harness | Local `/home/ulisesjcf/.ai-workspace/repos/github.com/ulises-jeremias/agentic-harness`. | Durable workspace context and orchestration integration; it is deliberately not another execution runtime. |
| agentic-workstation | Local `/home/ulisesjcf/.ai-workspace/repos/github.com/ulises-jeremias/agentic-workstation`. | Thin host provisioning and machine-specific LLM policy; reusable orchestration/capabilities live downstream in agent-toolkit. |
| LangChainV | Local `/home/ulisesjcf/.ai-workspace/repos/github.com/ulises-jeremias/langchainv`. Read README, AGENTS, CONTRIBUTING, implementation plan, standard-library catalog and parity ledger. | Small V-native contracts, isolated adapters, deterministic HTTP fixtures, explicit errors/cancellation, feature-level evidence ledger. Left untouched. |
| OpenCode | Upstream [repository](https://github.com/anomalyco/opencode), MIT. No local source checkout. Immutable comparison sample [`95daf90670b7c039c436c85537da5fbfe2205b41`](https://github.com/anomalyco/opencode/commit/95daf90670b7c039c436c85537da5fbfe2205b41), committed 2026-09-11; not asserted to be current head. | Server-backed multi-client architecture, sessions, event stream, providers/tools, agents and permission UX. Current route overlap and gaps are tracked in [`compatibility/opencode.md`](compatibility/opencode.md); refresh/pin revisions before compatibility work. |
| Agent Plugins | Official [specification](https://agent-plugins.org/specification), published v1.0.0; immutable release source [`bd383552095128f6effe895b9257cfd580a6d179`](https://github.com/agentplugins/agent-plugins-spec/tree/bd383552095128f6effe895b9257cfd580a6d179), release dated 2026-09-28. Current repository head is the 1.1.0 working draft and is not the compatibility target. | Portable directory package, strict manifest and component failure boundaries, Agent Skills, and MCP config. The full Veasel target and evidence gate live in [`compatibility/agent-plugins.md`](compatibility/agent-plugins.md). Normative documentation is CC BY 4.0; schema/code material is Apache-2.0 per the project charter; do not vendor without preserving applicable notices. |
| Agent Skills | Official [Skills specification](https://agentskills.io/specification), consulted 2026-10-09. | Required nested format for the Agent Plugins `skills/` component; reuse V `yaml` for frontmatter and validate its constraints without changing skill Markdown instructions. |
| Claude Code | Public product documentation only; no source repository or source license available. | User-facing concepts and permission/context behavior only. No source copying. |
| Codex CLI | Upstream [repository](https://github.com/openai/codex), Apache-2.0. No local checkout. A 2026-09 historical immutable sample is [`89c8bcf`](https://github.com/openai/codex/commit/89c8bcf); this is not asserted to be the current head. | App-server protocol, typed requests/notifications/errors, session lifecycle, approvals and client/server separation. Apache license and NOTICE obligations apply to any source reuse. |
| Pi (`pi-mono`) | Project now appears as [earendil-works/pi](https://github.com/earendil-works/pi), MIT. No local checkout. A 2026-09 historical immutable sample is [`71dca87`](https://github.com/earendil-works/pi/commit/71dca87); this is not asserted to be the current head. | Small composable core, provider API boundary, multiple UI/SDK surfaces, append-only session/event history and extension seams. Extensions execute code and therefore need a trust model. |

Local checkout status is evidence only for the paths listed. There were no
local source checkouts of OpenCode, Claude Code, Codex CLI, Pi, RxV, setup-v,
`awesome-v`, or `v-mascot` in the workspace when inspected. Public repositories
and product documentation were reviewed read-only for those sources.

## V ecosystem findings

The actual installed compiler is V 0.5.2. The local V source at the versioned
commit contains `veb`, `veb.sse`, `db.sqlite`, `net.http`, `json2`, `sync`,
`context`, `term`, `readline`, `ncurses`, and `mcp`. Confirm each API against
the supported compiler version instead of relying on examples for older V
releases. A concrete example from the first Veasel compile: `encoding.json`
is unavailable in this compiler; the current JSON API is `json2`.

The detailed [`VLIB_REUSE.md`](VLIB_REUSE.md) inventory records available
modules and APIs across transport, storage, JSON, processes, cancellation,
filesystem, search, diffs, MCP, terminal, logging, benchmarks and tests. Treat
it as the dependency review gate for later milestones; it distinguishes
missing high-level facilities from functionality V already supplies.

Relevant source evidence in `vlib`:

- `vlib/veb/README.md`: Veb routes and loopback binding parameters.
- `vlib/veb/sse/README.md` and `sse.v`: takeover of a direct TCP connection is
  required for a long-lived SSE response; handlers must manage disconnect and
  stream lifetime.
- `vlib/db/sqlite/sqlite.c.v`: prepared-parameter APIs, transaction methods,
  busy timeout and native SQLite linkage. Some transaction options are not
  publicly constructible from outside the module; compile probes are required.
- `vlib/json2/README.md`: typed generic encode/decode and current wire behavior.
- `vlib/net/http/request.v`: progress callbacks exist, but verify streaming
  behavior per platform before promising token streaming.
- `vlib/context/README.md` and `vlib/sync/README.md`: examine cancellation and
  synchronization semantics at each worker boundary; do not assume a spawned
  goroutine has safe ownership or shutdown by default.

`awesome-v` catalogs alternatives including `eventbus`, `rxv`, terminal UI
helpers and multiple Veb servers. Treat it as a discovery list; compare
maintenance, licensing, compatibility and lifecycle before taking a dependency.
RxV's channel operators are promising for event transformations, but its
thread-per-operator model must be measured and cancellation behavior verified
before adoption in a long-lived server.

## Practices to carry into Veasel

### Product boundaries

- Keep Veasel as the execution runtime. Agent Toolkit owns generic skills,
  reusable capabilities, loops and job orchestration; agentic-harness owns
  durable workspace context; agentic-workstation owns machine provisioning and
  host-specific model policy. Integrate through a stable API instead of
  duplicating those responsibilities.
- Separate domain operations from Veb transport. Route handlers should decode,
  validate, authenticate, map errors and publish events; session, permission,
  provider and tool rules belong in independently testable core modules.
- Keep the V runtime useful without any UI. The terminal client is an HTTP API
  consumer; desktop, web, IDE and Agent Toolkit clients can use the same
  versioned contract.
- Keep core V-only and portable. Isolate SQLite, provider, MCP, Git, process,
  accelerator and other optional/native integrations behind adapters.

### VSL/VTL engineering patterns

- VSL owns numerical kernels and backend dispatch; VTL owns tensors, autograd,
  datasets and neural-network APIs. Their deliberate ownership boundary is a
  good model for keeping Veasel's API, execution engine, and provider/tool
  adapters separate.
- VTL distinguishes stable public API from experimental GPU execution paths.
  Veasel should similarly distinguish stable session/API behavior from
  experimental providers, tools, MCP transports and UI widgets.
- Both libraries pair feature docs with runnable, named examples and tests.
  Veasel features should ship with focused tests, a small real example, and
  documented limits together.
- CI tests pure-V and optional backend configurations separately. Keep
  provider/network/OS-dependent checks explicitly categorized and visible;
  never silently turn a missing integration into a pass.
- Their CI caps compiler memory and runs test packages sequentially. The local
  workspace also has active V compiler memory pressure; serialize V invocations
  and use the documented systemd memory bounds.
- VSL/VTL contributor guides contain useful formatting/test/API conventions but
  retain stale fork/`hub` and branch instructions. Reuse the technical rules,
  not that publication workflow.

### Agent-toolkit and workspace patterns

- Agent Toolkit's `agent_toolkit_server` routes call typed
  `agent_toolkit_core` operations; `result_to_http` centralizes status/error
  mapping. This is the pattern Veasel's transport and domain layers should
  follow.
- `agent_toolkit_server/server.v` validates loopback/remote binding, requires
  an explicit auth token for remote bind, checks remote mutations and avoids
  logging secrets. Veasel currently hard-codes loopback; any future remote mode
  must add authentication, origin/host checks, and read/write policy before it
  can bind beyond loopback.
- `agent_toolkit_core/install_tx.v` demonstrates staged, idempotent, atomic
  filesystem changes, explicit ownership, backups and reverse-order rollback.
  File editing and worktree tooling in Veasel should use equivalent guarded,
  recoverable operations.
- Harness and workstation document ownership boundaries and canonical sources.
  Veasel must mark generated contracts/clients as generated and derive them
  from one source to prevent API drift.

### Coding-agent references

| Product | Borrow | Keep distinct / risk |
|---|---|---|
| OpenCode | A server shared by TUI and other clients; typed sessions/events; provider and tool boundaries; agent modes and fine-grained permission UX. | Its API evolves quickly and is broad. Build a small compatibility matrix against pinned schemas and add contract tests instead of translating the codebase or promising blanket compatibility. |
| Claude Code | Publicly documented permission modes, project instructions and clear human control points. | Proprietary implementation; use public behavior as product research only. Tool approval must be enforced in Veasel's host/runtime, not delegated to model instructions. |
| Codex CLI | A durable app-server protocol with explicit method/event schemas, typed failures, cancellation and approvals across multiple clients. | Its protocol and policy are product-specific. Adopt explicit lifecycle/error design; Apache-2.0 applies to reused source. |
| Pi | A minimal composable model/agent core, separate CLI/TUI/SDK interfaces, append-only session events with parent-linked branching, and deliberate extension seams. | Pi intentionally has different built-in permission and orchestration tradeoffs. Arbitrary extensions are executable code; require a trust and permission design. |

### TUI technology decision

The installed Bun is 1.4.2. Current OpenTUI runtime documentation requires Bun
1.3.14 or newer and lists native artifacts for macOS x64/arm64, Linux
x64/arm64 (glibc and musl), and Windows x64/arm64. The current TUI pins
`@opentui/core` 0.5.17 and uses Core renderables directly, avoiding a second
renderer abstraction while this initial view is small. Core is MIT licensed
and its native renderer is written in Zig. OpenTUI Solid remains evaluated;
its current documentation requires `solid-js` 1.9.12 exactly. Reconsider it
when signals and component composition provide a clear maintenance benefit.

Linux x64 installation, typechecking, interactive rendering, keyboard input,
session creation and event streaming were verified locally. OpenTUI's
published artifact matrix does not replace Veasel release tests: verify
installation and interactive behavior on macOS, Windows and both Linux libc
families before claiming cross-platform support. V `term`, `readline`, and
`ncurses` remain available for a native client or fallback.

## Architecture consequences

The current local implementation must be reshaped before the foundation is
called complete:

1. Move persistence and session/event domain logic out of the route/CLI entry
   file into a testable V module; keep HTTP handlers as adapters.
2. Apply every schema migration transactionally and propagate errors. Session
   creation and its event must be one atomic SQLite write; rollback on any
   intermediate failure.
3. Add route tests for body validation, HTTP status semantics, event replay,
   malformed cursors, disconnects and multiple readers. Store-only tests do not
   prove the HTTP/SSE contract.
4. Make OpenAPI the canonical API source or add automated checks that compare
   the implementation and generated client to its declared routes/schemas.
5. Add OpenTUI as a separate TUI package once its locked dependency and runtime
   smoke are verified; remove duplicate UI behavior from the V server binary.
6. Keep the capability endpoint truthful: expose only features with
   implementation and validation evidence.
7. Pin source revisions, record licenses and add a compatibility row before any
   OpenCode/Codex/Pi contract compatibility claim or code reuse.

## Licensing notes

Research-only license snapshot: V, VSL, VTL, RxV and setup-v are MIT; Agent
Toolkit, agentic-harness and agentic-workstation are MIT; OpenCode and Pi are
MIT; Codex is Apache-2.0; Awesome V is CC0; Veasel mascot artwork is CC BY-NC
4.0; Claude Code source is not available under a public source license. This is
not legal advice. Preserve upstream notices for any adapted code. The startup
pixel portrait is already included under CC BY-NC 4.0; do not use it in
commercial product materials without separate rights.
