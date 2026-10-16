import { describe, expect, test } from "bun:test"
import {
  modelVariantIds,
  outputBudgetForVariant,
  variantBudgetLabel,
  variantForOutputBudget,
  VARIANT_OUTPUT_BUDGET,
} from "./variant-budget"

describe("variant-budget", () => {
  test("maps named variants to output token budgets", () => {
    expect(outputBudgetForVariant(undefined)).toBe(VARIANT_OUTPUT_BUDGET.default)
    expect(outputBudgetForVariant("default")).toBe(4096)
    expect(outputBudgetForVariant("fast")).toBe(1024)
    expect(outputBudgetForVariant("max")).toBe(32_768)
  })

  test("infers nearest variant from configured tokens", () => {
    expect(variantForOutputBudget(0)).toBe("default")
    expect(variantForOutputBudget(1000)).toBe("fast")
    expect(variantForOutputBudget(4096)).toBe("default")
    expect(variantForOutputBudget(30_000)).toBe("max")
  })

  test("exposes picker labels and ordered ids", () => {
    expect(modelVariantIds).toEqual(["default", "fast", "max"])
    expect(variantBudgetLabel("fast")).toBe("fast · max_output 1024")
  })
})
