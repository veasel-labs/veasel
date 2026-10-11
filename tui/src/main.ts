import {
  BoxRenderable,
  InputRenderable,
  InputRenderableEvents,
  StyledText,
  TextRenderable,
  createCliRenderer,
  fg,
} from "@opentui/core"

type Session = {
  id: string
  title: string
  directory: string
  created_at: string
}

type ChatTurn = {
  id: number
  session_id: string
  role: "user" | "assistant"
  content: string
  created_at: string
}

type ChatExchange = {
  messages: ChatTurn[]
  provider: string
  model: string
}

type PluginCatalog = {
  plugins: Array<{
    name: string
    skills: Array<{ name: string; description: string }>
    mcp_servers: Array<{ name: string; transport: string; command: string; url_origin: string; header_count: number; header_names: string[] }>
  }>
}

type SessionPluginSkill = {
  plugin_name: string
  skill_name: string
}

type SessionPluginMCPServer = {
  plugin_name: string
  server_name: string
}

type WorkspaceEditSummary = {
  id: string
  path: string
  status: "pending" | "applying" | "applied" | "rejected" | "conflict" | "interrupted"
  created_at: string
  updated_at: string
}

type WorkspaceEditProposal = WorkspaceEditSummary & { session_id: string; diff: string }

type ShellCommandSummary = {
  id: string
  command: string
  cwd: string
  timeout_seconds: number
  status: "pending" | "running" | "succeeded" | "failed" | "timed_out" | "output_limited" | "rejected" | "uncertain"
  exit_code: number
  output: string
  created_at: string
  updated_at: string
}

const port = process.env.VEASEL_PORT ?? "4097"
const configuredApi = process.env.VEASEL_API_URL ?? `http://127.0.0.1:${port}`
const apiUrl = new URL(configuredApi)
if (
  apiUrl.protocol !== "http:" ||
  !["localhost", "127.0.0.1", "[::1]", "::1"].includes(apiUrl.hostname) ||
  apiUrl.username !== "" ||
  apiUrl.password !== "" ||
  apiUrl.pathname !== "/" ||
  apiUrl.search !== "" ||
  apiUrl.hash !== ""
) {
  throw new Error("Veasel TUI only connects to an unauthenticated loopback API")
}
const apiBase = apiUrl.origin
const renderer = await createCliRenderer({ exitOnCtrlC: true })
const controller = new AbortController()

const shell = new BoxRenderable(renderer, {
  width: "100%",
  height: "100%",
  flexDirection: "column",
  backgroundColor: "#101318",
  padding: 1,
  gap: 1,
})
const header = new BoxRenderable(renderer, {
  height: 3,
  flexDirection: "row",
  alignItems: "center",
  justifyContent: "space-between",
  paddingLeft: 1,
  paddingRight: 1,
  backgroundColor: "#1b222b",
  borderStyle: "rounded",
  borderColor: "#40534f",
})
header.add(new TextRenderable(renderer, { content: " VEASEL  /  CODE", fg: "#a7f3d0" }))
header.add(new TextRenderable(renderer, { content: "local session workspace", fg: "#87949e" }))

const body = new BoxRenderable(renderer, {
  flexGrow: 1,
  flexDirection: "row",
  gap: 1,
})
const sidebar = new BoxRenderable(renderer, {
  width: "36%",
  flexDirection: "column",
  padding: 1,
  gap: 1,
  backgroundColor: "#171c22",
  borderStyle: "rounded",
  borderColor: "#303944",
})
sidebar.add(new TextRenderable(renderer, { content: "SESSIONS", fg: "#d6a7ff" }))
const sessionList = new TextRenderable(renderer, {
  content: "Connecting to Veasel…",
  fg: "#d4d8dc",
  wrapMode: "word",
})
sidebar.add(sessionList)
const detail = new BoxRenderable(renderer, {
  flexGrow: 1,
  flexDirection: "column",
  padding: 2,
  gap: 1,
  backgroundColor: "#171c22",
  borderStyle: "rounded",
  borderColor: "#303944",
})
const portrait = [
  "    DDDDD     DDDDD    ",
  "   DLLLLD     DLLLLD   ",
  "  DLLLLLDDDDDDDLLLLLD  ",
  "  DLLLDDDDDDDDDDDLLLDD ",
  " DDDDDDDDBBBBBBDDDDDDD ",
  "DDDDDDBBBBBBBBBBBBBBDDDD",
  "DDDDBBBBBBBBBBBBBBBBBBDDD",
  "DDBBBBBBBBBBBBBBBBBBBBBBDD",
  "DBBBBKBBBBBBBBBBBBKBBBBBBBD",
  "DBBBBHKBBBBBBBBBBHKBBBBBBBD",
  "DBBBBBBBBBBNNBBBBBBBBBBBBBD",
  " DDBBWWWWWNNNNNWWWWWWBBBBDD ",
  "  DDBBWWWWWWWWWWWWBBBBDD  ",
  "   DDDBBWWWWWWWWBBBDDD   ",
  "     DDDBBBBBBBDDD     ",
  "       DDDDDD       ",
]
const pixelColors: Record<string, string> = {
  D: "#202e3b",
  B: "#4b6c88",
  L: "#90b8db",
  K: "#080b0f",
  H: "#ffffff",
  N: "#080b0f",
  W: "#ffffff",
}
const portraitText = new StyledText(portrait.flatMap((row) => [
  ...[...row].map((pixel) => fg(pixelColors[pixel] ?? "#171c22")(pixel === " " ? "  " : "██")),
  fg("#171c22")("\n"),
]))
detail.add(new TextRenderable(renderer, { content: portraitText }))
detail.add(new TextRenderable(renderer, { content: "VEASEL CODE", fg: "#a7f3d0" }))
const sessionDetail = new TextRenderable(renderer, {
  content: "Your V-powered coding companion.\n\nChoose a session on the left, or press n to start a fresh workspace. Veasel keeps your session history close and ready to pick up again.",
  fg: "#b9c2ca",
  wrapMode: "word",
})
detail.add(sessionDetail)
body.add(sidebar)
body.add(detail)

const footer = new BoxRenderable(renderer, {
  height: 3,
  flexDirection: "row",
  alignItems: "center",
  paddingLeft: 1,
  gap: 2,
  backgroundColor: "#1b222b",
  borderStyle: "rounded",
  borderColor: "#303944",
})
const status = new TextRenderable(renderer, { content: "● connecting", fg: "#f3c969" })
footer.add(status)
footer.add(new TextRenderable(renderer, {
  content: "n new   /skills   /mcp   /patches   /commands   /patch show|approve|reject   /command show|approve|reject   Esc cancel   ↑/↓   q quit",
  fg: "#87949e",
}))
shell.add(header)
shell.add(body)
shell.add(footer)
renderer.root.add(shell)

let sessions: Session[] = []
let selected = 0
let creating = false
let titleInput: InputRenderable | undefined
let activeSession: Session | undefined
let chatInput: InputRenderable | undefined
let sendingMessage = false
let activeTurnId: string | undefined
let activeTurnController: AbortController | undefined
let activeTurnCancelled = false
let chatMessages: ChatTurn[] = []
let skillNotice = ""
const reviewedEditIds = new Set<string>()
const reviewedShellCommandIds = new Set<string>()

function renderSessions() {
  if (sessions.length === 0) {
    sessionList.content = "No sessions yet.\n\nPress n to start one."
    return
  }
  sessionList.content = sessions.map((session, index) => {
    const marker = index === selected ? "›" : " "
    const title = session.title.replace(/[\r\n\t]/g, " ")
    return `${marker} ${title}\n  ${session.directory}`
  }).join("\n\n")
}

async function refreshSessions() {
  try {
    const response = await fetch(`${apiBase}/v1/sessions`, { signal: controller.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    sessions = await response.json() as Session[]
    selected = Math.min(selected, Math.max(0, sessions.length - 1))
    renderSessions()
    status.content = `● connected  ·  ${sessions.length} session${sessions.length === 1 ? "" : "s"}`
    status.fg = "#a7f3d0"
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● server unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = "#f28b82"
  }
}

async function createSession(title: string) {
  const response = await fetch(`${apiBase}/v1/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      title,
      directory: process.env.VEASEL_PROJECT_DIR ?? process.cwd(),
    }),
    signal: controller.signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
  const created = await response.json() as Session
  await refreshSessions()
  selected = sessions.findIndex((session) => session.id === created.id)
  renderSessions()
}

function renderChat(messages: ChatTurn[]) {
  chatMessages = messages
  const heading = activeSession
    ? `SESSION  /  ${activeSession.title}\n${activeSession.directory}\n\nWORKSPACE / DATA FLOW\nFile excerpts requested by Veasel are sent to your configured model provider. Proposed replacements and commands stay local until review and approval. Approved shell commands inherit the server environment, run as your OS user, and are not sandboxed.\n\n`
    : ""
  sessionDetail.content = safeTerminalText(heading)
    + (skillNotice ? `${safeTerminalText(skillNotice)}\n\n` : "") + (messages.length === 0
    ? "Start with a question or describe a coding task."
    : messages.map((message) => {
      const label = message.role === "assistant" ? "VEASEL" : "YOU"
      return `${label}\n${safeTerminalText(message.content)}`
    }).join("\n\n"))
}

function safeTerminalText(value: string) {
  return value.replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
}

async function openSession(session: Session) {
  activeSession = session
  reviewedShellCommandIds.clear()
  skillNotice = ""
  reviewedEditIds.clear()
  renderChat([])
  const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(session.id)}/messages`, {
    signal: controller.signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  renderChat(await response.json() as ChatTurn[])
  await notifyPendingProposals()
  if (!chatInput) {
    const input = new InputRenderable(renderer, {
      id: "chat-composer",
      width: "100%",
      placeholder: "Ask Veasel to explain or propose a workspace change…",
      backgroundColor: "#202832",
      focusedBackgroundColor: "#293640",
      textColor: "#e5e7eb",
      cursorColor: "#a7f3d0",
      maxLength: 100_000,
    })
    chatInput = input
    detail.add(input)
    input.on(InputRenderableEvents.ENTER, (value) => {
      void sendMessage(value)
    })
  }
  chatInput.focus()
}

async function sendMessage(value: string) {
  const content = value.trim()
  if (!content || !activeSession || !chatInput || sendingMessage) return
  if (content === "/skills") {
    await showSkills()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/mcp") {
    await showMcpServers()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpCommand = /^\/mcp\s+(trust|untrust)\s+([a-z0-9.-]+)\/([^\r\n]+)$/.exec(content)
  if (mcpCommand) {
    await setMcpServerTrust(mcpCommand[1] === "trust", mcpCommand[2], mcpCommand[3].trim())
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/mcp ")) {
    skillNotice = "Use /mcp to list servers, then /mcp trust <plugin>/<server> or /mcp untrust <plugin>/<server>. Review the stdio command or remote origin before trusting a server."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/patches") {
    await showWorkspaceEdits()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const editCommand = /^\/patch\s+(approve|reject)\s+([0-9a-f-]{36})$/.exec(content)
  if (editCommand) {
    await actOnWorkspaceEdit(editCommand[1] === "approve" ? "approve" : "reject", editCommand[2])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const showEditCommand = /^\/patch\s+show\s+([0-9a-f-]{36})$/.exec(content)
  if (showEditCommand) {
    await showWorkspaceEdit(showEditCommand[1])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/patch ")) {
    skillNotice = "Use /patches to find an ID, /patch show <id> to inspect its diff, then approve or reject it."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/commands") {
    await showShellCommands()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const shellAction = /^\/command\s+(approve|reject)\s+([0-9a-f-]{36})$/.exec(content)
  if (shellAction) {
    await actOnShellCommand(shellAction[1] as "approve" | "reject", shellAction[2])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const showShellAction = /^\/command\s+show\s+([0-9a-f-]{36})$/.exec(content)
  if (showShellAction) {
    await showShellCommand(showShellAction[1])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/command ")) {
    skillNotice = "Use /commands to list proposals, /command show <id> to inspect one, then /command approve <id> or /command reject <id>. Commands run with your OS user permissions and are not sandboxed."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const skillCommand = /^\/skill\s+(on|off)\s+([a-z0-9.-]+)\/([a-z0-9-]+)$/.exec(content)
  if (skillCommand) {
    await setSkill(skillCommand[1] === "on", skillCommand[2], skillCommand[3])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/skill ")) {
    skillNotice = "Use /skill on <plugin>/<skill> or /skill off <plugin>/<skill>."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  sendingMessage = true
  activeTurnId = crypto.randomUUID()
  activeTurnController = new AbortController()
  activeTurnCancelled = false
  const operationId = activeTurnId
  const turnController = activeTurnController
  chatInput.value = ""
  chatInput.blur()
  status.content = "● Veasel is thinking…"
  status.fg = "#f3c969"
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-veasel-operation-id": operationId },
      body: JSON.stringify({ content }),
      signal: AbortSignal.any([controller.signal, turnController.signal]),
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const exchange = await response.json() as ChatExchange
    const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      signal: controller.signal,
    })
    if (!historyResponse.ok) throw new Error(`HTTP ${historyResponse.status}`)
    renderChat(await historyResponse.json() as ChatTurn[])
    await notifyPendingProposals()
    status.content = `● ${exchange.provider}  ·  ${exchange.model}`
    status.fg = "#a7f3d0"
  } catch (error) {
    if (activeTurnCancelled) {
      status.content = "● response cancelled"
      status.fg = "#f3c969"
      return
    }
    if (controller.signal.aborted) return
    status.content = `● message failed  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = "#f28b82"
  } finally {
    sendingMessage = false
    activeTurnId = undefined
    activeTurnController = undefined
    chatInput?.focus()
  }
}

async function cancelActiveTurn() {
  if (!activeSession || !activeTurnId || !activeTurnController || activeTurnCancelled) return
  activeTurnCancelled = true
  status.content = "● cancelling response…"
  status.fg = "#f3c969"
  try {
    await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/operations/${activeTurnId}/cancel`, {
      method: "POST",
    })
  } catch {
    // Closing the local response below still stops TUI waiting if the server exited.
  } finally {
    activeTurnController.abort()
  }
}

async function showSkills() {
  if (!activeSession) return
  try {
    const [catalogResponse, activeResponse] = await Promise.all([
      fetch(`${apiBase}/v1/plugins`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/skills`, { signal: controller.signal }),
    ])
    if (!catalogResponse.ok || !activeResponse.ok) throw new Error("plugin catalog is unavailable")
    const catalog = await catalogResponse.json() as PluginCatalog
    const active = await activeResponse.json() as SessionPluginSkill[]
    const enabled = new Set(active.map((item) => `${item.plugin_name}/${item.skill_name}`))
    const lines = catalog.plugins.flatMap((plugin) => plugin.skills.map((skill) => {
      const key = `${plugin.name}/${skill.name}`
      return `${enabled.has(key) ? "● enabled" : "○ available"}  ${key}\n  ${skill.description}`
    }))
    skillNotice = lines.length > 0
      ? `AGENT PLUGIN SKILLS\n${lines.join("\n\n")}\n\nEnable with /skill on <plugin>/<skill>. Disable with /skill off <plugin>/<skill>.`
      : "No Agent Plugin skills found. Add a package with plugin.json under VEASEL_PLUGIN_DIR (or the data/plugins directory)."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load plugin skills: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showMcpServers() {
  if (!activeSession) return
  try {
    const [catalogResponse, activeResponse] = await Promise.all([
      fetch(`${apiBase}/v1/plugins`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-servers`, { signal: controller.signal }),
    ])
    if (!catalogResponse.ok || !activeResponse.ok) throw new Error("plugin catalog is unavailable")
    const catalog = await catalogResponse.json() as PluginCatalog
    const active = await activeResponse.json() as SessionPluginMCPServer[]
    const trusted = new Set(active.map((item) => `${item.plugin_name}/${item.server_name}`))
    const lines = catalog.plugins.flatMap((plugin) => plugin.mcp_servers.map((server) => {
      const key = `${plugin.name}/${server.name}`
      const command = server.command ? `\n  command: ${safeTerminalText(server.command)}` : ""
      const endpoint = server.url_origin ? `\n  endpoint: ${safeTerminalText(server.url_origin)}` : ""
      const headers = server.header_count
        ? `\n  configured headers: ${server.header_names.map(safeTerminalText).join(", ")}`
        : ""
      const support = ["stdio", "streamable-http"].includes(server.transport)
        ? server.transport
        : `${server.transport} (unsupported)`
      return `${trusted.has(key) ? "● trusted" : "○ available"}  ${safeTerminalText(key)} [${safeTerminalText(support)}]${command}${endpoint}${headers}`
    }))
    const inventory = lines.length > 0
      ? lines.join("\n\n")
      : "No Agent Plugin MCP servers found. Add a package with mcp.json under VEASEL_PLUGIN_DIR (or the data/plugins directory)."
    skillNotice = `AGENT PLUGIN MCP SERVERS\n${inventory}\n\nTrust with /mcp trust <plugin>/<server>; revoke with /mcp untrust <plugin>/<server>. Stdio servers run with your OS privileges and can access files and network available to your user. Streamable HTTP servers receive configured headers and MCP tool inputs only at the displayed origin; redirects are refused. MCP tool inputs and results are sent to your configured model provider. Review each package and endpoint before trusting it.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load MCP servers: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showWorkspaceEdits() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const edits = await response.json() as WorkspaceEditSummary[]
    skillNotice = edits.length > 0
      ? `WORKSPACE EDIT PROPOSALS\n${edits.map((edit) => {
        const commands = edit.status === "pending"
          ? `\nInspect diff: /patch show ${edit.id}`
          : ""
        const recovery = edit.status === "interrupted"
          ? "\nApplication stopped unexpectedly. Inspect the file manually; Veasel will not replay this edit."
          : ""
        return `${edit.status.toUpperCase()}  ${safeTerminalText(edit.path)}\n${edit.id}${commands}${recovery}`
      }).join("\n\n")}`
      : "No workspace edit proposals. Ask Veasel to make a change; it will show a diff for your review before writing any file."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load workspace edit proposals: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function notifyPendingProposals() {
  if (!activeSession) return
  try {
    const notices: string[] = []
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits`, {
      signal: controller.signal,
    })
    if (response.ok) {
      const edits = await response.json() as WorkspaceEditSummary[]
      const pending = edits.filter((edit) => edit.status === "pending")
      if (pending.length > 0) notices.push(`${pending.length} workspace edit proposal${pending.length === 1 ? "" : "s"} need review. Type /patches to inspect them. No files have changed.`)
    }
    const commandResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands`, {
      signal: controller.signal,
    })
    if (commandResponse.ok) {
      const commands = await commandResponse.json() as ShellCommandSummary[]
      const pending = commands.filter((item) => item.status === "pending")
      if (pending.length > 0) notices.push(`${pending.length} shell command proposal${pending.length === 1 ? "" : "s"} need review. Type /commands to inspect them. Approval runs commands with your OS user permissions and inherited environment, without a sandbox.`)
    }
    if (notices.length === 0) return
    skillNotice = notices.join("\n\n")
    renderChat(chatMessages)
  } catch {
    // Keep chat usable when the optional proposal notification cannot be loaded.
  }
}

async function showWorkspaceEdit(editId: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits/${editId}`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const edit = await response.json() as WorkspaceEditProposal
    if (edit.status === "pending") reviewedEditIds.add(edit.id)
    skillNotice = `REVIEW WORKSPACE EDIT  /  ${edit.status.toUpperCase()}\n${safeTerminalText(edit.path)}\n${safeTerminalText(edit.diff)}${edit.status === "pending" ? `\nAfter inspecting the diff, type /patch approve ${edit.id} or /patch reject ${edit.id}.` : ""}`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load workspace edit diff: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function actOnWorkspaceEdit(action: "approve" | "reject", editId: string) {
  if (!activeSession) return
  if (!reviewedEditIds.has(editId)) {
    skillNotice = `Inspect this proposal first with /patch show ${editId}.`
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits/${editId}/${action}`, {
      method: "POST",
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const result = await response.json() as { status: string }
    reviewedEditIds.delete(editId)
    skillNotice = action === "approve" && result.status === "applied"
      ? `Applied the reviewed workspace edit (${editId}). Use /patches to inspect the outcome.`
      : `Rejected the workspace edit (${editId}). Use /patches to review remaining proposals.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not ${action} workspace edit: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showShellCommands() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands`, { signal: controller.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const commands = await response.json() as ShellCommandSummary[]
    skillNotice = commands.length
      ? `SHELL COMMAND PROPOSALS\n${commands.map((item) => `${item.status.toUpperCase()}  ${item.id}\n${safeTerminalText(item.command)}\nCWD: ${safeTerminalText(item.cwd)} · timeout ${item.timeout_seconds}s${item.status === "pending" ? `\nInspect: /command show ${item.id}` : item.status === "uncertain" ? "\nExecution was interrupted. Inspect workspace state; Veasel will not rerun it." : ""}`).join("\n\n")}`
      : "No shell command proposals. Veasel shows the exact command and waits for explicit approval. Commands run with your OS user permissions and have no sandbox."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load shell command proposals: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showShellCommand(commandId: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands/${commandId}`, { signal: controller.signal })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const item = await response.json() as ShellCommandSummary
    if (item.status === "pending") reviewedShellCommandIds.add(item.id)
    skillNotice = `REVIEW SHELL COMMAND  /  ${item.status.toUpperCase()}\n${safeTerminalText(item.command)}\nCWD: ${safeTerminalText(item.cwd)} · timeout ${item.timeout_seconds}s\nRunner: ${process.platform === "win32" ? "COMSPEC" : "/bin/sh"} · non-interactive stdin\nRuns as your OS user, inherits its environment, and has filesystem and network access without a sandbox. Review every effect before approval.${item.status === "pending" ? `\nType /command approve ${item.id} or /command reject ${item.id}.` : item.output ? `\n\n${safeTerminalText(item.output)}` : ""}`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not inspect shell command: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function actOnShellCommand(action: "approve" | "reject", commandId: string) {
  if (!activeSession) return
  if (!reviewedShellCommandIds.has(commandId)) {
    skillNotice = `Inspect the exact command first with /command show ${commandId}.`
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands/${commandId}/${action}`, { method: "POST", signal: controller.signal })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const result = await response.json() as ShellCommandSummary
    reviewedShellCommandIds.delete(commandId)
    skillNotice = action === "approve"
      ? `Command ${result.status} · exit ${result.exit_code}\n${safeTerminalText(result.output || "(no output)")}\n\nInspect workspace effects before continuing with the agent.`
      : `Rejected shell command ${commandId}. It was not executed.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not ${action} shell command: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function setSkill(enabled: boolean, pluginName: string, skillName: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/skills`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ plugin_name: pluginName, skill_name: skillName, enabled }),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    skillNotice = `${enabled ? "Enabled" : "Disabled"} ${pluginName}/${skillName} for this session. Use /skills to review active skills.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not update skill: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function setMcpServerTrust(trusted: boolean, pluginName: string, serverName: string) {
  if (!activeSession) return
  if (!serverName || serverName.length > 256) {
    skillNotice = "MCP server name must contain 1 to 256 characters."
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-servers`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ plugin_name: pluginName, server_name: serverName, trusted }),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    skillNotice = trusted
      ? `Trusted ${safeTerminalText(pluginName)}/${safeTerminalText(serverName)} for this session. It connects or launches on the next model turn. Use /mcp to review the command or remote origin and revoke trust.`
      : `Revoked MCP trust for ${safeTerminalText(pluginName)}/${safeTerminalText(serverName)}. It will not start on future model turns.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not update MCP trust: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function consumeEvents() {
  let lastEventId = "0"
  while (!controller.signal.aborted) {
    try {
      const response = await fetch(`${apiBase}/v1/events`, {
        headers: { "Last-Event-ID": lastEventId, accept: "text/event-stream" },
        signal: controller.signal,
      })
      if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`)
      status.content = "● connected  ·  listening for activity"
      status.fg = "#a7f3d0"
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ""
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const blocks = buffer.split(/\r?\n\r?\n/)
        buffer = blocks.pop() ?? ""
        for (const block of blocks) {
          for (const line of block.split(/\r?\n/)) {
            if (line.startsWith("id:")) lastEventId = line.slice(3).trim()
            if (line.startsWith("event:") && line.slice(6).trim() !== "heartbeat") {
              status.content = `● live  ·  ${line.slice(6).trim()}`
            }
          }
          void refreshSessions()
        }
      }
      if (!controller.signal.aborted) {
        status.content = "● reconnecting to event stream…"
        status.fg = "#f3c969"
        await new Promise((resolve) => setTimeout(resolve, 1200))
      }
    } catch {
      if (controller.signal.aborted) return
      status.content = "● reconnecting to event stream…"
      status.fg = "#f3c969"
      await new Promise((resolve) => setTimeout(resolve, 1200))
    }
  }
}

function beginCreate() {
  if (creating) return
  creating = true
  sessionList.content = "Name this workspace session:"
  const input = new InputRenderable(renderer, {
    id: "session-title",
    width: 48,
    placeholder: "e.g. Refactor the parser",
    backgroundColor: "#202832",
    focusedBackgroundColor: "#293640",
    textColor: "#e5e7eb",
    cursorColor: "#a7f3d0",
    maxLength: 200,
  })
  titleInput = input
  sidebar.add(input)
  input.focus()
  input.on(InputRenderableEvents.ENTER, (value) => {
    const title = value.trim()
    if (!title) return
    input.blur()
    sidebar.remove(input)
    titleInput = undefined
    creating = false
    void createSession(title).catch((error) => {
      status.content = `● could not create session  ·  ${error instanceof Error ? error.message : "request failed"}`
      status.fg = "#f28b82"
    })
  })
}

renderer.keyInput.on("keypress", (key) => {
  if (key.name === "q" && !creating) {
    key.stopPropagation()
    void cancelActiveTurn()
    controller.abort()
    renderer.destroy()
    return
  }
  if (creating) {
    if (key.name === "escape") {
      if (titleInput) sidebar.remove(titleInput)
      titleInput = undefined
      creating = false
      renderSessions()
    }
    return
  }
  if (chatInput && activeSession) {
    if (key.name === "escape") {
      if (sendingMessage) {
        key.stopPropagation()
        void cancelActiveTurn()
        return
      }
      detail.remove(chatInput)
      chatInput = undefined
      activeSession = undefined
      sessionDetail.content = "Your V-powered coding companion.\n\nChoose a session on the left, or press n to start a fresh workspace. Veasel keeps your session history close and ready to pick up again."
    }
    return
  }
  if (key.name === "n") {
    key.stopPropagation()
    beginCreate()
  }
  else if (key.name === "r") void refreshSessions()
  else if (key.name === "up" || key.name === "k") {
    selected = Math.max(0, selected - 1)
    renderSessions()
  } else if (key.name === "down" || key.name === "j") {
    selected = Math.min(Math.max(0, sessions.length - 1), selected + 1)
    renderSessions()
  } else if (key.name === "return" && sessions[selected]) {
    const session = sessions[selected]
    void openSession(session).catch((error) => {
      status.content = `● unable to open session  ·  ${error instanceof Error ? error.message : "request failed"}`
      status.fg = "#f28b82"
    })
  }
})

renderer.on("destroy", () => controller.abort())
await refreshSessions()
void consumeEvents()
