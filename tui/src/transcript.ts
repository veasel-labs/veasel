import { alignWordDiff, isWordDiffPair, type WordDiffToken } from "./review-diff"

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
  | "systemLabel"
  | "systemText"
  | "toolLabel"
  | "toolText"
  | "codeFence"
  | "codeBody"
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
export const systemLabel = "○ SYSTEM"
export const toolLabel = "▸ TOOL"
export const streamingCursor = "█"

type TurnKind = "user" | "assistant" | "system" | "tool"

type Turn = {
  kind: TurnKind
  content: string
  status?: string
}

function turnKind(role: string): TurnKind {
  if (role === "assistant") return "assistant"
  if (role === "system") return "system"
  if (role === "tool" || role === "tool_result") return "tool"
  return "user"
}

function labelFor(kind: TurnKind): { text: string; tone: TranscriptTone } {
  if (kind === "assistant") return { text: assistantLabel, tone: "assistantLabel" }
  if (kind === "system") return { text: systemLabel, tone: "systemLabel" }
  if (kind === "tool") return { text: toolLabel, tone: "toolLabel" }
  return { text: userLabel, tone: "userLabel" }
}

function bodyTone(kind: TurnKind): TranscriptTone {
  if (kind === "assistant") return "assistantText"
  if (kind === "system") return "systemText"
  if (kind === "tool") return "toolText"
  return "userText"
}

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
  const turns: Turn[] = input.messages.map((message) => ({
    kind: turnKind(message.role),
    content: message.content,
  }))
  if (input.pendingUserMessage) {
    turns.push({ kind: "user", content: input.pendingUserMessage, status: "sending" })
  }
  if (input.streaming || input.streamingText) {
    const body = input.streamingText ?? ""
    turns.push({
      kind: "assistant",
      content: input.streaming ? `${body}${streamingCursor}` : body,
      status: input.streaming ? "streaming…" : "partial response",
    })
  }
  if (turns.length === 0) {
    push("Start with a question or describe a coding task.", "hint")
  }
  turns.forEach((turn, index) => {
    if (index > 0) push("\n\n", "meta")
    const label = labelFor(turn.kind)
    push(label.text, label.tone)
    if (turn.status) push(`  ·  ${turn.status}`, "status")
    const body = messageBodySegments(turn.content, bodyTone(turn.kind))
    if (body.length === 0) {
      push("\n", bodyTone(turn.kind))
    } else {
      body[0] = { text: `\n${body[0]!.text}`, tone: body[0]!.tone }
      for (const segment of body) push(segment.text, segment.tone)
    }
  })
  if (input.hasOlder) push("\n\n/history older · load earlier messages", "hint")
  return segments
}

// Split prose from fenced code so ``` / ~~~ blocks stay visually distinct while
// streaming and after the turn lands. Fence markers stay in the text itself.
export function messageBodySegments(content: string, proseTone: TranscriptTone): TranscriptSegment[] {
  if (!content) return []
  const lines = content.split("\n")
  const segments: TranscriptSegment[] = []
  let inFence = false
  let fenceMarker = ""
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!
    const trailing = index < lines.length - 1 ? "\n" : ""
    const open = /^(```|~~~)(.*)$/.exec(line)
    if (open && !inFence) {
      inFence = true
      fenceMarker = open[1]!
      segments.push({ text: `${line}${trailing}`, tone: "codeFence" })
      continue
    }
    if (inFence && fenceMarker && line.startsWith(fenceMarker) && /^(`{3}|~{3})\s*$/.test(line)) {
      inFence = false
      fenceMarker = ""
      segments.push({ text: `${line}${trailing}`, tone: "codeFence" })
      continue
    }
    segments.push({ text: `${line}${trailing}`, tone: inFence ? "codeBody" : proseTone })
  }
  return segments
}

export function transcriptPlainText(segments: TranscriptSegment[]): string {
  return segments.map((segment) => segment.text).join("")
}

function wordLineSegments(
  prefix: "-" | "+",
  tokens: WordDiffToken[],
  changeTone: TranscriptTone,
  trailing: string,
): TranscriptSegment[] {
  const segments: TranscriptSegment[] = [{ text: prefix, tone: changeTone }]
  for (const token of tokens) {
    segments.push({
      text: token.text,
      tone: token.kind === "change" ? changeTone : "notice",
    })
  }
  segments.push({ text: trailing, tone: "notice" })
  return segments
}

// Unified diffs keep their + and - prefixes. Adjacent -/+ hunk pairs also get
// word-level emphasis so only the changed tokens carry the add/remove tone.
export function noticeSegments(notice: string): TranscriptSegment[] {
  const lines = notice.split("\n")
  const diff = lines.some((line) => line.startsWith("@@") || line.startsWith("diff --git ") || line.startsWith("--- ") || line.startsWith("+++ "))
  if (!diff) return [{ text: `${notice}\n\n`, tone: "notice" }]
  const segments: TranscriptSegment[] = []
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!
    const trailing = index === lines.length - 1 ? "\n\n" : "\n"
    const next = lines[index + 1]
    if (next && isWordDiffPair(line, next)) {
      const aligned = alignWordDiff(line, next)
      const addedTrailing = index + 1 === lines.length - 1 ? "\n\n" : "\n"
      segments.push(...wordLineSegments("-", aligned.removed, "diffRemove", "\n"))
      segments.push(...wordLineSegments("+", aligned.added, "diffAdd", addedTrailing))
      index++
      continue
    }
    if (line.startsWith("+") && !line.startsWith("+++")) {
      segments.push({ text: `${line}${trailing}`, tone: "diffAdd" })
      continue
    }
    if (line.startsWith("-") && !line.startsWith("---")) {
      segments.push({ text: `${line}${trailing}`, tone: "diffRemove" })
      continue
    }
    if (line.startsWith("@@") || line.startsWith("diff ") || line.startsWith("index ") || line.startsWith("---") || line.startsWith("+++")) {
      segments.push({ text: `${line}${trailing}`, tone: "diffMeta" })
      continue
    }
    segments.push({ text: `${line}${trailing}`, tone: "notice" })
  }
  return segments
}
