// Status chrome that stays readable without relying on color alone.
// Distinct glyphs plus spoken words ("attention", "error", "selected") help
// high-contrast terminals and screen-reader-ish copy/paste of the status row.

import { busyGlyphForMotion } from "./reduced-motion"

export type StatusLevel = "ok" | "warn" | "error" | "busy"

export type BusyStatusOptions = {
  reducedMotion?: boolean
  frame?: number
}

export function statusGlyph(level: StatusLevel, options: BusyStatusOptions = {}): string {
  if (level === "ok") return "●"
  if (level === "warn") return "▲"
  if (level === "error") return "✖"
  return busyGlyphForMotion(Boolean(options.reducedMotion), options.frame ?? 0)
}

export function formatStatusLine(level: StatusLevel, message: string, options: BusyStatusOptions = {}): string {
  return `${statusGlyph(level, options)} ${message}`
}

// In-flight turns and reconnects: ◌ (or a quiet frame under reduced motion)
// plus the spoken word "busy" so the row stays meaningful when color is flat
// or when the status is copied as text.
export function formatBusyStatus(message: string, options: BusyStatusOptions = {}): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("busy", "busy", options)
  if (/^busy\b/i.test(trimmed)) return formatStatusLine("busy", trimmed, options)
  return formatStatusLine("busy", `busy  ·  ${trimmed}`, options)
}

// Compact measured length for the streaming busy cue (not a token estimate).
export function formatStreamingCharCount(chars: number): string {
  const n = Math.max(0, Math.floor(chars))
  if (n < 1000) return `${n} chars`
  const k = n / 1000
  if (k >= 10) return `${Math.round(k)}k chars`
  return `${k.toFixed(1).replace(/\.0$/, "")}k chars`
}

// In-flight assistant deltas: keep ◌ busy, speak "streaming", and show measured
// character growth so operators see progress without color alone.
export function formatStreamingBusyStatus(chars: number, options: BusyStatusOptions = {}): string {
  if (chars <= 0) return formatBusyStatus("Veasel is thinking…", options)
  return formatBusyStatus(`streaming  ·  ${formatStreamingCharCount(chars)}`, options)
}

// Successful idle/action cues: ● plus spoken "ok" so success is not only a
// green glyph when color is flat or the row is copied as text.
export function formatOkStatus(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("ok", "ok")
  if (/^ok\b/i.test(trimmed)) return formatStatusLine("ok", trimmed)
  return formatStatusLine("ok", `ok  ·  ${trimmed}`)
}

export function formatWarnStatus(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("warn", "attention")
  if (/^attention\b/i.test(trimmed)) return formatStatusLine("warn", trimmed)
  return formatStatusLine("warn", `attention  ·  ${trimmed}`)
}

// Esc cancel / server-cancelled turns: ▲ plus spoken "cancelled" so the row
// stays meaningful without color and does not look like a generic attention cue.
export function formatCancelledStatus(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return formatStatusLine("warn", "cancelled")
  if (/^cancelled\b/i.test(trimmed)) return formatStatusLine("warn", trimmed)
  return formatStatusLine("warn", `cancelled  ·  ${trimmed}`)
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
