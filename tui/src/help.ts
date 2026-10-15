export type HelpItem = {
  command: string
  description: string
}

export const helpItems: HelpItem[] = [
  { command: "/help, /?", description: "Show this guide." },
  { command: "home · j/k · Enter · n", description: "Move the session list, open the selected session, or start one. A long list keeps the selection on screen and shows its position." },
  { command: "/connect", description: "Paste an API key, save it on this machine, and pick a model. Enter keeps a saved key; !clear removes it. Environment variables stay optional." },
  { command: "s · /models", description: "Full provider settings: authenticate, discover models, and adjust endpoint or output budget (Ctrl+U / Ctrl+O)." },
  { command: "/skills · /skill on|off <source>/<skill>", description: "List discovered Agent Skills (optional text filter), or enable and disable them for persistent prompt injection. Covers plugins and standalone SKILL.md. The model can also load a skill body on demand without enablement." },
  { command: "/plugins · /plugin add · /plugin remove", description: "List operator-managed plugin directory links, or link/unlink an absolute local Agent Plugin package. PLUGIN_DATA stays keyed by plugin name. Only symlinks are removed." },
  { command: "/mcp · /mcp calls", description: "List servers or calls waiting for review." },
  { command: "/mcp call show|approve|reject <id>", description: "Inspect arguments, then approve once or reject. The decision stays above the arguments, including when the argument list is long." },
  { command: "/mcp trust|untrust <plugin>/<server>", description: "Change a server's trust state." },
  { command: "/patches · /patch show|approve|reject <id>", description: "Review and decide file edits. The summary states lines added and removed; a long diff keeps the first screen." },
  { command: "/commands · /command show|approve|reject <id>", description: "Review and decide shell commands. The sandbox warning stays above the command, including when the command is long." },
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
