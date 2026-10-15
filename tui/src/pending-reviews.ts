import { formatStatusLine } from "./status-a11y"

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
// The warn glyph plus the word "attention" keep the cue meaningful without color.
export function formatPendingReviewStatus(
  counts: PendingReviewCounts,
  modelLabel?: string,
): string | undefined {
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
  const total = totalPendingReviews(counts)
  const actions = pendingReviewActions(counts)
  // Prefer keeping slash actions on-screen: when a model label is present,
  // drop the redundant "review needed" words to free columns.
  const model = modelLabel?.trim()
  const lead = model ? `attention  ·  ${model}` : "attention  ·  review needed"
  return formatStatusLine(
    "warn",
    `${lead}  ·  ${total} pending  ·  ${parts.join(" · ")}  ·  ${actions.join(" · ")}  ·  Ctrl+R`,
  )
}

export function statusWithPendingReviews(
  baseStatus: string,
  counts: PendingReviewCounts,
  modelLabel?: string,
): string {
  const pending = formatPendingReviewStatus(counts, modelLabel)
  if (!pending) return baseStatus
  // Prefer the review cue: approvals block progress more than usage trivia.
  return pending
}
