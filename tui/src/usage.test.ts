import { describe, expect, test } from "bun:test"
import { formatReportedUsage, formatTokenCount, statusWithUsage } from "./usage"

describe("formatTokenCount", () => {
  test("keeps small counts exact", () => {
    expect(formatTokenCount(0)).toBe("0")
    expect(formatTokenCount(999)).toBe("999")
  })

  test("uses compact units for larger counts", () => {
    expect(formatTokenCount(1000)).toBe("1.0k")
    expect(formatTokenCount(1200)).toBe("1.2k")
    expect(formatTokenCount(15_400)).toBe("15k")
    expect(formatTokenCount(1_500_000)).toBe("1.5M")
  })
})

describe("statusWithUsage", () => {
  test("omits tokens unless the provider reported them", () => {
    expect(statusWithUsage("openai-compatible", "fixture")).toBe("● openai-compatible  ·  fixture")
    expect(statusWithUsage("openai-compatible", "fixture", { usage_reported: false, input_tokens: 9 })).toBe(
      "● openai-compatible  ·  fixture",
    )
  })

  test("appends reported input and output counts", () => {
    expect(formatReportedUsage(1200, 340)).toBe("1.2k in · 340 out")
    expect(statusWithUsage("openai-compatible", "fixture", {
      usage_reported: true,
      input_tokens: 1200,
      output_tokens: 340,
    })).toBe("● openai-compatible  ·  fixture  ·  1.2k in · 340 out")
  })
})
