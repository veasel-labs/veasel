export type PendingReviewCounts = {
  edits: number
  commands: number
  mcp: number
}

export function totalPendingReviews(counts: PendingReviewCounts): number {
  return counts.edits + counts.commands + counts.mcp
}

// Compact footer text inspired by Crush's always-visible pending chrome.
// Exact proposals still appear in the transcript notice.
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
  return `● review needed  ·  ${parts.join(" · ")}`
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
