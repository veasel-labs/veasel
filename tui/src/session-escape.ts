// Layered Esc: cancel in-flight turn, dismiss an overlay notice, then leave.

export type SessionEscapeAction = "cancel-turn" | "dismiss-notice" | "leave-session"

export function sessionEscapeAction(input: {
  sending: boolean
  hasNotice: boolean
}): SessionEscapeAction {
  if (input.sending) return "cancel-turn"
  if (input.hasNotice) return "dismiss-notice"
  return "leave-session"
}
