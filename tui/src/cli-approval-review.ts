import type { ApiCliToolApproval } from "./api-client"

export type CliApprovalInputPreview = {
  text: string
  fullyVisible: boolean
  truncationNotice?: string
}

export type CliToolApproval = ApiCliToolApproval

export type CliApprovalPollerOptions = {
  list: (sessionId: string) => Promise<CliToolApproval[]>
  isCurrent: (sessionId: string) => boolean
  onPending: (sessionId: string, approvals: CliToolApproval[]) => boolean | void | Promise<boolean | void>
}

/** Poll only during an active turn and notify once for each newly pending request. */
export function createCliApprovalPoller(options: CliApprovalPollerOptions) {
  let sessionId: string | undefined
  let timer: ReturnType<typeof setInterval> | undefined
  let inFlight = false
  const notifiedIds = new Set<string>()

  async function poll() {
    const currentSessionId = sessionId
    if (!currentSessionId || !options.isCurrent(currentSessionId) || inFlight) return
    inFlight = true
    try {
      const pending = (await options.list(currentSessionId))
        .filter((approval) => approval.status === "pending")
      const pendingIds = new Set(pending.map((approval) => approval.id))
      for (const knownId of notifiedIds) {
        if (!pendingIds.has(knownId)) notifiedIds.delete(knownId)
      }
      const newApprovals = pending.filter((approval) => !notifiedIds.has(approval.id))
      if (newApprovals.length > 0 && sessionId === currentSessionId && options.isCurrent(currentSessionId)) {
        const handled = await options.onPending(currentSessionId, newApprovals)
        if (handled === false || sessionId !== currentSessionId || !options.isCurrent(currentSessionId)) return
        for (const approval of newApprovals) notifiedIds.add(approval.id)
      }
    } catch {
      // Durable turn completion stays authoritative; a failed poll is not an empty queue.
    } finally {
      inFlight = false
    }
  }

  function stop() {
    if (timer) clearInterval(timer)
    timer = undefined
    sessionId = undefined
    notifiedIds.clear()
  }

  function start(nextSessionId: string) {
    stop()
    sessionId = nextSessionId
    timer = setInterval(() => void poll(), 1_000)
  }

  return { start, stop, pollNow: poll }
}

/** Escape terminal controls before showing provider-supplied tool arguments. */
export function cliApprovalInputPreview(input: string, maxLength = 12_000): CliApprovalInputPreview {
  const safe = input.replace(
    /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/gu,
    (character) => `\\u${character.codePointAt(0)!.toString(16).padStart(4, "0")}`,
  )
  if (safe.length <= maxLength) return { text: safe, fullyVisible: true }
  return {
    text: safe.slice(0, maxLength),
    fullyVisible: false,
    truncationNotice: "Input truncated; approval is disabled because the complete request is not visible.",
  }
}

export function cliApprovalCanApprove(approvalId: string, inspectedIds: ReadonlySet<string>): boolean {
  return inspectedIds.has(approvalId)
}
