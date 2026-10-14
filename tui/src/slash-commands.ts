export type SlashCommand = {
  name: string
  description: string
  // Present when the command needs arguments; completion then stops after a trailing space.
  usage?: string
}

export const slashCommands: SlashCommand[] = [
  { name: "/help", description: "Show the quick guide" },
  { name: "/help advanced", description: "Show full command syntax" },
  { name: "/models", description: "Configure provider, model, and output budget" },
  { name: "/skills", description: "List Skills for this session" },
  { name: "/skill", description: "Turn a Skill on or off", usage: "/skill on|off <plugin>/<skill>" },
  { name: "/mcp", description: "List MCP servers" },
  { name: "/mcp calls", description: "List MCP calls waiting for review" },
  { name: "/mcp call", description: "Inspect, approve, or reject an MCP call", usage: "/mcp call show|approve|reject <id>" },
  { name: "/mcp trust", description: "Trust an MCP server", usage: "/mcp trust <plugin>/<server>" },
  { name: "/mcp untrust", description: "Stop trusting an MCP server", usage: "/mcp untrust <plugin>/<server>" },
  { name: "/patches", description: "List proposed file edits" },
  { name: "/patch", description: "Show, approve, or reject a file edit", usage: "/patch show|approve|reject <id>" },
  { name: "/commands", description: "List proposed shell commands" },
  { name: "/command", description: "Show, approve, or reject a shell command", usage: "/command show|approve|reject <id>" },
  { name: "/history older", description: "Load earlier messages in this session" },
]

export const maxSlashSuggestions = 6

function normalize(input: string): string {
  return input.toLowerCase().replace(/\s+/g, " ").trimStart()
}

// Returns commands matching a partially typed slash command, best match first.
// Suggestions stop once the user is typing arguments for a command that takes them.
export function slashSuggestions(input: string, commands: SlashCommand[] = slashCommands): SlashCommand[] {
  const query = normalize(input)
  if (!query.startsWith("/")) return []
  if (commands.some((command) => command.usage && query.startsWith(`${command.name} `))) return []
  const prefix = commands.filter((command) => command.name.startsWith(query.trimEnd()))
  const needle = query.slice(1).trim()
  const contains = needle
    ? commands.filter((command) => !prefix.includes(command) && command.name.slice(1).includes(needle))
    : []
  const exact = prefix.filter((command) => command.name === query.trimEnd())
  return [...exact, ...prefix.filter((command) => !exact.includes(command)), ...contains]
}

// Text placed in the composer when a suggestion is accepted.
export function completeSlashCommand(command: SlashCommand): string {
  return command.usage ? `${command.name} ` : command.name
}

// Enter runs a suggestion directly only when it needs no arguments.
export function runsOnAccept(command: SlashCommand): boolean {
  return !command.usage
}

export function moveSuggestion(index: number, delta: number, count: number): number {
  if (count <= 0) return 0
  return (((index + delta) % count) + count) % count
}

// Keeps the selected row visible inside a fixed-height suggestion window.
export function suggestionWindow(selected: number, count: number, size = maxSlashSuggestions): { start: number; end: number } {
  if (count <= size) return { start: 0, end: count }
  const start = Math.min(Math.max(0, selected - size + 1), count - size)
  return { start, end: start + size }
}
