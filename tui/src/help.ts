export type HelpItem = {
  command: string
  description: string
}

export const helpItems: HelpItem[] = [
  { command: "/help, /?", description: "Show this guide." },
  { command: "/skills · /skill on|off <plugin>/<skill>", description: "List or manage session Skills." },
  { command: "/mcp · /mcp calls", description: "List servers or calls waiting for review." },
  { command: "/mcp call show|approve|reject <id>", description: "Inspect arguments, then approve once or reject." },
  { command: "/mcp trust|untrust <plugin>/<server>", description: "Change a server's trust state." },
  { command: "/patches · /patch show|approve|reject <id>", description: "Review and decide file edits." },
  { command: "/commands · /command show|approve|reject <id>", description: "Review and decide shell commands." },
  { command: "/history older", description: "Load earlier messages in this session." },
]

export function unknownSlashCommand(input: string): string | undefined {
  const command = input.trim()
  return command.startsWith("/") ? command : undefined
}

export function renderHelp() {
  const commands = helpItems
    .map(({ command, description }) => `${command}  ${description}`)
    .join("\n")
  return [
    "VEASEL CODE / QUICK HELP",
    "Describe a coding task in plain language.",
    "",
    commands,
    "",
    "SHORTCUTS",
    "n  new session   r  refresh sessions   ↑/↓ or j/k  navigate   Esc  cancel turn   q  quit",
    "",
    "SAFETY",
    "Review file diffs, exact shell commands, and MCP arguments before approval. Shell runs as your user without a sandbox.",
    "",
    "Use /help whenever you need this guide again.",
  ].join("\n")
}
