import { describe, expect, test } from "bun:test"
import {
  highlightWrappedLines,
  highlightsDialogCompact,
  highlightsVisibleCount,
  type HighlightEntry,
} from "./highlights-dialog"

// Title 1 line + body 2 lines at the 66-column large-dialog content
// width; +1 margin outside compact heights.
const entry = (n: number): HighlightEntry => ({
  title: `Highlight ${n}`,
  body: "word ".repeat(24).trim(),
})
const entries = [entry(1), entry(2), entry(3), entry(4)]

describe("highlightWrappedLines", () => {
  test("counts greedy word wrap", () => {
    expect(highlightWrappedLines("hello world", 66)).toBe(1)
    expect(highlightWrappedLines("aaaa bbbb", 4)).toBe(2)
    expect(highlightWrappedLines("aaaa bbbb cccc", 9)).toBe(2)
  })

  test("wraps words longer than the line mid-word", () => {
    expect(highlightWrappedLines("abcdefghij", 4)).toBe(3)
  })

  test("empty text still occupies its line", () => {
    expect(highlightWrappedLines("", 10)).toBe(1)
  })
})

describe("highlightsDialogCompact", () => {
  test("treats 24 rows as compact like sibling dialogs", () => {
    expect(highlightsDialogCompact(100, 24)).toBe(true)
    expect(highlightsDialogCompact(100, 25)).toBe(false)
  })
})

describe("highlightsVisibleCount", () => {
  test("truncates with a reserved summary line at 24 rows", () => {
    // contentHeight 16 - 5 chrome = 11; compact cost 3/entry fits 3.
    expect(highlightsVisibleCount(entries, 100, 24)).toBe(3)
  })

  test("shows every entry when wrapped heights fit", () => {
    expect(highlightsVisibleCount(entries, 120, 40)).toBe(4)
    expect(highlightsVisibleCount(entries.slice(0, 2), 100, 24)).toBe(2)
  })

  test("shows no entry rather than overflow when one entry exceeds the box", () => {
    // At 40x12 the first entry alone (5 wrapped lines) plus the summary
    // row exceeds the 5-line budget; forcing one entry overdrew the
    // footer and border at 32x12.
    expect(highlightsVisibleCount(entries, 40, 12)).toBe(0)
  })
})
