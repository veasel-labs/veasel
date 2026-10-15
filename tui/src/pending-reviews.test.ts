import { describe, expect, test } from "bun:test"
import {
  formatPendingReviewStatus,
  pendingReviewActions,
  pendingReviewOpenCommand,
  statusWithPendingReviews,
  totalPendingReviews,
} from "./pending-reviews"

describe("formatPendingReviewStatus", () => {
  test("returns nothing when the session has no pending reviews", () => {
    expect(formatPendingReviewStatus({ edits: 0, commands: 0, mcp: 0 })).toBeUndefined()
    expect(totalPendingReviews({ edits: 0, commands: 0, mcp: 0 })).toBe(0)
    expect(pendingReviewActions({ edits: 0, commands: 0, mcp: 0 })).toEqual([])
    expect(pendingReviewOpenCommand({ edits: 0, commands: 0, mcp: 0 })).toBeUndefined()
  })

  test("lists each pending review family with the slash that opens it", () => {
    expect(formatPendingReviewStatus({ edits: 1, commands: 0, mcp: 0 })).toBe(
      "▲ attention  ·  review needed  ·  1 pending  ·  1 edit  ·  /patches  ·  Ctrl+R",
    )
    expect(formatPendingReviewStatus({ edits: 2, commands: 1, mcp: 3 })).toBe(
      "▲ attention  ·  review needed  ·  6 pending  ·  2 edits · 1 shell · 3 MCP  ·  /patches · /commands · /mcp calls  ·  Ctrl+R",
    )
    expect(pendingReviewActions({ edits: 2, commands: 1, mcp: 3 })).toEqual([
      "/patches",
      "/commands",
      "/mcp calls",
    ])
    expect(pendingReviewOpenCommand({ edits: 0, commands: 2, mcp: 1 })).toBe("/commands")
  })

  test("prefers the review cue over a completed-turn status", () => {
    expect(statusWithPendingReviews("● openai-compatible  ·  fixture  ·  1.2k in · 340 out", {
      edits: 1,
      commands: 0,
      mcp: 0,
    })).toBe("▲ attention  ·  review needed  ·  1 pending  ·  1 edit  ·  /patches  ·  Ctrl+R")
    expect(statusWithPendingReviews("● openai-compatible  ·  fixture", {
      edits: 0,
      commands: 0,
      mcp: 0,
    })).toBe("● openai-compatible  ·  fixture")
  })
})
