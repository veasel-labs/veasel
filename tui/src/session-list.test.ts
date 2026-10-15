import { describe, expect, test } from "bun:test"
import { formatSessionList, sessionListCapacity, sessionListColumns, sessionSidebarWidth } from "./session-list"

const sessions = Array.from({ length: 20 }, (_, index) => ({
  title: index === 0 ? "Alpha" : `Lane-${String(index).padStart(2, "0")}`,
  directory: `/tmp/workspaces/very-long-directory/lane-${String(index).padStart(2, "0")}`,
}))

describe("formatSessionList", () => {
  test("explains an empty home screen", () => {
    expect(formatSessionList([], 0, { rows: 40, columns: 24 })).toBe("No sessions yet.\n\nPress n to start one.")
  })

  test("shows a short list without a position counter", () => {
    const text = formatSessionList(sessions.slice(0, 2), 1, { rows: 40, columns: 40 })
    expect(text.startsWith("●")).toBe(false)
    expect(text).toContain("● Lane-01")
    expect(text).toContain("○ Alpha")
    expect(text).not.toContain("1/2")
    expect(text).not.toContain("2/2")
  })

  test("keeps the selected session on screen and states its position", () => {
    expect(sessionListCapacity(40, 20)).toBeLessThan(20)
    const text = formatSessionList(sessions, 19, { rows: 40, columns: 36 })
    expect(text.startsWith("20/20\n")).toBe(true)
    expect(text).toContain("● Lane-19")
    expect(text).not.toContain("Alpha")
    expect(text).not.toContain("Lane-01")
  })

  test("returns to the first session after moving back up", () => {
    const text = formatSessionList(sessions, 0, { rows: 40, columns: 36 })
    expect(text.startsWith("1/20\n")).toBe(true)
    expect(text).toContain("● Alpha")
    expect(text).not.toContain("Lane-19")
  })

  test("reserves the sidebar text width inside the border and padding", () => {
    expect(sessionListColumns(100)).toBe(sessionSidebarWidth(100) - 4)
    expect(sessionListColumns(100)).toBeLessThanOrEqual(28)
  })

  test("clips a long directory from the start so the workspace name stays visible", () => {
    const columns = sessionListColumns(80)
    const text = formatSessionList(sessions.slice(0, 1), 0, { rows: 40, columns })
    const directory = text.split("\n")[1] ?? ""
    expect(directory.endsWith("lane-00")).toBe(true)
    expect(directory.startsWith("  …")).toBe(true)
    expect([...directory].length).toBeLessThanOrEqual(columns)
  })

  test("strips control characters from titles before they can wrap", () => {
    const text = formatSessionList([{ title: "Alpha\nBeta\tGamma", directory: "/tmp/alpha" }], 0, { rows: 40, columns: 40 })
    expect(text).toContain("● Alpha Beta Gamma")
    expect(text).not.toContain("\nBeta")
  })
})
