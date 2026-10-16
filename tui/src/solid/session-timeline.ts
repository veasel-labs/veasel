export type TimelineMessage = {
  role: string
  content: string
}

export type SessionTimelineEntry = {
  /** Stable id for DialogSelect value (`user-0`, …). */
  id: string
  /** Index into the full messages array. */
  messageIndex: number
  /** 1-based user-turn ordinal (newest list still keeps ascending ordinals). */
  turn: number
  title: string
  content: string
}

export function timelinePreview(text: string, max = 56): string {
  const first = text.replace(/\s+/g, " ").trim()
  if (!first) return "(empty)"
  if (first.length <= max) return first
  return `${first.slice(0, Math.max(1, max - 1)).trimEnd()}…`
}

/** User messages newest-first for the timeline dialog (OpenCode order). */
export function buildSessionTimeline(
  messages: readonly TimelineMessage[],
): SessionTimelineEntry[] {
  const entries: SessionTimelineEntry[] = []
  let turn = 0
  messages.forEach((message, messageIndex) => {
    if (message.role !== "user") return
    turn += 1
    entries.push({
      id: `user-${messageIndex}`,
      messageIndex,
      turn,
      title: timelinePreview(message.content),
      content: message.content,
    })
  })
  return entries.reverse()
}
