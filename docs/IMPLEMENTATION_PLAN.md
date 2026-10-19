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

The TUI is TypeScript with OpenTUI + SolidJS (`@opentui/solid` **0.6.2**), kept
as a separate API client; the agent runtime, tools and persistence remain in V.
**Solid is the default entry** (`bun run start` → `src/solid/main.tsx` /
`LiveApp`): loopback HTTP session home, SSE assistant deltas, and MODEL SETTINGS
via `api-client.ts`. Pure shared modules (`stream-events`, `chat-history`,
autocomplete matchers, review formatters, themes) stay framework-agnostic. The
retired imperative shell lives at `src/classic-main.ts` (`bun run start:classic`
/ `--classic` standalone) for emergency comparison only. Solid also ships shell
+ composer, session transcript on OpenTUI `scrollbox` (follow-tail), collapsible
tool/activity grouping (**Ctrl+G**), **Ctrl+P** command palette, pending
**reviews** (**Ctrl+R**), toast host, session list / rename, dialog primitives,
and product dialogs. Pins and adapted patterns are recorded in
[`compatibility/opentui-solid.md`](compatibility/opentui-solid.md). Remaining
parity (full review HTTP approve path, pane-resize, deeper settings connect) is
follow-up. CI builds and packages the backend and TUI bundle for x64 Linux, macOS,
and Windows and publishes verified main builds automatically. Standalone
interactive TUI PTY smoke runs on Linux and macOS in CI; Windows interactive
validation still needs a ConPTY harness (see
[`compatibility/tui-interactive-smoke.md`](compatibility/tui-interactive-smoke.md)).
Linux TUI CLI + PTY-connected baselines are recorded there; macOS/Windows
baselines remain open. See [`RESEARCH.md`](RESEARCH.md) and
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
- [x] OpenTUI terminal client connected to the server; Solid is the default.
- [x] Solid P0 shell + composer (`tui/src/solid/`, `testRender`).
- [x] Solid default cutover: `bun run start` + standalone `build:standalone`
  use `solid/main.tsx` / `LiveApp` (loopback HTTP session loop + SSE); classic
  shell retired to `classic-main.ts` / `start:classic`.
- [x] Solid composer `/` `@` `$` autocomplete dropdown (classic matchers,
  Tab/Enter/Esc/arrows); fixture skills/paths until HTTP session wiring.
- [x] Solid session transcript on `scrollbox` with sticky follow-tail,
  `transcriptSegments` tone rendering, and `testRender` coverage (long scroll,
  streaming append, 80×30); HTTP session wiring still optional.
- [x] Solid dialog host + Ctrl+P command palette (`solid/ui/dialog.tsx`,
  `solid/component/command-palette.tsx`) wired to slash/help/theme-cycle/
  session-list stubs; `testRender` for open/close, filter, keyboard select, Esc.
- [x] Solid tool/activity grouping on the transcript (`solid/activity-group.ts`):
  consecutive tool roles collapse into mint activity groups with
  running/done/error status, expand/collapse via **Ctrl+G** (or click / palette
  `veasel.activity.toggle`); pure helper tests + `testRender` at 80×30.
- [x] Solid reviews / diff / approvals overlay (`solid/reviews.ts`,
  `solid/component/review-panel.tsx`): pending file/shell/MCP queue with
  legacy `reviewHotkey` bindings (a/x/A/X/Space/]/[/n/p/{/}/v),
  `formatReviewDiff` / shell / MCP formatters, OpenTUI `<diff>` split when
  toggled; **Ctrl+R** + palette `veasel.reviews.open`; fixture demos +
  `testRender`; Solid is the default entry (`classic-main.ts` retired).
- [x] Shared dialog geometry and result budgets adapt selectors and the
  command palette to terminal size. Compact layouts retain search, selection,
  and match counts, and command rows support mouse activation. Rendered tests
  cover 32×12, 40×16, 80×24, 120×40, resizing, keyboard, and mouse input.
  This does not establish responsive coverage for every product dialog.
  toggled; **Ctrl+R** + palette `veasel.reviews.open`. LiveApp loads and
  decides reviews through the HTTP API. The panel waits for confirmation,
  retains failed items with inline errors, blocks duplicate submissions while
  waiting, and restores composer focus on close. Loopback HTTP and rendered
  keyboard tests cover failures, partial batches, and late completion after
  dismissal; these tests do not replace cross-platform interactive validation.
- [x] Reactive builtin theme ownership for Solid components and overlays.
  Theme changes recolor the transcript, composer, dialogs, notifications, and
  diff views without remounting local interaction state. Rendered-color tests
  verify draft retention and isolation between application roots.

- [x] Solid toast host (`solid/ui/toast.tsx`): non-modal mint notices with
  queue, hover-pause, click dismiss/activate; palette `veasel.toast.demo`;
  wired for theme/activity/review cues; `testRender` coverage.
- [x] LiveApp turn cancellation through Ctrl+X or the command palette uses
  the originating session and operation ID, waits for server confirmation, and
  reports cancellation errors without pretending the operation stopped.
  Cancelled, failed, and uncertain completions retain their distinct status.
  Loopback HTTP/SSE tests exercise keyboard cancellation across session tabs.
- [x] LiveApp isolates pending composer text and attachments by session during
  the current TUI process. Session switching updates project context for file
  completion and relative attachments; submitted text is cleared consistently.
  Real LiveApp keyboard/HTTP tests verify that session B does not submit A's
  pending attachment. Drafts now also persist across TUI restarts in
  `~/.local/state/veasel/session-drafts.json` (0600, workspace-scoped keys,
  50-session cap, debounced saves while typing), so reopening a session
  restores its pending text and attachments.
- [x] LiveApp history responses are scoped to the current session visit.
  Late success/error responses cannot replace a newer session view, including
  A → B → A navigation. Older-page responses are discarded after navigation or
  another history update. Loopback HTTP tests exercise actual LiveApp keyboard
  navigation with delayed responses; cross-platform manual checks remain open.
- [x] Solid session list + rename dialogs (`session-list-dialog.tsx`,
  `session-rename-dialog.tsx`): filter via `session-list.ts`, digit jump,
  `r` rename (dialog `push`/`pop`), `n` create stub when filter empty; palette
  `veasel.session.list`; fixture demos + `testRender`.
- [x] Solid dialog primitives (`dialog-select`, alert/confirm/prompt/help +
  `DialogLayout`) and product dialogs (theme list, model favorites/recents,
  stash, error details, shell output, MCP servers, skills) with palette
  commands + `testRender`.
- [x] Focused V test, TUI typecheck, interactive Linux smoke and reproducible API smoke.
- [x] Initial OpenAPI contract and documentation.

### Milestone 2 — first real coding agent

- [x] OpenAI-compatible, Anthropic, and Gemini provider adapters with bounded SSE streaming, incremental durable assistant events, TUI rendering, and complete response/tool-call aggregation.
- [x] SQLite-backed session chat history and a TUI conversation composer.
- [x] Persist user/assistant exchanges atomically and restore recent history when reopening a session.
- [x] Serialize turns per session and cap concurrent provider requests with a bounded semaphore.
- [x] Reject provider work immediately with `503` and `Retry-After` when all provider slots are occupied, keeping overload from accumulating unbounded waiting requests.
- [x] Add UUID operation IDs and explicit cancellation endpoints, make queued per-session turns cancellable, enforce a two-minute turn deadline, pass context deadlines into all provider transports, and expose Escape cancellation in the TUI. The provider slot remains reserved until the blocking transport finishes its bounded cleanup.
- [x] Abort provider SSE body progress as soon as turn cancellation is visible,
  including non-2xx and status_code-0 progress callbacks, and re-check the turn
  context after `http.fetch` returns. True socket close before any progress
  callback remains limited by the pinned `net.http.fetch` API (no external
  cancel handle).
- [x] Add provider-native tool calls for OpenAI-compatible, Anthropic, and Gemini with a bounded read-only tool loop.
- [x] Expose bounded read-only workspace list/read/search operations over the API, with canonical-root containment and symlink-safe traversal.
- [x] Connect read-only workspace tools to provider-native calls; treat file content as untrusted and enforce per-tool, round, call-count, and aggregate-result limits.
- [x] When a provider returns two or more workspace list/read/search calls in one
  round, execute them concurrently and append tool results in provider call
  order; skill load/read, edits, shell, and MCP stay sequential.
- [x] Generate bounded single-file diffs, persist proposals, require explicit durable approval, reject stale snapshots, and recover interrupted applications without replay.
- [x] Add permissioned shell execution with explicit, durable approval. The
  TUI requires opening the exact command, working directory, and timeout before
  approval; execution limits and recovery behavior are documented in
  [`SHELL_COMMANDS.md`](SHELL_COMMANDS.md).
- [x] Deliver bounded SSE text streaming for OpenAI-compatible, Anthropic, and Gemini providers through durable API events and the TUI; aggregate complete responses and provider tool calls.
- [x] Add opt-in `Prefer: respond-async` session turns so long model calls and human MCP approvals do not occupy an HTTP request worker; persist the operation as `queued` with request payload before accepting, claim to `running` in a worker, expose status/list/cancel for reconnect, and commit successful history, operation state, and terminal events atomically. Queued jobs resume after restart; claimed `running`/`cancelling` work is classified as `uncertain` and never replayed.
- [x] Add `veasel run` for non-interactive session turns using the shared server, provider, and agent runtime; persist and continue sessions, emit machine-readable JSON, and request cancellation on timeout. Default edit, shell, and MCP approvals remain intact.
- [x] Add an explicitly opt-in autonomous path for isolated benchmark tasks. The running server must opt in separately; ordinary CLI/TUI approval behavior remains unchanged. Autonomous file edits and shell commands retain durable proposal/result records, shell subprocesses receive an allowlisted environment, and MCP sessions are rejected. Autonomous shell is fail-closed OS-sandboxed: Linux Bubblewrap (read-only host, writable workspace, hidden home/removable/runtime, isolated network, allowlisted env), macOS Seatbelt when `/usr/bin/sandbox-exec` is present (allowlisted env, network denied), and Windows AppContainer + Job Object when available (network denied; inherited env filtering remains a known Windows backend limit). Platforms without that backend refuse to start a process. Stdio MCP remains outside this sandbox.
- [x] Add a graduated execution permission policy (`ask` | `auto-edit` | `sandbox-auto`) with allow/deny/ask decisions bound to those OS sandboxes. `autonomous: true` maps to `sandbox-auto`. Non-interactive turns map ask→deny. Auto-edit requires `VEASEL_ALLOW_AUTO_EDIT=1` (or autonomous allow); sandbox-auto still requires `VEASEL_ALLOW_AUTONOMOUS_EXECUTION=1`. MCP stays deny under sandbox-auto and ask/deny otherwise (never auto-apply). Capability `agent.execution_policy` (+ `.auto_edit` / `.sandbox_auto` when server-enabled).
- [x] Wrap manually approved Linux shell commands in Bubblewrap when `bwrap` is available (`VEASEL_SHELL_SANDBOX=auto|off|require`, network deny by default with optional `VEASEL_SHELL_SANDBOX_NETWORK=allow`). Capability `shell.sandbox.bubblewrap` is true only when the wrap will run; missing bwrap falls back unsandboxed under auto and never pretends sandboxed. Approval remains mandatory.
- [x] macOS Seatbelt parity for approved shell via `/usr/bin/sandbox-exec` only (`shell.sandbox.seatbelt` when wrap will run; shared `VEASEL_SHELL_SANDBOX` / `VEASEL_SHELL_SANDBOX_NETWORK` knobs; fail-closed `require`).
- [x] Windows Job Object wrap for approved shell (kill-on-close + active-process/memory caps; shared sandbox knobs; fail-closed `require`).
- [x] Windows AppContainer deepening for approved shell (`shell.sandbox.windows` only when AppContainer + Job Object wrap will run; workspace ACL grant; network deny by default via missing capability SIDs, `VEASEL_SHELL_SANDBOX_NETWORK=allow` adds well-known network SIDs; not Codex WFP helper-service / LPAC).
- [x] Complete an end-to-end coding task against a disposable fixture workspace for OpenAI-compatible, Anthropic, and Gemini providers: propose and inspect a greeting implementation, prove the workspace stays unchanged before approval, approve the diff, run its V test, and verify rejected or unreviewed edits and shell effects do not occur (`scripts/api-smoke.sh`).

### Milestone 3 — persistent execution

- [x] Persist async session turn status before accepting the request, expose a
  session-scoped status resource for reconnecting clients, atomically commit
  terminal success with chat history, and classify active work as `uncertain`
  after restart without replaying provider calls or tool effects.
- [x] Durable queued jobs and worker execution across server restarts, plus
  bounded terminal operation retention (200 per session) and bounded session
  event retention (5,000 per session, FIFO by event id) on the streaming
  assistant-delta path and after committed chat exchanges so reconnect
  replay stays finite. `Prefer: respond-async`
  persists `queued` + request JSON, workers claim to `running`,
  `GET /v1/sessions/{id}/operations` lists state, and startup resumes only
  `queued` rows after validating request JSON/content and that the session
  workspace directory still exists (missing workspaces fail closed as
  cancelled without claim). At most 32 `queued` rows are retained per session
  (`503` + `Retry-After` when full). Claimed `running`/`cancelling` work still
  becomes `uncertain` and is never replayed (provider/tool effects may already
  have started).
- [x] Capture provider-reported token usage from all four adapters in opt-in
  ATIF `final_metrics`. USD cost uses a pinned Models.dev-derived schedule for
  curated models (`sessions.usage.cost` when present); unmatched models stay
  `unavailable`.
- [x] Opt-in `veasel run --trace-file` export of successful turns as ATIF v1.8,
  including the current prompt, provider model responses, tool-call arguments,
  and tool observations. Collection is disabled unless a trace path is supplied.
- [x] Persist partial trajectories on failures/cancellation (partial
  steps are stored with a `failed`/`cancelled` outcome and returned by the
  operation result endpoint when trace collection was enabled); add provider
  usage/cost metadata only when adapters return authoritative values (usage
  done: all four adapters report token counts, aggregated into ATIF
  `final_metrics`; cost from pinned schedule when models match); redact
  credentials from trace content (done: at ATIF encode time, sensitive
  environment values, credential token shapes and credential-named fields in
  text and structured arguments are replaced with `[REDACTED]`, marked with
  `extra.redaction: "credentials"`; source content remains by design). Linux CI validates a deterministic live-provider
  fixture trace against Harbor 0.24.0 at pinned revision
  `dc933be707feafbb9efcdf092cb8a0e391332617`.
- [x] Implement a custom Harbor 0.24.0 `BaseInstalledAgent` for exact Linux
  x86_64 releases, checksum verification, supported provider mapping,
  bounded headless execution, and ATIF trajectory export. Unit tests run
  against Harbor's published 0.24.0 package and trajectory model.
- [x] Exercise the adapter end-to-end through `harbor run` in a disposable
  task environment using a deterministic local provider. The checked-in smoke
  fixture completed one trial with reward 1.0 and a Harbor-validated four-step
  ATIF v1.8 trajectory. This is adapter plumbing evidence, not a benchmark
  score. Do not start a paid benchmark until a budget is authorized.
- [x] Harbor adapter: accept `openai-responses` (and openai-family overrides),
  forward provider-reported usage/cache counters into agent metadata when
  `veasel run --json` reports them; cost stays unavailable. Pin:
  `docs/compatibility/harbor.md`.
- [ ] Prepare the Harbor upstream design discussion and contribution only after
  following its current policy, including the required human-authored first and
  final PR drafts.
- [x] Add bounded, cursor-paginated session chat history while retaining the
  latest-100 default response for existing clients.
- [x] Recovery classification; require human intervention for uncertain effects.
  Operations, shell commands and MCP calls interrupted mid-flight are marked
  `uncertain` (never replayed) and surfaces instruct the user to inspect
  workspace state before continuing; durable single-use approvals are recovered
  after restart (`main_test.v`: restart/uncertain cases for shell, MCP, edits
  and session operations).
- [x] Persist provider-reported token counts on completed session operations and
  expose them on operation status/result, `session.turn_completed` events,
  synchronous ChatExchange responses, the TUI status line, and `veasel run`
  JSON. Counts are omitted unless an adapter set `usage.reported`. Session cost
  is USD only when every reported turn matches the pinned schedule.
- [x] Aggregate those reported totals per session on `GET /v1/sessions/{id}/usage`
  and surface them through the TUI `/usage` command without inventing rates.
  The same reported-only aggregation is available across all sessions on
  `GET /v1/usage` (`sessions`, turn counts, token/cache/reasoning totals and
  the pinned-schedule cost label); a durable dashboard UI remains open below.
- [x] Fork a session with `POST /v1/sessions/{id}/fork`: the chat history is
  copied under a new id (title suffixed ` (fork)`) so an alternative direction
  can be explored without losing the original conversation. Operations, usage,
  workspace edits, and tool state stay with the source session.
- [x] Persist provider-reported prompt-cache counters (`cache_read_tokens`,
  `cache_creation_tokens`) when adapters see provider cache fields; expose them
  on operations, turn completion events, ChatExchange, session usage, TUI
  `/usage`, headless JSON/stderr, and opt-in ATIF `final_metrics`. Capability
  `sessions.usage.prompt_cache` advertises accounting only—no invented savings.
  Request-side Anthropic markers are a separate capability
  (`provider.anthropic.prompt_cache`). Field mapping pin:
  `docs/compatibility/prompt-cache-accounting.md`.
- [x] Theme the OpenTUI shell to the mint product look (charcoal panels, mint
  accents, LOCAL cue, session markers) and let operators switch among mint,
  ember, slate, mono, aurora, day, and contrast via `/theme`, with the choice
  persisted under `~/.config/veasel/tui-theme` (override with `VEASEL_TUI_THEME`).
  Custom themes load from `~/.config/veasel/themes/*.json` and
  `<workspace>/.veasel/themes/*.json` (optional `extends` builtin id);
  `/theme reload` rescans without restart and `/theme open` creates/shows
  those directories.
- [x] TUI `/map` shows the extractive workspace repository map with measured
  UTF-8 bytes, bytes/4 bound, ranked paths, and an optional ranking hint.
  Help documents Windows AppContainer alongside Bubblewrap/Seatbelt.
- [ ] General execution history and a durable usage/cost dashboard beyond
  per-session reported tokens and opt-in ATIF `final_metrics`.
- [x] Request-side Anthropic prompt-cache markers: default ephemeral
  `cache_control` (top-level automatic + system-block breakpoint), opt-out /
  `1h` TTL via `VEASEL_ANTHROPIC_PROMPT_CACHE`, capability
  `provider.anthropic.prompt_cache` distinct from accounting
  `sessions.usage.prompt_cache`. Fixture evidence: `provider_cache_test.v`;
  pin: `docs/compatibility/prompt-cache-accounting.md`. Does not invent hit
  rates or USD savings.
- [x] Request-side OpenAI `prompt_cache_key` (and optional
  `prompt_cache_retention` for `24h` / `in_memory`) on Chat Completions
  (`openai`) and Responses (`openai-responses`) via
  `VEASEL_OPENAI_PROMPT_CACHE` / `VEASEL_OPENAI_PROMPT_CACHE_KEY`, capability
  `provider.openai.prompt_cache` distinct from accounting. Not applied to Meta
  or generic openai-compatible gateways. Fixture evidence:
  `provider_cache_test.v`; pin: `docs/compatibility/prompt-cache-accounting.md`.
- [x] Request-side Gemini explicit cache: emit `cachedContent` on generateContent
  when `VEASEL_GEMINI_CACHED_CONTENT` names a resource (`VEASEL_GEMINI_PROMPT_CACHE=off`
  disables); capability `provider.gemini.prompt_cache` only when configured.
  Create/expire are explicit helpers (`create_gemini_cached_content` /
  `expire_gemini_cached_content`) and are never called on the turn path;
  fixture-tested over loopback HTTP plus create-body encoding.
  Pin: `docs/compatibility/prompt-cache-accounting.md`.
  Keys do not invent hit rates; hits remain provider-reported.

### Milestone 4 — extensibility

- [ ] Complete the typed tool and provider interfaces, safe Git/worktree APIs,
  and versioned agent definitions. **Deferred past Build Board READY (2026-10-15):**
  git/worktree APIs already shipped; a meaningful typed-tool/provider or
  versioned-agent-definition slice does not fit ≤2 PRs without a larger design
  spike, so keep this open rather than partial scaffolding. Workspace edit
  propose/apply already refuse when well-known git lock files are present under
  the checkout `.git` directory or a linked worktree `gitdir:` path
  (`workspace_edits.v`). Read-only worktree listing is available via
  `GET /v1/sessions/{id}/workspace/git/worktrees` (capability
  `workspace.git.worktrees`, filesystem-only). Create/remove use
  `POST`/`PATCH`/`DELETE` on the same path with argv-only `git worktree
  add|lock|unlock|remove` (bounded timeout; lock-aware; absolute paths).
  Headless `veasel worktrees list|add|remove|lock|unlock|prune` drives the same
  session API. Listing reports `missing` for stale linked checkouts; `POST`
  with `prune: true` runs argv-only `git worktree prune`.

- [x] Local Agent Plugins host READY (portable format + install UX). Directory
  loading, manifest and Skill validation, MCP stdio/Streamable HTTP,
  `PLUGIN_DATA`, placeholder expansion, failure isolation, and per-call MCP
  consent are CI-gated with the spec-derived fixture corpus. Operator-managed
  local package links (`/v1/plugins/links`, TUI `/plugin add [--replace]|remove`,
  headless `veasel plugins links … [--replace]`, capability `plugins.links`)
  ship with a durable `$VEASEL_DATA_DIR/plugin-links.json` sidecar (restore
  missing symlinks on list; optional `replace`) and validated package summary
  fields for install UX; they do not fetch remote packages. Remaining open:
  remote marketplace, upstream cross-implementation fixtures (none published at
  the pinned revision), OAuth DCR (deferred), legacy HTTP+SSE.
  Operator-configured MCP servers support user scope, project scope
  (`<workspace>/.veasel/mcp-servers.json`), and read-only project-import of
  portable `.mcp.json` / `.cursor/mcp.json` via `/v1/mcp-servers`, TUI
  `/mcp add|remove|enable|disable` with optional `user|project`, and
  capability `mcp.servers.configured`; trust and per-call approval reuse
  `configured/<name>`. Precedence: project > project-import > user. The
  client namespace `com.veasel.code` records an optional `display_name` and
  whether its directory stays inside the package; it does not read that
  directory.   Named Streamable HTTP credentials are available via `/v1/mcp-credentials`
  (`mcp.credentials`). Stdio emits `notifications/cancelled` when a turn is
  cancelled mid-call; Streamable HTTP cancels mid-body via progress callbacks,
  re-checks cancel after fetch returns, and aborts on first progress bytes after
  a slow TTFB. True socket abort before any progress callback is a pinned
  `net.http` hard limit (no external cancel handle); residual documented in
  [`compatibility/http-cancel-limits.md`](compatibility/http-cancel-limits.md).
  Streamable HTTP 401 responses parse WWW-Authenticate Bearer challenges
  including RFC 9728 `resource_metadata`, then best-effort fetch protected-
  resource metadata and the first authorization server's RFC 8414 metadata
  (issuer/authorize/token endpoints) without forwarding MCP headers; GET
  notification streams append SSE `message` events into a dedicated
  notifications queue (not RPC pending) with mid-stream cancel, and trusted
  HTTP connects best-effort listen after initialize.   Authorization-code + PKCE S256 authorize URL construction, loopback
  redirect_uri validation, callback parsing, token exchange, owner-only
  pending-session persistence, writing `Authorization: Bearer` into named
  `/v1/mcp-credentials` entries, and `POST /v1/mcp-oauth/authorize|complete`
  (capability `mcp.oauth`) are shipped.   A single-shot `127.0.0.1` loopback
  callback listener (`mcp_oauth_listener.v`) captures the browser redirect;
  headless `veasel mcp oauth authorize|complete` (optional `--listen`) is shipped.
  `POST /v1/mcp-oauth/refresh` and headless `veasel mcp oauth refresh` exchange
  stored refresh tokens (owner-only `mcp-oauth-refresh.json`) and rotate
  credential Bearer headers without returning secrets.
  Streamable HTTP transports that reference a named credential with refresh
  metadata auto-refresh once on HTTP 401 and retry that request (not a general
  retry policy; side-effecting retries remain disabled otherwise).
  `DELETE /v1/mcp-oauth/refresh` and `veasel mcp oauth clear-refresh` clear
  refresh metadata; deleting a credential also clears its refresh row.
  Credential views expose boolean `oauth_refresh` without secrets.
  **OAuth Dynamic Client Registration (RFC 7591) is deferred:** authorize already
  requires an explicit `client_id`; AS metadata may advertise
  `registration_endpoint` for operator discovery, but Veasel does not POST
  client registrations. Spike (2026-10-15): PKCE public-client + pre-registered
  `client_id` covers the configured MCP servers we target; DCR adds redirect_uri
  registration attack surface without unblocking a current product path. Revisit
  only if a required authorization server refuses pre-registered clients.
  Plugin skill/MCP component enable/disable is available via
  `/v1/plugins/components`.
- [x] Discover local Agent Plugin Skills, expose metadata through the API,
  persist per-session activation, include bounded instructions as untrusted
  model context, and let the model read bounded resources from active Skill
  directories on demand. This is a partial integration, not a conformance claim.
- [x] Discover standalone `SKILL.md` packages from project and user agent skill
  roots (`.agents`, `.claude`, `.codex`, `.cursor`, `.opencode`, `.gemini`,
  `.pi`, `.qwen`, `.github`, `.copilot`, XDG/CODEX_HOME, and `VEASEL_SKILLS_DIRS`)
  without `plugin.json`, expose `/v1/skills` plus synthetic `/v1/plugins`
  catalog entries, and keep `/skills` / `/skill` enablement on the same
  metadata-first, never-auto-execute path. Headless `veasel skills list`
  reads the discovery API without printing instruction bodies.
- [x] Let the model load a discovered skill body on demand via `agent_skill_load`
  without prior session enablement (OpenCode-style progressive disclosure),
  sample relative resource paths, and read bounded UTF-8 resources for the rest
  of the turn; content stays untrusted and files are never executed. Session
  `/skill on` remains the path for persistent prompt injection.
- [x] Disclose a bounded metadata-only `<available_skills>` catalog (plugin/source
  name, skill name, truncated description) inside the `agent_skill_load` tool
  description at turn start so the model can see discovered skills before load;
  omit the tool when the catalog is empty or every skill component is disabled;
  never embed instruction bodies in the catalog.
- [x] Harden the model skill catalog: closed `plugin_name`/`skill_name` enums,
  optional `<location>`, Codex-style description shrink before omit (~8k char
  budget / 64-entry cap), and omit skills with `disable-model-invocation` or
  OpenCode `metadata.opencode/autoinvoke=false` while keeping explicit load.
- [x] Bound project skill ancestor walks at the git worktree/repo root (`.git`
  directory or gitfile), matching OpenCode/Codex/Pi; non-git trees still use
  the existing ancestor cap.
- [x] Cover Windows `%APPDATA%/opencode/skills` discovery and standalone skill
  junction escape rejection in CI (`$if windows` tests).
- [x] Fail-closed project skill trust: `scope=project` skills stay out of the
  model `<available_skills>` catalog and `agent_skill_load` until the user
  enables them with session `/skill on` (existing POST `/v1/sessions/{id}/skills`);
  user/configured/plugin-package skills keep progressive disclosure. Capability
  `skills.project.trust`.
- [x] One-shot user skill invoke: `POST /v1/sessions/{id}/skills/invoke` queues
  a skill body for the next turn only (cap 8); TUI `/skill run <source>/<skill>`
  and `$source/skill`; capability `sessions.skills.invoke`.
- [x] When a standalone skill source key collides with an Agent Plugin package
  name, expose the standalone source as `standalone-<source>` (with a catalog
  diagnostic) instead of omitting the entire source; load resolves both the
  qualified catalog name and the original discovery source.
- [x] Opt-in Linux Bubblewrap wrap for trusted MCP stdio
  (`VEASEL_MCP_STDIO_SANDBOX=auto|require`; default `off` / unset = unsandboxed);
  capability `mcp.stdio.sandbox.bubblewrap` only when wrap will run; network
  shared; PLUGIN_ROOT/PLUGIN_DATA writable; honest unsandboxed fallback under
  auto.
- [x] Opt-in macOS Seatbelt wrap for trusted MCP stdio under the same
  `VEASEL_MCP_STDIO_SANDBOX` knobs; capability `mcp.stdio.sandbox.seatbelt` only
  when wrap will run; network shared; PLUGIN_ROOT/PLUGIN_DATA writable; honest
  unsandboxed fallback under auto; `require` fails closed without
  `/usr/bin/sandbox-exec`.
- [x] Opt-in Windows AppContainer + Job wrap for trusted MCP stdio under the
  same `VEASEL_MCP_STDIO_SANDBOX` knobs; capability `mcp.stdio.sandbox.windows`
  only when wrap will run; PLUGIN_ROOT/PLUGIN_DATA ACL grants; network
  capability SIDs always enabled (parity with Linux/macOS MCP); honest
  unsandboxed fallback under auto; `require` fails closed without AppContainer.
  Not Codex WFP/LPAC.
- [x] Persist per-session MCP trust, launch trusted stdio servers or connect
  to trusted Streamable HTTP endpoints with redirects and retries disabled,
  discover bounded tools, route calls through provider adapters, and keep nested
  JSON Schemas intact. Full conformance suite remains open.
- [x] Let operators add standalone MCP servers (stdio or Streamable HTTP) without
  an Agent Plugin package: durable user and project files, read-only import of
  portable `.mcp.json` / `.cursor/mcp.json`, `GET/POST /v1/mcp-servers` and
  `PATCH/DELETE /v1/mcp-servers/{name}` with scope, TUI `/mcp` with
  `user|project`, capability `mcp.servers.configured`, synthetic catalog
  package `configured`, trust as `configured/<name>`. Per-call approval is
  unchanged. Headless `veasel mcp list|add|enable|disable|remove` manages the
  same scopes via the local API, including `veasel mcp credentials
  list|set|remove` for named HTTP header sets. Named HTTP credentials via
  `/v1/mcp-credentials`. Stdio `notifications/cancelled` on turn cancel is
  implemented; HTTP mid-body cancel via progress callbacks is shipped, with
  post-fetch cancel refusal and first-progress abort after slow TTFB. True
  TTFB-before-any-progress socket abort under pinned `net.http` is a documented
  hard limit ([`compatibility/http-cancel-limits.md`](compatibility/http-cancel-limits.md)),
  not open product work pending a custom HTTP stack.
  WWW-Authenticate Bearer challenge discovery, RFC 9728 protected-resource
  metadata, RFC 8414 authorization-server metadata, OAuth authorize/complete,
  loopback listener, and headless `veasel mcp oauth` are shipped on 401/auth.
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

- [ ] Progressive SolidJS + `@opentui/solid` 0.6.2 migration (ordered:
  shell → … → toast → session dialogs → dialog primitives → product dialogs →
  settings). Shell through model/theme/stash/error/shell dual-path shipped;
  next slices are pane-resize/sidebar, fade/spinner, HTTP session wiring /
  mount-budget, or remaining OpenCode dialogs (MCP/skill/agent/workspaces).
  Solid LiveApp is already the default; audit remaining journeys against the
  classic client rather than treating the default cutover as pending. See
  [`compatibility/opentui-solid.md`](compatibility/opentui-solid.md).
- [x] Configure and persist multiple provider profiles from the TUI; keep API
  keys out of responses and mask them in the input flow.
- [x] OpenCode-style `/connect` credential UX: paste a key, save it locally,
  continue to model discovery; saved profile keys win over environment
  variables for the same provider; `/models` remains the full settings path.
- [x] Suggest slash commands while typing `/` in the session composer: prefix
  and substring filtering, descriptions and argument syntax, Tab to complete,
  arrows to choose, Enter to run commands without arguments, and Esc to dismiss.
  Unknown slash commands are still reported locally instead of being sent to
  the model.
- [x] Deliver a server-owned 210-preset provider catalog and keyboard-navigable TUI
  provider picker with protocol descriptions, environment-key hints, editable
  endpoints, live model discovery, and a local no-key Ollama profile. The picker
  can filter configured credentials, loopback-local endpoints, specialized API
  protocols, and OpenAI-compatible endpoints while preserving text search.
  OpenAI-compatible presets use
  the shared Chat Completions transport; provider-specific auth and SDK features
  remain out of scope until implemented and tested. One hundred seventy-eight
  compatible endpoints are generated from a pinned Models.dev snapshot; see
  [PROVIDERS.md](PROVIDERS.md) and `tools/provider-catalog/`.
- [x] Add Meta Model API and a separate OpenAI Responses preset alongside the
  existing OpenAI Chat Completions profile. Muse/GPT model discovery, streamed
  text and tools, and encrypted reasoning replay work for reasoning-capable
  models; OpenAI reasoning parameters are omitted for unsupported model
  families. `scripts/api-smoke.sh` exercises both OpenAI transports against
  local fixtures. Muse Wonder and Muse Spark advertise a 1,048,576-token
  context window ([Meta model docs](https://dev.meta.ai/docs/models)), while
  Veasel currently limits submitted input to 1 MiB (1,048,576 bytes). Model settings now
  expose a per-provider output budget (16–131,072 tokens); zero selects
  Veasel's 4,096-token default, except Meta, which omits `max_output_tokens`
  from the encoded Responses body so Meta applies its own limit (covered by
  provider encode fixtures). Headless `veasel config model get|set` updates the
  same `/v1/config/model` profiles (including `--max-output-tokens`) without
  printing API keys. Meta counts reasoning tokens in that budget
  ([Meta Responses API](https://dev.meta.ai/docs/protocols/responses)).
  Veasel still does not consume Muse's full advertised 1,048,576-token context
  window. Provider-reported token usage is aggregated into opt-in ATIF
  `final_metrics` (Milestone 3); cost uses the pinned curated schedule when every
  reported turn matches, otherwise `unavailable`.
- [x] Configurable submitted-input byte budget: `VEASEL_MAX_CHAT_INPUT_BYTES`
  raises the 1 MiB default (never lowers it) up to 64 MiB for long-context
  providers; invalid or out-of-range values fall back to the default. The
  resolved limit drives provider message validation, HTTP body bounds,
  headless prompt bounds, queued-operation and turn-record bounds, the agent
  context budget, and compaction pressure, so every layer agrees. This is a
  byte budget, not a token budget: it does not by itself consume a model's
  full advertised token window, and compaction still applies above the
  pressure threshold.
- [x] Model-aware compaction pressure: a curated context-window schedule
  (`tools/model-context/schedule.json`, `[limit] context` values from its own
  pinned Models.dev commit) resolves the active model's window when one is
  pinned. Coverage is every anthropic, openai, gemini and meta model whose
  provider or canonical `models/` TOML declares `tool_call`, text output and
  a `[limit] context` (134 rows including `openai-responses` mirrors; Muse
  Wonder 1.0 resolves to its real 1,048,576-token window). When the
  conservative bytes/4 token bound reaches three quarters of a known window,
  compaction fires with reason `token_pressure` even below the byte and
  message-count thresholds. Unknown models keep the existing thresholds;
  Veasel never invents a window. This is compaction pressure only, not a
  token budget: the submitted-input byte budget above still bounds requests.
- [x] Adaptive session compaction for in-flight provider requests when measured
  UTF-8 payload bytes (or conversation message count) cross a local pressure
  threshold: older turns are replaced with an untrusted extractive summary,
  recent turns stay verbatim, durable SQLite chat history is preserved, and a
  `session.compaction` event records measured bytes before/after plus a
  conservative bytes/4 token bound. This is not a claim of Muse's advertised
  token window.
- [x] Optional session compaction summarizer (`VEASEL_SESSION_COMPACTION_SUMMARIZER=
  extractive|native|llm`): structured native summary or one no-tools LLM
  completion over the bounded extractive digest, with automatic extractive
  fallback on error/empty/growth; capability `session.compaction.summarizer`
  when enabled; events record `compaction_summarizer_mode` and provider usage
  only when reported. Not provider-native compaction APIs; not invented cost or
  percent savings. Study pin:
  [`compatibility/session-compaction-summarizer.md`](compatibility/session-compaction-summarizer.md).
- [x] Aider-style extractive repository map for intelligent context selection:
  deterministic workspace walk, heuristic symbol extraction, mention-weighted
  ranking under a measured UTF-8 byte budget (plus bytes/4 bound), untrusted
  injection into the turn system prompt when useful, `GET
  /v1/sessions/{id}/workspace/map`, capabilities `workspace.repository_map` /
  `session.repository_map`, and `session.repository_map` events. This is not
  tree-sitter/PageRank parity with Aider and does not claim provider token or
  cost savings. Provider-reported prompt-cache accounting and request markers
  are shipped; invented cost/savings remain refused.
- [x] Start or reuse a healthy local backend when `veasel` or `veasel tui` is
  invoked, then open the TUI.
- [x] Cross-platform validation of provider settings and automatic backend
  startup probes in the pinned CI matrix: Linux/macOS/Windows run
  `model_settings_test` / `headless_config_test`; macOS also runs `main_test`
  (including `backend_is_healthy` / `ensure_backend` healthy-reuse); Windows
  keeps `main_test` plus repository-map coverage. Save/discovery also reject
  catalog endpoint placeholders such as `YOUR_ACCOUNT_ID` or `<ACCOUNT_ID>`.
  Interactive TUI matrix gaps remain under the separate ConPTY /
  measured-baseline item.
- [ ] Multi-agent isolation and orchestration.
- [x] Keep the selected home-screen session inside the sidebar. A longer list
  shows a text position such as `8/20` and omits sessions outside that window.
  Titles and directories are clipped so a narrow sidebar cannot wrap the
  selection off screen.
- [x] A workspace diff review states how many lines were added and removed.
  A diff taller than the terminal keeps the first screen and says how many
  lines remain hidden. The + and - markers stay on the visible lines.
- [x] A shell-command review states the sandbox warning and the approve
  instruction before the command text. A command or captured output taller
  than the terminal keeps the first screen and says how many lines remain.
- [x] An MCP call review states that the call has not reached its server, and
  the approve instruction, before the arguments. An argument list taller than
  the terminal keeps the first screen and says how many lines remain.
- [ ] Richer context retrieval beyond the extractive repository map, rich diff
  review, accessibility, and UX refinement. Extractive map ranking now includes
  test/source pairing, CamelCase/snake symbol-part matches, same-directory
  neighbor boosts, cross-directory same-basename-stem sibling boosts, and
  file↔package stem pairing (`lib/session.v` ↔ `lib/session/`)
  (still not tree-sitter/PageRank).
- [x] Automate x64 backend and TUI bundle packaging for Linux, macOS, and
  Windows in CI and attach verified artifacts to automated prereleases.
- [ ] Validate interactive TUI behavior on each platform and establish
  measured performance baselines. Linux + macOS standalone PTY smoke is in
  CI; one Linux workstation CLI/PTY baseline is recorded in
  [`compatibility/tui-interactive-smoke.md`](compatibility/tui-interactive-smoke.md).
  Windows remains a ConPTY checklist; macOS/Windows timing baselines are open.

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
  async turns use a durable queued job row; concurrent agents and their
  resource limits remain open.
- The organization and repository publication are tracked separately from the
  code milestones; do not describe them as complete until GitHub confirms them.
- Milestone 1 is complete only for the local Linux x64 development environment;
  macOS, Windows, Linux musl, concurrent client and production reliability
  checks remain open.
- V's SQLite module can link system SQLite when `pkg-config` discovers it. The
  release build isolates that lookup and bundles SQLite on Linux and Windows;
  macOS uses its system SQLite. The Veasel binary still uses the platform C
  runtime, but it needs no separately installed V runtime or Linux SQLite
  shared library. CI checks these platform-specific linkage guarantees.
- SSE and SQLite behavior must be tested under concurrent clients before the
  server claims durable or restart-resilient background execution.
- Solid MCP/Skills dialogs + session export options/result (OpenCode parity rows 7–8, 11–12).
- Solid composer `/` `@` `$` autocomplete (`solid/composer-autocomplete.ts` +
  `composer.tsx`): reuses classic slash/path/skill matchers; Tab/Enter/Esc/arrows;
  `testRender` coverage. HTTP catalog wiring and polish (sticky cursor sync,
  argument-context refresh) remain open.

### Transcript keyboard ownership

- Solid transcript navigation respects the focused editor: plain Home/End and page keys remain available for text editing and autocomplete. Ctrl+Home/End and Ctrl+PageUp/PageDown navigate the transcript from the composer.
- Page navigation moves the viewport explicitly, with one line of overlap. Follow-tail cues advertise Ctrl+End.
- Rendered component regression tests exercise the real composer, cursor positions, scroll geometry, and ANSI page-key sequences. These tests do not establish cross-terminal compatibility or a completed UI redesign.
### Lazy review inspection

- Pending-review inventory only fetches summaries. Detail endpoints (which record backend inspection) are called for the currently opened review, not the entire queue.
- Production approval requires every target to have successfully loaded its details in this panel. Batch approval remains available after inspection; unseen targets block the batch. Rejection remains available without inspection.
- Detail failures remain visible with `r` retry; superseded or disposed detail responses cannot replace the current view.
- Loopback HTTP and rendered keyboard tests cover inventory requests, unseen-item gating, batch approval after navigation, and detail retry. This is a client workflow guarantee, not proof a human read every line or an OS sandbox guarantee.
### Cursor-aware composer completion

- Path and Skill menus now track native editor cursor changes, including movement back into a mention without editing the draft.
- Left/right navigation remains usable while a completion menu is open; Ctrl/Alt word movement and Shift selection use OpenTUI editor methods. Completing a mention preserves the text after it.
- Rendered keyboard regressions cover both path and Skill mentions, entering/leaving menus, and suffix preservation.
### First-run project picker

- The production Open dialog no longer falls back to demo projects when no session exists. It offers a real new-session action for the current project.
- A rendered LiveApp test exercises Ctrl+O, selection, and the resulting HTTP session creation request. No model call is needed.
### Conversation surfaces and wrapping

- User messages have a raised surface and a left rail; assistant text stays on the main conversation surface. Spoken role labels remain visible without color.
- Message lines wrap to the actual available width, including narrow terminals. Rendered snapshots at 32, 56, and 100 columns protect long-text visibility and role boundaries.
- Production streaming, thinking sections, and activity groups retain their existing data flow. Full rich-Markdown migration and the complete design-system audit remain open.
### Real Skill completions

- Production composer defaults to an empty Skill catalog instead of demo entries. LiveApp discovers Skills through the versioned plugin API when a draft first contains a Skill token.
- Discovery uses the active session project, clears old entries on context changes, and discards superseded responses. Loading, empty, and failure states are visible; retry by re-entering the token or opening `/skills`.
- Loopback HTTP/component tests cover real catalog insertion, project query parameters, discovery failure, and retry. Live provider calls are not required.
