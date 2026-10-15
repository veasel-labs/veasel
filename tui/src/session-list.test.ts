import { describe, expect, test } from "bun:test"
import {
  filterSessionList,
  formatSessionFilterHeader,
  formatSessionList,
  moveSessionSelection,
  sessionListCapacity,
  sessionListColumns,
  sessionSidebarWidth,
} from "./session-list"

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
    expect(text).not.toContain("Selected")
  })

  test("keeps the selected session on screen and states its position", () => {
    expect(sessionListCapacity(40, 20)).toBeLessThan(20)
    const text = formatSessionList(sessions, 19, { rows: 40, columns: 36 })
    expect(text.startsWith("Selected 20 of 20\n")).toBe(true)
    expect(text).toContain("● Lane-19")
    expect(text).not.toContain("Alpha")
    expect(text).not.toContain("Lane-01")
  })

  test("returns to the first session after moving back up", () => {
    const text = formatSessionList(sessions, 0, { rows: 40, columns: 36 })
    expect(text.startsWith("Selected 1 of 20\n")).toBe(true)
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

describe("filterSessionList", () => {
  test("keeps every session when the filter is empty", () => {
    expect(filterSessionList(sessions, "")).toEqual(sessions)
    expect(filterSessionList(sessions, "   ")).toEqual(sessions)
  })

  test("matches title and directory tokens", () => {
    expect(filterSessionList(sessions, "Alpha").map((session) => session.title)).toEqual(["Alpha"])
    expect(filterSessionList(sessions, "lane-19").map((session) => session.title)).toEqual(["Lane-19"])
    expect(filterSessionList(sessions, "lane 03").map((session) => session.title)).toEqual(["Lane-03"])
    expect(filterSessionList(sessions, "zzz")).toEqual([])
  })

  test("states the filter in the list header", () => {
    expect(formatSessionFilterHeader(1, 20, "Alpha")).toContain("1/20 match “Alpha”")
    const text = formatSessionList(filterSessionList(sessions, "Alpha"), 0, {
      rows: 40,
      columns: 36,
      filter: "Alpha",
      totalCount: 20,
    })
    expect(text).toContain("Filter  1/20 match “Alpha”")
    expect(text).toContain("Selected 1 of 1")
    expect(text).toContain("● Alpha")
    expect(formatSessionList([], 0, { rows: 40, columns: 24, filter: "zzz" })).toContain("No sessions match")
  })
})

describe("moveSessionSelection", () => {
  test("moves by one and jumps to edges without wrapping", () => {
    expect(moveSessionSelection(5, 20, "up", 4)).toBe(4)
    expect(moveSessionSelection(5, 20, "down", 4)).toBe(6)
    expect(moveSessionSelection(5, 20, "home", 4)).toBe(0)
    expect(moveSessionSelection(5, 20, "end", 4)).toBe(19)
    expect(moveSessionSelection(5, 20, "pageup", 4)).toBe(1)
    expect(moveSessionSelection(5, 20, "pagedown", 4)).toBe(9)
    expect(moveSessionSelection(0, 20, "up", 4)).toBe(0)
    expect(moveSessionSelection(19, 20, "down", 4)).toBe(19)
    expect(moveSessionSelection(1, 20, "pageup", 4)).toBe(0)
    expect(moveSessionSelection(18, 20, "pagedown", 4)).toBe(19)
  })
})
