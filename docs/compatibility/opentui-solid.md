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

## Startup note (light)

Solid entry (`bun run start:solid`) loads `@opentui/solid` + the transcript
scrollbox in addition to core. A local import smoke (~2026-10-16) showed
`solid/transcript.tsx` ~280 ms vs a thin legacy helper ~160 ms cold; keep
measuring with `benchmarks/tui-startup*` before default cutover. No V backend
changes in the transcript slice.

Do not copy OpenCode logos, splash art, or product strings. Prefer Veasel mint
tokens and HTTP-API client boundaries.
