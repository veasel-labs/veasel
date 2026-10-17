import { describe, expect, test } from "bun:test"
import { providerListWindowStart } from "./provider-settings-dialog"

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
