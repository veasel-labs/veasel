import { describe, expect, test } from "bun:test"
import {
  clearSessionUnread,
  formatSessionTabLabel,
  markSessionUnread,
  moveSessionTabIndex,
  sessionTabsLayout,
  sessionTabUnreadMarker,
  sessionTabsFromEntries,
  truncateTabTitle,
  visibleSessionTabs,
} from "./session-tabs"

describe("session tabs helpers", () => {
  test("truncates long titles", () => {
    expect(truncateTabTitle("short")).toBe("short")
    expect(truncateTabTitle("this title is definitely too long for a tab", 12)).toBe("this title…")
  })

  test("wraps tab index when moving", () => {
    expect(moveSessionTabIndex(0, -1, 3)).toBe(2)
    expect(moveSessionTabIndex(2, 1, 3)).toBe(0)
    expect(moveSessionTabIndex(1, 1, 3)).toBe(2)
  })

  test("keeps active tab inside a capped visible window", () => {
    const tabs = sessionTabsFromEntries(
      Array.from({ length: 10 }, (_, index) => ({ id: `s${index}`, title: `T${index}` })),
    )
    const mid = visibleSessionTabs(tabs, "s5", 4)
    expect(mid.tabs.map((tab) => tab.id)).toEqual(["s3", "s4", "s5", "s6"])
    expect(mid.overflowLeft).toBe(3)
    expect(mid.overflowRight).toBe(3)

    const head = visibleSessionTabs(tabs, "s0", 4)
    expect(head.tabs[0]?.id).toBe("s0")
    expect(head.overflowLeft).toBe(0)

    const all = visibleSessionTabs(tabs.slice(0, 3), "s1", 6)
    expect(all.overflowLeft + all.overflowRight).toBe(0)
  })

  test("fits the session rail to narrow terminals and widens titles when space allows", () => {
    const tabs = sessionTabsFromEntries(
      Array.from({ length: 20 }, (_, index) => ({ id: `s${index}`, title: `Session ${index} with a long title` })),
    )
    const narrow = sessionTabsLayout(tabs, "s10", 32, { showNew: true, showClose: true })
    const wide = sessionTabsLayout(tabs, "s10", 120, { showNew: true, showClose: true })

    expect(narrow.tabs.some((tab) => tab.id === "s10")).toBe(true)
    expect(narrow.overflowLeft).toBeGreaterThan(0)
    expect(narrow.overflowRight).toBeGreaterThan(0)
    expect(narrow.showNew).toBe(true)
    expect(narrow.showClose).toBe(true)
    expect(wide.titleWidth).toBeGreaterThan(narrow.titleWidth)
    expect(wide.tabs.length).toBe(6)
  })

  test("truncates session titles by terminal-cell width", () => {
    expect(formatSessionTabLabel({ id: "wide", title: "你好 Veasel", unread: true }, 7)).toBe("● 你好…")
    expect(formatSessionTabLabel({ id: "unread", title: "Session", unread: true }, 1)).toBe("●")
    expect(truncateTabTitle("你好", 1)).toBe("…")
  })

  test("marks unread for background sessions only", () => {
    const marked = markSessionUnread({}, "bg", "fg")
    expect(marked).toEqual({ bg: true })
    expect(markSessionUnread(marked, "fg", "fg")).toEqual({ bg: true })
    expect(clearSessionUnread(marked, "bg")).toEqual({})
  })

  test("projects unread onto tab entries and formats labels", () => {
    const tabs = sessionTabsFromEntries(
      [
        { id: "a", title: "Alpha" },
        { id: "b", title: "Beta session with a long title" },
      ],
      { b: true },
    )
    expect(tabs[0]?.unread).toBe(false)
    expect(tabs[1]?.unread).toBe(true)
    expect(formatSessionTabLabel(tabs[0]!)).toBe("Alpha")
    expect(formatSessionTabLabel(tabs[1]!, 12)).toBe(`${sessionTabUnreadMarker} Beta sess…`)
  })
})
