import { describe, expect, test } from "bun:test"
import {
  findAdjacentMessageTarget,
  findLastUserMessageTarget,
  findMessageBoundaryByScroll,
  listMessageNavTargets,
  messageNavShortcut,
} from "./transcript-nav"

const sample = [
  { role: "user", content: "first question", id: 1 },
  { role: "assistant", content: "first answer", id: 2 },
  { role: "tool", content: "read: foo.ts", id: 3 },
  { role: "user", content: "   ", id: 4 },
  { role: "user", content: "second question", id: 5 },
  { role: "assistant", content: "second answer", id: 6 },
] as const

describe("transcript message navigation", () => {
  test("documents Alt+[ / ] / End shortcuts", () => {
    expect(messageNavShortcut.previousUser.label).toBe("Alt+[")
    expect(messageNavShortcut.nextUser.label).toBe("Alt+]")
    expect(messageNavShortcut.lastUser.label).toBe("Alt+End")
    expect(messageNavShortcut.previousUser.meta).toBe(true)
  })

  test("lists user-only targets and skips empty / tool roles", () => {
    const users = listMessageNavTargets(sample, { userOnly: true })
    expect(users.map((item) => item.index)).toEqual([0, 4])
    expect(users.map((item) => item.content)).toEqual(["first question", "second question"])

    const all = listMessageNavTargets(sample)
    expect(all.map((item) => item.index)).toEqual([0, 1, 4, 5])
  })

  test("finds adjacent targets from a cursor index", () => {
    const users = listMessageNavTargets(sample, { userOnly: true })
    expect(findAdjacentMessageTarget({ targets: users, currentIndex: 0, direction: "next" })?.index).toBe(4)
    expect(findAdjacentMessageTarget({ targets: users, currentIndex: 4, direction: "prev" })?.index).toBe(0)
    expect(
      findAdjacentMessageTarget({ targets: users, currentIndex: 0, direction: "prev" }),
    ).toBeUndefined()
    expect(
      findAdjacentMessageTarget({ targets: users, currentIndex: undefined, direction: "prev" })?.index,
    ).toBe(4)
    expect(
      findAdjacentMessageTarget({ targets: users, currentIndex: undefined, direction: "next" })?.index,
    ).toBe(0)
  })

  test("steps from a non-target cursor (tool row) to the next user", () => {
    const users = listMessageNavTargets(sample, { userOnly: true })
    expect(findAdjacentMessageTarget({ targets: users, currentIndex: 2, direction: "next" })?.index).toBe(4)
    expect(findAdjacentMessageTarget({ targets: users, currentIndex: 2, direction: "prev" })?.index).toBe(0)
  })

  test("finds the last user message", () => {
    expect(findLastUserMessageTarget(sample)?.index).toBe(4)
    expect(findLastUserMessageTarget([])).toBeUndefined()
  })

  test("scroll boundary prefers geometry when cursor is unset", () => {
    const children = [
      { index: 0, y: 2 },
      { index: 4, y: 40 },
      { index: 5, y: 60 },
    ]
    expect(
      findMessageBoundaryByScroll({
        direction: "prev",
        children,
        scrollTop: 45,
      })?.index,
    ).toBe(4)
    expect(
      findMessageBoundaryByScroll({
        direction: "next",
        children,
        scrollTop: 10,
      })?.index,
    ).toBe(4)
    expect(
      findMessageBoundaryByScroll({
        direction: "next",
        children,
        scrollTop: 10,
        currentIndex: 4,
      })?.index,
    ).toBe(5)
  })
})
