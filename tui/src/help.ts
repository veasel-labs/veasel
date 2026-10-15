export type HelpItem = {
  command: string
  description: string
}

export const helpItems: HelpItem[] = [
  { command: "/help, /? · session ?", description: "Show this guide. In a session with an empty composer, press ? (no slash) for the same overlay." },
  { command: "home · j/k · g/G · 1-9 · type · Home/End · PgUp/PgDn · Enter · n", description: "Move the session list, press g/G for first/last when no filter is active, press 1-9 to jump to the Nth visible session (the sidebar labels those slots), type to filter by title or directory (Ctrl+L clears; labels hide while filtering; the status line says filter and which match is focused), jump to edges or page through it, open the selected session, or start one. A long list keeps the selection on screen and states Selected N of M in plain text." },
  { command: "/connect", description: "Quick connect: pick a provider (Tab cycles All/Configured/Local/…), j/k move, g/G for first/last, or press 1-9 to jump when the filter is empty, type to filter, Home/End and PgUp/PgDn jump the list, Ctrl+L clears the filter, and the status line states selected N of M in plain text. Paste an API key if needed, then choose a model. Enter keeps a saved key; !clear removes it. Environment variables stay optional. Switching providers replaces the active profile for new turns." },
  { command: "s · /models", description: "Full provider settings cockpit: authenticate, discover models (same j/k · g/G · 1-9 · Home/End · Pg · Ctrl+L filter keys), override endpoint (Ctrl+U), and set output budget (Ctrl+O). Same provider list and filters as /connect." },
  { command: "/skills · /skill on|off|run <source>/<skill> · $source/skill", description: "List discovered Agent Skills (optional text filter; all tokens must match; header shows match counts), enable/disable for persistent injection, or one-shot invoke for the next turn only. Covers plugins and standalone SKILL.md. Project skills need /skill on before model load; user skills can still load on demand." },
  { command: "/plugins · /plugin add · /plugin remove", description: "List operator-managed plugin directory links (optional /plugins <text> filter), or link/unlink an absolute local Agent Plugin package. PLUGIN_DATA stays keyed by plugin name. Only symlinks are removed." },
  { command: "/mcp · /mcp calls", description: "List configured and Agent Plugin MCP servers (optional /mcp <text> filter for name, transport, or trust state), or calls waiting for review." },
  { command: "/mcp add", description: "Add a configured MCP server: /mcp add [user|project] stdio <name> <command> [args…] or /mcp add [user|project] http <name> <url>. Project scope writes <workspace>/.veasel/mcp-servers.json. No install scripts are executed." },
  { command: "/mcp remove · /mcp enable · /mcp disable", description: "Remove or toggle a configured MCP server (optional user|project scope) without changing Agent Plugin packages." },
  { command: "/mcp credentials · /mcp credential set|remove", description: "List named Streamable HTTP credentials (header names only; secret values never shown). Set with /mcp credential set <name> <Header>=<value>… (values cannot contain spaces). Remove with /mcp credential remove <name>." },
  { command: "/mcp oauth authorize|complete|refresh", description: "Start a PKCE OAuth flow into a named credential (/mcp oauth authorize <credential> <authorization_endpoint> <token_endpoint> <client_id> <redirect_uri> [scope]); the TUI copies the browser authorize URL (OSC 52) and points at headless --listen for loopback ownership. Finish with /mcp oauth complete <credential> <callback_url> or <state> <code>. Refresh with /mcp oauth refresh <credential> when a refresh token was stored. Token values are never shown." },
  { command: "/mcp call show|approve|reject <id>", description: "Inspect arguments, then approve once or reject. The decision stays above the arguments, including when the argument list is long." },
  { command: "/mcp trust|untrust <plugin>/<server>", description: "Change a server's trust state. Configured servers use configured/<name>." },
  { command: "/patches · /patch show|approve|reject <id>", description: "Review and decide file edits (optional /patches <text> filter). The summary states lines added and removed; a long diff keeps the first screen. Short adjacent -/+ pairs render side-by-side (`-left │ +right`) with word-level emphasis when they fit the terminal width; wider pairs stay stacked. Press v to toggle OpenTUI DiffRenderable split view (synced scroll, themed +/- signs, separate gutter/content washes, selection colors, filetype SyntaxStyle highlighting) without leaving the review. After /patch show, an empty composer accepts a approve, Space to multi-select, a/x on the selection (or the current item), Shift+A / Shift+X approve or reject all pending of that kind, {/} between hunks (including scrolling the split panel), and ]/[ or n/p to move between pending reviews. Ctrl+R opens the first pending list." },
  { command: "/commands · /command show|approve|reject <id>", description: "Review and decide shell commands (optional /commands <text> filter). The sandbox warning stays above the command, including when the command is long. Pending shell and MCP counts share the same status cue, Ctrl+R shortcut, and Space/a/A/x/X/]/[ hotkeys while the composer is empty." },
  { command: "session · ↑/↓ history · PgUp/PgDn · Home/End · ? · Enter · Shift+Enter · Ctrl+J · @ · $ · Ctrl+A/E · Ctrl+←/→ · Alt+B/F · Ctrl+U · Ctrl+_ · Ctrl+W · Alt+Backspace · Alt+D · Alt+C · Alt+U/L · Ctrl+K · Ctrl+T · Alt+Y · Ctrl+Y · Esc", description: "With an empty composer, ↑/↓ recalls earlier submitted lines (slash commands and prompts); ? opens the quick help overlay (same as /help). Page the transcript with PgUp/PgDn (Home/End when empty). Stick to the latest reply with End or PgDn (End after scroll restores follow and the streaming busy cue). While scrolled above a live stream, the cue reads streaming below · End follows and the status line says scrolled · End follows; Esc still cancels the turn (and never leaves the session) while scrolled. While stuck to a live reply, busy status grows from thinking… to streaming · N chars (measured characters, not tokens), and the live assistant body renders through OpenTUI MarkdownRenderable streaming (themed markup + fenced code); scrolling the transcript falls back to TextChunk markdown tones so Home/PgUp still page earlier deltas. The always-visible footer swaps by mode: default discovery, @-path / $-skill / slash completion keys, pending-review hotkeys (a/x · A/X · Space · ]/[ · {/} · v for patches), or Esc cancel · End follow while streaming — so the row stays under ~72 columns without stuffing every hotkey at once. Enter submits the draft; Shift+Enter, Ctrl+J, Ctrl+Enter, or Alt+Enter inserts a newline for multiline prompts. Type @ to autocomplete workspace paths under the session directory (Tab/Enter inserts; Esc dismisses). Type $ to autocomplete discovered Skills as a one-shot `$source/skill` token (same Tab/Enter/Esc keys; typo-tolerant ranking). Ctrl+A / Ctrl+E jump to the start or end of the draft; Ctrl+← / Ctrl+→ or Alt+B / Alt+F move by words (readline). Ctrl+U clears the composer draft (and exits history recall). Ctrl+_ (or Ctrl+-) undoes the last composer edit, including a Ctrl+U clear. Ctrl+W or Alt+Backspace deletes the word before the cursor; Alt+D deletes from the cursor through the next word; Alt+C capitalizes the next word; Alt+U uppercases it; Alt+L lowercases it; Ctrl+K deletes from the cursor to the end; Ctrl+T swaps characters around the cursor (readline). Alt+Y yanks the latest kill (from Ctrl+U/W/K or Alt+D/Backspace) back into the draft. Ctrl+Y copies the latest assistant reply to the clipboard (OSC 52) — not kill-ring yank. Esc dismisses a notice or review overlay first; a second Esc returns to the session list. Esc also cancels an in-flight turn — it never clears the composer. The status line uses ● ok (or ● connected / selected when those roles apply), ◌ busy (thinking/reconnect/streaming), ▲ attention (or ▲ cancelled after Esc cancel), and ✖ error so it stays readable without color. Idle shows the active provider/model when configured. Set VEASEL_TUI_REDUCED_MOTION=1 (or GTK gtk-enable-animations=false) to keep the busy glyph and streaming cursor static instead of blinking." },
  { command: "/history older", description: "Load earlier messages in this session." },
  { command: "/usage", description: "Show provider-reported token totals for this session (totals, average per reported turn, optional cache counters). Never estimates tokens or invents savings. Cost is USD from the pinned schedule when every reported turn matches; otherwise unavailable." },
  { command: "/map", description: "Show the untrusted extractive workspace repository map (ranked paths and declarations) with measured UTF-8 bytes and a bytes/4 bound. Add text after /map to reweight ranking. Capability workspace.repository_map." },
  { command: "/theme", description: "List TUI color themes (builtins plus any custom JSON), or pass mint, ember, slate, mono, aurora, day (light), contrast (high-contrast light), or a custom id to switch. /theme lists ~/.config/veasel/themes and <workspace>/.veasel/themes, marks missing/empty dirs, and surfaces clear errors for bad JSON. /theme reload rescans those directories without restarting; /theme open creates and shows the paths so you can drop JSON. The choice is stored for the next launch. Transcript roles stay spoken in plain text (you / assistant / system / tool) and each role has its own theme colors (including dedicated system/tool tokens custom JSON may override)." },
]

export function unknownSlashCommand(input: string): string | undefined {
  const command = input.trim()
  return command.startsWith("/") ? command : undefined
}

export function isModelSettingsCommand(input: string): boolean {
  return input.trim() === "/models"
}

export function isConnectCommand(input: string): boolean {
  return input.trim() === "/connect"
}

export function renderHelp(compact = false) {
  if (compact) {
    return [
      "VEASEL CODE / QUICK HELP",
      "/help advanced  Show command syntax",
      "/skills · /plugins · /mcp · /patches · /commands",
      "/mcp credentials · /mcp oauth  Named HTTP auth (no secrets shown)",
      "/history older  Load earlier messages",
      "/connect · /models · /theme · /map  Auth, model, map",
      "Files go to your provider. Review diffs and MCP calls.",
      "Approved shell: Bubblewrap, Seatbelt, or Windows AppContainer when available.",
    ].join("\n")
  }

  const commands = helpItems
    .map(({ command, description }) => `${command}  ${description}`)
    .join("\n")
  return [
    "VEASEL CODE / QUICK HELP",
    "Files go to your provider. Review diffs and MCP arguments; approved shell uses Bubblewrap on Linux, Seatbelt on macOS, or AppContainer on Windows when available, otherwise runs without an OS sandbox.",
    commands,
  ].join("\n")
}
