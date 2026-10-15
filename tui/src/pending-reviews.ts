export type PendingReviewCounts = {
  edits: number
  commands: number
  mcp: number
}

export function totalPendingReviews(counts: PendingReviewCounts): number {
  return counts.edits + counts.commands + counts.mcp
}

// Slash list commands that open each pending review family, in priority order.
export function pendingReviewActions(counts: PendingReviewCounts): string[] {
  const actions: string[] = []
  if (counts.edits > 0) actions.push("/patches")
  if (counts.commands > 0) actions.push("/commands")
  if (counts.mcp > 0) actions.push("/mcp calls")
  return actions
}

export function pendingReviewOpenCommand(counts: PendingReviewCounts): string | undefined {
  return pendingReviewActions(counts)[0]
}

// Compact footer text inspired by Crush's always-visible pending chrome.
// Exact proposals still appear in the transcript notice. Actionable slash
// commands stay in the cue so operators can jump without reopening /help.
export function formatPendingReviewStatus(counts: PendingReviewCounts): string | undefined {
  const parts: string[] = []
  if (counts.edits > 0) {
    parts.push(`${counts.edits} edit${counts.edits === 1 ? "" : "s"}`)
  }
  if (counts.commands > 0) {
    parts.push(`${counts.commands} shell`)
  }
  if (counts.mcp > 0) {
    parts.push(`${counts.mcp} MCP`)
  }
  if (parts.length === 0) return undefined
  const actions = pendingReviewActions(counts)
  return `● review needed  ·  ${parts.join(" · ")}  ·  ${actions.join(" · ")}  ·  Ctrl+R`
}

export function statusWithPendingReviews(
  baseStatus: string,
  counts: PendingReviewCounts,
): string {
  const pending = formatPendingReviewStatus(counts)
  if (!pending) return baseStatus
  // Prefer the review cue: approvals block progress more than usage trivia.
  return pending
}
