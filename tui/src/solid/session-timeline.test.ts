import { describe, expect, test } from "bun:test"
import { buildSessionTimeline, timelinePreview } from "./session-timeline"

describe("session timeline", () => {
  test("previews and truncates titles", () => {
    expect(timelinePreview("  hello   world  ")).toBe("hello world")
    expect(timelinePreview("x".repeat(80), 12)).toBe(`${"x".repeat(11)}…`)
    expect(timelinePreview("   ")).toBe("(empty)")
  })

  test("lists user turns newest-first with stable indexes", () => {
    const entries = buildSessionTimeline([
      { role: "user", content: "first" },
      { role: "assistant", content: "ok" },
      { role: "user", content: "second ask" },
      { role: "tool", content: "noise" },
    ])
    expect(entries.map((entry) => entry.content)).toEqual(["second ask", "first"])
    expect(entries[0]?.messageIndex).toBe(2)
    expect(entries[0]?.turn).toBe(2)
    expect(entries[1]?.turn).toBe(1)
    expect(entries[0]?.id).toBe("user-2")
  })
})
