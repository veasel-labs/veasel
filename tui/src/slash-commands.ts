export type SlashCommand = {
  name: string
  description: string
  // Present when the command needs arguments; name completion stops after a trailing space.
  usage?: string
}

export type SlashArgument = {
  value: string
  description: string
}

// A completion list belongs to the session that requested it. Applying it
// after the user switches sessions would offer the previous session's skills,
// servers, edits, and commands.
export function slashContextApplies(requestedSessionId: string, activeSessionId: string | undefined): boolean {
  return activeSessionId === requestedSessionId
}

export type SlashCompletionContext = {
  skills?: SlashArgument[]
  pluginLinks?: SlashArgument[]
  mcpServers?: SlashArgument[]
  mcpCalls?: SlashArgument[]
  patches?: SlashArgument[]
  commands?: SlashArgument[]
}

export type SlashSuggestion = SlashCommand & {
  insert: string
  run: boolean
}

export const slashCommands: SlashCommand[] = [
  { name: "/help", description: "Show the quick guide" },
  { name: "/help advanced", description: "Show full command syntax" },
  { name: "/connect", description: "Paste an API key and pick a model for a provider" },
  { name: "/models", description: "Configure provider, model, and output budget" },
  { name: "/skills", description: "List discovered Skills; add text to filter" },
  { name: "/skill", description: "Turn a Skill on or off", usage: "/skill on|off <source>/<skill>" },
  { name: "/plugins", description: "List linked Agent Plugin packages" },
  { name: "/plugin add", description: "Link an absolute local plugin directory", usage: "/plugin add <absolute-path>" },
  { name: "/plugin remove", description: "Remove a managed plugin link", usage: "/plugin remove <name>" },
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
  { name: "/usage", description: "Show provider-reported token totals for this session" },
  { name: "/map", description: "Show the extractive workspace repository map; add text to hint ranking" },
  { name: "/theme", description: "List or switch TUI color themes", usage: "/theme <id>" },
]

export const maxSlashSuggestions = 6

const decisionChoices = [
  { value: "show", description: "Inspect before deciding" },
  { value: "approve", description: "Allow this one action" },
  { value: "reject", description: "Refuse without running it" },
]

type ChoiceSpec = { kind: "choice"; choices: SlashArgument[] }
type ValueSpec = { kind: "value"; values: (context: SlashCompletionContext) => SlashArgument[]; empty: string }
type ArgSpec = ChoiceSpec | ValueSpec

const themeChoices: SlashArgument[] = [
  { value: "mint", description: "Charcoal panels with mint accents — the Veasel product look" },
  { value: "ember", description: "Warm dark panels with amber focus cues" },
  { value: "slate", description: "Cool blue-gray workspace with steel accents" },
  { value: "mono", description: "High-contrast black and white with green only for status" },
  { value: "aurora", description: "Deep teal field with cyan highlights" },
]

const argumentSpecs: Record<string, ArgSpec[]> = {
  "/theme": [
    { kind: "choice", choices: themeChoices },
  ],
  "/skill": [
    { kind: "choice", choices: [{ value: "on", description: "Enable a Skill for this session" }, { value: "off", description: "Disable a Skill" }] },
    { kind: "value", values: (context) => context.skills ?? [], empty: "No Skills are available yet" },
  ],
  "/plugin remove": [
    { kind: "value", values: (context) => context.pluginLinks ?? [], empty: "No managed plugin links yet" },
  ],
  "/mcp call": [
    { kind: "choice", choices: decisionChoices },
    { kind: "value", values: (context) => context.mcpCalls ?? [], empty: "No MCP calls are waiting" },
  ],
  "/mcp trust": [
    { kind: "value", values: (context) => context.mcpServers ?? [], empty: "No MCP servers are available" },
  ],
  "/mcp untrust": [
    { kind: "value", values: (context) => context.mcpServers ?? [], empty: "No MCP servers are available" },
  ],
  "/patch": [
    { kind: "choice", choices: decisionChoices },
    { kind: "value", values: (context) => context.patches ?? [], empty: "No file edits are waiting" },
  ],
  "/command": [
    { kind: "choice", choices: decisionChoices },
    { kind: "value", values: (context) => context.commands ?? [], empty: "No shell commands are waiting" },
  ],
}

function normalize(input: string): string {
  return input.toLowerCase().replace(/\s+/g, " ").trimStart()
}

function asSuggestion(command: SlashCommand): SlashSuggestion {
  const insert = command.usage ? `${command.name} ` : command.name
  return { ...command, insert, run: !command.usage }
}

function activeArgumentCommand(query: string): SlashCommand | undefined {
  const matches = slashCommands.filter((command) =>
    command.usage && argumentSpecs[command.name] && (query === command.name || query.startsWith(`${command.name} `))
  )
  matches.sort((left, right) => right.name.length - left.name.length)
  return matches[0]
}

function filterArguments(values: SlashArgument[], typed: string): SlashArgument[] {
  const needle = typed.toLowerCase()
  if (!needle) return values
  const prefix = values.filter((value) => value.value.toLowerCase().startsWith(needle))
  const contains = values.filter((value) => !prefix.includes(value) && value.value.toLowerCase().includes(needle))
  return [...prefix, ...contains]
}

function argumentSuggestions(command: SlashCommand, rest: string, context: SlashCompletionContext): SlashSuggestion[] {
  const specs = argumentSpecs[command.name] ?? []
  const typed = rest.replace(/\s+/g, " ")
  const words = typed.trimEnd() === "" ? [] : typed.trimEnd().split(" ")
  const finished = typed.endsWith(" ") ? words : words.slice(0, -1)
  const spec = specs[finished.length]
  if (!spec) return []
  const partial = typed.endsWith(" ") ? "" : (words.at(-1) ?? "")
  const stem = [command.name, ...finished].join(" ")
  if (spec.kind === "choice") {
    return filterArguments(spec.choices, partial).map((choice) => {
      const more = specs.length > finished.length + 1
      return {
        name: `${stem} ${choice.value}`.replace(/\s+/g, " "),
        description: choice.description,
        insert: more ? `${stem} ${choice.value} ` : `${stem} ${choice.value}`,
        run: !more,
      }
    })
  }
  const matches = filterArguments(spec.values(context), partial)
  if (matches.length === 0) {
    if (partial) return []
    return [{
      name: stem,
      description: spec.empty,
      insert: `${stem} `,
      run: false,
    }]
  }
  return matches.map((value) => ({
    name: `${stem} ${value.value}`.replace(/\s+/g, " "),
    description: value.description,
    insert: `${stem} ${value.value}`,
    run: true,
  }))
}

// Returns commands or argument values matching a partially typed slash command.
export function slashSuggestions(
  input: string,
  commands: SlashCommand[] = slashCommands,
  context: SlashCompletionContext = {},
): SlashSuggestion[] {
  const query = normalize(input)
  if (!query.startsWith("/")) return []
  const argumentCommand = commands === slashCommands ? activeArgumentCommand(query) : undefined
  if (argumentCommand && query.startsWith(`${argumentCommand.name} `)) {
    return argumentSuggestions(argumentCommand, query.slice(argumentCommand.name.length + 1), context)
  }
  const prefix = commands.filter((command) => command.name.startsWith(query.trimEnd()))
  const needle = query.slice(1).trim()
  const contains = needle
    ? commands.filter((command) => !prefix.includes(command) && command.name.slice(1).includes(needle))
    : []
  const exact = prefix.filter((command) => command.name === query.trimEnd())
  return [...exact, ...prefix.filter((command) => !exact.includes(command)), ...contains].map(asSuggestion)
}

export function completeSlashCommand(command: { name: string; insert?: string; usage?: string }): string {
  if (command.insert) return command.insert
  return command.usage ? `${command.name} ` : command.name
}

export function runsOnAccept(command: { run?: boolean; usage?: string }): boolean {
  if (command.run !== undefined) return command.run
  return !command.usage
}

export function moveSuggestion(index: number, delta: number, count: number): number {
  if (count <= 0) return 0
  return (((index + delta) % count) + count) % count
}

export function suggestionWindow(selected: number, count: number, size = maxSlashSuggestions): { start: number; end: number } {
  if (count <= size) return { start: 0, end: count }
  const start = Math.min(Math.max(0, selected - size + 1), count - size)
  return { start, end: start + size }
}

export function slashContextNeeded(input: string): boolean {
  const query = normalize(input)
  const command = activeArgumentCommand(query)
  return Boolean(command && query.startsWith(`${command.name} `))
}
