export type SlashCategory = "guide" | "setup" | "skills" | "plugins" | "mcp" | "approvals" | "session"

export type SlashCommand = {
  name: string
  description: string
  category: SlashCategory
  // Present when the command needs arguments; name completion stops after a trailing space.
  usage?: string
}

export const slashCategoryLabels: Record<SlashCategory, string> = {
  guide: "guide",
  setup: "setup",
  skills: "skills",
  plugins: "plugins",
  mcp: "mcp",
  approvals: "review",
  session: "session",
}

export function slashCategoryLabel(command: { category?: SlashCategory; name: string }): string {
  const category = command.category ?? slashCategoryForName(command.name)
  return slashCategoryLabels[category]
}

export function slashCategoryForName(name: string): SlashCategory {
  if (name.startsWith("/help")) return "guide"
  if (name === "/connect" || name === "/models" || name === "/theme") return "setup"
  if (name.startsWith("/skill")) return "skills"
  if (name.startsWith("/plugin")) return "plugins"
  if (name === "/mcp calls" || name.startsWith("/mcp call")) return "approvals"
  if (name.startsWith("/mcp")) return "mcp"
  if (name.startsWith("/patch") || name.startsWith("/command")) return "approvals"
  return "session"
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
  configuredMcpServers?: SlashArgument[]
  mcpCalls?: SlashArgument[]
  patches?: SlashArgument[]
  commands?: SlashArgument[]
}

export type SlashSuggestion = SlashCommand & {
  insert: string
  run: boolean
}

export const slashCommands: SlashCommand[] = [
  { name: "/help", category: "guide", description: "Show the quick guide" },
  { name: "/help advanced", category: "guide", description: "Show full command syntax" },
  { name: "/connect", category: "setup", description: "Authenticate: paste an API key, save credentials, and pick a model" },
  { name: "/models", category: "setup", description: "Configure provider, model, endpoint, and output budget" },
  { name: "/theme", category: "setup", description: "List or switch TUI color themes (mint, ember, slate, mono, aurora)", usage: "/theme <id>" },
  { name: "/skills", category: "skills", description: "List discovered Skills; add text to filter (all tokens must match)" },
  { name: "/skill", category: "skills", description: "Turn a Skill on or off", usage: "/skill on|off <source>/<skill>" },
  { name: "/plugins", category: "plugins", description: "List linked Agent Plugin packages; add text to filter" },
  { name: "/plugin add", category: "plugins", description: "Link an absolute local plugin directory", usage: "/plugin add <absolute-path>" },
  { name: "/plugin remove", category: "plugins", description: "Remove a managed plugin link", usage: "/plugin remove <name>" },
  { name: "/mcp", category: "mcp", description: "List MCP servers; add text to filter (stdio, trusted, name…)" },
  { name: "/mcp add", category: "mcp", description: "Add a configured MCP server (user or project scope)", usage: "/mcp add [user|project] stdio <name> <command> [args…]  or  /mcp add [user|project] http <name> <url>" },
  { name: "/mcp remove", category: "mcp", description: "Remove a configured MCP server", usage: "/mcp remove [user|project] <name>" },
  { name: "/mcp enable", category: "mcp", description: "Enable a configured MCP server", usage: "/mcp enable [user|project] <name>" },
  { name: "/mcp disable", category: "mcp", description: "Disable a configured MCP server without deleting it", usage: "/mcp disable [user|project] <name>" },
  { name: "/mcp trust", category: "mcp", description: "Trust an MCP server", usage: "/mcp trust <plugin>/<server>" },
  { name: "/mcp untrust", category: "mcp", description: "Stop trusting an MCP server", usage: "/mcp untrust <plugin>/<server>" },
  { name: "/mcp credentials", category: "mcp", description: "List named Streamable HTTP credentials (header names only; no secret values)" },
  { name: "/mcp credential", category: "mcp", description: "Set or remove a named MCP HTTP credential (Bearer headers, API keys)", usage: "/mcp credential set|remove …" },
  { name: "/mcp oauth", category: "mcp", description: "Start or finish an MCP OAuth PKCE authorize flow into a named credential", usage: "/mcp oauth authorize|complete …" },
  { name: "/mcp calls", category: "approvals", description: "List MCP calls waiting for review" },
  { name: "/mcp call", category: "approvals", description: "Inspect, approve, or reject an MCP call", usage: "/mcp call show|approve|reject <id>" },
  { name: "/patches", category: "approvals", description: "List proposed file edits waiting for approval; add text to filter by path or status" },
  { name: "/patch", category: "approvals", description: "Show, approve, or reject a file edit", usage: "/patch show|approve|reject <id>" },
  { name: "/commands", category: "approvals", description: "List proposed shell commands waiting for approval; add text to filter by command or cwd" },
  { name: "/command", category: "approvals", description: "Show, approve, or reject a shell command", usage: "/command show|approve|reject <id>" },
  { name: "/history older", category: "session", description: "Load earlier messages in this session" },
  { name: "/usage", category: "session", description: "Show provider-reported token totals for this session" },
  { name: "/map", category: "session", description: "Show the extractive workspace repository map; add text to hint ranking" },
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
  "/mcp add": [
    {
      kind: "choice",
      choices: [
        { value: "stdio", description: "Local process (bare command or absolute path); user scope" },
        { value: "http", description: "Streamable HTTP endpoint; user scope" },
        { value: "project", description: "Write under <workspace>/.veasel/mcp-servers.json" },
        { value: "user", description: "Write under VEASEL_DATA_DIR/mcp-servers.json" },
      ],
    },
  ],
  "/mcp remove": [
    {
      kind: "choice",
      choices: [
        { value: "user", description: "Remove from user-scope mcp-servers.json" },
        { value: "project", description: "Remove from project-scope .veasel/mcp-servers.json" },
      ],
    },
    { kind: "value", values: (context) => context.configuredMcpServers ?? [], empty: "No configured MCP servers yet" },
  ],
  "/mcp enable": [
    {
      kind: "choice",
      choices: [
        { value: "user", description: "Enable in user-scope mcp-servers.json" },
        { value: "project", description: "Enable in project-scope .veasel/mcp-servers.json" },
      ],
    },
    { kind: "value", values: (context) => context.configuredMcpServers ?? [], empty: "No configured MCP servers yet" },
  ],
  "/mcp disable": [
    {
      kind: "choice",
      choices: [
        { value: "user", description: "Disable in user-scope mcp-servers.json" },
        { value: "project", description: "Disable in project-scope .veasel/mcp-servers.json" },
      ],
    },
    { kind: "value", values: (context) => context.configuredMcpServers ?? [], empty: "No configured MCP servers yet" },
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
  "/mcp credential": [
    {
      kind: "choice",
      choices: [
        { value: "set", description: "Upsert Header=value pairs (values never listed back)" },
        { value: "remove", description: "Delete a named credential" },
      ],
    },
  ],
  "/mcp oauth": [
    {
      kind: "choice",
      choices: [
        { value: "authorize", description: "Start PKCE authorize; open the returned URL in a browser" },
        { value: "complete", description: "Finish with a loopback callback URL or state+code" },
      ],
    },
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

// Match description tokens so operators can find /connect via "key" or "auth",
// /theme via "color", /map via "repo", and pending edits via a path fragment.
// Substring-in-word matches are avoided ("repo" must not hit "provider").
function matchesDescription(description: string, needle: string): boolean {
  if (needle.length < 3) return false
  const tokens = description.toLowerCase().split(/[^a-z0-9._-]+/).filter(Boolean)
  return tokens.some((word) => {
    if (word === needle || word.startsWith(needle)) return true
    const stem = word.includes(".") ? word.slice(0, word.indexOf(".")) : word
    return stem === needle || stem.startsWith(needle)
  })
}

function filterArguments(values: SlashArgument[], typed: string): SlashArgument[] {
  const needle = typed.toLowerCase()
  if (!needle) return values
  const prefix = values.filter((value) => value.value.toLowerCase().startsWith(needle))
  const contains = values.filter((value) => !prefix.includes(value) && value.value.toLowerCase().includes(needle))
  const described = values.filter((value) =>
    !prefix.includes(value) && !contains.includes(value) && matchesDescription(value.description, needle)
  )
  return [...prefix, ...contains, ...described]
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
        category: command.category,
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
      category: command.category,
      insert: `${stem} `,
      run: false,
    }]
  }
  return matches.map((value) => ({
    name: `${stem} ${value.value}`.replace(/\s+/g, " "),
    description: value.description,
    category: command.category,
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
  const trimmed = query.trimEnd()
  const prefix = commands.filter((command) => command.name.startsWith(trimmed))
  const needle = query.slice(1).trim()
  const contains = needle
    ? commands.filter((command) => !prefix.includes(command) && command.name.slice(1).includes(needle))
    : []
  // Description search only fills gaps: keep name matches exclusive when any exist
  // so /plugin does not also surface every command that mentions "plugin".
  const described = needle && prefix.length === 0 && contains.length === 0
    ? commands.filter((command) => matchesDescription(command.description, needle))
    : []
  const exact = prefix.filter((command) => command.name === trimmed)
  return [
    ...exact,
    ...prefix.filter((command) => !exact.includes(command)),
    ...contains,
    ...described,
  ].map(asSuggestion)
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

// Home/End and page keys jump without wrapping past the list edges.
export function jumpSuggestion(index: number, count: number, where: "home" | "end" | "pageup" | "pagedown", page = maxSlashSuggestions): number {
  if (count <= 0) return 0
  if (where === "home") return 0
  if (where === "end") return count - 1
  if (where === "pageup") return Math.max(0, index - page)
  return Math.min(count - 1, index + page)
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
