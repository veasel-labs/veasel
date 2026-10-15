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

// Home session switcher cue: always states which session is focused so the
// selection is not only the ● marker in the sidebar.
export function formatHomeSessionStatus(selected: number, count: number): string {
  if (count <= 0) return formatStatusLine("ok", "connected  ·  no sessions yet")
  const index = Math.min(Math.max(0, selected), count - 1)
  return formatStatusLine("ok", `connected  ·  session ${index + 1} of ${count} selected`)
}
