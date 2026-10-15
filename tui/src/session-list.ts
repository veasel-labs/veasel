import { suggestionWindow } from "./slash-commands"

export type SessionListEntry = {
  title: string
  directory: string
}

export type SessionListMove = "up" | "down" | "home" | "end" | "pageup" | "pagedown"

// Home/End and page keys jump without wrapping past the list edges, matching
// slash-menu navigation so operators transfer muscle memory from / commands.
export function moveSessionSelection(
  selected: number,
  count: number,
  action: SessionListMove,
  pageSize: number,
): number {
  if (count <= 0) return 0
  const max = count - 1
  const index = Math.min(Math.max(0, selected), max)
  const page = Math.max(1, pageSize)
  if (action === "up") return Math.max(0, index - 1)
  if (action === "down") return Math.min(max, index + 1)
  if (action === "home") return 0
  if (action === "end") return max
  if (action === "pageup") return Math.max(0, index - page)
  return Math.min(max, index + page)
}

// Sidebar chrome outside the session text: shell padding, header, footer,
// gaps, and the sidebar border, padding, and "SESSIONS" label.
const reservedRows = 17

function fits(count: number, rows: number): boolean {
  if (count <= 0) return true
  return 3 * count - 1 <= rows
}

// How many sessions the home sidebar can show without wrapping a row away.
export function sessionListCapacity(terminalRows: number, count: number): number {
  const listRows = Math.max(1, terminalRows - reservedRows)
  if (fits(count, listRows)) return Math.max(count, 0)
  const body = Math.max(1, listRows - 1)
  let visible = 1
  while (fits(visible + 1, body)) visible++
  return visible
}

// Explicit sidebar width. A percentage shrinks once the detail pane takes its
// padding, and a wrapped directory then pushes the selected session off screen.
export function sessionSidebarWidth(terminalColumns: number): number {
  return Math.max(24, Math.min(42, Math.floor(terminalColumns * 0.32)))
}

export function sessionListColumns(terminalColumns: number): number {
  return Math.max(12, sessionSidebarWidth(terminalColumns) - 4)
}

function clean(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/ {2,}/g, " ").trim()
}

function clipStart(value: string, width: number): string {
  const chars = [...value]
  if (chars.length <= width) return value
  if (width <= 1) return "…"
  return `${chars.slice(0, width - 1).join("")}…`
}

function clipEnd(value: string, width: number): string {
  const chars = [...value]
  if (chars.length <= width) return value
  if (width <= 1) return "…"
  return `…${chars.slice(chars.length - (width - 1)).join("")}`
}

// Renders the home session list. A selection past the visible rows stays on
// screen, and the position is spoken as plain text so it does not depend on
// color ("Selected 8 of 20" for screen readers and high-contrast terminals).
export function formatSessionList(
  sessions: SessionListEntry[],
  selected: number,
  options: { rows: number; columns: number },
): string {
  if (sessions.length === 0) return "No sessions yet.\n\nPress n to start one."
  const width = Math.max(4, options.columns)
  const index = Math.min(Math.max(0, selected), sessions.length - 1)
  const capacity = sessionListCapacity(options.rows, sessions.length)
  const { start, end } = suggestionWindow(index, sessions.length, capacity)
  const lines: string[] = []
  if (end - start < sessions.length) {
    lines.push(`Selected ${index + 1} of ${sessions.length}`)
  }
  for (let cursor = start; cursor < end; cursor++) {
    const session = sessions[cursor]
    if (!session) continue
    const marker = cursor === index ? "●" : "○"
    const title = clipStart(clean(session.title) || "Untitled session", width - 2)
    const directory = clipEnd(clean(session.directory), width - 2)
    lines.push(`${marker} ${title}`, `  ${directory}`)
    if (cursor < end - 1) lines.push("")
  }
  return lines.join("\n")
}
