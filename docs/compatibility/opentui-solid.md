# OpenTUI Solid migration pins

**Purpose:** Record upstream pins and license before adapting Solid/OpenTUI
patterns into Veasel's terminal client. This is not a claim of OpenCode UI
compatibility and does not authorize copying branding or product chrome.

## Upstream pins (study + package)

| Upstream | Pin | License | Role |
|----------|-----|---------|------|
| OpenCode | [`e25b7abf8955a4fa1b02b935964cb47db4c3a02a`](https://github.com/anomalyco/opencode/tree/e25b7abf8955a4fa1b02b935964cb47db4c3a02a) | MIT | Engineering patterns for `packages/tui/` (`render` / `testRender`, `jsxImportSource`, bunfig preload, standalone bun-plugin). Catalog still pins `@opentui/core` + `@opentui/solid` **0.5.17** and `solid-js` **1.9.15** (study reference only). |
| OpenTUI | [`341d728b40ee2d1b34f1ea1eaaf3ee0ef801ec69`](https://github.com/anomalyco/opentui/tree/341d728b40ee2d1b34f1ea1eaaf3ee0ef801ec69) (`@opentui/core` + `@opentui/solid` **0.6.8**) | MIT | Solid package APIs and the class-owned render-hook implementation. Veasel runtime packages are pinned to published **0.6.8** (see upgrade history below). |

## Veasel package pins (runtime)

- `@opentui/core` **0.6.8**
- `@opentui/solid` **0.6.8**
- `solid-js` **1.9.17** (1.9.x line matching OpenCode's catalog intent; bumped from
  1.9.15 so transitive `seroval` lands on the CVE-fixed ≥1.6.2 line. Peer of
  `@opentui/solid` remains `1.9.12`.)

### Upgrade history from 0.5.17 → 0.6.8 (2026-10-16 to 2026-10-24)

Dependabot [#404](https://github.com/veasel-labs/veasel/pull/404) landed
`@opentui/core` + `@opentui/solid` **0.6.2** on `main`. Compatibility docs had
pinned **0.5.17** until a deliberate upgrade; that upgrade is now accepted:

- Follow-up [#406](https://github.com/veasel-labs/veasel/pull/406) adapted
  `SyntaxStyle.fromStyles` to the OpenTUI 0.6 `NativeResourceOwner` API.
- Local proof on tip (`cd tui && bun install && bun test && bun run typecheck`):
  **340** tests pass, `tsc --noEmit` clean.
- Dependabot [#499](https://github.com/veasel-labs/veasel/pull/499) later upgraded
  both packages from 0.6.2 to **0.6.6**. The merged revision passed the core
  Linux, macOS, Windows, terminal-client, Harbor, and security jobs. Repeat the
  platform checks before accepting another OpenTUI update.
- The 0.6.8 update uses OpenTUI's class-owned hook records. Upstream's
  `Renderable` now captures hook methods at construction and publishes them to
  native once, replacing reflective instance scans and repeated accessor
  installs. The upstream hook matrix tests cover constructor options, class
  methods, reflection refresh, and failed refreshes. Veasel does not subclass
  those hook APIs; its `testRender` journey tests, typecheck, standalone build,
  and PTY smoke passed on this pin (see the PR validation record).

## Adapted patterns (Veasel-owned code)

- `tui/bunfig.toml` preload `@opentui/solid/preload` (dev + test)
- `tui/tsconfig.json` `jsx: preserve` + `jsxImportSource: @opentui/solid`
- **Default entry:** `bun run start` → `src/entry.ts` →
  `src/solid/main.tsx` → `LiveApp`
  (loopback `api-client.ts`, session home, SSE deltas, MODEL SETTINGS).
  The standalone CLI entry handles `--help` and `--version` without loading the
  API client or Solid UI graph; interactive launches import the application.
  Standalone `build:standalone` defaults to Solid; `--classic` builds the
  retired imperative shell at `src/classic-main.ts`.
- Solid UI modules under `tui/src/solid/` with Veasel mint chrome (no OpenCode branding)
- Standalone Solid compile uses `createSolidTransformPlugin()` from `@opentui/solid/bun-plugin`
- Component tests via `testRender` + `captureCharFrame` at 80×30
- Session transcript (`solid/transcript.tsx`) mounts OpenTUI `scrollbox` with
  `stickyScroll` / `stickyStart="bottom"` for streaming follow-tail; tone-tagged
  lines come from existing `transcriptSegments` + `transcriptSegmentLines` (no
  forked role rules). `transcriptMessagesFromChatTurns` bridges `chat-history`
  turns. Mint tone colors mirror classic `buildTranscriptStyles`.
  Assistant bodies and the streaming trail now render through OpenTUI's
  MarkdownRenderable (`markdown-view.ts` syntax styles, top-level blocks,
  concealed markup, shared tree-sitter client for code fences) while spoken
  role labels and status stay in the tone-tagged text path, so roles remain
  readable without color. User, system, and tool text stay plain.
- Durable follow-up queue in `LiveApp`: send while a turn is active to queue
  the next prompt; **Ctrl+Shift+X** cancels the most recent queued follow-up,
  while **Ctrl+X** still cancels only the active operation. Both actions use
  the backend's durable operation cancellation endpoint, so the UI does not
  remove a queued prompt before the server confirms its cancellation. Opening a
  session rehydrates queued, running, and cancelling operations through
  `GET /v1/sessions/{id}/operations`, so pending work remains visible and
  cancellable after a TUI restart; live events received during the fetch win
  over a racing initial snapshot, including operations absent from that snapshot.
  The API preserves submission order when timestamps tie, so the newest queued
  follow-up remains the newest after recovery.
  An uncertain latest turn restores the explicit inspect-before-retry warning.
- Dialog host (`solid/ui/dialog.tsx`): overlay stack with Esc dismiss, restore
  previous focus, mint panel chrome. Command palette
  (`solid/component/command-palette.tsx` + `solid/commands.ts`) opens on
  **Ctrl+P** (Ctrl+K remains composer kill-line). Actions reuse `slashCommands`,
  `renderHelp`, builtin theme cycle, and a session-list stub under `veasel.*`
  ids — engineering pattern from OpenCode dialog/palette modules, not product
  keys or branding.
- Tool/activity grouping (`solid/activity-group.ts` + `solid/transcript.tsx`):
  consecutive `tool` / `tool_result` roles project into collapsible activity
  groups with spoken running/done/error status (reuses `status-a11y` glyphs).
  **Ctrl+G** toggles the latest group; click the header or palette
  `veasel.activity.toggle` does the same. Pattern informed by OpenCode
  `grouping/session.ts` / `group-view.tsx` / `activity-summary.ts` (engineering
  only; Veasel-owned labels and mint chrome).
- Transcript message navigation (`solid/transcript-nav.ts` + `transcript.tsx`):
  **Alt+[** / **Alt+]** jump previous/next user turn; **Alt+End** jumps to the
  last user message. Palette ids `veasel.message.user.previous|next|last`.
  Pattern informed by OpenCode `message-navigation.ts` / `anchors.ts`
  (engineering only; Veasel-owned shortcuts and `veasel.*` command ids).
- Transcript verbosity (`solid/transcript-verbosity.ts`): palette
  `veasel.transcript.verbosity` cycles Quiet (hide tools + thinking) →
  Default (current activity groups) → Everything (force-expand groups).
  Pattern informed by OpenCode `mini/verbosity.ts` (engineering only).
- Thinking collapse (`solid/thinking-blocks.ts` + `transcript.tsx`):
  fenced thinking code blocks start collapsed with a mint preview header;
  **Ctrl+H** / palette `veasel.thinking.toggle` expands the latest.
  Pattern informed by OpenCode reasoning disclosure (engineering only).
- Reviews / approvals (`solid/reviews.ts` + `solid/component/review-panel.tsx`):
  large dialog overlay for pending file edits, shell commands, and MCP calls.
  Reuses `reviewHotkey` / `formatReviewDiff` / `formatShellReview` /
  `formatMcpReview` / `diff-view` helpers. Default body is tone-tagged text
  (DiffRenderable segment patterns via `noticeSegments`); **v** toggles OpenTUI
  Solid `<diff view="split">` (available on pinned **0.6.8** catalogue).
  **Ctrl+R** opens the panel (same chord as legacy pending jump); a/x/A/X/
  Space/]/[/n/p/{/} match `active-review` docs. Palette
  `veasel.reviews.open`. Demo fixture queue for fixture `App` tests. Engineering
  reference only: OpenCode `permission.tsx` / diff-viewer — Veasel mint chrome,
  not OpenCode branding. LiveApp loads pending review summaries and fetches a
  review's detail only when opened; approval is gated on successful detail
  inspection, and approve/reject calls use the versioned session API. Rendered
  tests cover loading, stale navigation, failure/retry, and batch approval
  gating. This does not prove a human read every diff or command.
- Toast host (`solid/ui/toast.tsx`): non-modal top-right mint notices with
  variant borders, optional title/action, queue (`+N more`), hover pause/resume,
  click dismiss/activate. Pattern from OpenCode `ui/toast.tsx` (engineering
  only; Veasel tokens and copy). Palette `veasel.toast.demo`. Does not steal Esc
  from the dialog stack.
- Session list + rename (`solid/component/session-list-dialog.tsx`,
  `session-rename-dialog.tsx`): large dialog reusing `filterSessionList` /
  `moveSessionSelection` / digit jump. Bare **`r`** (filter empty) pushes a
  rename prompt (dialog stack `push`/`pop`); bare **`n`** create stub; Enter
  selects. Ctrl+E/Ctrl+N remain secondary chords (focused filter input may
  swallow Ctrl+E as readline end-of-line).
  Pattern from OpenCode `dialog-session-list.tsx` / `dialog-session-rename.tsx`
  (engineering only). Live `LiveApp` lists/opens sessions over HTTP; fixture
  `App` demos keep palette `veasel.session.list` stubs for tests.
- Dialog primitives (`solid/ui/dialog-select.tsx`, `dialog-alert.tsx`,
  `dialog-confirm.tsx`, `dialog-prompt.tsx`, `dialog-help.tsx` + `DialogLayout`):
  fuzzy/category select, modal alert/confirm/prompt, help overlay. Pattern from
  OpenCode `ui/dialog-*.tsx` (engineering only). Palette help opens
  `DialogHelp`; `veasel.confirm.demo` smokes confirm.
- Product dialogs on DialogSelect / layout: theme list (`dialog-theme-list.tsx`,
  live preview on move), model favorites/recents (`model-dialog.tsx`), stash
  (`stash-dialog.tsx`), error details (`error-details-dialog.tsx`), shell
  output (`shell-output-dialog.tsx`). Theme/model data uses live settings and
  provider catalogs; composer draft stash is local state. Some secondary dialogs
  remain fixture-driven and need an explicit per-journey backend audit.
  Palette: `veasel.theme.list`, `veasel.model.picker`, `veasel.stash.list`,
  `veasel.error.details`, `veasel.shell.output`.
- MCP servers + skills (`mcp-dialog.tsx`, `skill-dialog.tsx`): DialogSelect
  inventories with status categories / descriptions; failed MCP rows open
  error-details. Palette `veasel.mcp.list`, `veasel.skills.list`. Fixture demos
  remain for isolated component tests; LiveApp loads MCP and plugin/Skill
  catalogs over the loopback API and distinguishes available servers from
  session-trusted servers. `/mcp trust|untrust <plugin>/<server>` updates trust
  through the session API; trust only permits connection on a future turn and
  each MCP tool call still requires review. Bare `/mcp add` opens guided stdio
  or Streamable HTTP setup without launching the server; inline configuration
  uses the same loopback API. `/mcp` server selection exposes session-trust and
  configured-server actions; enable/disable toggle saved servers and removal
  requires confirmation. Headless `veasel mcp` commands remain available.
  Session Skill enable/disable/invoke slash actions use the session Skill
  endpoints (covered by `live-skill-commands.test.tsx`); MCP trust flows are
  covered by `live-mcp-trust-commands.test.tsx`.
- Composer autocomplete (`solid/composer-autocomplete.ts` + `SolidComposer`):
  `/` slash, `@` workspace paths, `$` skills using the same pure matchers as
  the imperative shell (`slash-commands`, `path-autocomplete`,
  `skill-autocomplete`). Mint popup above Compose; Tab/↑↓/Enter/Esc. Skills
  catalog and workspace path listing are injectable props on fixture `App`;
  LiveApp loads Skills through the plugin API and workspace paths from the
  session project.
- Home pane resize (`solid/ui/pane-layout.ts`, `pane-resize.ts`,
  `pane-resize-handle.tsx` + `LiveHome`): drag grip + Alt+←/→ + palette widen/
  narrow/reset; preferred width persisted under XDG state. Drag/double-click
  controller pattern adapted from OpenCode `ui/pane-resize.ts` /
  `pane-resize-handle.tsx` at [`eeec76bb620f9bee8cab89c5a3a88e315539645b`](https://github.com/anomalyco/opencode/tree/eeec76bb620f9bee8cab89c5a3a88e315539645b)
  (MIT; engineering only — Veasel mint grip, clamp constants, and persistence).

## Startup note (light)

Default Solid entry (`bun run start`) loads `@opentui/solid` + `LiveApp`
(session home, HTTP turns, SSE). Keep measuring with `benchmarks/tui-startup*`.
No V backend changes required for the Solid default cutover.

Do not copy OpenCode logos, splash art, or product strings. Prefer Veasel mint
tokens and HTTP-API client boundaries.

### Conversation readability reference

Inspected OpenCode `ed772f5009755b5262805a7ba07e66e1417f140a`, `packages/tui/src/routes/session/index.tsx`, `UserMessage` (MIT). It uses a raised background and a left border to distinguish user contributions. Veasel retains its own spoken role labels, semantic colors, and message projection, using a user surface and open assistant text. No upstream code copied.

The Solid segment renderer now wraps at the actual available terminal width instead of clipping long lines. Rendered tests cover narrow terminals and role surfaces. This is a conversation-readability change, not evidence that the complete design overhaul is finished.
## Reactive theme ownership

Inspected OpenCode's theme context and prompt consumer at
`ed772f5009755b5262805a7ba07e66e1417f140a`, specifically
`packages/tui/src/context/theme.tsx` and
`packages/tui/src/component/prompt/index.tsx`. The relevant principle is a
reactive theme owned by an application provider, consumed by components and
overlays without remounting their state. This implementation uses Veasel's
existing semantic theme schema; no upstream implementation or branding was copied.

Veasel's `SolidThemeProvider` now owns the selected builtin theme. Components,
transcript tones, composer controls, diff views, dialogs, and toasts consume its
reactive colors instead of fixed Mint constants. LiveApp still loads and saves
selection through the existing theme settings. Standalone component fixtures
default to Mint; independent roots do not share mutable theme state.

`theme-reactivity.test.tsx` checks rendered foreground colors across a theme
change, retained composer drafts, open dialogs, and root isolation. These checks
do not establish accessibility contrast compliance, terminal light/dark detection,
or complete visual redesign; those remain separate validation work.
