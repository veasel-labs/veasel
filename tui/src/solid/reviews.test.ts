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
import { solidCliFromApproval } from "./reviews-inventory"

describe("Solid reviews helpers", () => {
  test("documents Ctrl+R as the review shortcut", () => {
    expect(reviewShortcut.label).toBe("Ctrl+R")
    expect(reviewShortcut.name).toBe("r")
    expect(reviewShortcut.ctrl).toBe(true)
  })

  test("demo fixture covers patch, shell, and MCP families", () => {
    const demo = demoPendingReviews()
    expect(countsFromReviews(demo)).toEqual({ edits: 1, commands: 1, mcp: 1, cli: 0 })
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
    const shellBody = formatSolidReviewBody(shell!)
    expect(shellBody).toContain("bun test")
    expect(shellBody).toContain("Bubblewrap")
    expect(shellBody.indexOf("Bubblewrap")).toBeLessThan(shellBody.indexOf("Command:"))
    expect(formatSolidReviewBody(mcp!)).toContain("write_note")
    expect(formatSolidReviewBody(mcp!)).toContain("Arguments")
  })

  test("formats installed CLI requests without exposing terminal controls or allowing truncated approval", () => {
    const approval = solidCliFromApproval({
      id: "cli-1",
      session_id: "session-1",
      request_id: "request-1",
      tool_name: "Edit\u001b[2J",
      input_json: `{"path":"src/a.ts","text":"${"x".repeat(13_000)}"}`,
      status: "pending",
      created_at: "",
      updated_at: "",
    })
    expect(approval).toMatchObject({ kind: "cli", pending: true, inputFullyVisible: false })
    if (approval.kind !== "cli") throw new Error("expected installed CLI review")
    const body = formatSolidReviewBody(approval)
    expect(body).toContain("REVIEW INSTALLED CLI TOOL  /  PENDING")
    expect(body).toContain("Edit\\u001b[2J")
    expect(body).not.toContain("\u001b[2J")
    expect(body).toContain("INPUT TRUNCATED — APPROVAL DISABLED")
    expect(countsFromReviews([approval])).toEqual({ edits: 0, commands: 0, mcp: 0, cli: 1 })
    expect(reviewKindLabel("cli")).toBe("installed CLI")
  })

  test("keeps every pending command line available in the scrollable review body", () => {
    const shell = demoPendingReviews()[1]!
    if (shell.kind !== "command") throw new Error("expected shell review fixture")
    const command = Array.from({ length: 80 }, (_, index) => `echo inspect-step-${index + 1}`).join("\n")
    const body = formatSolidReviewBody({ ...shell, command }, { terminalRows: 12 })
    expect(body).toContain("echo inspect-step-1\n")
    expect(body).toContain("echo inspect-step-80")
    expect(body).not.toContain("Showing ")
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
    expect(countsFromReviews(next)).toEqual({ edits: 0, commands: 1, mcp: 1, cli: 0 })
    expect(pendingStatusForReviews([])).toBeUndefined()
  })
})
