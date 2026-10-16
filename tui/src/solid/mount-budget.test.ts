import { describe, expect, test } from "bun:test"
import type { TranscriptBlock } from "./activity-group"
import {
  blockMountWeight,
  blocksAfter,
  blocksBefore,
  mountCueAbove,
  windowBlocks,
} from "./mount-budget"

function messages(id: string): TranscriptBlock {
  return { type: "messages", id, messages: [{ role: "user", content: id }], startIndex: 0 }
}

function activity(id: string, count: number): TranscriptBlock {
  return {
    type: "activity",
    id,
    items: Array.from({ length: count }, (_, index) => ({
      id: `${id}-${index}`,
      name: "tool",
      detail: "x",
      status: "done" as const,
      messageIndex: index,
    })),
  }
}

describe("Solid transcript mount budget", () => {
  test("collapsed activity costs 1; expanded costs 1 + items", () => {
    const group = activity("g1", 4)
    expect(blockMountWeight(group, () => false)).toBe(1)
    expect(blockMountWeight(group, () => true)).toBe(5)
    expect(blockMountWeight(messages("m1"), () => false)).toBe(1)
  })

  test("blocksBefore walks from the end by weight", () => {
    const weights = [1, 1, 5, 1, 1]
    expect(blocksBefore(weights, 5, 3)).toBe(2)
    expect(blocksBefore(weights, 5, 100)).toBe(0)
    expect(blocksBefore(weights, 0, 3)).toBe(0)
  })

  test("blocksAfter walks forward by weight", () => {
    const weights = [1, 1, 5, 1, 1]
    expect(blocksAfter(weights, 0, 3)).toBe(3)
    expect(blocksAfter(weights, 2, 6)).toBe(4)
    expect(blocksAfter(weights, 4, 10)).toBe(5)
  })

  test("windowBlocks reports truncation cues", () => {
    const blocks = [messages("a"), messages("b"), messages("c"), messages("d")]
    const { visible, window } = windowBlocks(blocks, 1, 3)
    expect(visible.map((block) => block.id)).toEqual(["b", "c"])
    expect(window.truncatedAbove).toBe(true)
    expect(window.truncatedBelow).toBe(true)
    expect(window.hiddenAbove).toBe(1)
    expect(mountCueAbove(2)).toContain("2 earlier")
    expect(mountCueAbove(0)).toBe("")
  })
})
