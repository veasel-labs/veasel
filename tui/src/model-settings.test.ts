import { describe, expect, test } from "bun:test"
import { defaultOutputTokenBudget, initialOutputTokenBudget, maximumOutputTokenBudget, parseOutputTokenBudget } from "./model-settings"

describe("model output settings", () => {
  test("uses Meta's provider default for a new Meta profile and keeps safe caps elsewhere", () => {
    expect(initialOutputTokenBudget("meta")).toBe(0)
    expect(initialOutputTokenBudget("anthropic")).toBe(defaultOutputTokenBudget)
    expect(initialOutputTokenBudget("meta", 8192)).toBe(8192)
  })

  test("accepts provider default or a bounded token budget", () => {
    expect(parseOutputTokenBudget("0")).toBe(0)
    expect(parseOutputTokenBudget("4096")).toBe(4096)
    expect(parseOutputTokenBudget(String(maximumOutputTokenBudget))).toBe(maximumOutputTokenBudget)
  })

  test("rejects malformed, too-small, unsafe, and oversized values", () => {
    for (const value of ["", "-1", "15", "1.5", "1e3", "NaN", "131073", "9007199254740992"]) {
      expect(parseOutputTokenBudget(value)).toBeUndefined()
    }
  })
})
