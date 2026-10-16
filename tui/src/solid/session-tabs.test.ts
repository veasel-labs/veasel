import { describe, expect, test } from "bun:test"
import {
  moveSessionTabIndex,
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
})
