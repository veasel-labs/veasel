import { describe, expect, test } from "bun:test"
import {
  countsFromReviews,
  demoPendingReviews,
  formatSolidReviewBody,
  hunkCountForReview,
  nextDiffSurface,
  pendingStatusForReviews,
  resolveReviewAction,
  reviewKindLabel,
  reviewPanelTitle,
  reviewShortcut,
  reviewSummaryLine,
  settleReviews,
  toActiveReview,
} from "./reviews"

describe("Solid reviews helpers", () => {
  test("documents Ctrl+R as the review shortcut", () => {
    expect(reviewShortcut.label).toBe("Ctrl+R")
    expect(reviewShortcut.name).toBe("r")
    expect(reviewShortcut.ctrl).toBe(true)
  })

  test("demo fixture covers patch, shell, and MCP families", () => {
    const demo = demoPendingReviews()
    expect(countsFromReviews(demo)).toEqual({ edits: 1, commands: 1, mcp: 1 })
    expect(pendingStatusForReviews(demo)).toContain("Ctrl+R")
    expect(pendingStatusForReviews(demo)).toContain("1 edit")
    expect(reviewPanelTitle(demo[0], 3)).toContain("Workspace edit")
    expect(reviewSummaryLine(demo[0]!)).toContain("reviews.ts")
    expect(reviewKindLabel("command")).toBe("shell")
  })

  test("formats patch body through formatReviewDiff", () => {
    const patch = demoPendingReviews()[0]!
    const body = formatSolidReviewBody(patch, { terminalRows: 40, hunkIndex: 0 })
    expect(body).toContain("REVIEW WORKSPACE EDIT")
    expect(body).toContain("reviews.ts")
    expect(body).toContain("added")
    expect(hunkCountForReview(patch)).toBeGreaterThanOrEqual(2)
  })

  test("formats shell and MCP bodies through legacy helpers", () => {
    const [, shell, mcp] = demoPendingReviews()
    expect(formatSolidReviewBody(shell!)).toContain("bun test")
    expect(formatSolidReviewBody(shell!)).toContain("Bubblewrap")
    expect(formatSolidReviewBody(mcp!)).toContain("write_note")
    expect(formatSolidReviewBody(mcp!)).toContain("Arguments")
  })

  test("resolveReviewAction maps approve/reject/navigate/hunk/surface", () => {
    const queue = demoPendingReviews()
    const current = queue[0]!
    expect(
      resolveReviewAction({ action: "approve" }, queue, current, new Set()),
    ).toEqual({
      type: "decide",
      decision: "approve",
      targets: [toActiveReview(current)],
    })
    expect(
      resolveReviewAction({ action: "rejectAll" }, queue, current, new Set()),
    ).toEqual({
      type: "decide",
      decision: "reject",
      targets: [toActiveReview(current)],
    })
    expect(resolveReviewAction({ action: "next" }, queue, current, new Set())).toEqual({
      type: "navigate",
      delta: 1,
    })
    expect(resolveReviewAction({ action: "hunkNext" }, queue, current, new Set())).toEqual({
      type: "hunk",
      delta: 1,
    })
    expect(
      resolveReviewAction({ action: "toggleDiffSurface" }, queue, current, new Set()),
    ).toEqual({ type: "toggleDiffSurface" })
    expect(nextDiffSurface("segments")).toBe("split")
  })

  test("settleReviews removes decided targets", () => {
    const queue = demoPendingReviews()
    const next = settleReviews(queue, [toActiveReview(queue[0]!)])
    expect(countsFromReviews(next)).toEqual({ edits: 0, commands: 1, mcp: 1 })
    expect(pendingStatusForReviews([])).toBeUndefined()
  })
})
