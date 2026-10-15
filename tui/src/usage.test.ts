import { describe, expect, test } from "bun:test"
import { formatReportedUsage, formatSessionUsageSummary, formatTokenCount, statusWithUsage } from "./usage"

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

describe("formatSessionUsageSummary", () => {
  test("states when no provider has reported tokens yet", () => {
    expect(formatSessionUsageSummary({
      session_id: "s",
      completed_turns: 2,
      reported_turns: 0,
      input_tokens: 0,
      output_tokens: 0,
      usage_reported: false,
      cost: "unavailable",
    })).toContain("Tokens: unavailable")
  })

  test("sums reported tokens without inventing a cost", () => {
    const text = formatSessionUsageSummary({
      session_id: "s",
      completed_turns: 3,
      reported_turns: 2,
      input_tokens: 1500,
      output_tokens: 400,
      usage_reported: true,
      cost: "unavailable",
    })
    expect(text).toContain("Completed turns: 3")
    expect(text).toContain("Turns with provider-reported tokens: 2")
    expect(text).toContain("1.5k in · 400 out")
    expect(text).toContain("Cost: unavailable (no price schedule)")
  })
})
