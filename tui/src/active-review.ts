export type ActiveReviewKind = "patch" | "command" | "mcp"

export type ActiveReview = {
  kind: ActiveReviewKind
  id: string
  pending: boolean
}

export type ReviewHotkey =
  | { action: "approve" }
  | { action: "approveAll" }
  | { action: "reject" }
  | { action: "next" }
  | { action: "prev" }
  | { action: "hunkNext" }
  | { action: "hunkPrev" }

// Single-key review actions when the composer is empty and a pending review is
// on screen. Letters stay available for typing once the composer has text.
// Shift+A approves every pending item of the same kind (patches, shell, or MCP).
// `{`/`}` move between unified-diff hunks while a patch review is open.
export function reviewHotkey(
  key: { name: string; ctrl: boolean; meta: boolean; shift?: boolean },
  context: { composerEmpty: boolean; review: ActiveReview | undefined },
): ReviewHotkey | undefined {
  if (!context.composerEmpty || !context.review?.pending) return undefined
  if (key.ctrl || key.meta) return undefined
  if (key.name === "a" && key.shift) return { action: "approveAll" }
  if (key.name === "a") return { action: "approve" }
  if (key.name === "x") return { action: "reject" }
  if (key.name === "]" || key.name === "n") return { action: "next" }
  if (key.name === "[" || key.name === "p") return { action: "prev" }
  if (context.review.kind === "patch" && key.name === "}") return { action: "hunkNext" }
  if (context.review.kind === "patch" && key.name === "{") return { action: "hunkPrev" }
  return undefined
}

export function reviewHotkeyHint(
  review: ActiveReview | undefined,
  options: { hunkCount?: number } = {},
): string | undefined {
  if (!review?.pending) return undefined
  const hunks = review.kind === "patch" && (options.hunkCount ?? 0) > 1
    ? " · {/} hunks"
    : ""
  return `a approve · A all same kind · x reject · ]/[ or n/p next/prev${hunks}`
}

export function pendingReviewsOfKind(queue: ActiveReview[], kind: ActiveReviewKind): ActiveReview[] {
  return queue.filter((item) => item.pending && item.kind === kind)
}

export function moveActiveReviewIndex(index: number, delta: number, count: number): number {
  if (count <= 0) return 0
  return (((index + delta) % count) + count) % count
}

export function activeReviewIndex(queue: ActiveReview[], current: ActiveReview | undefined): number {
  if (!current) return 0
  const index = queue.findIndex((item) => item.kind === current.kind && item.id === current.id)
  return index >= 0 ? index : 0
}

export function withReviewHotkeyHint(
  notice: string,
  review: ActiveReview | undefined,
  options: { hunkCount?: number } = {},
): string {
  const hint = reviewHotkeyHint(review, options)
  if (!hint) return notice
  if (notice.includes(hint)) return notice
  // Keep the hotkey cue on the first screen above long diffs/commands/arguments.
  const lines = notice.split("\n")
  if (lines.length === 0) return hint
  return `${lines[0]}\n${hint}\n${lines.slice(1).join("\n")}`
}
