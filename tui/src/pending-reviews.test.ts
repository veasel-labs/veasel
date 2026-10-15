import { describe, expect, test } from "bun:test"
import { formatPendingReviewStatus, statusWithPendingReviews, totalPendingReviews } from "./pending-reviews"

describe("formatPendingReviewStatus", () => {
  test("returns nothing when the session has no pending reviews", () => {
    expect(formatPendingReviewStatus({ edits: 0, commands: 0, mcp: 0 })).toBeUndefined()
    expect(totalPendingReviews({ edits: 0, commands: 0, mcp: 0 })).toBe(0)
  })

  test("lists each pending review family compactly", () => {
    expect(formatPendingReviewStatus({ edits: 1, commands: 0, mcp: 0 })).toBe("● review needed  ·  1 edit")
    expect(formatPendingReviewStatus({ edits: 2, commands: 1, mcp: 3 })).toBe(
      "● review needed  ·  2 edits · 1 shell · 3 MCP",
    )
  })

  test("prefers the review cue over a completed-turn status", () => {
    expect(statusWithPendingReviews("● openai-compatible  ·  fixture  ·  1.2k in · 340 out", {
      edits: 1,
      commands: 0,
      mcp: 0,
    })).toBe("● review needed  ·  1 edit")
    expect(statusWithPendingReviews("● openai-compatible  ·  fixture", {
      edits: 0,
      commands: 0,
      mcp: 0,
    })).toBe("● openai-compatible  ·  fixture")
  })
})
