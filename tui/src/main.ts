import {
  BoxRenderable,
  InputRenderable,
  InputRenderableEvents,
  TextRenderable,
  createCliRenderer,
} from "@opentui/core"

type Session = {
  id: string
  title: string
  directory: string
  created_at: string
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
detail.add(new TextRenderable(renderer, { content: "YOUR WORK, KEPT CLOSE", fg: "#a7f3d0" }))
const sessionDetail = new TextRenderable(renderer, {
  content: "Choose a session on the left, or start a fresh workspace.\n\nVeasel keeps session history on this machine and streams updates as they happen.",
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
  content: "n new session   ↑/↓ navigate   enter open   r refresh   q quit",
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
    sessionDetail.content = `SESSION  /  ${session.title}\n\nid  ${session.id}\npath  ${session.directory}\ncreated  ${session.created_at}\n\nThis session is ready. Agent execution is coming in the next milestone.`
  }
})

renderer.on("destroy", () => controller.abort())
await refreshSessions()
void consumeEvents()
