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
  }>
}

type SessionPluginSkill = {
  plugin_name: string
  skill_name: string
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
  content: "n new session   /skills list   /skill on|off plugin/skill   ↑/↓ navigate   q quit",
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
let chatMessages: ChatTurn[] = []
let skillNotice = ""

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
    ? `SESSION  /  ${activeSession.title}\n${activeSession.directory}\n\nWORKSPACE / DATA FLOW\nWhen Veasel uses read-only workspace tools, returned file excerpts are sent to your configured model provider.\n\n`
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
  return value.replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, "")
}

async function openSession(session: Session) {
  activeSession = session
  skillNotice = ""
  renderChat([])
  const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(session.id)}/messages`, {
    signal: controller.signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  renderChat(await response.json() as ChatTurn[])
  if (!chatInput) {
    const input = new InputRenderable(renderer, {
      id: "chat-composer",
      width: "100%",
      placeholder: "Ask Veasel to explain or change something…",
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
  chatInput.value = ""
  chatInput.blur()
  status.content = "● Veasel is thinking…"
  status.fg = "#f3c969"
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content }),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const exchange = await response.json() as ChatExchange
    const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      signal: controller.signal,
    })
    if (!historyResponse.ok) throw new Error(`HTTP ${historyResponse.status}`)
    renderChat(await historyResponse.json() as ChatTurn[])
    status.content = `● ${exchange.provider}  ·  ${exchange.model}`
    status.fg = "#a7f3d0"
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● message failed  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = "#f28b82"
  } finally {
    sendingMessage = false
    chatInput?.focus()
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
