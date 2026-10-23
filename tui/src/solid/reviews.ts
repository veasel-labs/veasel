import {
  type ActiveReview,
  type ActiveReviewKind,
  pendingReviewsOfKind,
  reviewSelectionKey,
  resolveSelectedReviews,
} from "../active-review"
import {
  formatPendingReviewStatus,
  totalPendingReviews,
  type PendingReviewCounts,
} from "../pending-reviews"
import { formatReviewDiff, reviewDiffLineBudget, reviewHunkStarts } from "../review-diff"
import { formatMcpReview, mcpReviewLineBudget } from "../mcp-review"
import {
  formatShellReview,
  shellReviewLineBudget,
  type ReviewSandboxPreview,
} from "../shell-review"
import {
  cycleReviewDiffSurface,
  formatPatchSplitChrome,
  type ReviewDiffSurface,
} from "../diff-view"

/** Discoverable binding — matches legacy Ctrl+R pending-review jump. */
export const reviewShortcut = {
  name: "r",
  ctrl: true,
  label: "Ctrl+R",
} as const

export type SolidPatchReview = {
  kind: "patch"
  id: string
  pending: boolean
  path: string
  diff: string
  status?: string
}

export type SolidCommandReview = {
  kind: "command"
  id: string
  pending: boolean
  command: string
  cwd: string
  timeoutSeconds: number
  runner: string
  output?: string
  sandbox?: ReviewSandboxPreview
}

export type SolidMcpReview = {
  kind: "mcp"
  id: string
  pending: boolean
  plugin: string
  server: string
  tool: string
  operationId: string
  argumentsText: string
  stdioSandbox?: ReviewSandboxPreview
}

export type SolidReviewItem = (SolidPatchReview | SolidCommandReview | SolidMcpReview) & {
  /** False until details have been loaded for the visible review. */
  inspected?: boolean
}

export type ReviewDecision = "approve" | "reject"

export type ReviewDecisionResult = {
  settled: ActiveReview[]
  failed: string[]
}

export function toActiveReview(item: Pick<SolidReviewItem, "kind" | "id" | "pending">): ActiveReview {
  return { kind: item.kind, id: item.id, pending: item.pending }
}

export function countsFromReviews(items: readonly SolidReviewItem[]): PendingReviewCounts {
  let edits = 0
  let commands = 0
  let mcp = 0
  for (const item of items) {
    if (!item.pending) continue
    if (item.kind === "patch") edits++
    else if (item.kind === "command") commands++
    else mcp++
  }
  return { edits, commands, mcp }
}

export function pendingSolidReviews(items: readonly SolidReviewItem[]): SolidReviewItem[] {
  return items.filter((item) => item.pending)
}

export function reviewKindLabel(kind: ActiveReviewKind): string {
  if (kind === "patch") return "edit"
  if (kind === "command") return "shell"
  return "MCP"
}

export function reviewPanelTitle(item: SolidReviewItem | undefined, pendingTotal: number): string {
  if (!item) return pendingTotal > 0 ? "Pending reviews" : "No pending reviews"
  const kind = item.kind === "patch" ? "Workspace edit" : item.kind === "command" ? "Shell command" : "MCP call"
  return `Review · ${kind}`
}

export function reviewSummaryLine(item: SolidReviewItem): string {
  if (item.kind === "patch") return item.path
  if (item.kind === "command") return item.command.split("\n")[0] ?? item.command
  return `${item.plugin}/${item.server} · ${item.tool}`
}

/** Body text for segment / fallback rendering (not used when split DiffRenderable owns the hunk). */
export function formatSolidReviewBody(
  item: SolidReviewItem,
  options: { terminalRows?: number; hunkIndex?: number; lineOffset?: number } = {},
): string {
  const rows = options.terminalRows ?? 40
  if (item.kind === "patch") {
    const review = formatReviewDiff(item.diff, reviewDiffLineBudget(rows), {
      hunkIndex: options.hunkIndex ?? 0,
      lineOffset: options.lineOffset ?? 0,
    })
    const status = item.status?.trim() || (item.pending ? "pending" : "settled")
    return `REVIEW WORKSPACE EDIT  /  ${status}\n${item.path}\n${review.text}`
  }
  if (item.kind === "command") {
    return formatShellReview({
      command: item.command,
      cwd: item.cwd,
      timeoutSeconds: item.timeoutSeconds,
      runner: item.runner,
      id: item.id,
      pending: item.pending,
      output: item.output ?? "",
      maxLines: shellReviewLineBudget(rows),
      sandbox: item.sandbox,
    })
  }
  return formatMcpReview({
    plugin: item.plugin,
    server: item.server,
    tool: item.tool,
    operationId: item.operationId,
    id: item.id,
    pending: item.pending,
    argumentsText: item.argumentsText,
    maxLines: mcpReviewLineBudget(rows),
    stdioSandbox: item.stdioSandbox,
  })
}

export function patchSplitChrome(
  item: SolidPatchReview,
  hunkIndex: number,
  terminalColumns = 80,
): string {
  const starts = reviewHunkStarts(item.diff)
  const review = formatReviewDiff(item.diff, reviewDiffLineBudget(40), { hunkIndex })
  return formatPatchSplitChrome({
    status: item.status?.trim() || (item.pending ? "pending" : "settled"),
    path: item.path,
    additions: review.additions,
    removals: review.removals,
    hunkCount: starts.length,
    hunkIndex,
    terminalColumns,
    pendingInstruction: item.pending
      ? `Type /patch approve ${item.id} or /patch reject ${item.id}.`
      : undefined,
  })
}

export function hunkCountForReview(item: SolidReviewItem | undefined): number {
  if (!item || item.kind !== "patch") return 0
  return reviewHunkStarts(item.diff).length
}

export function nextDiffSurface(current: ReviewDiffSurface): ReviewDiffSurface {
  return cycleReviewDiffSurface(current)
}

export type ReviewActionResult =
  | { type: "decide"; decision: ReviewDecision; targets: ActiveReview[] }
  | { type: "toggleSelect" }
  | { type: "navigate"; delta: number }
  | { type: "hunk"; delta: number }
  | { type: "diffPage"; delta: number }
  | { type: "toggleDiffSurface" }

/** Map a hotkey action + queue state into a Solid review panel effect. */
export function resolveReviewAction(
  action:
    | { action: "approve" }
    | { action: "approveAll" }
    | { action: "reject" }
    | { action: "rejectAll" }
    | { action: "toggleSelect" }
    | { action: "next" }
    | { action: "prev" }
    | { action: "hunkNext" }
    | { action: "hunkPrev" }
    | { action: "diffPageNext" }
    | { action: "diffPagePrev" }
    | { action: "toggleDiffSurface" },
  queue: readonly SolidReviewItem[],
  current: SolidReviewItem | undefined,
  selectedKeys: ReadonlySet<string>,
): ReviewActionResult | undefined {
  if (!current?.pending) return undefined
  const active = toActiveReview(current)
  switch (action.action) {
    case "toggleSelect":
      return { type: "toggleSelect" }
    case "next":
      return { type: "navigate", delta: 1 }
    case "prev":
      return { type: "navigate", delta: -1 }
    case "hunkNext":
      return { type: "hunk", delta: 1 }
    case "hunkPrev":
      return { type: "hunk", delta: -1 }
    case "diffPageNext":
      return { type: "diffPage", delta: 1 }
    case "diffPagePrev":
      return { type: "diffPage", delta: -1 }
    case "toggleDiffSurface":
      return { type: "toggleDiffSurface" }
    case "approve":
    case "reject": {
      const decision: ReviewDecision = action.action === "approve" ? "approve" : "reject"
      const selected = resolveSelectedReviews(queue.map(toActiveReview), selectedKeys)
      const targets = selected.length > 0 ? selected : [active]
      return { type: "decide", decision, targets }
    }
    case "approveAll":
    case "rejectAll": {
      const decision: ReviewDecision = action.action === "approveAll" ? "approve" : "reject"
      const batch = pendingReviewsOfKind(queue.map(toActiveReview), current.kind)
      return { type: "decide", decision, targets: batch }
    }
  }
}

/** Remove decided items from the local fixture queue (HTTP wiring comes later). */
export function settleReviews(
  queue: readonly SolidReviewItem[],
  targets: readonly ActiveReview[],
): SolidReviewItem[] {
  if (targets.length === 0) return [...queue]
  const keys = new Set(targets.map((item) => reviewSelectionKey(item)))
  return queue.filter((item) => !keys.has(reviewSelectionKey(toActiveReview(item))))
}

export function pendingStatusForReviews(
  items: readonly SolidReviewItem[],
  modelLabel?: string,
): string | undefined {
  const counts = countsFromReviews(items)
  if (totalPendingReviews(counts) === 0) return undefined
  return formatPendingReviewStatus(counts, modelLabel)
}

/** Demo queue for Solid shell demos and testRender fixtures. */
export function demoPendingReviews(): SolidReviewItem[] {
  return [
    {
      kind: "patch",
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      pending: true,
      path: "tui/src/solid/reviews.ts",
      status: "pending",
      diff: [
        "diff --git a/tui/src/solid/reviews.ts b/tui/src/solid/reviews.ts",
        "--- a/tui/src/solid/reviews.ts",
        "+++ b/tui/src/solid/reviews.ts",
        "@@ -1,4 +1,5 @@",
        " export const reviewShortcut = {",
        "   name: \"r\",",
        "+  ctrl: true,",
        "   label: \"Ctrl+R\",",
        " }",
        "@@ -10,4 +11,5 @@",
        " export function countsFromReviews(items) {",
        "   let edits = 0",
        "+  // pending file / shell / MCP",
        "   let commands = 0",
        "   let mcp = 0",
      ].join("\n"),
    },
    {
      kind: "command",
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      pending: true,
      command: "bun test tui/src/solid/reviews.test.ts",
      cwd: "~/veasel",
      timeoutSeconds: 120,
      runner: "shell",
      sandbox: {
        mode: "auto",
        will_wrap: true,
        backend: "bubblewrap",
        network: "deny",
      },
    },
    {
      kind: "mcp",
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      pending: true,
      plugin: "demo",
      server: "docs",
      tool: "write_note",
      operationId: "op-solid-review-1",
      argumentsText: '{\n  "path": "notes/review.md",\n  "text": "Solid review panel"\n}',
      stdioSandbox: {
        mode: "off",
        will_wrap: false,
        backend: "none",
        network: "host",
      },
    },
  ]
}
