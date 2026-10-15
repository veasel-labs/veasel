export type TranscriptTone =
  | "title"
  | "meta"
  | "notice"
  | "diffAdd"
  | "diffRemove"
  | "diffMeta"
  | "userLabel"
  | "userText"
  | "assistantLabel"
  | "assistantText"
  | "status"
  | "hint"

export type TranscriptSegment = { text: string; tone: TranscriptTone }

export type TranscriptMessage = { role: string; content: string }

export type TranscriptInput = {
  session?: { title: string; directory: string }
  notice?: string
  messages: TranscriptMessage[]
  pendingUserMessage?: string
  streamingText?: string
  streaming?: boolean
  hasOlder?: boolean
  showMessages?: boolean
}

export const userLabel = "● YOU"
export const assistantLabel = "◆ VEASEL"

// Builds the session transcript as tone-tagged text. Roles stay in the text
// itself, so the transcript remains readable without color, and each body uses
// its role's tone so wrapped lines never look like the other speaker.
export function transcriptSegments(input: TranscriptInput): TranscriptSegment[] {
  const segments: TranscriptSegment[] = []
  const push = (text: string, tone: TranscriptTone) => {
    if (text) segments.push({ text, tone })
  }
  if (input.session) {
    push(`${input.session.title}\n`, "title")
    push(`${input.session.directory}\n\n`, "meta")
  }
  if (input.notice) segments.push(...noticeSegments(input.notice))
  if (input.showMessages === false) return segments
  const turns: Array<{ user: boolean; content: string; status?: string }> = input.messages.map((message) => ({
    user: message.role !== "assistant",
    content: message.content,
  }))
  if (input.pendingUserMessage) turns.push({ user: true, content: input.pendingUserMessage, status: "sending" })
  if (input.streamingText) {
    turns.push({ user: false, content: input.streamingText, status: input.streaming ? "streaming…" : "partial response" })
  }
  if (turns.length === 0) {
    push("Start with a question or describe a coding task.", "hint")
  }
  turns.forEach((turn, index) => {
    if (index > 0) push("\n\n", "meta")
    push(turn.user ? userLabel : assistantLabel, turn.user ? "userLabel" : "assistantLabel")
    if (turn.status) push(`  ·  ${turn.status}`, "status")
    push(`\n${turn.content}`, turn.user ? "userText" : "assistantText")
  })
  if (input.hasOlder) push("\n\n/history older · load earlier messages", "hint")
  return segments
}

export function transcriptPlainText(segments: TranscriptSegment[]): string {
  return segments.map((segment) => segment.text).join("")
}

// Unified diffs keep their + and - prefixes, and each changed line gets its
// own tone so color is not the only way to tell an addition from a removal.
export function noticeSegments(notice: string): TranscriptSegment[] {
  const lines = notice.split("\n")
  const diff = lines.some((line) => line.startsWith("@@") || line.startsWith("diff --git ") || line.startsWith("--- ") || line.startsWith("+++ "))
  if (!diff) return [{ text: `${notice}\n\n`, tone: "notice" }]
  return lines.map((line, index) => {
    const text = `${line}${index === lines.length - 1 ? "\n\n" : "\n"}`
    if (line.startsWith("+") && !line.startsWith("+++")) return { text, tone: "diffAdd" as const }
    if (line.startsWith("-") && !line.startsWith("---")) return { text, tone: "diffRemove" as const }
    if (line.startsWith("@@") || line.startsWith("diff ") || line.startsWith("index ") || line.startsWith("---") || line.startsWith("+++")) {
      return { text, tone: "diffMeta" as const }
    }
    return { text, tone: "notice" as const }
  })
}
