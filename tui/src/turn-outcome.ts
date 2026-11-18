// Honest finish text for a completed turn (epic #689, item B). The backend
// derives `outcome` and a public summary from recorded facts; a "completed"
// turn that applied edits or had approvals denied/expired must not look like
// a clean, verified success in the status line.

export type TurnOutcomeView = {
  status?: string
  outcome?: string
  error?: string
}

// Returns the warning to show instead of the idle "listening" status, or
// undefined when the turn really was a plain completion.
export function completedTurnNote(completion: TurnOutcomeView): string | undefined {
  if (completion.status !== "completed") return undefined
  const summary = completion.error?.trim()
  if (!summary) return undefined
  if (completion.outcome === "completed_with_denials") return `Done with denied approvals · ${summary}`
  if (completion.outcome === "completed") return `Done · ${summary}`
  return undefined
}

// A cancelled turn that already applied work says so; a plain cancel keeps
// the short existing wording.
export function cancelledTurnNote(completion: TurnOutcomeView, plain: string): string {
  const summary = completion.error?.trim()
  if (completion.outcome === "cancelled" && summary && summary !== "Turn cancelled.") return summary
  return plain
}
