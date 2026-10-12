# Veasel Code implementation plan

## Architecture direction

Build the execution core as a V application with independently testable
domain, persistence, and transport modules. Keep Veb routes thin: validate the
request, call typed core operations, map domain errors, and publish events.
A versioned loopback HTTP API is the stable boundary for terminal, desktop,
web, IDE, and Agent Toolkit clients. SQLite is the initial durable store, with
schema versions and transactional writes. Session events are persisted in the
same transaction as their state change before being published, so reconnecting
clients can resume by event ID. Tool execution is isolated behind permission
checks and must not be replayed blindly after a crash.

The API/client split follows the current OpenCode server architecture, where
clients use an HTTP API and event stream. This is a direction reference rather
than a promise of full route compatibility. The pinned comparison and
route-by-route gaps live in [`compatibility/opencode.md`](compatibility/opencode.md).

The TUI is TypeScript with OpenTUI Core renderables, kept as a separate API
client; the agent runtime, tools and persistence remain in V. Core was chosen
for the first small view because its direct event and renderer APIs work with
the pinned package and installed Bun 1.4.2. Solid remains an option as the
view's composition needs grow. The package is pinned and typechecked, and the
Linux x64 flow was exercised interactively. CI builds and packages the backend
and TUI bundle for x64 Linux, macOS, and Windows and publishes verified main
builds automatically. Interactive TUI validation on macOS and Windows and
measured performance baselines remain open; see [`RESEARCH.md`](RESEARCH.md)
and [`VLIB_REUSE.md`](VLIB_REUSE.md).

## Milestones and backlog

### Milestone 1 — functional foundation (complete locally)

- [x] Initialize the local product repository, license, agent contract, and
  architecture plan.
- [x] Inspect local VSL/VTL, V compiler/stdlib, LangChainV, agent-toolkit,
  agentic-harness, agentic-workstation, and requested agent references; record
  reusable practices in [`RESEARCH.md`](RESEARCH.md).
- [x] V HTTP server with health and capability endpoints.
- [x] SQLite migration ledger and transactional session create/list/get behavior.
- [x] Durable, replayable SSE event stream with cursor validation.
- [x] OpenTUI terminal client connected to the server; Solid remains evaluated.
- [x] Focused V test, TUI typecheck, interactive Linux smoke and reproducible API smoke.
- [x] Initial OpenAPI contract and documentation.

### Milestone 2 — first real coding agent

- [x] OpenAI-compatible, Anthropic, and Gemini provider adapters with bounded SSE streaming, incremental durable assistant events, TUI rendering, and complete response/tool-call aggregation.
- [x] SQLite-backed session chat history and a TUI conversation composer.
- [x] Persist user/assistant exchanges atomically and restore recent history when reopening a session.
- [x] Serialize turns per session and cap concurrent provider requests with a bounded semaphore.
- [x] Reject provider work immediately with `503` and `Retry-After` when all provider slots are occupied, keeping overload from accumulating unbounded waiting requests.
- [x] Add UUID operation IDs and explicit cancellation endpoints, make queued per-session turns cancellable, enforce a two-minute turn deadline, pass context deadlines into all provider transports, and expose Escape cancellation in the TUI. The provider slot remains reserved until the blocking transport finishes its bounded cleanup.
- [ ] Stop an in-flight provider socket immediately when cancellation arrives before its first response chunk; the pinned `net.http.fetch` API exposes bounded timeouts and progress callbacks but no external socket cancellation handle.
- [x] Add provider-native tool calls for OpenAI-compatible, Anthropic, and Gemini with a bounded read-only tool loop.
- [x] Expose bounded read-only workspace list/read/search operations over the API, with canonical-root containment and symlink-safe traversal.
- [x] Connect read-only workspace tools to provider-native calls; treat file content as untrusted and enforce per-tool, round, call-count, and aggregate-result limits.
- [x] Generate bounded single-file diffs, persist proposals, require explicit durable approval, reject stale snapshots, and recover interrupted applications without replay.
- [x] Add permissioned shell execution with explicit, durable approval. The
  TUI requires opening the exact command, working directory, and timeout before
  approval; execution limits and recovery behavior are documented in
  [`SHELL_COMMANDS.md`](SHELL_COMMANDS.md).
- [x] Deliver bounded SSE text streaming for OpenAI-compatible, Anthropic, and Gemini providers through durable API events and the TUI; aggregate complete responses and provider tool calls.
- [x] Add opt-in `Prefer: respond-async` session turns so long model calls and human MCP approvals do not occupy an HTTP request worker; persist the operation before accepting, expose status for reconnect, and commit successful history, operation state, and terminal events atomically. Active work is classified as uncertain on restart and never replayed. The worker itself remains process-local.
- [x] Add `veasel run` for non-interactive session turns using the shared server, provider, and agent runtime; persist and continue sessions, emit machine-readable JSON, and request cancellation on timeout. It keeps edit, shell, and MCP approvals intact, so it is not yet an unattended patch executor or benchmark adapter.
- [x] Complete an end-to-end coding task against a disposable fixture workspace for OpenAI-compatible, Anthropic, and Gemini providers: propose and inspect a greeting implementation, prove the workspace stays unchanged before approval, approve the diff, run its V test, and verify rejected or unreviewed edits and shell effects do not occur (`scripts/api-smoke.sh`).

### Milestone 3 — persistent execution

- [x] Persist async session turn status before accepting the request, expose a
  session-scoped status resource for reconnecting clients, atomically commit
  terminal success with chat history, and classify active work as `uncertain`
  after restart without replaying provider calls or tool effects.
- [ ] Durable queued jobs, cancellation across server restarts, bounded job
  retention, provider-reported token usage, and operation observability.
- [x] Opt-in `veasel run --trace-file` export of successful turns as ATIF v1.8,
  including the current prompt, provider model responses, tool-call arguments,
  and tool observations. Collection is disabled unless a trace path is supplied.
- [ ] Persist partial trajectories on failures/cancellation; add provider
  usage/cost metadata only when adapters return authoritative values; redact
  sensitive source/tool content. Linux CI validates a deterministic live-provider
  fixture trace against Harbor 0.24.0 at pinned revision
  `dc933be707feafbb9efcdf092cb8a0e391332617`.
- [x] Add bounded, cursor-paginated session chat history while retaining the
  latest-100 default response for existing clients.
- [ ] Recovery classification; require human intervention for uncertain effects.
- [ ] Execution history, token usage, and observability.

### Milestone 4 — extensibility

- [ ] Complete the typed tool and provider interfaces, safe Git/worktree APIs,
  and versioned agent definitions.
- [ ] Implement Agent Plugins v1.0.0 client conformance for directory loading,
  closed manifest validation, Skills, MCP stdio and Streamable HTTP, `PLUGIN_DATA`,
  placeholder expansion, failure isolation, and `com.veasel.code` extensions.
- [x] Discover local Agent Plugin Skills, expose metadata through the API,
  persist per-session activation, include bounded instructions as untrusted
  model context, and let the model read bounded resources from active Skill
  directories on demand. This is a partial integration, not a conformance claim.
- [x] Persist per-session MCP trust, launch trusted stdio servers or connect
  to trusted Streamable HTTP endpoints with redirects and retries disabled,
  discover bounded tools, route calls through provider adapters, and keep nested
  JSON Schemas intact. Full conformance suite remains open.
- [x] Require durable per-call MCP argument inspection and approval, pause and
  resume the active provider turn, persist rejection and execution outcomes,
  and recover interrupted calls without replay. API smoke proves no fixture
  effect occurs before approval and rejection causes no effect.
- [x] Add locally authored spec-derived fixtures, MCP fixture servers, and a
  public compatibility report. The full conformance gate remains open for the
  gaps recorded in [`compatibility/agent-plugins.md`](compatibility/agent-plugins.md).
- [x] Document the Agent Toolkit consumer contract and verify its catalog,
  session Skill, MCP trust, and per-call approval shapes in
  [`integrations/agent-toolkit.md`](integrations/agent-toolkit.md) and
  [`scripts/api-smoke.sh`](../scripts/api-smoke.sh).

### Milestone 5 — competitive experience

- [x] Configure and persist multiple provider profiles from the TUI; keep API
  keys out of responses and mask them in the input flow.
- [x] Start or reuse a healthy local backend when `veasel` or `veasel tui` is
  invoked, then open the TUI.
- [ ] Complete cross-platform validation of provider settings and automatic
  backend startup in the pinned CI matrix.
- [ ] Multi-agent isolation and orchestration.
- [ ] Context retrieval, rich diff review, accessibility, and UX refinement.
- [x] Automate x64 backend and TUI bundle packaging for Linux, macOS, and
  Windows in CI and attach verified artifacts to automated prereleases.
- [ ] Validate interactive TUI behavior on each platform and establish
  measured performance baselines.

## Initial compatibility target

Milestone 1 is an original API, not an OpenCode clone. The current comparison
covers session lifecycle and events against the pinned OpenCode contract; Veasel
health and capability routes are product-specific. The historical
OpenCode/Codex/Pi samples in [`RESEARCH.md`](RESEARCH.md) are research pins only,
not claims of current heads. Refresh and pin exact upstream schemas before
adding a compatibility claim. Do not reuse source code without recording and
honoring its license and attribution.

## Risks and decisions

- The official Veasel artwork is CC BY-NC 4.0. Keep it out of the product until
  commercial-use rights are established; use original typography and colors.
- Session creation records an existing, canonical workspace root. The initial
  list/read/search tools enforce root-bound access on every operation, reject
  symlink escapes, and treat file contents as untrusted. Loopback plus Origin
  validation is not a filesystem sandbox; repeat containment checks for every
  future filesystem tool.
- Agent Plugins v1.0.0 is a published normative format for Skills and MCP; it
  does not define permission UX, marketplace installation, sandboxing, or
  lifecycle policy. Implement those client responsibilities in Veasel. Track
  exact requirements and evidence in
  [`compatibility/agent-plugins.md`](compatibility/agent-plugins.md); do not
  claim conformance until its release gate passes.
- The initial tool loop caps in-flight provider calls and tool-loop steps;
  same-session turns are serialized so provider history cannot race. Opt-in
  async turns remain process-local; durable job recovery, concurrent agents,
  and their resource limits remain open.
- The organization and repository publication are tracked separately from the
  code milestones; do not describe them as complete until GitHub confirms them.
- Milestone 1 is complete only for the local Linux x64 development environment;
  macOS, Windows, Linux musl, concurrent client and production reliability
  checks remain open.
- V's SQLite module uses native SQLite linkage. CI and packaging must verify
  platform-specific headers/libraries rather than assuming zero system needs.
- SSE and SQLite behavior must be tested under concurrent clients before the
  server claims durable or restart-resilient background execution.
