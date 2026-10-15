export type HelpItem = {
  command: string
  description: string
}

export const helpItems: HelpItem[] = [
  { command: "/help, /?", description: "Show this guide." },
  { command: "home · j/k · Home/End · PgUp/PgDn · Enter · n", description: "Move the session list, jump to edges or page through it, open the selected session, or start one. A long list keeps the selection on screen and states Selected N of M in plain text." },
  { command: "/connect", description: "Authenticate: paste an API key, save it on this machine, and pick a model. Enter keeps a saved key; !clear removes it. Environment variables stay optional." },
  { command: "s · /models", description: "Full provider settings: authenticate, discover models, and adjust endpoint or output budget (Ctrl+U / Ctrl+O)." },
  { command: "/skills · /skill on|off <source>/<skill>", description: "List discovered Agent Skills (optional text filter; all tokens must match; header shows match counts), or enable and disable them for persistent prompt injection. Covers plugins and standalone SKILL.md. The model can also load a skill body on demand without enablement." },
  { command: "/plugins · /plugin add · /plugin remove", description: "List operator-managed plugin directory links (optional /plugins <text> filter), or link/unlink an absolute local Agent Plugin package. PLUGIN_DATA stays keyed by plugin name. Only symlinks are removed." },
  { command: "/mcp · /mcp calls", description: "List configured and Agent Plugin MCP servers (optional /mcp <text> filter for name, transport, or trust state), or calls waiting for review." },
  { command: "/mcp add", description: "Add a configured MCP server: /mcp add [user|project] stdio <name> <command> [args…] or /mcp add [user|project] http <name> <url>. Project scope writes <workspace>/.veasel/mcp-servers.json. No install scripts are executed." },
  { command: "/mcp remove · /mcp enable · /mcp disable", description: "Remove or toggle a configured MCP server (optional user|project scope) without changing Agent Plugin packages." },
  { command: "/mcp call show|approve|reject <id>", description: "Inspect arguments, then approve once or reject. The decision stays above the arguments, including when the argument list is long." },
  { command: "/mcp trust|untrust <plugin>/<server>", description: "Change a server's trust state. Configured servers use configured/<name>." },
  { command: "/patches · /patch show|approve|reject <id>", description: "Review and decide file edits. The summary states lines added and removed; a long diff keeps the first screen. After /patch show, an empty composer accepts a approve, x reject, and ]/[ or n/p to move between pending reviews. Ctrl+R opens the first pending list." },
  { command: "/commands · /command show|approve|reject <id>", description: "Review and decide shell commands. The sandbox warning stays above the command, including when the command is long. Pending shell and MCP counts share the same status cue, Ctrl+R shortcut, and a/x/]/[ hotkeys while the composer is empty." },
  { command: "/history older", description: "Load earlier messages in this session." },
  { command: "/usage", description: "Show provider-reported token totals for this session. Cost stays unavailable without a price schedule." },
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
