/**
 * Transcript message navigation — jump previous/next user (or any) message.
 * Engineering pattern from OpenCode message-navigation / anchors; Veasel-owned
 * ids, shortcuts, and mint chrome (no opencode.* keys).
 */

export type TranscriptNavMessage = {
  /** Index into the flat transcript message list. */
  index: number
  role: string
  content: string
  id?: string | number
}

export type TranscriptNavDirection = "next" | "prev"

/** Discoverable bindings — Alt matches LiveApp sidebar resize chords. */
export const messageNavShortcut = {
  previousUser: { name: "[", meta: true, label: "Alt+[" },
  nextUser: { name: "]", meta: true, label: "Alt+]" },
  lastUser: { name: "end", meta: true, label: "Alt+End" },
} as const

function hasVisibleText(content: string): boolean {
  return content.trim().length > 0
}

/** List scroll targets; `userOnly` keeps user turns with non-empty text. */
export function listMessageNavTargets(
  messages: readonly { role: string; content: string; id?: string | number }[],
  options?: { userOnly?: boolean },
): TranscriptNavMessage[] {
  const userOnly = options?.userOnly ?? false
  const targets: TranscriptNavMessage[] = []
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index]!
    if (!hasVisibleText(message.content)) continue
    if (userOnly) {
      if (message.role !== "user") continue
    } else if (message.role !== "user" && message.role !== "assistant") {
      continue
    }
    targets.push({
      index,
      role: message.role,
      content: message.content,
      id: message.id,
    })
  }
  return targets
}

/**
 * Pick the adjacent target from an explicit cursor index.
 * When `currentIndex` is undefined, prev → last target, next → first.
 */
export function findAdjacentMessageTarget(input: {
  targets: readonly TranscriptNavMessage[]
  currentIndex: number | undefined
  direction: TranscriptNavDirection
}): TranscriptNavMessage | undefined {
  const { targets, direction } = input
  if (targets.length === 0) return undefined
  if (input.currentIndex === undefined) {
    return direction === "next" ? targets[0] : targets[targets.length - 1]
  }
  const at = targets.findIndex((target) => target.index === input.currentIndex)
  if (at === -1) {
    // Cursor points at a non-target (e.g. tool row): step from neighbors.
    if (direction === "next") {
      return targets.find((target) => target.index > input.currentIndex!) ?? undefined
    }
    for (let i = targets.length - 1; i >= 0; i--) {
      if (targets[i]!.index < input.currentIndex!) return targets[i]
    }
    return undefined
  }
  return targets[at + (direction === "next" ? 1 : -1)]
}

/** Most recent user message with visible text. */
export function findLastUserMessageTarget(
  messages: readonly { role: string; content: string; id?: string | number }[],
): TranscriptNavMessage | undefined {
  const targets = listMessageNavTargets(messages, { userOnly: true })
  return targets[targets.length - 1]
}

export type MessageScrollChild = {
  index: number
  y: number
}

/**
 * Geometry-aware boundary (OpenCode findMessageBoundary idea): when no cursor,
 * prev finds the last target above scrollTop; next finds the first below.
 */
export function findMessageBoundaryByScroll(input: {
  direction: TranscriptNavDirection
  children: readonly MessageScrollChild[]
  scrollTop: number
  currentIndex?: number
}): MessageScrollChild | undefined {
  const visible = [...input.children].sort((a, b) => a.y - b.y)
  if (visible.length === 0) return undefined
  if (input.currentIndex !== undefined) {
    const at = visible.findIndex((child) => child.index === input.currentIndex)
    if (at !== -1) return visible[at + (input.direction === "next" ? 1 : -1)]
  }
  if (input.direction === "next") {
    return visible.find((child) => child.y > input.scrollTop)
  }
  for (let i = visible.length - 1; i >= 0; i--) {
    if (visible[i]!.y < input.scrollTop) return visible[i]
  }
  return undefined
}
