// Status chrome that stays readable without relying on color alone.
// Distinct glyphs plus spoken words ("attention", "error", "selected") help
// high-contrast terminals and screen-reader-ish copy/paste of the status row.

export type StatusLevel = "ok" | "warn" | "error" | "busy"

export function statusGlyph(level: StatusLevel): string {
  if (level === "ok") return "●"
  if (level === "warn") return "▲"
  if (level === "error") return "✖"
  return "◌"
}

export function formatStatusLine(level: StatusLevel, message: string): string {
  return `${statusGlyph(level)} ${message}`
}

// In-flight turns and reconnects: ◌ plus the spoken word "busy" so the row
// stays meaningful when color is flat or when the status is copied as text.
export function formatBusyStatus(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("busy", "busy")
  if (/^busy\b/i.test(trimmed)) return formatStatusLine("busy", trimmed)
  return formatStatusLine("busy", `busy  ·  ${trimmed}`)
}

export function formatWarnStatus(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("warn", "attention")
  if (/^attention\b/i.test(trimmed)) return formatStatusLine("warn", trimmed)
  return formatStatusLine("warn", `attention  ·  ${trimmed}`)
}

export function formatErrorStatus(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("error", "error")
  if (/^error\b/i.test(trimmed)) return formatStatusLine("error", trimmed)
  return formatStatusLine("error", `error  ·  ${trimmed}`)
}

// Home session switcher cue: always states which session is focused so the
// selection is not only the ● marker in the sidebar.
export function formatHomeSessionStatus(selected: number, count: number): string {
  if (count <= 0) return formatStatusLine("ok", "connected  ·  no sessions yet")
  const index = Math.min(Math.max(0, selected), count - 1)
  return formatStatusLine("ok", `connected  ·  session ${index + 1} of ${count} selected`)
}

// Home type-to-filter cue: spoken "filter" plus which match is focused so the
// status row stays meaningful when color is flat or when copied as text.
export function formatHomeFilterStatus(
  selected: number,
  matched: number,
  total: number,
  filter: string,
): string {
  const trimmed = filter.trim()
  if (!trimmed) return formatHomeSessionStatus(selected, total)
  if (matched <= 0) {
    return formatStatusLine("ok", `connected  ·  filter  ·  0 of ${total} match “${trimmed}”`)
  }
  const index = Math.min(Math.max(0, selected), matched - 1)
  return formatStatusLine(
    "ok",
    `connected  ·  filter  ·  session ${index + 1} of ${matched} match “${trimmed}” (${total} total)`,
  )
}
