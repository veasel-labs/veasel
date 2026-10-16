import { describe, expect, test } from "bun:test"
import {
  activityGroupHeader,
  activityGroupStatus,
  activityItemLine,
  activityToggleShortcut,
  defaultGroupExpanded,
  isGroupExpanded,
  latestActivityGroupId,
  parseToolName,
  projectTranscriptBlocks,
  summarizeActivityGroup,
  toggleGroupExpanded,
  toolCallFromMessage,
  type ToolAwareMessage,
} from "./activity-group"

describe("activity grouping helpers", () => {
  test("documents Ctrl+G as the activity toggle (not Ctrl+P)", () => {
    expect(activityToggleShortcut.label).toBe("Ctrl+G")
    expect(activityToggleShortcut.name).toBe("g")
    expect(activityToggleShortcut.ctrl).toBe(true)
  })

  test("groups consecutive tool roles and leaves chat turns alone", () => {
    const messages: ToolAwareMessage[] = [
      { role: "user", content: "inspect main" },
      { role: "tool", content: "read: src/main.v", toolName: "read", toolStatus: "done" },
      { role: "tool", content: "grep: turnKind", toolName: "grep", toolStatus: "done" },
      { role: "assistant", content: "found the helper" },
      { role: "tool", content: "shell: v test", toolName: "shell", toolStatus: "running" },
    ]
    const blocks = projectTranscriptBlocks(messages)
    expect(blocks.map((block) => block.type)).toEqual(["messages", "activity", "messages", "activity"])
    expect(blocks[1]).toMatchObject({
      type: "activity",
      items: [
        { name: "read", status: "done" },
        { name: "grep", status: "done" },
      ],
    })
    expect(blocks[3]).toMatchObject({
      type: "activity",
      items: [{ name: "shell", status: "running" }],
    })
  })

  test("aggregates status with error > running > done", () => {
    expect(
      activityGroupStatus([
        toolCallFromMessage({ role: "tool", content: "read ok", toolStatus: "done" }, 0),
        toolCallFromMessage({ role: "tool", content: "shell…", toolStatus: "running" }, 1),
      ]),
    ).toBe("running")
    expect(
      activityGroupStatus([
        toolCallFromMessage({ role: "tool", content: "read ok", toolStatus: "done" }, 0),
        toolCallFromMessage({ role: "tool", content: "failed", toolStatus: "error" }, 1),
        toolCallFromMessage({ role: "tool", content: "shell…", toolStatus: "running" }, 2),
      ]),
    ).toBe("error")
    expect(
      activityGroupStatus([
        toolCallFromMessage({ role: "tool", content: "read ok", toolStatus: "done" }, 0),
      ]),
    ).toBe("done")
  })

  test("summarizes activity with spoken status-a11y labels", () => {
    const done = summarizeActivityGroup([
      toolCallFromMessage({ role: "tool", content: "read: a", toolName: "read", toolStatus: "done" }, 0),
      toolCallFromMessage({ role: "tool", content: "grep: b", toolName: "grep", toolStatus: "done" }, 1),
    ])
    expect(done.statusWord).toBe("done")
    expect(done.label).toContain("ok")
    expect(done.label).toContain("2 tools")

    const running = summarizeActivityGroup([
      toolCallFromMessage({ role: "tool", content: "read…", toolName: "read", toolStatus: "running" }, 0),
    ])
    expect(running.statusWord).toBe("running")
    expect(running.label).toContain("busy")
    expect(running.label).toContain("Running read")

    const failed = summarizeActivityGroup([
      toolCallFromMessage({ role: "tool", content: "boom", toolName: "shell", toolStatus: "error" }, 0),
    ])
    expect(failed.statusWord).toBe("error")
    expect(failed.label).toContain("error")
    expect(failed.label).toContain("1 failed")
  })

  test("header and item lines stay readable without color", () => {
    const items = [
      toolCallFromMessage({ role: "tool", content: "read: src/main.v", toolName: "read", toolStatus: "done" }, 0),
      toolCallFromMessage({ role: "tool", content: "grep: foo", toolName: "grep", toolStatus: "done" }, 1),
    ]
    expect(activityGroupHeader(items, false)).toMatch(/^▸ activity/)
    expect(activityGroupHeader(items, true)).toMatch(/^▾ activity/)
    expect(activityItemLine(items[0]!)).toContain("read")
    expect(activityItemLine(items[0]!)).toContain("done")
    expect(activityItemLine(items[0]!)).toContain("src/main.v")
  })

  test("toggle and default disclosure prefer open while running", () => {
    const running = [toolCallFromMessage({ role: "tool", content: "x", toolStatus: "running" }, 0)]
    const done = [toolCallFromMessage({ role: "tool", content: "x", toolStatus: "done" }, 0)]
    expect(defaultGroupExpanded(running)).toBe(true)
    expect(defaultGroupExpanded(done)).toBe(false)
    expect(isGroupExpanded({}, "g1", running)).toBe(true)
    expect(isGroupExpanded({}, "g1", done)).toBe(false)
    expect(toggleGroupExpanded({}, "g1")).toEqual({ g1: true })
    expect(toggleGroupExpanded({ g1: true }, "g1")).toEqual({ g1: false })
    expect(toggleGroupExpanded({ g1: false }, "g1", true)).toEqual({ g1: true })
  })

  test("latestActivityGroupId points at the trailing activity block", () => {
    const blocks = projectTranscriptBlocks([
      { role: "user", content: "hi" },
      { role: "tool", content: "read a", toolStatus: "done" },
      { role: "assistant", content: "ok" },
      { role: "tool", content: "grep b", toolStatus: "done" },
    ])
    expect(latestActivityGroupId(blocks)).toBe("activity-3-3")
  })

  test("parses tool names from content when metadata is absent", () => {
    expect(parseToolName("read: src/main.v")).toBe("read")
    expect(parseToolName("grep pattern", "Grep")).toBe("Grep")
    expect(parseToolName("just some output")).toBe("just")
  })
})
