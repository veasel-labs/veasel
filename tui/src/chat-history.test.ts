import { describe, expect, test } from "bun:test"
import { mergeChatTurns, pageMayHaveOlder, type ChatTurn } from "./chat-history"

function turn(id: number, content = `message ${id}`): ChatTurn {
  return {
    id,
    session_id: "session",
    role: id % 2 === 0 ? "assistant" : "user",
    content,
    created_at: `2026-10-12 00:00:${id.toString().padStart(2, "0")}`,
  }
}

describe("chat history pages", () => {
  test("merges older and refreshed messages once in chronological order", () => {
    const merged = mergeChatTurns([turn(4), turn(5)], [turn(1), turn(2), turn(3), turn(5, "updated")])

    expect(merged.map((message) => message.id)).toEqual([1, 2, 3, 4, 5])
    expect(merged.at(-1)?.content).toBe("updated")
  })

  test("requests another page only when the current page is full", () => {
    expect(pageMayHaveOlder([turn(1), turn(2)], 2)).toBe(true)
    expect(pageMayHaveOlder([turn(1)], 2)).toBe(false)
    expect(pageMayHaveOlder([], 2)).toBe(false)
  })
})
