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

The TUI is TypeScript with OpenTUI + SolidJS (`@opentui/solid` **0.6.8**), kept
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
[`compatibility/opentui-solid.md`](compatibility/opentui-solid.md). The default
journeys are wired to the loopback API where supported; remaining work is
tracked per journey and must be validated against the production backend. CI
builds and packages the backend and TUI bundle for x64 Linux, macOS,
and Windows and publishes verified main builds automatically. Standalone
interactive TUI PTY smoke runs on Linux and macOS in CI; a native Windows
ConPTY harness now runs in the same CI workflow, with the exact-head result
tracked in the compatibility ledger (see
[`compatibility/tui-interactive-smoke.md`](compatibility/tui-interactive-smoke.md)).
Linux TUI CLI + PTY-connected baselines are recorded there; timing baselines
remain open. See [`RESEARCH.md`](RESEARCH.md) and
[`VLIB_REUSE.md`](VLIB_REUSE.md).

## Milestones and backlog

### Historical installed daily-driver evidence (#550; repeat on current package)

- Linux preview `v0.103.2-next.0` reproduced a Desktop-first startup failure:
  the AppImage started its backend on an ephemeral port, and the released TUI
  launcher then tried to start another backend for the same locked data directory.
  The Desktop startup fix uses the same loopback port as the launcher. A local
  Desktop build attached to the released V backend and shared its PID with the
  released TUI in both startup orders, using isolated profiles.
- A temporary predecessor harness recorded the published Linux release
  `v0.103.3-next.0` passing with both packaged launchers in both orders
  (AppImage→TUI and TUI→AppImage). The artifacts matched `release.json`; both
  runs kept one authenticated backend PID and reached a TUI connected view plus
  the Desktop Focus route. A later corrected routeprobe independently passed
  both orders and confirmed the visible TUI, routed Focus page, artifact hashes,
  and shared backend PID/version; the sanitized result is preserved in the
  [`corrected routeprobe evidence`](desktop/evidence/shared-listener-v0.103.3-next.0.json)
  alongside the checked-in harness result.
  The checked-in harness itself still failed to observe AppImage-first
  readiness/Focus, then hit the host disk quota creating its second-order
  profile. These results establish packaged startup/reuse only, not the complete
  daily-driver journey. The Desktop renderer was inspected headlessly. The
  separate diagnostic attempt that exited 127 is intermittent; available logs
  do not establish its cause. The release predates exact-file approval PR #821.
  Reproduction and exact artifact
  hashes are in [`desktop/packaged-shared-listener-smoke.md`](desktop/packaged-shared-listener-smoke.md)
  and [`desktop/evidence/shared-listener-v0.103.3-next.0.json`](desktop/evidence/shared-listener-v0.103.3-next.0.json).
- On the same Linux host, the released AppImage completed a real Claude Code
  task with a file-edit approval in Focus. The released TUI completed a real
  Codex task in explicit accept-edits mode. Both sessions edited only
  `CONTRIBUTING.md` in separate disposable checkouts of the public Veasel Labs
  community repository. Both diffs passed `git diff --check`.
- Repeat on a published Desktop build containing the fix. Cancellation,
  installed cross-platform recovery and full daily-driver acceptance remain
  tracked in [#550](https://github.com/veasel-labs/veasel/issues/550).
  These runs used the `v0.103.2-next.0` preview and are historical evidence,
  not acceptance of the current `v0.103.3-next.0` package. Attach the exact
  installed/executed version, source and workspace SHAs, session, permissions,
  and receipts for any repeat.
- HorneroOS smoke on 2026-11-26 used the installed `v0.106.3-next.0` Desktop
  and TUI against one isolated temporary backend profile. Desktop health was
  HTTP 200; native discovery verified the installed Codex CLI, and a
  read-only `plan` session against this repository completed through Codex.
  The TUI then connected to that same backend and saw the shared session. The
  worktree stayed clean. The stale Desktop launcher was corrected to the
  extracted `v0.106.3-next.0` AppDir and passes `desktop-file-validate`.
  Evidence and installed executable hashes are recorded in
  [`desktop/evidence/hornero-installed-smoke-2026-11-26.json`](desktop/evidence/hornero-installed-smoke-2026-11-26.json).
  This does not complete daily-driver acceptance: the session was admitted via
  the backend API rather than submitted through the Desktop composer, the
  installed build is still a prerelease, and the host's other native provider
  checks remain partly unknown.

### Optional cozy World (#693)

- The packaged Linux preview `v0.105.0-next.0` was installed side-by-side on
  HorneroOS and launched through its extracted AppDir because this host denies
  AppImage FUSE mounting. Its top-down pixel-art World rendered nine real
  destinations; no session or productivity activity was fabricated. A
  separate isolated profile also opened the World with real temporary sessions.
  Screenshots are retained under `/home/ulisesjcf/.cache/veasel-validation/`.
- On 2026-11-26, the published `v0.106.1-next.0` AppImage was downloaded and
  SHA-256 verified against its release manifest before extraction. Its packaged
  Desktop launched with a throwaway HOME, data directory and workspace. The
  Cozy Valley at 1440×900 and Cyberpunk City at 1024×640 were rendered and
  visually reviewed; the map composition and pixel scaling are coherent at
  both sizes. Screenshots are retained in
  `/home/ulisesjcf/.cache/veasel-validation/v0.106.1-next.0/`. This isolated
  profile had no authenticated providers or active sessions, and its runtime
  detail queries were unavailable. It proves packaged launch and visual
  framing only, not the daily-driver journey or live-agent display.
- The packaged World currently projects the real Focus session list and
  destinations. PR #836 projects data from the existing memory, tools, and jobs
  APIs, makes project job state explicitly unknown when that source is
  unavailable, and labels retained data after a backend disconnect. It also
  replaces fixed “ready” claims with destination descriptions and improves
  camera framing for tall compact windows while keeping Fit World as the
  complete overview. PR #836 merged to main as `33f98183`; published release
  `v0.106.1-next.0` is based on `709d6857`, which contains that merge. Its
  packaged Desktop still needs the updated readiness fix below and fresh
  visual/acceptance evidence.
- Exact-main CI run `45726898766` for merge commit `33f98183` completed with a
  failure in `V backend / linux`: the Linux HTTP and persistence smoke reported
  `health version does not match the CLI version`. The smoke's readiness loop
  could accept anonymous liveness before the API token existed, leaving a
  response without version metadata for the later assertion. The fix waits for
  authenticated health with the expected version and process ID. Exact branch
  CI passed for candidate `72ca0ff4` in run `45746852114`, including required
  Linux, macOS and Windows jobs. It is not yet integrated into `main`; rerun
  exact-main checks and packaged acceptance after integration. The later
  `Ensure main CI` workflow-run `45734923673` succeeded, but did not rerun the
  failing smoke.
- The World remains optional and is not evidence of daily-driver completion.
  Focus/TUI session parity, provider authentication recovery, cancellation,
  packaged-session recovery, and cross-platform acceptance remain open under
  [#550](https://github.com/veasel-labs/veasel/issues/550). On this host, the
  installed Codex authentication completed a real isolated read-only acceptance
  turn. Claude’s UI reported an authenticated MAX account but the provider
  rejected its revoked OAuth token; Cursor is detected but is not yet
  launchable through Veasel. No credentials were changed as part of acceptance.

### Durable goals and worker coordination

- [x] Add Veasel-specific, authenticated admission, listing and manifest replay for portable goals.
  Admission records preserve the declared scope and survive restart.
- [x] Implement authenticated read-only repository identity preflight for
  local roots and scoped paths (PR #830). The result remains point-in-time
  diagnostic evidence and must be revalidated by any future dispatcher.
- [ ] Bind repository identity/base-SHA revalidation to every dispatch. Resolve
  runner and verifier IDs against registered capabilities and enforce policy
  ceilings and deadlines in V.
- [x] Persist per-task status and attempt history, initialize it idempotently,
  and atomically claim only dependency-ready tasks within the goal-wide attempt
  budget (all tasks and retries count). Classify claims with missing, exited,
  or unverifiable owner identity as uncertain and never replay them.
  This state-only groundwork landed in #835; it does not dispatch work. PR #840
  is merged into `main` at `495f57cb`; it links claimed attempts to the existing
  operation lifecycle with fencing tokens and goal-specific events. It still
  does not launch workers.
- [x] Link claimed attempts to the existing operation lifecycle (PR #840).
  Runner and verifier resolution, policy enforcement, dispatch and UI remain
  separate milestones.
- [ ] Prepare an isolated, clean worktree for each claimed task at its exact
  admitted full base SHA. PR #841 adds fail-closed checkout
  revalidation, repository-config refusal, collision and symlink checks,
  durable attempt/worktree identity, and uncertain recovery; focused tests pass
  in the development compiler. This PR remains unmerged and does not launch an
  agent. Expose no public start/claim path until the full dispatch acceptance
  gates below are implemented.
- [ ] Surface goals, review requests and evidence in TUI and Desktop. Run
  progressive concurrency acceptance with live agents and independent review.
- [x] Integrate the authenticated deterministic task projection (PR #831). It
  returns dependency-ordered metadata with durable status and
  attempt history; it does not schedule or launch workers. Runner/verifier
  resolution, dispatch and UI remain separate milestones.

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
  Tab/Enter/Esc/arrows); live workspace Skills and path catalogs load from the
  loopback API/filesystem, with rendered tests for cursor movement and suffix
  preservation.
- [x] Solid session transcript on `scrollbox` with sticky follow-tail,
  `transcriptSegments` tone rendering, and `testRender` coverage (long scroll,
  streaming append, 80×30); LiveApp loads and refreshes transcript history via
  the loopback API.
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
- [x] Restore queued/running/cancelling operations when reopening a Solid TUI session, retaining submission order even when creation timestamps tie. Events received during recovery supersede stale snapshots (including missing rows); older events do not override newer server states. Uncertain outcomes retain an inspect-before-retry warning, and the client never replays a provider operation.
- [x] Abort provider SSE body progress as soon as turn cancellation is visible,
  including non-2xx and status_code-0 progress callbacks, and re-check the turn
  context after `http.fetch` returns. True socket close before any progress
  callback remains limited by the pinned `net.http.fetch` API (no external
  cancel handle).
- [x] Retry transient provider failures inside the turn with bounded,
  deterministic backoff so a shared upstream hiccup no longer fails the whole
  operation: connection-level failures and HTTP 408/425/429/5xx get up to two
  identical retries (500ms, 2s) while the provider slot stays held. A retry
  never runs after a request delivered any text delta (no duplicated output),
  never crosses the request deadline, always yields to cancellation, and
  never replays `provider_busy`/`app_shutting_down` local slot errors or
  permanent client errors (401/403/404). Anything not classified transient
  keeps the exact fail-closed behavior and durable error reporting. Covered
  by local OpenAI-compatible fixtures (500→500→success, 429→success,
  401→single attempt, connection-refused dial with the pinned backend's
  socket-error wording), a classifier unit test with platform errno tables,
  and retry-loop unit tests proving text already delivered is never replayed.
- [x] Honor provider `Retry-After` delta-seconds and HTTP-date headers on the
  shared streaming path. Typed internal error metadata carries the delay
  without exposing the raw header in durable errors. Use the longer of the
  server delay and deterministic backoff, reject retry windows beyond the
  turn deadline immediately, and preserve cancellation, attempt limits,
  no-replay-after-text, and permanent-error exclusions. Invalid headers retain
  deterministic backoff; numeric overflow cannot shorten the wait.
- [x] Add provider-native tool calls for OpenAI-compatible, Anthropic, and Gemini with a bounded read-only tool loop.
- [x] Expose bounded read-only workspace list/read/search operations over the API, with canonical-root containment and symlink-safe traversal.
- [x] Connect read-only workspace tools to provider-native calls; treat file content as untrusted and enforce per-tool, round, call-count, and aggregate-result limits.
- [x] Size the per-turn budget for real multi-file tasks: 24 provider rounds / 48 tool calls (was 6/12, which failed an end-to-end fixture task with `agent tool call limit reached` before any edit was proposed). Exceeding either budget now ends the turn with the existing durable tool-budget summary instead of failing the operation; the identical-repeat tracker remains the runaway guard.
- [x] Execute contiguous workspace list/read/search calls in a provider round
  concurrently as ordered waves, with skill load/read, edits, shell, and MCP as
  sequential barriers. Preserve provider result order and suppress duplicate
  file reads across waves.
- [x] Let models request bounded, one-based line ranges from a workspace file, with line-numbered evidence, a 200-line/32 KB result cap, and range-aware duplicate-read suppression. Range and search scans avoid allocating every source line; mixed CR/LF endings and UTF-8 truncation remain covered. Only successful, permitted reads enter the duplicate cache, with collision-safe identities and invalidation at mutation barriers.
- [x] Generate bounded single-file diffs, persist proposals, require explicit durable approval, reject stale snapshots, and recover interrupted applications without replay.
- [x] Add permissioned shell execution with explicit, durable approval. The
  TUI requires opening the exact command, working directory, and timeout before
  approval; execution limits and recovery behavior are documented in
  [`SHELL_COMMANDS.md`](SHELL_COMMANDS.md).
- [x] Deliver bounded SSE text streaming for OpenAI-compatible, Anthropic, and Gemini providers through durable API events and the TUI; aggregate complete responses and provider tool calls.
- [x] Add opt-in `Prefer: respond-async` session turns so long model calls and human MCP approvals do not occupy an HTTP request worker; persist the operation as `queued` with request payload before accepting, claim to `running` in a worker, expose status/list/cancel for reconnect, and commit successful history, operation state, and terminal events atomically. Queued jobs resume after restart; claimed `running`/`cancelling` work is classified as `uncertain` and never replayed.
- [x] Add `veasel run` for non-interactive session turns using the shared server, provider, and agent runtime; persist and continue sessions, emit machine-readable JSON, and request cancellation on timeout. Default edit, shell, and MCP approvals remain intact.
- [x] Add an explicitly opt-in autonomous path for isolated benchmark tasks. The running server must opt in separately; ordinary CLI/TUI approval behavior remains unchanged. Autonomous file edits and shell commands retain durable proposal/result records, shell subprocesses receive an allowlisted environment, and MCP sessions are rejected. Autonomous shell is fail-closed OS-sandboxed: Linux Bubblewrap (read-only host, writable workspace, hidden home/removable/runtime, isolated network, allowlisted env), macOS Seatbelt when `/usr/bin/sandbox-exec` is present (allowlisted env, network denied), and Windows AppContainer + Job Object when available (network denied, allowlisted env). Platforms without that backend refuse to start a process. Stdio MCP remains outside this sandbox.
- [x] Add a graduated execution permission policy (`ask` | `auto-edit` | `sandbox-auto`) with allow/deny/ask decisions bound to those OS sandboxes. `autonomous: true` maps to `sandbox-auto`. Non-interactive turns map ask→deny. Auto-edit requires `VEASEL_ALLOW_AUTO_EDIT=1` (or autonomous allow); sandbox-auto still requires `VEASEL_ALLOW_AUTONOMOUS_EXECUTION=1`. MCP stays deny under sandbox-auto and ask/deny otherwise (never auto-apply). Capability `agent.execution_policy` (+ `.auto_edit` / `.sandbox_auto` when server-enabled).
- [x] Wrap manually approved shell commands in the platform OS sandbox by default (`VEASEL_SHELL_SANDBOX` unset/invalid = `require`; `auto`/`off` also refuse unless the explicit `VEASEL_SHELL_ALLOW_UNSANDBOXED` opt-in is set). Linux uses Bubblewrap, macOS Seatbelt, and Windows AppContainer + Job. Capabilities are true only when the wrap will run; `require` fails closed when the backend is missing. Network is denied by default for shell. Approval remains mandatory.
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
- [x] Delete a session with `DELETE /v1/sessions/{id}`: chat history, events,
  and cascade-dependent session state are removed; workspace files on disk
  are never touched. Missing sessions return 404.
- [x] Aggregate those reported totals per session on `GET /v1/sessions/{id}/usage`
  and surface them through the TUI `/usage` command without inventing rates.
  The same reported-only aggregation is available across all sessions on
  `GET /v1/usage` (`sessions`, turn counts, token/cache/reasoning totals and
  the pinned-schedule cost label); LiveApp Home Status exposes a compact
  aggregate of those counters even without an active session. The searchable
  TUI `/usage` dashboard groups durable counters by provider and model across
  sessions. The aggregate query prices each provider/model group once while
  retaining per-turn cache validation. Each model group also reports how many
  completed turns supplied cache and reasoning counters, so partial provider
  metadata is visible in the dashboard.
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
- [x] A durable usage/cost dashboard beyond per-session reported tokens and
  opt-in ATIF `final_metrics`. `/usage` now browses durable provider/model
  groups across sessions with reported counters and pinned-schedule cost labels;
  `/status` remains the session/model/connection snapshot.
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
  local package links use `/v1/plugins/links` and capability `plugins.links`.
  Solid TUI supports `/plugin add [--replace] <absolute-path>` with an
  interactive path prompt and explicit replacement confirmation, plus
  `/plugin remove <name>` with confirmation. Links ship with a durable
  `$VEASEL_DATA_DIR/plugin-links.json` sidecar (restore missing symlinks on
  list; optional `replace`) and validated
  package summary fields for install UX; they do not fetch remote packages.
  Remaining open:
  remote marketplace, upstream cross-implementation fixtures (none published at
  the pinned revision), OAuth DCR (deferred), legacy HTTP+SSE.
  Operator-configured MCP servers support user scope, project scope
  (`<workspace>/.veasel/mcp-servers.json`), and read-only project-import of
  portable `.mcp.json` / `.cursor/mcp.json` via `/v1/mcp-servers`, headless
  `veasel mcp add|remove|enable|disable` with optional `user|project`, and
  capability `mcp.servers.configured`; the default Solid TUI lists these
  servers with `/mcp` and sets session trust with `/mcp trust|untrust`, while
  every tool call still uses the per-call review panel. Trust reuses
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
- [x] Fail-closed-by-default Linux Bubblewrap wrap for trusted MCP stdio
  (`VEASEL_MCP_STDIO_SANDBOX` unset/invalid = `require`; `auto`/`off` refuse unless the explicit `VEASEL_SHELL_ALLOW_UNSANDBOXED` opt-in is set);
  capability `mcp.stdio.sandbox.bubblewrap` only when wrap will run; network
  shared; PLUGIN_ROOT/PLUGIN_DATA writable; unsandboxed only with the explicit opt-in.
- [x] macOS Seatbelt wrap for trusted MCP stdio under the same
  `VEASEL_MCP_STDIO_SANDBOX` knobs; capability `mcp.stdio.sandbox.seatbelt` only
  when wrap will run; network shared; PLUGIN_ROOT/PLUGIN_DATA writable; unsandboxed only with the explicit opt-in; `require` fails closed without
  `/usr/bin/sandbox-exec`.
- [x] Windows AppContainer + Job wrap for trusted MCP stdio under the
  same `VEASEL_MCP_STDIO_SANDBOX` knobs; capability `mcp.stdio.sandbox.windows`
  only when wrap will run; PLUGIN_ROOT/PLUGIN_DATA ACL grants; network
  capability SIDs always enabled (parity with Linux/macOS MCP); unsandboxed only with the explicit opt-in; `require` fails closed without AppContainer.
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
  package `configured`, Solid TUI session trust as `configured/<name>`. Per-call approval is
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

- [x] Make the SolidJS + `@opentui/solid` 0.6.8 LiveApp the standalone TUI
  default. The default migration is complete. Remaining Solid work is product
  behavior and validation, not a pending migration; audit each journey against
  the production HTTP backend and current OpenCode/OpenTUI sources. See
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
  The packaged interactive smoke now passes on Linux, macOS, and Windows; the
  exact Windows ConPTY run is recorded in
  [`compatibility/tui-interactive-smoke.md`](compatibility/tui-interactive-smoke.md).
- [ ] Multi-agent isolation and orchestration. OpenCode's focused 2026-10-23
  recheck is in [`COMPETITIVE_SOURCE_STUDY.md`](COMPETITIVE_SOURCE_STUDY.md),
  with exact source and test links.
  Design this over Veasel's existing session/durable-operation store: persist
  parent-child ownership; authorize the selected non-primary agent; bound
  nesting, concurrent children, runtime, and result bytes; isolate each child
  workspace; support cancellation; and deliver terminal outcomes once across
  restart. Do not expose a model-callable subagent tool until those lifecycle
  guarantees have focused tests and task-level benchmark evidence.
  The first storage increment adds an idempotent parent-operation/request key,
  atomic child-session ownership, a two-level nesting ceiling, four concurrent
  runs and a 32-run persistence ceiling per parent, a 64 KiB terminal result
  cap, and durable terminal outcome delivery. Claiming an outcome and recording
  its parent-session event commit together; retrying after restart returns the
  same terminal result rather than losing it behind a one-shot claim. The
  startup recovery transaction also emits one parent-session event for each
  durable terminal outcome that remains unclaimed, including children
  classified as `uncertain`; event persistence and the recovered claim commit
  together. A partial covering SQLite index limits this recovery lookup to
  terminal runs whose outcomes remain unclaimed instead of scanning the full
  child-run history at every startup.
  The event contains only the child run ID and terminal status marked untrusted;
  the bounded durable run row remains the source of the result text.
  Replaying the parent turn from these events and fetching the result into model
  context remain separate work.
  An unmerged prototype on `feat/subagent-readonly-worker` adds a synchronous,
  model-callable `subagent_run` path for the two built-in read-only profiles,
  using the parent cancellation context and persisting child usage and outcome.
  After the terminal outcome is durably claimed, it removes the generated
  worktree only if its tracked snapshot, copied untracked files, permissions,
  and ignored-file set remain unchanged. Edited workspaces are preserved, while
  untouched investigations stop consuming the shared 64-worktree limit.
  Local fake-provider end-to-end tests now prove dispatch, child file inspection,
  usage persistence, safe failure delivery, and that the parent turn returns
  when cancelled while a child provider HTTP response remains pending. The
  cancelled child outcome is durable, but its blocking HTTP worker may remain
  until the transport returns: pinned V `net.http.fetch` exposes no public
  handle to close a socket immediately on cancellation. The pinned V
  [`Request.read_timeout`](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/net/http/request.v#L57-L60)
  field comment says SSL is unsupported, but the implementation propagates it
  to `SSLConn.set_read_timeout` in the
  [pinned HTTP backend](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/net/http/backend.c.v#L46-L50).
  Veasel sets the timeout to the smaller of the remaining turn deadline and
  60 seconds; provider progress callbacks also observe cancellation. This
  bounds an idle TLS read but does not close the active socket immediately or
  impose an absolute lifetime on the request. A cancelled worker can therefore
  retain its child provider slot until progress arrives or the idle timeout
  expires. Task-level comparative evidence remains outstanding; lifecycle
  coverage alone does not establish that delegation improves task success or
  efficiency.
  To keep such a worker from occupying every provider slot, delegated workers
  are limited to one active provider call within the existing shared
  four-call process-wide pool. A stalled child can therefore leave three slots
  for ordinary turns; when no child is active, all four slots remain available
  to ordinary turns. This bounds starvation impact; it does not make the
  delegated socket immediately cancellable.
  The storage boundary accepts only the built-in `reviewer` and `explorer` profile
  IDs; both grant read-only
  workspace list/read/search tools. Interrupted running children become
  `uncertain` on restart and are never replayed. This is persistence groundwork
  only. Parent stop now cancels queued children and persists a
  cancellation request for running children so a future worker can observe it;
  a late child result is discarded if that request was committed first. This
  storage-level signal does not itself terminate a provider request or process.
  `subagent_worktree.v` now prepares a separate branch/worktree from staged and
  unstaged tracked changes plus bounded, non-ignored untracked regular files;
  ignored files are excluded, untracked symlinks are rejected, and the parent
  checkout stays unchanged. Child-run creation now reserves an unready row,
  prepares the worktree without holding the SQLite mutex, and marks it ready
  only while its parent operation is still running. Workers cannot claim
  unready rows. A durable start marker lets startup remove cancelled/failed
  worktrees only when the child never began. After a terminal result and
  delivery claim are durable, an unchanged generated worktree is removed while
  the run row, transcript, usage, and outcome remain in SQLite; changed
  workspaces are preserved. The child session returns to its source project
  directory only after successful removal. Startup retries cleanup after
  interrupted delivery. OS-level preparation locks distinguish a crashed
  preparer from one still creating or cleaning the workspace, including across
  store instances.
  Authorizing callers beyond the built-in allowlist, enforceable child runtime
  deadlines, cancellation of the underlying in-flight HTTP request/process,
  parent turn replay, API/TUI integration, and task-level benchmark evidence
  remain required before a model-callable tool is enabled outside this draft.
  The `implementer` profile now has file-only tools; its trusted profile does
  not grant shell or MCP. Issue #642 keeps child commands disabled while the
  platform boundary is incomplete. A Linux-only Bubblewrap primitive can bind
  a canonical strict-descendant directory as writable while the rest of its
  workspace remains read-only, with symlink, parent-escape, and pre-existing
  hard-link rejection in the writable tree. This primitive is not exposed to
  agents: aggregate memory/disk/process limits,
  durable child command lifecycle and review, restart/cancellation acceptance,
  and equivalent macOS/Windows enforcement remain open. Unsupported platforms
  therefore continue to have no child command capability.
- [x] Keep the selected home-screen session inside the sidebar. A longer list
  shows a text position such as `8/20` and omits sessions outside that window.
  Titles and directories are clipped so a narrow sidebar cannot wrap the
  selection off screen.
- [x] A workspace diff review states how many lines were added and removed.
  A diff taller than the terminal pages through the selected hunk with PgDn/b,
  while {/} moves between hunks. The + and - markers stay on visible lines.
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
  (still not tree-sitter/PageRank). Symbol extraction recognizes Go functions
  and receiver methods, Kotlin `fun`/class forms, Swift protocols/extensions,
  and common visibility/behavior modifiers on supported declaration forms;
  this remains bounded line-based extraction, not parsing.
  Ranking also uses bounded lexical overlap against already-read source and
  compound path terms, normalizes common `-ing` query words, strengthens the
  high-confidence argument/args filename alias, and applies a test-file
  demotion only when the user asks about behavior rather than tests. Bounded
  source reads now prioritize path relevance and enforce the aggregate byte
  cap. The metadata-only walk now considers up to 20,000 paths before ranking
  the strongest 2,000 candidates; source extraction remains capped at 800 files
  and 8 MiB, and ranking uses V's O(n log n) `sort_with_compare`. Curated
  retrieval cases for Aider, mini-swe-agent, SWE-agent, OpenCode, and Pi are
  recorded with exact revisions and rankings in `benchmarks/README.md` and its
  linked reports (22/22 recall@3 and 22/22 recall@10 on this small sample after
  generic-basename demotion and ordered-compound ranking); semantic retrieval
  and broader task-success evidence remain open gaps.
  Built-in muted/meta text now has at least 4.5:1 contrast against shell,
  panel, header, and composer backgrounds. Warning-status text meets the same
  threshold on shell, panel, and composer backgrounds. The regression lives in
  `tui/src/themes.test.ts`; this is a targeted color check, not a complete
  accessibility review. Transcript role labels and body text now also have
  focused contrast coverage against their rendered surfaces; the Day theme's
  amber tool label was darkened to meet the same 4.5:1 threshold.
- [x] Automate x64 backend and TUI bundle packaging for Linux, macOS, and
  Windows in CI and attach verified artifacts to automated prereleases.
- [x] Validate the packaged interactive TUI smoke on Linux, macOS, and Windows.
  The exact-head Windows ConPTY result and journey are recorded in
  [`compatibility/tui-interactive-smoke.md`](compatibility/tui-interactive-smoke.md).
- [ ] Establish stable measured TUI performance baselines beyond the existing
  Linux workstation CLI/PTY baseline, and broaden interactive coverage to
  streaming, MCP OAuth browser open, and long diffs. The packaged PTY/ConPTY
  smoke now also seeds a real workspace edit, opens it through Ctrl+R, approves
  it, and verifies the backend's applied state and file contents. CI retains
  three launch-to-connected-home samples per Linux/macOS/Windows run; hosted-
  runner timing is not yet a stable hardware-controlled baseline or a
  performance gate. The Solid client coalesces rapid SSE assistant deltas
  into 16 ms batches before updating the reactive transcript; this reduces
  signal/render churn but is not a substitute for measured cross-platform FPS
  and latency baselines.

## Initial compatibility target

Milestone 1 is an original API, not an OpenCode clone. The current comparison
covers session lifecycle and events against the pinned OpenCode contract; Veasel
health and capability routes are product-specific. The historical
OpenCode/Codex/Pi samples in [`RESEARCH.md`](RESEARCH.md) are research pins only,
not claims of current heads. Refresh and pin exact upstream schemas before
adding a compatibility claim. Do not reuse source code without recording and
honoring its license and attribution.

## Risks and decisions

- The official V mascot artwork is CC BY-NC 4.0. The terminal client encodes
  Veasel Labs' original website pixel companion under MIT; do not add upstream
  mascot artwork unless rights for the intended use are established.
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
- The initial tool loop caps in-flight provider calls and tool-loop steps, warns
  after three identical consecutive tool calls, and skips calls from number five
  before dispatch; focused coverage checks canonical JSON arguments and confirms
  a skipped edit has no workspace effect. Same-session turns are serialized so
  provider history cannot race. Opt-in
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
- Solid MCP/Skills dialogs and session export options/results (OpenCode parity
  rows 7–8, 11–12) still need journey-level comparison and validation; the live
  dialogs already load their catalogs through the loopback API. MCP server
  configuration now adds stdio/Streamable HTTP servers and enables, disables,
  or removes configured servers through the same API; removal is confirmed.
  Bare `/mcp add` opens a guided stdio/HTTP setup that records configuration but
  does not launch a server before the operator separately trusts it.
- Solid composer `/` `@` `$` autocomplete (`solid/composer-autocomplete.ts` +
  `composer.tsx`): reuses classic slash/path/skill matchers; Tab/Enter/Esc/arrows;
  live catalog wiring and cursor synchronization are implemented and covered by
  rendered tests. `/skill on|off|run <source>/<skill>` now loads the active
  project's catalog and offers real argument completions. `/mcp trust|untrust`
  loads configured servers plus session trust state and suggests enabled,
  available or trusted targets as appropriate. `/mcp remove|enable|disable`
  suggests configured server names from the live catalog, filtered by scope.
  Selecting a server in `/mcp` opens actions for session trust and configured
  enable/disable/removal; replacement and removal require confirmation.
  Pending edit, shell, and MCP
  review IDs come from the summary-only inventory; Enter opens the selected
  review and fetches details only for that item, without applying a decision.
  Plugin-link add and removal complete from the live registry, with explicit
  confirmation for replacement/removal. Cross-terminal validation remains open.

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
- Production streaming, thinking sections, and activity groups retain their existing data flow. The Solid transcript renders assistant history and live responses as rich Markdown, including syntax-highlighted code blocks. The classic transcript renders the followed live/latest assistant response as rich Markdown and uses styled Markdown segments when scrolled. The complete design-system audit and cross-terminal rendering review remain open.
### Real Skill completions

- Production composer defaults to an empty Skill catalog instead of demo entries. LiveApp discovers Skills through the versioned plugin API when a draft first contains a Skill token.
- Discovery uses the active session project, clears old entries on context changes, and discards superseded responses. Loading, empty, and failure states are visible; retry by re-entering the token or opening `/skills`.
- Loopback HTTP/component tests cover real catalog insertion, project query parameters, discovery failure, and retry. Live provider calls are not required.

## Fleet orchestration and portable workflow handoff (incomplete)

The existing session-turn queue, merged Goal v1 admission/preflight work, and
the merged #831 task projection are not an objective scheduler. `veasel-labs/veasel`
must own execution, persistence, scheduling, workers, GitHub reconciliation,
evidence, and the versioned API. `ulises-jeremias/agent-toolkit` owns portable
goal/task/evidence contracts, validators, playbooks, and workflow recipes;
`veasel-labs/agent-toolkit` is the reference-based plugin marketplace, with no
separate runtime. `~/.ai-workspace` remains the owner of its seven existing
loop definitions, histories, reports, packs, policies, and scheduler artifacts
until a per-loop handoff is reviewed and accepted. HorneroOS and
`agentic-workstation` retain privileged desktop and OS actions; Veasel must not
duplicate those capabilities.

- [ ] Publish a versioned Toolkit goal/task/evidence contract with an offline
  validator and planner; require authorized repositories, observable finish
  conditions, playbook, deadline, budget, permissions, delivery mode, DAG,
  base SHA, paths, runner, verifier, and evidence. Start with research, bug,
  feature, migration, and release playbooks, reusing loop validators and
  handoff formats where they match. Preserve current Swarm commands and states.
  Add an optional pstack-inspired pack with provenance and compatibility
  metadata; do not copy external playbook sources into the marketplace.
- [ ] Keep the official `veasel-labs/agent-toolkit` marketplace reference-based:
  pin plugin versions, record provenance/compatibility/permissions, and retain
  trust review before installation. Keep `agent-toolkit.io` focused on the
  portable capabilities in `ulises-jeremias/agent-toolkit`, not its retired
  Desktop.
- [ ] Build an objective scheduler in V and SQLite, separate from session-turn
  operations. Persist tasks, attempts, leases/generations, evidence, decisions,
  and audit events transactionally. Validate DAGs, repository identity, base
  commits, runner/verifier capabilities, policy ceilings, and paths before
  dispatch. Writers acquire leases for overlapping paths; revalidate actual
  diffs before any external publication. Persist a claim and its generation
  atomically, use stable automation branch identities, record cancellation
  before confirming process termination, and pause by stopping new assignments
  while preserving visible in-flight work.
- [ ] Define goal states separately from session operation states, including
  `queued`, `leased`, `building`, `verifying`, `draft_ready`, `accepted`,
  `blocked`, `uncertain`, `failed`, and `cancelled`. Remote leases heartbeat at
  20 seconds and expire at 90 seconds; an expired or ambiguous effect becomes
  `uncertain` and is never replayed without reconciliation. A stale attempt
  cannot publish after losing its generation.
- [ ] Bind independent verification receipts to repository, base and candidate
  SHAs, task attempt, verifier/version, environment, modality, result, artifact
  digest, and source links. Label fixture, simulated, and real runs distinctly;
  any push invalidates evidence for the previous candidate SHA.
- [ ] Require an owner agent and a separate verifier for every PR. The owner
  cannot approve its own work. Run the verifier swarm against the code-ready
  SHA; a later rebase or narrow fix gets a fresh verifier, while new behavior
  or a substantially larger diff triggers full re-review. Only a clean verdict
  on the exact merge candidate may authorize automatic merge.
- [ ] Add versioned goals/tasks/attempts/evidence/decisions API and the CLI
  commands `veasel goals plan`, `veasel goals start`, `veasel goals list`,
  `veasel goals status --json`, `veasel goals watch`, `veasel goals pause`,
  `veasel goals resume`, `veasel goals cancel`, and `veasel goals report`.
  Add capability discovery for registered agents, models, runners, and
  verifiers. TUI and Focus consume the same API, show pending decisions with
  reasons and evidence, resume event streams by cursor, and fetch a snapshot
  when a cursor expires. Keep loopback binding as the default. World may
  visualize this real shared activity only after
  TUI and Focus parity is proven; it must never simulate productivity.
  Herdr remains a way to open supported runner terminals, not another runtime.
  Until goal dispatch and remote authentication ship, describe the integration
  as on-host session work only; do not claim remote execution is supported.
- [ ] Keep GitHub intake and publication separate. Begin with authenticated,
  cursor-based, deduplicated GitHub App reads that propose reviewable work.
  Intake signals are issues with an explicit intake label, failed checks on
  enabled branches, and release observations; install the GitHub App only on
  explicitly enabled repositories.
  A publisher with repository-scoped credentials creates or updates drafts,
  first recovering an existing PR idempotently. Workers never receive
  publication credentials. Support separate delivery modes: stack produces
  independently verified drafts for human merge; full may merge only after the
  exact-SHA verifier, required checks, branch/merge-queue eligibility, and
  post-merge `main` check pass. During pilots, all outcomes are drafts and all
  external writes remain explicitly gated.
- [ ] Preserve all seven current loops. Veasel's initial view is read/report
  only for the new Veasel-Labs integration scope for six, with OSS triage
  draft-only. Original loops retain their existing permissions for their
  existing scopes until separately migrated. Define a local `(repository,
  effect)` owner manifest covering issue/PR create and update, assignment,
  labels, comments, commit, push, close, merge, and release publication;
  enforce it in the executor and with scoped credentials.
  Compare the same event in both paths and prove that at most one external
  effect occurs. Do not change loop YAML, histories, reports, or triggers until
  ownership is confirmed on other hosts/schedulers and a one-loop rollback is
  documented. Existing loop output stays local by default.
- [ ] Maintain two distinct local pilot goals: (1) the packaged Linux Claude
  Code and Codex daily-driver journey tracked by #550, and (2) the existing
  four-repository release-sync report goal. Add a separate product-pilot
  manifest; do not broaden or overwrite the release-sync manifest. Record the
  exact installed/executed binary versions, repository/workspace SHAs, session,
  permissions, cancellation/recovery outcome, verifier, and evidence. Keep
  distribution checksums and per-channel evidence separate.
  Limit the first local plan to two goals and eight tasks, at most four provider
  turns and two concurrent writers, while reserving capacity for independent
  verification and operator decisions. Before cutover, run both paths for two
  nights with at least ten real tasks, one induced restart, evidence on every
  draft, and proof that the same event caused no duplicate external effect.
- [ ] Drive website downloads, Homebrew and AUR from one verified Veasel
  release manifest with asset hashes and platform metadata. Publish real
  screenshots of the installed TUI and Desktop only after the corresponding
  packaged flows have been exercised; keep CLI/TUI and optional Desktop install
  paths clear on each platform.
  Complete packaged TUI/Desktop workdays on macOS and Windows before claiming
  cross-platform daily-driver parity.
- [ ] After local recovery and cancellation are proven, add the persistent
  Linux coordinator and remote workers. Use authenticated SSH tunnels to the
  loopback coordinator, rootless disposable checkouts, CPU/RAM/disk limits,
  no container socket, dedicated API credentials in the runner only, and
  tested backup/restore. Reconcile refs, PRs, releases, and process state before
  retrying any uncertain effect.
  Before remote admission, reconcile live process identity and query the
  canonical ref, PR, or release; an ambiguous effect stays `uncertain` until
  that check resolves it. Preflight versions, authentication, coordinator
  connection, and typed-action permissions in `agentic-workstation`/HorneroOS.
- [ ] Test recovery and cancellation after coordinator, host, provider, and
  publisher failures; prove duplicate-event and expired-lease behavior. Stage
  concurrency at 8, 12, 16, then 24 active workers, preserving capacity for
  independent verification and operator decisions. A 24-worker claim requires
  a real run with live processes and valid leases, not a simulation. Run a
  documented 32-task failure simulation first.
  Certify OpenCode, Muse, Copilot, and Pi through the same provider/runner
  matrix before adding them to rotation. Display backlog, workers with live
  leases, and active provider turns separately. Unknown provider cost remains
  unknown and still obeys explicit turn/time limits.
- [ ] Evaluate 12–20 frozen historical cases with held-out final cases and the
  same model/version/budget as the manual baseline. Measure accepted goals per
  operator-attention hour, available cost per goal, p95 wait, reopens, and
  duplicate effects. The pilot target is a 25% reduction in attention time;
  review failures before raising concurrency.
- [ ] Enable merge only after draft delivery, human-reviewed merge, and a
  documentation-only canary pass in order. Verify the exact eligible SHA,
  required checks and merge-queue candidate where used, then verify `main`
  after merge. Keep immediate pause/drain, retained receipts, and per-repository
  rollback available. Releases, credentials, CI permissions, and destructive
  effects remain human-approved.
- [ ] Apply the operational lessons of the
  [pstack overnight guide](https://github.com/lgs/lauren-plugins/blob/main/pstack/docs/guide/07-overnight.md)
  without copying its implementation: earn autonomy through watched runs,
  checkable finish conditions, isolated worktrees, stop conditions, independent
  reviewers on a different model family, and a decision log with evidence.
  Each iteration makes one justified change, verifies the real artifact, and
  records one decision; pause/resume keeps a checkpoint and resume note. A
  standing coordinator delegates and verifies but does not write task code.
- [ ] Keep `docs/consolidation/RESOLUTION_LEDGER.md` synchronized with exact
  repository owners, issue/PR heads, releases, and acceptance evidence. Do not
  close #550, #673, or #689 or claim the 24-worker objective complete until the
  corresponding real acceptance evidence is attached and reviewed.
