export type HelpItem = {
  command: string
  description: string
}

export const helpItems: HelpItem[] = [
  { command: "/help, /?", description: "Show this guide." },
  { command: "home · j/k · Home/End · PgUp/PgDn · Enter · n", description: "Move the session list, jump to edges or page through it, open the selected session, or start one. A long list keeps the selection on screen and states Selected N of M in plain text." },
  { command: "/connect", description: "Quick connect: pick a provider (Tab cycles All/Configured/Local/…), paste an API key if needed, then choose a model. Enter keeps a saved key; !clear removes it. Environment variables stay optional. Switching providers replaces the active profile for new turns." },
  { command: "s · /models", description: "Full provider settings cockpit: authenticate, discover models, override endpoint (Ctrl+U), and set output budget (Ctrl+O). Same provider list and filters as /connect." },
  { command: "/skills · /skill on|off <source>/<skill>", description: "List discovered Agent Skills (optional text filter; all tokens must match; header shows match counts), or enable and disable them for persistent prompt injection. Covers plugins and standalone SKILL.md. The model can also load a skill body on demand without enablement." },
  { command: "/plugins · /plugin add · /plugin remove", description: "List operator-managed plugin directory links (optional /plugins <text> filter), or link/unlink an absolute local Agent Plugin package. PLUGIN_DATA stays keyed by plugin name. Only symlinks are removed." },
  { command: "/mcp · /mcp calls", description: "List configured and Agent Plugin MCP servers (optional /mcp <text> filter for name, transport, or trust state), or calls waiting for review." },
  { command: "/mcp add", description: "Add a configured MCP server: /mcp add [user|project] stdio <name> <command> [args…] or /mcp add [user|project] http <name> <url>. Project scope writes <workspace>/.veasel/mcp-servers.json. No install scripts are executed." },
  { command: "/mcp remove · /mcp enable · /mcp disable", description: "Remove or toggle a configured MCP server (optional user|project scope) without changing Agent Plugin packages." },
  { command: "/mcp credentials · /mcp credential set|remove", description: "List named Streamable HTTP credentials (header names only; secret values never shown). Set with /mcp credential set <name> <Header>=<value>… (values cannot contain spaces). Remove with /mcp credential remove <name>." },
  { command: "/mcp oauth authorize|complete", description: "Start a PKCE OAuth flow into a named credential (/mcp oauth authorize <credential> <authorization_endpoint> <token_endpoint> <client_id> <redirect_uri> [scope]), then finish with /mcp oauth complete <credential> <callback_url> or <state> <code>. The TUI never shows token values; use headless --listen when you want Veasel to own the loopback listener." },
  { command: "/mcp call show|approve|reject <id>", description: "Inspect arguments, then approve once or reject. The decision stays above the arguments, including when the argument list is long." },
  { command: "/mcp trust|untrust <plugin>/<server>", description: "Change a server's trust state. Configured servers use configured/<name>." },
  { command: "/patches · /patch show|approve|reject <id>", description: "Review and decide file edits (optional /patches <text> filter). The summary states lines added and removed; a long diff keeps the first screen. After /patch show, an empty composer accepts a approve, Space to multi-select, a/x on the selection (or the current item), Shift+A / Shift+X approve or reject all pending of that kind, {/} between hunks, and ]/[ or n/p to move between pending reviews. Ctrl+R opens the first pending list." },
  { command: "/commands · /command show|approve|reject <id>", description: "Review and decide shell commands (optional /commands <text> filter). The sandbox warning stays above the command, including when the command is long. Pending shell and MCP counts share the same status cue, Ctrl+R shortcut, and Space/a/A/x/X/]/[ hotkeys while the composer is empty." },
  { command: "session · ↑/↓ history · PgUp/PgDn · Home/End · Ctrl+Y · Esc", description: "With an empty composer, ↑/↓ recalls earlier submitted lines (slash commands and prompts). Page the transcript with PgUp/PgDn (Home/End when empty). Stick to the latest reply with End or PgDn. Ctrl+Y copies the latest assistant reply to the clipboard (OSC 52). Esc dismisses a notice or review overlay first; a second Esc returns to the session list. Esc also cancels an in-flight turn. The idle status line shows the active provider/model when configured." },
  { command: "/history older", description: "Load earlier messages in this session." },
  { command: "/usage", description: "Show provider-reported token totals for this session (totals, average per reported turn, optional cache counters). Never estimates tokens or invents savings. Cost stays unavailable without a price schedule." },
  { command: "/map", description: "Show the untrusted extractive workspace repository map (ranked paths and declarations) with measured UTF-8 bytes and a bytes/4 bound. Add text after /map to reweight ranking. Capability workspace.repository_map." },
  { command: "/theme", description: "List TUI color themes, or pass mint, ember, slate, mono, or aurora to switch. The choice is stored for the next launch." },
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
