/**
 * Desktop attention notifications for finished turns.
 *
 * When the terminal window is blurred, a completed or failed turn raises an
 * OS notification through the OpenTUI renderer so long-running work can pull
 * the user back. Focused terminals stay quiet: the in-app status line and
 * toasts already cover that case. Unknown focus state is treated as focused
 * (quiet) so terminals without focus reporting never spam notifications.
 */

export type AttentionFocusState = "unknown" | "focused" | "blurred"

export type AttentionRendererLike = {
  readonly isDestroyed?: boolean
  on(event: "focus" | "blur", listener: () => void): unknown
  off?: (event: "focus" | "blur", listener: () => void) => unknown
  removeListener?: (event: "focus" | "blur", listener: () => void) => unknown
  triggerNotification(message: string, title?: string): boolean
}

const TITLE_LIMIT = 80
const MESSAGE_LIMIT = 240
const DEFAULT_TITLE = "Veasel Code"

function cleanAttentionText(value: string, limit: number): string {
  // Strip ANSI/control bytes so notification text stays plain and safe.
  const plain = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim()
  return plain.length > limit ? `${plain.slice(0, limit - 1)}…` : plain
}

export function attentionMessageForStatus(status: string, sessionTitle?: string): string | undefined {
  const title = sessionTitle ? cleanAttentionText(sessionTitle, TITLE_LIMIT) : ""
  if (status === "completed") return title ? `Turn complete · ${title}` : "Turn complete"
  if (status === "failed") return title ? `Turn failed · ${title}` : "Turn failed"
  return undefined
}

export function shouldNotifyAttention(state: AttentionFocusState): boolean {
  return state === "blurred"
}

export type AttentionNotifier = {
  notifyTurnFinished(status: string, sessionTitle?: string): boolean
  focusState(): AttentionFocusState
  dispose(): void
}

export function createAttentionNotifier(renderer: AttentionRendererLike): AttentionNotifier {
  let state: AttentionFocusState = "unknown"
  const onFocus = () => {
    state = "focused"
  }
  const onBlur = () => {
    state = "blurred"
  }
  renderer.on("focus", onFocus)
  renderer.on("blur", onBlur)
  let disposed = false
  return {
    focusState: () => state,
    notifyTurnFinished(status: string, sessionTitle?: string): boolean {
      if (disposed || renderer.isDestroyed) return false
      if (!shouldNotifyAttention(state)) return false
      const message = attentionMessageForStatus(status, sessionTitle)
      if (!message) return false
      try {
        return renderer.triggerNotification(cleanAttentionText(message, MESSAGE_LIMIT), DEFAULT_TITLE)
      } catch {
        return false
      }
    },
    dispose() {
      disposed = true
      const off = renderer.off ?? renderer.removeListener
      if (off) {
        off.call(renderer, "focus", onFocus)
        off.call(renderer, "blur", onBlur)
      }
    },
  }
}
