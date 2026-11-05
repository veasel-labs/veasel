import { describe, expect, test } from "bun:test"
import { statusDialogCompact, statusMcpVisibleCount } from "./status-dialog"

describe("statusDialogCompact", () => {
  test("treats 24 rows as compact like the provider dialog", () => {
    expect(statusDialogCompact(100, 24)).toBe(true)
    expect(statusDialogCompact(100, 25)).toBe(false)
    expect(statusDialogCompact(120, 40)).toBe(false)
  })

  test("inherits the shared compact thresholds", () => {
    expect(statusDialogCompact(50, 40)).toBe(true)
    expect(statusDialogCompact(120, 20)).toBe(true)
  })
})

describe("statusMcpVisibleCount", () => {
  test("reserves a summary row when the list overflows at 24 rows", () => {
    // contentHeight 16, compact chrome 8 + 3 detail lines = 11, budget 5.
    expect(statusMcpVisibleCount(100, 24, 20, 3)).toBe(4)
  })

  test("shows every server when they all fit", () => {
    expect(statusMcpVisibleCount(100, 24, 3, 3)).toBe(3)
    expect(statusMcpVisibleCount(120, 40, 10, 3)).toBe(10)
  })

  test("charges detail lines and their gaps at tall sizes", () => {
    // contentHeight 32, chrome 11 + 2*3 = 17, budget 15, minus summary.
    expect(statusMcpVisibleCount(120, 40, 20, 3)).toBe(14)
    // Fewer detail lines leave more room for servers.
    expect(statusMcpVisibleCount(120, 40, 20, 0)).toBe(20)
  })

  test("absent detail lines free rows at 24 rows", () => {
    expect(statusMcpVisibleCount(100, 24, 20, 0)).toBe(7)
  })

  test("never returns less than one row", () => {
    expect(statusMcpVisibleCount(40, 12, 20, 3)).toBe(1)
  })
})
