import {
  BoxRenderable,
  InputRenderable,
  InputRenderableEvents,
  StyledText,
  TextRenderable,
  createCliRenderer,
  fg,
} from "@opentui/core"
import { mergeChatTurns, pageMayHaveOlder, type ChatTurn } from "./chat-history"
import { isModelSettingsCommand, renderHelp, unknownSlashCommand } from "./help"

type Session = {
  id: string
  title: string
  directory: string
  created_at: string
}

type ModelProfileView = { model: string; base_url: string; api_key_saved: boolean }
type ModelSettingsView = { active_provider: string; profiles: Record<string, ModelProfileView> }

type ChatExchange = {
  messages: ChatTurn[]
  provider: string
  model: string
}

type SessionTurnAccepted = {
  operation_id: string
  status: "running"
}

type SessionTurnCompletion = {
  operation_id?: string
  status?: string
  provider?: string
  model?: string
  error?: string
}

type PluginCatalog = {
  plugins: Array<{
    name: string
    skills: Array<{ name: string; description: string; allowed_tools_declared: boolean; allowed_tools: string[] }>
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

type PluginMCPToolCallApproval = {
  id: string
  operation_id: string
  plugin_name: string
  server_name: string
  tool_name: string
  arguments_json: string
  status: "pending" | "approved" | "running" | "completed" | "rejected" | "failed" | "cancelled" | "uncertain"
  reviewed_at: string
  created_at: string
  updated_at: string
}

type PluginMCPToolCallSummary = Omit<PluginMCPToolCallApproval, "arguments_json"> & {
  arguments_bytes: number
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
const chatHistoryPageSize = 100

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
const portraitRenderable = new TextRenderable(renderer, { content: portraitText })
detail.add(portraitRenderable)
const brandLabel = new TextRenderable(renderer, { content: "VEASEL CODE", fg: "#a7f3d0" })
detail.add(brandLabel)
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
  content: "n new   s models   /models   /help   /skills   /mcp   /patches   /commands   Esc cancel   ↑/↓   q quit",
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
let pendingUserMessage = ""
let chatMessages: ChatTurn[] = []
let chatHistoryHasOlder = false
let chatHistoryLoading = false
let settingsOpen = false
let settingsInput: InputRenderable | undefined
let settingsSecretIndicator: TextRenderable | undefined
let settingsStep = 0
let settingsView: ModelSettingsView | undefined
const settingsValues = { provider: "", model: "", base_url: "", api_key: "", clear_api_key: false }
let streamingAssistantText = ""
let skillNotice = ""
const reviewedEditIds = new Set<string>()
const reviewedShellCommandIds = new Set<string>()
const handledTurnCompletionIds = new Set<string>()

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
  const helpVisible = skillNotice.startsWith("VEASEL CODE / QUICK HELP")
  header.visible = !helpVisible
  sidebar.visible = !helpVisible
  portraitRenderable.content = activeSession ? "" : portraitText
  brandLabel.content = activeSession ? "" : "VEASEL CODE"
  const heading = activeSession && !helpVisible
    ? `SESSION  /  ${activeSession.title}\n${activeSession.directory}\n\n`
    : ""
  sessionDetail.content = safeTerminalText(heading)
    + (skillNotice ? `${safeTerminalText(skillNotice)}\n\n` : "") + (helpVisible
    ? ""
    : messages.length === 0
    ? "Start with a question or describe a coding task."
    : messages.map((message) => {
      const label = message.role === "assistant" ? "VEASEL" : "YOU"
      return `${label}\n${safeTerminalText(message.content)}`
    }).join("\n\n"))
    + (pendingUserMessage
      ? `\n\nYOU  ·  sending\n${safeTerminalText(pendingUserMessage)}`
      : "")
    + (streamingAssistantText
      ? `\n\nVEASEL  ·  ${activeTurnId ? "streaming" : "partial response"}\n${safeTerminalText(streamingAssistantText)}`
      : "")
    + (chatHistoryHasOlder ? "\n\n/history older · load earlier messages" : "")
}

function safeTerminalText(value: string) {
  return value.replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
}

function safeTerminalReviewText(value: string) {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/gu,
    (character) => `\\u${character.codePointAt(0)!.toString(16).padStart(4, "0")}`)
}

async function openSession(session: Session) {
  activeSession = session
  chatHistoryHasOlder = false
  chatHistoryLoading = false
  chatMessages = []
  streamingAssistantText = ""
  pendingUserMessage = ""
  reviewedShellCommandIds.clear()
  skillNotice = ""
  reviewedEditIds.clear()
  renderChat([])
  const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(session.id)}/messages`, {
    signal: controller.signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const messages = await response.json() as ChatTurn[]
  chatHistoryHasOlder = pageMayHaveOlder(messages, chatHistoryPageSize)
  renderChat(messages)
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
      if (isModelSettingsCommand(value)) {
        input.value = ""
        void openSettings()
        return
      }
      void sendMessage(value)
    })
  }
  chatInput.focus()
}

async function sendMessage(value: string) {
  const content = value.trim()
  const mcpCallCommand = /^\/mcp (calls|call (show|approve|reject) [0-9a-f-]{36})$/.test(content)
  if (!content || !activeSession || !chatInput || sendingMessage && !mcpCallCommand) return
  if (content === "/help" || content === "/?" || content === "/help advanced") {
    skillNotice = renderHelp(content === "/help" && (process.stdout.rows ?? 40) < 30)
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/history older") {
    chatInput.value = ""
    await loadOlderChatHistory()
    chatInput.focus()
    return
  }
  if (/^\/history(?:\s|$)/.test(content)) {
    skillNotice = "Use /history older to load the preceding page of this session's chat history."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
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
  if (content === "/mcp calls") {
    await showMcpToolCalls()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpToolCallCommand = /^\/mcp call (show|approve|reject) ([0-9a-f-]{36})$/.exec(content)
  if (mcpToolCallCommand) {
    const action = mcpToolCallCommand[1]
    const callId = mcpToolCallCommand[2]
    if (action === "show") await showMcpToolCall(callId)
    else if (action === "approve" || action === "reject") await actOnMcpToolCall(callId, action)
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
  if (unknownSlashCommand(content)) {
    skillNotice = `Unknown command: ${safeTerminalText(content)}\n\nType /help to see available commands. Messages to the model should start with normal text.`
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  skillNotice = ""
  sendingMessage = true
  activeTurnId = crypto.randomUUID()
  activeTurnController = new AbortController()
  activeTurnCancelled = false
  pendingUserMessage = content
  streamingAssistantText = ""
  renderChat(chatMessages)
  const operationId = activeTurnId
  const turnController = activeTurnController
  let awaitingAsyncCompletion = false
  chatInput.value = ""
  chatInput.blur()
  status.content = "● Veasel is thinking…"
  status.fg = "#f3c969"
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-veasel-operation-id": operationId,
        prefer: "respond-async",
      },
      body: JSON.stringify({ content }),
      signal: AbortSignal.any([controller.signal, turnController.signal]),
    })
    if (response.status === 202) {
      const accepted = await response.json() as SessionTurnAccepted
      if (accepted.operation_id !== operationId) throw new Error("Server returned a different operation ID")
      if (activeTurnId === operationId) awaitingAsyncCompletion = true
      return
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const exchange = await response.json() as ChatExchange
    const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      signal: controller.signal,
    })
    if (!historyResponse.ok) throw new Error(`HTTP ${historyResponse.status}`)
    streamingAssistantText = ""
    const latest = await historyResponse.json() as ChatTurn[]
    chatHistoryHasOlder ||= pageMayHaveOlder(latest, chatHistoryPageSize)
    renderChat(mergeChatTurns(chatMessages, latest))
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
    if (!awaitingAsyncCompletion && activeTurnId === operationId) {
      sendingMessage = false
      pendingUserMessage = ""
      activeTurnId = undefined
      activeTurnController = undefined
      if (streamingAssistantText) renderChat(chatMessages)
      chatInput?.focus()
    }
  }
}

async function loadOlderChatHistory() {
  if (!activeSession || chatHistoryLoading) return
  if (!chatHistoryHasOlder || chatMessages.length === 0) {
    status.content = "● no earlier chat messages"
    status.fg = "#87949e"
    return
  }
  const sessionId = activeSession.id
  const before = chatMessages[0].id
  chatHistoryLoading = true
  status.content = "● loading earlier messages…"
  status.fg = "#f3c969"
  try {
    const response = await fetch(
      `${apiBase}/v1/sessions/${encodeURIComponent(sessionId)}/messages?before=${before}&limit=${chatHistoryPageSize}`,
      { signal: controller.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const older = await response.json() as ChatTurn[]
    if (activeSession?.id !== sessionId) return
    chatHistoryHasOlder = pageMayHaveOlder(older, chatHistoryPageSize)
    const previousCount = chatMessages.length
    renderChat(mergeChatTurns(chatMessages, older))
    const loadedCount = chatMessages.length - previousCount
    status.content = loadedCount > 0
      ? `● loaded ${loadedCount} earlier messages`
      : "● no earlier chat messages"
    status.fg = "#a7f3d0"
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● history load failed  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = "#f28b82"
  } finally {
    chatHistoryLoading = false
  }
}

async function finishAsyncSessionTurn(sessionId: string, completion: SessionTurnCompletion) {
  const operationId = completion.operation_id
  if (!operationId || handledTurnCompletionIds.has(operationId)) return
  handledTurnCompletionIds.add(operationId)
  if (handledTurnCompletionIds.size > 128) {
    const oldest = handledTurnCompletionIds.values().next().value
    if (oldest) handledTurnCompletionIds.delete(oldest)
  }
  if (activeTurnId !== operationId) {
    if (activeSession?.id === sessionId) {
      if (completion.status === "uncertain") {
        status.content = "● operation outcome uncertain · inspect the workspace before retrying"
        status.fg = "#f3c969"
      }
      try {
        const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(sessionId)}/messages`, {
          signal: controller.signal,
        })
        if (historyResponse.ok) {
          const latest = await historyResponse.json() as ChatTurn[]
          chatHistoryHasOlder ||= pageMayHaveOlder(latest, chatHistoryPageSize)
          renderChat(mergeChatTurns(chatMessages, latest))
        }
      } catch {
        // Reopening the session reloads its durable history if this refresh fails.
      }
    }
    return
  }
  if (activeSession?.id !== sessionId) {
    pendingUserMessage = ""
    streamingAssistantText = ""
    sendingMessage = false
    activeTurnId = undefined
    activeTurnController = undefined
    activeTurnCancelled = false
    return
  }
  pendingUserMessage = ""
  streamingAssistantText = ""
  const userCancelled = activeTurnCancelled
  sendingMessage = false
  activeTurnId = undefined
  activeTurnController = undefined
  activeTurnCancelled = false
  if (completion.status === "completed") {
    try {
      const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(sessionId)}/messages`, {
        signal: controller.signal,
      })
      if (!historyResponse.ok) throw new Error(`HTTP ${historyResponse.status}`)
      const latest = await historyResponse.json() as ChatTurn[]
      chatHistoryHasOlder ||= pageMayHaveOlder(latest, chatHistoryPageSize)
      renderChat(mergeChatTurns(chatMessages, latest))
      await notifyPendingProposals()
      status.content = `● ${completion.provider ?? "provider"}  ·  ${completion.model ?? "assistant"}`
      status.fg = "#a7f3d0"
    } catch (error) {
      status.content = `● turn completed  ·  ${error instanceof Error ? error.message : "history refresh failed"}`
      status.fg = "#f3c969"
    }
  } else if (completion.status === "uncertain") {
    renderChat(chatMessages)
    status.content = "● operation outcome uncertain · inspect the workspace before retrying"
    status.fg = "#f3c969"
  } else if (completion.status === "cancelled") {
    renderChat(chatMessages)
    status.content = userCancelled ? "● response cancelled" : "● turn cancelled"
    status.fg = "#f3c969"
  } else {
    renderChat(chatMessages)
    status.content = `● message failed  ·  ${completion.error ?? "assistant turn failed"}`
    status.fg = "#f28b82"
  }
  chatInput?.focus()
}

async function cancelActiveTurn() {
  if (!activeSession || !activeTurnId || !activeTurnController || activeTurnCancelled) return
  activeTurnCancelled = true
  status.content = "● cancelling response…"
  status.fg = "#f3c969"
  void fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/operations/${activeTurnId}/cancel`, {
    method: "POST",
  }).catch(() => undefined)
  activeTurnController.abort()
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
      const restriction = skill.allowed_tools_declared
        ? `\n  Tool access: ${skill.allowed_tools.length > 0 ? skill.allowed_tools.join(", ") : "none"}`
        : ""
      return `${enabled.has(key) ? "● enabled" : "○ available"}  ${key}\n  ${skill.description}${restriction}`
    }))
    skillNotice = lines.length > 0
      ? `AGENT PLUGIN SKILLS\n${lines.join("\n\n")}\n\nEnable with /skill on <plugin>/<skill>. Disable with /skill off <plugin>/<skill>. Active skills can let the model read bounded text resources from their own folder; files are not executed. A declared tool list only restricts tools already available to this session; approval rules still apply.`
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
    skillNotice = `AGENT PLUGIN MCP SERVERS\n${inventory}\n\nTrust with /mcp trust <plugin>/<server>; revoke with /mcp untrust <plugin>/<server>. Trust allows the server to connect and expose tools; every model-requested tool call still requires you to inspect its exact arguments and approve it with /mcp calls. Stdio servers run with your OS privileges and can access files and network available to your user. Streamable HTTP servers receive configured headers and approved MCP tool inputs only at the displayed origin; redirects are refused. MCP tool inputs and results are sent to your configured model provider. Review each package and endpoint before trusting it.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load MCP servers: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showMcpToolCalls() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const calls = await response.json() as PluginMCPToolCallSummary[]
    const lines = calls.map((call) => {
      const pending = call.status === "pending"
        ? `\n  Inspect with /mcp call show ${call.id}`
        : ""
      return `${call.status.toUpperCase()}  ${call.id}\n  ${safeTerminalReviewText(call.plugin_name)}/${safeTerminalReviewText(call.server_name)} · ${safeTerminalReviewText(call.tool_name)}\n  arguments: ${call.arguments_bytes} bytes${pending}`
    })
    skillNotice = calls.length > 0
      ? `MCP TOOL CALLS\n${lines.join("\n\n")}\n\nA pending call has not reached its MCP server. Inspect its arguments before approval.`
      : "No MCP tool calls have been recorded in this session."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load MCP tool call history: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showMcpToolCall(callId: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls/${callId}`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const call = await response.json() as PluginMCPToolCallApproval
    const args = JSON.stringify(JSON.parse(call.arguments_json) as unknown, null, 2)
    const action = call.status === "pending"
      ? `\nType /mcp call approve ${call.id} or /mcp call reject ${call.id}.`
      : ""
    skillNotice = `REVIEW MCP TOOL CALL  /  ${call.status.toUpperCase()}\n${safeTerminalReviewText(call.plugin_name)}/${safeTerminalReviewText(call.server_name)} · ${safeTerminalReviewText(call.tool_name)}\nOperation: ${call.operation_id}\nArguments (terminal control and direction characters are escaped):\n${safeTerminalReviewText(args)}${action}`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not inspect MCP tool call: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function actOnMcpToolCall(callId: string, action: "approve" | "reject") {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls/${callId}/${action}`, {
      method: "POST",
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    skillNotice = action === "approve"
      ? `Approved MCP call ${callId}. The server call may now run; the active Veasel turn will continue when it returns.`
      : `Rejected MCP call ${callId}. The server was not called.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not ${action} MCP tool call: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function notifyPendingMcpToolCalls() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls`, {
      signal: controller.signal,
    })
    if (!response.ok) return
    const calls = await response.json() as PluginMCPToolCallSummary[]
    const pending = calls.filter((call) => call.status === "pending")
    if (pending.length === 0) return
    skillNotice = `${pending.length} MCP tool call${pending.length === 1 ? "" : "s"} need review. The model turn is waiting and no pending call has reached its server. Type /mcp calls, inspect with /mcp call show <id>, then approve or reject.`
    chatInput?.focus()
    renderChat(chatMessages)
  } catch {
    // Keep the model turn usable if the optional approval notice cannot be loaded.
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
          let refreshSessionsForEvent = false
          for (const line of block.split(/\r?\n/)) {
            if (line.startsWith("id:")) lastEventId = line.slice(3).trim()
            if (line.startsWith("event:") && line.slice(6).trim() !== "heartbeat") {
              const eventType = line.slice(6).trim()
              refreshSessionsForEvent ||= eventType !== "assistant.delta"
              status.content = `● live  ·  ${eventType}`
              if (eventType === "assistant.delta" || eventType === "plugin.mcp_tool_call_pending"
                || eventType === "session.turn_completed") {
                const data = block.split(/\r?\n/).filter((item) => item.startsWith("data:"))
                  .map((item) => item.slice(5).trimStart()).join("\n")
                try {
                  const event = JSON.parse(data) as {
                    session_id?: string
                    data?: SessionTurnCompletion & { delta?: string }
                  }
                  if (eventType === "plugin.mcp_tool_call_pending" && event.session_id === activeSession?.id) {
                    void notifyPendingMcpToolCalls()
                  } else if (eventType === "assistant.delta" && activeSession && activeTurnId) {
                    const delta = event.data?.delta
                    if (event.session_id === activeSession.id
                      && event.data?.operation_id === activeTurnId
                      && typeof delta === "string" && delta.length > 0) {
                      streamingAssistantText += delta
                      renderChat(chatMessages)
                    }
                  } else if (eventType === "session.turn_completed" && event.session_id) {
                    void finishAsyncSessionTurn(event.session_id, event.data ?? {})
                  }
                } catch {
                  // Ignore malformed event payloads; the persisted turn remains authoritative.
                }
              }
            }
          }
          if (refreshSessionsForEvent) void refreshSessions()
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

const settingPrompts = [
  "Provider (openai-compatible, openai, anthropic, gemini):",
  "Model identifier (for example claude-sonnet-4-5 or gpt-5):",
  "API base URL (must use HTTPS, except loopback HTTP):",
  "API key (hidden; leave blank to keep saved key, type !clear to remove):",
]

function closeSettings(message = "Settings unchanged.") {
  if (settingsInput) detail.remove(settingsInput)
  if (settingsSecretIndicator) detail.remove(settingsSecretIndicator)
  settingsInput = undefined
  settingsSecretIndicator = undefined
  settingsValues.api_key = ""
  settingsOpen = false
  sessionDetail.content = "Your V-powered coding companion.\n\nChoose a session on the left, press n to start a workspace, or press s to configure your model provider."
  status.content = `● ${message}`
  status.fg = "#a7f3d0"
  if (activeSession) {
    const session = activeSession
    chatInput = undefined
    void openSession(session).catch(() => {
      status.content = "● settings saved · unable to restore session view"
      status.fg = "#f3c969"
    })
  }
}

function showSettingsStep() {
  if (settingsInput) detail.remove(settingsInput)
  if (settingsSecretIndicator) detail.remove(settingsSecretIndicator)
  settingsInput = undefined
  settingsSecretIndicator = undefined
  const active = settingsView?.active_provider ?? "openai-compatible"
  const prior = settingsView?.profiles[settingsValues.provider]
  const hint = settingsStep === 3
    ? `\n\n${prior?.api_key_saved ? "A key is already saved for this provider." : "No key is saved for this provider."} Key characters are hidden.`
    : ""
  sessionDetail.content = `MODEL SETTINGS  /  ${settingsStep + 1} OF 4\n\n${settingPrompts[settingsStep]}${hint}\n\nEnter accepts · Esc cancels`
  if (settingsStep === 3) {
    settingsSecretIndicator = new TextRenderable(renderer, {
      content: "",
      fg: "#a7f3d0",
    })
    detail.add(settingsSecretIndicator)
    return
  }
  const input = new InputRenderable(renderer, {
    id: `model-setting-${settingsStep}`,
    width: 58,
    placeholder: settingsStep === 0 ? active : settingsStep === 1 ? "model name" : settingsStep === 2 ? "https://api.example.com/v1" : "••••••••",
    backgroundColor: "#202832",
    focusedBackgroundColor: "#293640",
    textColor: "#e5e7eb",
    focusedTextColor: "#ffffff",
    cursorColor: "#a7f3d0",
    maxLength: 512,
  })
  settingsInput = input
  detail.add(input)
  input.focus()
  input.on(InputRenderableEvents.ENTER, (value) => {
    const clean = value.trim()
    if (settingsStep === 0) {
      settingsValues.provider = clean || active
      const profile = settingsView?.profiles[settingsValues.provider]
      settingsValues.model = profile?.model ?? ""
      settingsValues.base_url = profile?.base_url ?? ({ anthropic: "https://api.anthropic.com/v1", gemini: "https://generativelanguage.googleapis.com/v1beta", openai: "https://api.openai.com/v1", "openai-compatible": "https://api.openai.com/v1" }[settingsValues.provider] ?? "")
    } else if (settingsStep === 1) settingsValues.model = clean || settingsValues.model
    else if (settingsStep === 2) settingsValues.base_url = clean || settingsValues.base_url
    settingsStep++
    showSettingsStep()
  })
}

async function openSettings() {
  if (settingsOpen || creating || sendingMessage) return
  settingsOpen = true
  if (chatInput) {
    detail.remove(chatInput)
    chatInput = undefined
  }
  try {
    const response = await fetch(`${apiBase}/v1/config/model`, { signal: controller.signal })
    if (!response.ok) throw new Error("settings API unavailable")
    settingsView = await response.json() as ModelSettingsView
    settingsStep = 0
    settingsValues.provider = settingsView.active_provider
    settingsValues.model = ""
    settingsValues.base_url = ""
    settingsValues.api_key = ""
    settingsValues.clear_api_key = false
    showSettingsStep()
  } catch (error) {
    closeSettings(`could not load model settings · ${error instanceof Error ? error.message : "request failed"}`)
  }
}

async function saveModelSettings() {
  try {
    const response = await fetch(`${apiBase}/v1/config/model`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(settingsValues),
      signal: controller.signal,
    })
    if (!response.ok) {
      const body = await response.json().catch(() => ({})) as { error?: string }
      throw new Error(body.error ?? "settings were rejected")
    }
    settingsValues.api_key = ""
    closeSettings(`saved ${settingsValues.provider} · ${settingsValues.model}`)
  } catch (error) {
    settingsValues.api_key = ""
    closeSettings(`could not save settings · ${error instanceof Error ? error.message : "request failed"}`)
  }
}

renderer.keyInput.on("keypress", (key) => {
  if (settingsOpen) {
    if (key.name === "escape") closeSettings()
    else if (settingsStep === 3) {
      key.stopPropagation()
      if (key.name === "return" || key.name === "kpenter") {
        settingsValues.clear_api_key = settingsValues.api_key === "!clear"
        if (settingsValues.clear_api_key) settingsValues.api_key = ""
        void saveModelSettings()
      } else if (key.name === "backspace") {
        settingsValues.api_key = [...settingsValues.api_key].slice(0, -1).join("")
        if (settingsSecretIndicator) settingsSecretIndicator.content = "•".repeat([...settingsValues.api_key].length)
      } else if (!key.ctrl && !key.meta && /^[\x20-\x7e]+$/.test(key.sequence)) {
        const remaining = Math.max(0, 4096 - settingsValues.api_key.length)
        settingsValues.api_key += key.sequence.slice(0, remaining)
        if (settingsSecretIndicator) settingsSecretIndicator.content = "•".repeat([...settingsValues.api_key].length)
      }
    }
    return
  }
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
  else if (key.name === "s") void openSettings()
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

renderer.keyInput.on("paste", (event) => {
  if (!settingsOpen || settingsStep !== 3) return
  event.preventDefault()
  event.stopPropagation()
  const pasted = new TextDecoder().decode(event.bytes).replace(/[\x00-\x1f\x7f-\x9f]/g, "")
  const remaining = Math.max(0, 4096 - settingsValues.api_key.length)
  settingsValues.api_key += pasted.slice(0, remaining)
  if (settingsSecretIndicator) settingsSecretIndicator.content = "•".repeat([...settingsValues.api_key].length)
})

renderer.on("destroy", () => controller.abort())
await refreshSessions()
void consumeEvents()
