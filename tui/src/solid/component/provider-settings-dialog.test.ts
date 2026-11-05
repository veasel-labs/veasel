import { describe, expect, test } from "bun:test"
import { providerListPageSize, providerListWindowStart } from "./provider-settings-dialog"

describe("providerListWindowStart", () => {
  test("keeps a short list at the top", () => {
    expect(providerListWindowStart(0, 5, 12)).toBe(0)
    expect(providerListWindowStart(4, 5, 12)).toBe(0)
  })

  test("centers the focused row when possible", () => {
    expect(providerListWindowStart(0, 40, 12)).toBe(0)
    expect(providerListWindowStart(20, 40, 12)).toBe(14)
    expect(providerListWindowStart(39, 40, 12)).toBe(28)
  })
})

describe("providerListPageSize", () => {
  test("caps at the full page on tall terminals", () => {
    expect(providerListPageSize(120, 40, 100, false)).toBe(12)
    // Guidance rows are charged: content 32 - chrome 22 - showing 1.
    expect(providerListPageSize(120, 40, 100, true)).toBe(9)
    expect(providerListPageSize(120, 50, 100, true)).toBe(12)
  })

  test("24 rows is compact for this dialog: descriptive blocks hide", () => {
    // 100x24 (packaged-smoke size): content height 16, compact chrome 7.
    expect(providerListPageSize(100, 24, 3, false)).toBe(9)
    // One row is reserved for the "Showing x-y of n" line on overflow.
    expect(providerListPageSize(100, 24, 210, false)).toBe(8)
    // Guidance is hidden when compact, so it is never charged there.
    expect(providerListPageSize(100, 24, 210, true)).toBe(8)
  })

  test("compact geometry charges only header, status, filter, and gaps", () => {
    // 32x12: content height 10, compact chrome 7.
    expect(providerListPageSize(32, 12, 3, false)).toBe(3)
    expect(providerListPageSize(32, 12, 100, false)).toBe(2)
    // 40x16: content height 14.
    expect(providerListPageSize(40, 16, 100, false)).toBe(6)
    expect(providerListPageSize(32, 12, 100, true)).toBe(2)
  })

  test("non-compact chrome charges wrapped prompt, intro, and count lines", () => {
    // 100x30: content height 22, chrome 18, showing row 1.
    expect(providerListPageSize(100, 30, 210, false)).toBe(3)
    // Guidance would exceed the budget; never below one focused row.
    expect(providerListPageSize(100, 30, 210, true)).toBe(1)
  })
})
