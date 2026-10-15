import { describe, expect, test } from "bun:test"
import {
  formatBusyStatus,
  formatCancelledStatus,
  formatErrorStatus,
  formatHomeFilterStatus,
  formatHomeSessionStatus,
  formatStatusLine,
  formatStreamingBusyStatus,
  formatStreamingCharCount,
  formatWarnStatus,
  statusGlyph,
} from "./status-a11y"

describe("status a11y glyphs", () => {
  test("uses distinct markers per severity", () => {
    expect(statusGlyph("ok")).toBe("●")
    expect(statusGlyph("warn")).toBe("▲")
    expect(statusGlyph("error")).toBe("✖")
    expect(statusGlyph("busy")).toBe("◌")
    expect(formatStatusLine("error", "server unavailable")).toBe("✖ server unavailable")
  })

  test("marks in-flight work with busy glyph and spoken word", () => {
    expect(formatBusyStatus("Veasel is thinking…")).toBe("◌ busy  ·  Veasel is thinking…")
    expect(formatBusyStatus("cancelling response…")).toBe("◌ busy  ·  cancelling response…")
    expect(formatBusyStatus("reconnecting to event stream…")).toBe("◌ busy  ·  reconnecting to event stream…")
    expect(formatBusyStatus("busy  ·  already labeled")).toBe("◌ busy  ·  already labeled")
    expect(formatBusyStatus("Veasel is thinking…", { frame: 1 })).toBe("◍ busy  ·  Veasel is thinking…")
    expect(formatBusyStatus("Veasel is thinking…", { reducedMotion: true, frame: 1 })).toBe(
      "◌ busy  ·  Veasel is thinking…",
    )
  })

  test("reports measured streaming character growth without inventing tokens", () => {
    expect(formatStreamingCharCount(0)).toBe("0 chars")
    expect(formatStreamingCharCount(42)).toBe("42 chars")
    expect(formatStreamingCharCount(1500)).toBe("1.5k chars")
    expect(formatStreamingCharCount(12_400)).toBe("12k chars")
    expect(formatStreamingBusyStatus(0)).toBe("◌ busy  ·  Veasel is thinking…")
    expect(formatStreamingBusyStatus(42)).toBe("◌ busy  ·  streaming  ·  42 chars")
  })

  test("marks warn and error rows with spoken severity words", () => {
    expect(formatWarnStatus("pending review")).toBe("▲ attention  ·  pending review")
    expect(formatErrorStatus("message failed  ·  boom")).toBe("✖ error  ·  message failed  ·  boom")
    expect(formatErrorStatus("error  ·  already labeled")).toBe("✖ error  ·  already labeled")
  })

  test("marks cancelled turns with spoken cancelled instead of attention", () => {
    expect(formatCancelledStatus("response cancelled")).toBe("▲ cancelled  ·  response cancelled")
    expect(formatCancelledStatus("turn cancelled")).toBe("▲ cancelled  ·  turn cancelled")
    expect(formatCancelledStatus("cancelled  ·  already labeled")).toBe("▲ cancelled  ·  already labeled")
    expect(formatCancelledStatus("")).toBe("▲ cancelled")
  })

  test("states the focused session in plain text on home", () => {
    expect(formatHomeSessionStatus(0, 0)).toBe("● connected  ·  no sessions yet")
    expect(formatHomeSessionStatus(0, 20)).toBe("● connected  ·  session 1 of 20 selected")
    expect(formatHomeSessionStatus(19, 20)).toBe("● connected  ·  session 20 of 20 selected")
  })

  test("states filter matches and the focused match in plain text", () => {
    expect(formatHomeFilterStatus(0, 1, 20, "Lane")).toBe(
      "● connected  ·  filter  ·  session 1 of 1 match “Lane” (20 total)",
    )
    expect(formatHomeFilterStatus(0, 0, 20, "zzz")).toBe(
      "● connected  ·  filter  ·  0 of 20 match “zzz”",
    )
    expect(formatHomeFilterStatus(2, 5, 20, "")).toBe(
      "● connected  ·  session 3 of 20 selected",
    )
  })
})
