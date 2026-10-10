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
Linux x64 flow was exercised interactively. Cross-platform distribution still
needs release tests; see [`RESEARCH.md`](RESEARCH.md) and
[`VLIB_REUSE.md`](VLIB_REUSE.md).

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

- [x] OpenAI-compatible, Anthropic, and Gemini provider adapters with bounded synchronous completion transport.
- [x] SQLite-backed session chat history and a TUI conversation composer.
- [x] Persist user/assistant exchanges atomically and restore recent history when reopening a session.
- [x] Serialize turns per session and cap concurrent provider requests with a bounded semaphore.
- [ ] Propagate request cancellation and deadlines through queued turns and provider transports.
- [x] Add provider-native tool calls for OpenAI-compatible, Anthropic, and Gemini with a bounded read-only tool loop.
- [x] Expose bounded read-only workspace list/read/search operations over the API, with canonical-root containment and symlink-safe traversal.
- [x] Connect read-only workspace tools to provider-native calls; treat file content as untrusted and enforce per-tool, round, call-count, and aggregate-result limits.
- [ ] Add patch review and explicit, durable approval before writes or shell execution.
- [ ] Deliver streaming model responses and cancellation through the API, event store, and TUI.
- [ ] Complete an end-to-end coding task against a disposable fixture repository, including diff review, tests, and a denied unapproved effect.

### Milestone 3 — persistent execution

- [ ] Durable jobs, cancellation, status transitions, and disconnect/reconnect.
- [ ] Recovery classification; require human intervention for uncertain effects.
- [ ] Execution history, token usage, and observability.

### Milestone 4 — extensibility

- [ ] Complete the typed tool and provider interfaces, safe Git/worktree APIs,
  and versioned agent definitions.
- [ ] Implement Agent Plugins v1.0.0 client conformance for directory loading,
  closed manifest validation, Skills, MCP stdio and Streamable HTTP, `PLUGIN_DATA`,
  placeholder expansion, failure isolation, and `com.veasel.code` extensions.
- [x] Discover local Agent Plugin Skills, expose metadata through the API,
  persist per-session activation, and include bounded instructions as untrusted
  model context. This is a partial integration, not a conformance claim.
- [ ] Add spec-derived conformance fixtures, MCP fixture servers, and a public
  compatibility report before claiming support.
- [ ] Document and test the Agent Toolkit integration contract.

### Milestone 5 — competitive experience

- [ ] Multi-agent isolation and orchestration.
- [ ] Context retrieval, rich diff review, accessibility, and UX refinement.
- [ ] Cross-platform packaging and measured performance baselines.

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
  same-session turns are serialized so provider history cannot race. Revisit
  these limits before adding concurrent agents or background execution.
- The organization and repository publication are tracked separately from the
  code milestones; do not describe them as complete until GitHub confirms them.
- Milestone 1 is complete only for the local Linux x64 development environment;
  macOS, Windows, Linux musl, concurrent client and production reliability
  checks remain open.
- V's SQLite module uses native SQLite linkage. CI and packaging must verify
  platform-specific headers/libraries rather than assuming zero system needs.
- SSE and SQLite behavior must be tested under concurrent clients before the
  server claims reliable background execution.
