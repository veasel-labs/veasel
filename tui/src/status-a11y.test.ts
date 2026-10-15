import { describe, expect, test } from "bun:test"
import { formatBusyStatus, formatHomeSessionStatus, formatStatusLine, statusGlyph } from "./status-a11y"

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
  })

  test("states the focused session in plain text on home", () => {
    expect(formatHomeSessionStatus(0, 0)).toBe("● connected  ·  no sessions yet")
    expect(formatHomeSessionStatus(0, 20)).toBe("● connected  ·  session 1 of 20 selected")
    expect(formatHomeSessionStatus(19, 20)).toBe("● connected  ·  session 20 of 20 selected")
  })
})
