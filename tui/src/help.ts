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

export function renderHelp(compact = false) {
  if (compact) {
    return [
      "VEASEL CODE / QUICK HELP",
      "/help advanced  Show command syntax",
      "/skills · /mcp · /patches · /commands",
      "/history older  Load earlier messages",
      "Files go to your provider. Review diffs and MCP calls.",
      "Approved shell runs as you without a sandbox.",
    ].join("\n")
  }

  const commands = helpItems
    .map(({ command, description }) => `${command}  ${description}`)
    .join("\n")
  return [
    "VEASEL CODE / QUICK HELP",
    "Files go to your provider. Review diffs and MCP arguments; approved shell runs as you without a sandbox.",
    commands,
  ].join("\n")
}
