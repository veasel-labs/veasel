import { formatStatusLine } from "./status-a11y"
import type { ActiveReview } from "./active-review"

export type PendingReviewCounts = {
  edits: number
  commands: number
  mcp: number
}

export type PendingReviewInventoryResult =
  | { ok: true; counts: PendingReviewCounts; queue: ActiveReview[] }
  | { ok: false }

type ReviewRecord = { id?: unknown; status?: unknown }
type PendingReviewFetcher = (input: string | URL | Request, init?: RequestInit) => Promise<Response>

export type PendingReviewInventoryRequest = {
  current: boolean
  inventory: PendingReviewInventoryResult
}

/** Makes only the most recently requested inventory eligible to update UI state. */
export function createPendingReviewInventoryCoordinator() {
  let revision = 0
  return {
    invalidate() {
      revision++
    },
    async load(
      apiBase: string,
      sessionId: string,
      signal?: AbortSignal,
      fetcher?: PendingReviewFetcher,
    ): Promise<PendingReviewInventoryRequest> {
      const requestRevision = ++revision
      const inventory = await loadPendingReviewInventory(apiBase, sessionId, signal, fetcher)
      return { current: requestRevision === revision, inventory }
    },
  }
}

/** Fetch every review family as one inventory snapshot; partial failures are unavailable, not empty. */
export async function loadPendingReviewInventory(
  apiBase: string,
  sessionId: string,
  signal?: AbortSignal,
  fetcher: PendingReviewFetcher = fetch,
): Promise<PendingReviewInventoryResult> {
  const base = apiBase.replace(/\/+$/, "")
  const session = encodeURIComponent(sessionId)
  const load = async (path: string): Promise<ReviewRecord[]> => {
    const response = await fetcher(`${base}/v1/sessions/${session}/${path}`, { signal })
    if (!response.ok) throw new Error(`review inventory HTTP ${response.status}`)
    const value: unknown = await response.json()
    if (!Array.isArray(value) || value.some((item) =>
      !item || typeof item !== "object" || typeof item.id !== "string" || typeof item.status !== "string",
    )) {
      throw new Error("invalid review inventory")
    }
    return value as ReviewRecord[]
  }

  try {
    const [edits, commands, mcp] = await Promise.all([
      load("workspace/edits"),
      load("workspace/commands"),
      load("mcp-tool-calls"),
    ])
    const groups = [
      { kind: "patch" as const, records: edits, count: "edits" as const },
      { kind: "command" as const, records: commands, count: "commands" as const },
      { kind: "mcp" as const, records: mcp, count: "mcp" as const },
    ]
    const counts: PendingReviewCounts = { edits: 0, commands: 0, mcp: 0 }
    const queue: ActiveReview[] = []
    for (const group of groups) {
      const pending = group.records.filter((item) => item.status === "pending" && typeof item.id === "string")
      counts[group.count] = pending.length
      for (const item of pending) queue.push({ kind: group.kind, id: item.id as string, pending: true })
    }
    return { ok: true, counts, queue }
  } catch {
    return { ok: false }
  }
}

export function pendingReviewInventoryFailureNotice(): string {
  return "Could not load pending approvals. Press Ctrl+R to retry or run /patches, /commands, or /mcp calls to reopen a review list."
}

export function pendingReviewDecisionFailureNotice(
  inventoryUnavailable: boolean,
  inventoryRefreshing = false,
): string | undefined {
  if (inventoryUnavailable) {
    return `${pendingReviewInventoryFailureNotice()} Approval and rejection are paused until the queue loads.`
  }
  if (inventoryRefreshing) return "Approval and rejection are paused while the review queue refreshes. Retry after it finishes."
  return undefined
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

export function statusWithPendingReviewFailure(counts: PendingReviewCounts, modelLabel?: string): string {
  if (totalPendingReviews(counts) > 0) {
    return `${formatPendingReviewStatus(counts, modelLabel) ?? "▲ review needed"} · refresh failed`
  }
  return formatStatusLine("warn", "approvals unavailable  ·  Ctrl+R to retry")
}
