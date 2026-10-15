import { describe, expect, test } from "bun:test"
import { formatHomeSessionStatus, formatStatusLine, statusGlyph } from "./status-a11y"

describe("status a11y glyphs", () => {
  test("uses distinct markers per severity", () => {
    expect(statusGlyph("ok")).toBe("●")
    expect(statusGlyph("warn")).toBe("▲")
    expect(statusGlyph("error")).toBe("✖")
    expect(statusGlyph("busy")).toBe("◌")
    expect(formatStatusLine("error", "server unavailable")).toBe("✖ server unavailable")
  })

  test("states the focused session in plain text on home", () => {
    expect(formatHomeSessionStatus(0, 0)).toBe("● connected  ·  no sessions yet")
    expect(formatHomeSessionStatus(0, 20)).toBe("● connected  ·  session 1 of 20 selected")
    expect(formatHomeSessionStatus(19, 20)).toBe("● connected  ·  session 20 of 20 selected")
  })
})
