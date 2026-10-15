import {
  alignWordDiff,
  isWordDiffPair,
  prefersSideBySideDiff,
  sideBySideGutter,
  type WordDiffToken,
} from "./review-diff"

export type TranscriptTone =
  | "title"
  | "meta"
  | "notice"
  | "diffAdd"
  | "diffRemove"
  | "diffMeta"
  | "diffContext"
  | "userLabel"
  | "userText"
  | "assistantLabel"
  | "assistantText"
  | "systemLabel"
  | "systemText"
  | "toolLabel"
  | "toolText"
  | "codeFence"
  | "codeLang"
  | "codeBody"
  | "inlineCode"
  | "strong"
  | "listMarker"
  | "link"
  | "heading"
  | "blockquote"
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
  // Override the in-flight cursor glyph (reduced-motion / blink frames).
  streamingCursor?: string
  // "external" keeps assistant labels in the TextChunk transcript while
  // MarkdownRenderable owns the body (follow-mode live stream and/or the
  // latest completed assistant). "inline" is the TextChunk tone path when scrolled.
  streamingBodyMode?: "inline" | "external"
  // When "external-latest", omit only the last completed assistant body (label stays).
  // Streaming omission still follows streamingBodyMode.
  assistantBodyMode?: "inline" | "external-latest"
  hasOlder?: boolean
  showMessages?: boolean
  // Terminal columns for width-aware notice chrome (side-by-side word diffs).
  cols?: number
}

// Spoken role words stay in the plain-text transcript so roles remain clear
// without color (and when the row is copied). Brand lives in the header.
export const userLabel = "● you"
export const assistantLabel = "◆ assistant"
export const systemLabel = "○ system"
export const toolLabel = "▸ tool"
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
  if (input.notice) segments.push(...noticeSegments(input.notice, { cols: input.cols }))
  if (input.showMessages === false) return segments
  const externalLatest = input.assistantBodyMode === "external-latest"
  let latestAssistantIndex = -1
  if (externalLatest) {
    for (let index = input.messages.length - 1; index >= 0; index--) {
      if (turnKind(input.messages[index]!.role) === "assistant") {
        latestAssistantIndex = index
        break
      }
    }
  }
  const turns: Turn[] = input.messages.map((message, index) => ({
    kind: turnKind(message.role),
    content: externalLatest && index === latestAssistantIndex
        && !(input.streaming || input.streamingText)
      ? ""
      : message.content,
  }))
  if (input.pendingUserMessage) {
    turns.push({ kind: "user", content: input.pendingUserMessage, status: "sending" })
  }
  if (input.streaming || input.streamingText) {
    const external = input.streamingBodyMode === "external"
    const body = external ? "" : (input.streamingText ?? "")
    const cursor = input.streamingCursor ?? streamingCursor
    turns.push({
      kind: "assistant",
      content: input.streaming && !external ? `${body}${cursor}` : body,
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
    const prose = bodyTone(turn.kind)
    const body = indentBodySegments(messageBodySegments(turn.content, prose), prose)
    for (const segment of body) push(segment.text, segment.tone)
  })
  if (input.hasOlder) push("\n\n/history older · load earlier messages", "hint")
  return segments
}

// Body lines sit two spaces under the spoken role label so turns read as a
// clear hierarchy (label → prose) without adding chrome that copies poorly.
export const transcriptBodyIndent = "  "

export function indentBodySegments(
  segments: TranscriptSegment[],
  proseTone: TranscriptTone,
): TranscriptSegment[] {
  if (segments.length === 0) return [{ text: "\n", tone: proseTone }]
  const out: TranscriptSegment[] = [{ text: "\n", tone: proseTone }]
  let atLineStart = true
  for (const segment of segments) {
    let text = ""
    for (const ch of segment.text) {
      if (atLineStart) {
        text += transcriptBodyIndent
        atLineStart = false
      }
      text += ch
      if (ch === "\n") atLineStart = true
    }
    if (text) out.push({ text, tone: segment.tone })
  }
  return out
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
    const open = /^(```|~~~)(\S*)(.*)$/.exec(line)
    if (open && !inFence) {
      inFence = true
      fenceMarker = open[1]!
      segments.push({ text: fenceMarker, tone: "codeFence" })
      if (open[2]) segments.push({ text: open[2], tone: "codeLang" })
      segments.push({ text: `${open[3] ?? ""}${trailing}`, tone: "codeFence" })
      continue
    }
    if (inFence && fenceMarker && line.startsWith(fenceMarker) && /^(`{3}|~{3})\s*$/.test(line)) {
      inFence = false
      fenceMarker = ""
      segments.push({ text: `${line}${trailing}`, tone: "codeFence" })
      continue
    }
    if (inFence) {
      segments.push({ text: `${line}${trailing}`, tone: "codeBody" })
      continue
    }
    const heading = /^(#{1,6})(\s+)(.+)$/.exec(line)
    if (heading) {
      segments.push({ text: `${heading[1]}${heading[2]}`, tone: "heading" })
      segments.push(...proseInlineSegments(heading[3]!, "heading", trailing))
      continue
    }
    const quote = /^(\s*>\s?)(.*)$/.exec(line)
    if (quote) {
      segments.push({ text: quote[1]!, tone: "blockquote" })
      segments.push(...proseInlineSegments(quote[2]!, "blockquote", trailing))
      continue
    }
    const list = /^(\s*)([-*+]|\d+\.)(\s+)(.*)$/.exec(line)
    if (list) {
      segments.push({ text: `${list[1]}${list[2]}${list[3]}`, tone: "listMarker" })
      segments.push(...proseInlineSegments(list[4]!, proseTone, trailing))
      continue
    }
    segments.push(...proseInlineSegments(line, proseTone, trailing))
  }
  return segments
}

function nextInlineKind(rest: string): { next: number; kind: "code" | "bold" | "link" } | undefined {
  const codeAt = rest.indexOf("`")
  const boldAt = rest.indexOf("**")
  const linkAt = rest.indexOf("[")
  const candidates: Array<{ next: number; kind: "code" | "bold" | "link" }> = []
  if (codeAt >= 0) candidates.push({ next: codeAt, kind: "code" })
  if (boldAt >= 0) candidates.push({ next: boldAt, kind: "bold" })
  if (linkAt >= 0 && /^\[[^\]]+\]\([^)]+\)/.test(rest.slice(linkAt))) {
    candidates.push({ next: linkAt, kind: "link" })
  }
  if (candidates.length === 0) return undefined
  candidates.sort((left, right) => left.next - right.next)
  return candidates[0]
}

// Inline `code`, **strong**, and [label](url) spans keep their markers in the
// text so the transcript stays readable without color, while tones make them
// scannable during streaming.
export function proseInlineSegments(
  line: string,
  proseTone: TranscriptTone,
  trailing = "",
): TranscriptSegment[] {
  const segments: TranscriptSegment[] = []
  let rest = line
  while (rest.length > 0) {
    const hit = nextInlineKind(rest)
    if (!hit) {
      segments.push({ text: rest, tone: proseTone })
      break
    }
    if (hit.next > 0) segments.push({ text: rest.slice(0, hit.next), tone: proseTone })
    if (hit.kind === "code") {
      const close = rest.indexOf("`", hit.next + 1)
      if (close < 0) {
        segments.push({ text: rest.slice(hit.next), tone: proseTone })
        break
      }
      segments.push({ text: rest.slice(hit.next, close + 1), tone: "inlineCode" })
      rest = rest.slice(close + 1)
      continue
    }
    if (hit.kind === "bold") {
      const close = rest.indexOf("**", hit.next + 2)
      if (close < 0) {
        segments.push({ text: rest.slice(hit.next), tone: proseTone })
        break
      }
      segments.push({ text: rest.slice(hit.next, close + 2), tone: "strong" })
      rest = rest.slice(close + 2)
      continue
    }
    const linked = /^\[([^\]]+)\]\(([^)]+)\)/.exec(rest.slice(hit.next))
    if (!linked) {
      segments.push({ text: rest.slice(hit.next), tone: proseTone })
      break
    }
    segments.push({ text: linked[0]!, tone: "link" })
    rest = rest.slice(hit.next + linked[0]!.length)
  }
  if (trailing) {
    if (segments.length === 0) segments.push({ text: trailing, tone: proseTone })
    else {
      const last = segments[segments.length - 1]!
      segments[segments.length - 1] = { text: `${last.text}${trailing}`, tone: last.tone }
    }
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
      tone: token.kind === "change" ? changeTone : "diffContext",
    })
  }
  segments.push({ text: trailing, tone: "diffContext" })
  return segments
}

function sideBySideWordSegments(
  removed: WordDiffToken[],
  added: WordDiffToken[],
  trailing: string,
): TranscriptSegment[] {
  const segments: TranscriptSegment[] = [{ text: "-", tone: "diffRemove" }]
  for (const token of removed) {
    segments.push({
      text: token.text,
      tone: token.kind === "change" ? "diffRemove" : "diffContext",
    })
  }
  segments.push({ text: sideBySideGutter, tone: "diffMeta" })
  segments.push({ text: "+", tone: "diffAdd" })
  for (const token of added) {
    segments.push({
      text: token.text,
      tone: token.kind === "change" ? "diffAdd" : "diffContext",
    })
  }
  segments.push({ text: trailing, tone: "diffContext" })
  return segments
}

// Unified diffs keep their + and - prefixes. Adjacent -/+ hunk pairs also get
// word-level emphasis so only the changed tokens carry the add/remove tone.
// When the terminal is wide enough, short pairs render as one side-by-side row
// (`-left │ +right`) without switching the review surface to DiffRenderable.
export function noticeSegments(
  notice: string,
  options: { cols?: number } = {},
): TranscriptSegment[] {
  const cols = options.cols ?? 80
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
      if (prefersSideBySideDiff(line, next, cols)) {
        segments.push(...sideBySideWordSegments(aligned.removed, aligned.added, addedTrailing))
      } else {
        segments.push(...wordLineSegments("-", aligned.removed, "diffRemove", "\n"))
        segments.push(...wordLineSegments("+", aligned.added, "diffAdd", addedTrailing))
      }
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
    // Unified-diff context lines keep their leading space; mute them so +/- pop.
    if (line.startsWith(" ") || line === "") {
      segments.push({ text: `${line}${trailing}`, tone: "diffContext" })
      continue
    }
    segments.push({ text: `${line}${trailing}`, tone: "notice" })
  }
  return segments
}
