export type HelpItem = {
  command: string
  description: string
}

export const helpItems: HelpItem[] = [
  { command: "/help, /?", description: "Show this guide." },
  { command: "home · j/k · Enter · n", description: "Move the session list, open the selected session, or start one. A long list keeps the selection on screen and shows its position." },
  { command: "s · /models", description: "Choose a provider, authenticate, and pick a model. Known endpoints and the output budget are filled in; Ctrl+U changes an endpoint and Ctrl+O changes the budget." },
  { command: "/skills · /skill on|off <plugin>/<skill>", description: "List or manage session Skills." },
  { command: "/mcp · /mcp calls", description: "List servers or calls waiting for review." },
  { command: "/mcp call show|approve|reject <id>", description: "Inspect arguments, then approve once or reject." },
  { command: "/mcp trust|untrust <plugin>/<server>", description: "Change a server's trust state." },
  { command: "/patches · /patch show|approve|reject <id>", description: "Review and decide file edits. The summary states lines added and removed; a long diff keeps the first screen." },
  { command: "/commands · /command show|approve|reject <id>", description: "Review and decide shell commands. The sandbox warning stays above the command, including when the command is long." },
  { command: "/history older", description: "Load earlier messages in this session." },
]

export function unknownSlashCommand(input: string): string | undefined {
  const command = input.trim()
  return command.startsWith("/") ? command : undefined
}

export function isModelSettingsCommand(input: string): boolean {
  return input.trim() === "/models"
}

export function renderHelp(compact = false) {
  if (compact) {
    return [
      "VEASEL CODE / QUICK HELP",
      "/help advanced  Show command syntax",
      "/skills · /mcp · /patches · /commands",
      "/history older  Load earlier messages",
      "s · /models  Configure provider and model",
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
