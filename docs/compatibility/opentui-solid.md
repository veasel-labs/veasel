# OpenTUI Solid migration pins

**Purpose:** Record upstream pins and license before adapting Solid/OpenTUI
patterns into Veasel's terminal client. This is not a claim of OpenCode UI
compatibility and does not authorize copying branding or product chrome.

## Upstream pins (study + package)

| Upstream | Pin | License | Role |
|----------|-----|---------|------|
| OpenCode | [`e25b7abf8955a4fa1b02b935964cb47db4c3a02a`](https://github.com/anomalyco/opencode/tree/e25b7abf8955a4fa1b02b935964cb47db4c3a02a) | MIT | Engineering patterns for `packages/tui/` (`render` / `testRender`, `jsxImportSource`, bunfig preload, standalone bun-plugin). Catalog pins `@opentui/core` + `@opentui/solid` **0.5.17** and `solid-js` **1.9.15**. |
| OpenTUI | [`212eb27da4adf5b907031ad153fc6a5b9f713fbf`](https://github.com/anomalyco/opentui/tree/212eb27da4adf5b907031ad153fc6a5b9f713fbf) (`v0.6.6` tag for study) | MIT | Solid package README and APIs (`render`, `testRender`, `@opentui/solid/preload`, `@opentui/solid/bun-plugin`). Veasel **runtime** packages stay on published **0.5.17** to match OpenCode's catalog until a deliberate upgrade. |

## Veasel package pins (P0)

- `@opentui/core` **0.5.17** (already in tree)
- `@opentui/solid` **0.5.17**
- `solid-js` **1.9.17** (1.9.x line matching OpenCode's catalog intent; bumped from
  1.9.15 so transitive `seroval` lands on the CVE-fixed ≥1.6.2 line. Peer of
  `@opentui/solid` remains `1.9.12`.)

## Adapted patterns (Veasel-owned code)

- `tui/bunfig.toml` preload `@opentui/solid/preload` (dev + test)
- `tui/tsconfig.json` `jsx: preserve` + `jsxImportSource: @opentui/solid`
- Solid entry under `tui/src/solid/` with Veasel mint chrome (no OpenCode branding)
- Standalone build optional `--solid` path using `createSolidTransformPlugin()` from `@opentui/solid/bun-plugin`
- Component tests via `testRender` + `captureCharFrame` at 80×30
- Session transcript (`solid/transcript.tsx`) mounts OpenTUI `scrollbox` with
  `stickyScroll` / `stickyStart="bottom"` for streaming follow-tail; tone-tagged
  lines come from existing `transcriptSegments` + `transcriptSegmentLines` (no
  forked role rules). `transcriptMessagesFromChatTurns` bridges `chat-history`
  turns. Mint tone colors mirror `main.ts` `buildTranscriptStyles`.
  MarkdownRenderable follow-mode (`markdown-view.ts`) remains on the imperative
  path until a later dual-surface slice.
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
- Reviews / approvals (`solid/reviews.ts` + `solid/component/review-panel.tsx`):
  large dialog overlay for pending file edits, shell commands, and MCP calls.
  Reuses `reviewHotkey` / `formatReviewDiff` / `formatShellReview` /
  `formatMcpReview` / `diff-view` helpers. Default body is tone-tagged text
  (DiffRenderable segment patterns via `noticeSegments`); **v** toggles OpenTUI
  Solid `<diff view="split">` (available on pinned **0.5.17** catalogue).
  **Ctrl+R** opens the panel (same chord as legacy pending jump); a/x/A/X/
  Space/]/[/n/p/{/} match `active-review` docs. Palette
  `veasel.reviews.open`. Demo fixture queue for `start:solid` / tests. Engineering
  reference only: OpenCode `permission.tsx` / diff-viewer — Veasel mint chrome,
  not OpenCode branding. HTTP approve/reject wiring remains on the legacy path.
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
  (engineering only). HTTP list/update still on the legacy path; Solid uses
  fixture sessions until session wiring lands. Palette `veasel.session.list`.
- Dialog primitives (`solid/ui/dialog-select.tsx`, `dialog-alert.tsx`,
  `dialog-confirm.tsx`, `dialog-prompt.tsx`, `dialog-help.tsx` + `DialogLayout`):
  fuzzy/category select, modal alert/confirm/prompt, help overlay. Pattern from
  OpenCode `ui/dialog-*.tsx` (engineering only). Palette help opens
  `DialogHelp`; `veasel.confirm.demo` smokes confirm.
- Product dialogs on DialogSelect / layout: theme list (`dialog-theme-list.tsx`,
  live preview on move), model favorites/recents (`model-dialog.tsx`), stash
  (`stash-dialog.tsx`), error details (`error-details-dialog.tsx`), shell
  output (`shell-output-dialog.tsx`). Fixture catalogs until HTTP wiring.
  Palette: `veasel.theme.list`, `veasel.model.picker`, `veasel.stash.list`,
  `veasel.error.details`, `veasel.shell.output`.
- MCP servers + skills (`mcp-dialog.tsx`, `skill-dialog.tsx`): DialogSelect
  inventories with status categories / descriptions; failed MCP rows open
  error-details. Palette `veasel.mcp.list`, `veasel.skills.list`. Fixture demos
  until HTTP `/mcp*` and skills discovery wiring lands on Solid.
- Agent / variant / workspaces (`agent-dialog.tsx`, `variant-dialog.tsx`,
  `workspaces-dialog.tsx`): DialogSelect pickers with demo catalogs; workspaces
  can prompt for a new worktree name. Palette `veasel.agent.picker`,
  `veasel.variant.picker`, `veasel.workspaces.list`.

## Startup note (light)

Solid entry (`bun run start:solid`) loads `@opentui/solid` + the transcript
scrollbox, dialog/palette, review-panel, and toast modules in addition to core.
A local import smoke (~2026-10-16) showed `solid/transcript.tsx` ~280 ms vs a
thin legacy helper ~160 ms cold; keep measuring with `benchmarks/tui-startup*`
before default cutover. No V backend changes in the transcript, palette,
reviews, or toast slices.

Do not copy OpenCode logos, splash art, or product strings. Prefer Veasel mint
tokens and HTTP-API client boundaries.
