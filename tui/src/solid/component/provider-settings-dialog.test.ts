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
    expect(providerListPageSize(120, 40, 100, true)).toBe(12)
  })

  test("shrinks to the dialog content height on short terminals", () => {
    // 80x24: content height 16, non-compact chrome 13.
    expect(providerListPageSize(80, 24, 3, false)).toBe(3)
    // One row is reserved for the "Showing x-y of n" line on overflow.
    expect(providerListPageSize(80, 24, 100, false)).toBe(2)
    // Guidance rows are charged too; never below one focused row.
    expect(providerListPageSize(80, 24, 100, true)).toBe(1)
  })

  test("compact geometry charges only header, status, filter, and gaps", () => {
    // 32x12: content height 10, compact chrome 6.
    expect(providerListPageSize(32, 12, 3, false)).toBe(4)
    expect(providerListPageSize(32, 12, 100, false)).toBe(3)
    // 40x16: content height 14.
    expect(providerListPageSize(40, 16, 100, false)).toBe(7)
    // Guidance is hidden when compact, so it is never charged there.
    expect(providerListPageSize(32, 12, 100, true)).toBe(3)
  })
})
