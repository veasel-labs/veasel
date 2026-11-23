export type CliApprovalInputPreview = {
  text: string
  fullyVisible: boolean
}

export type CliToolApproval = {
  id: string
  session_id: string
  request_id: string
  tool_name: string
  input_json: string
  status: "pending" | "approved" | "denied" | "expired"
  created_at: string
  updated_at: string
}

export type CliApprovalPollerOptions = {
  list: (sessionId: string) => Promise<CliToolApproval[]>
  isCurrent: (sessionId: string) => boolean
  onPending: (sessionId: string, approvals: CliToolApproval[]) => void | Promise<void>
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
      const hasNewRequest = pending.some((approval) => !notifiedIds.has(approval.id))
      for (const approval of pending) notifiedIds.add(approval.id)
      if (hasNewRequest && sessionId === currentSessionId && options.isCurrent(currentSessionId)) {
        await options.onPending(currentSessionId, pending)
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
    /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/gu,
    (character) => `\\u${character.codePointAt(0)!.toString(16).padStart(4, "0")}`,
  )
  if (safe.length <= maxLength) return { text: safe, fullyVisible: true }
  return {
    text: `${safe.slice(0, maxLength)}\n… input truncated; approval is disabled until the full request can be reviewed.`,
    fullyVisible: false,
  }
}

export function cliApprovalCanApprove(approvalId: string, inspectedIds: ReadonlySet<string>): boolean {
  return inspectedIds.has(approvalId)
}
