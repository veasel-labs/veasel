import type { TranscriptSegment } from "./transcript"

// Leaves room for header, sidebar chrome, composer, and footer.
export function transcriptPageSize(terminalRows: number): number {
  return Math.max(8, terminalRows - 14)
}

// offsetFromBottom 0 keeps the latest lines on screen; higher values page up.
export function moveTranscriptScroll(
  offsetFromBottom: number,
  deltaPages: number,
  totalLines: number,
  pageSize: number,
): number {
  const maxOffset = Math.max(0, totalLines - Math.max(1, pageSize))
  const step = Math.max(1, pageSize)
  const next = offsetFromBottom + deltaPages * step
  return Math.min(maxOffset, Math.max(0, next))
}

export function jumpTranscriptScroll(
  where: "home" | "end",
  totalLines: number,
  pageSize: number,
): number {
  if (where === "end") return 0
  return Math.max(0, totalLines - Math.max(1, pageSize))
}

// Split tone segments into display lines while preserving per-span tones.
export function transcriptSegmentLines(segments: TranscriptSegment[]): TranscriptSegment[][] {
  const lines: TranscriptSegment[][] = [[]]
  for (const segment of segments) {
    const parts = segment.text.split("\n")
    for (let index = 0; index < parts.length; index++) {
      if (index > 0) lines.push([])
      const piece = parts[index]!
      const line = lines[lines.length - 1]!
      if (piece.length > 0) line.push({ text: piece, tone: segment.tone })
      if (index < parts.length - 1) {
        if (line.length === 0) line.push({ text: "\n", tone: segment.tone })
        else {
          const last = line[line.length - 1]!
          line[line.length - 1] = { text: `${last.text}\n`, tone: last.tone }
        }
      }
    }
  }
  if (lines.length > 1 && lines[lines.length - 1]!.length === 0) lines.pop()
  return lines
}

export function windowTranscriptSegments(
  segments: TranscriptSegment[],
  offsetFromBottom: number,
  pageSize: number,
): { segments: TranscriptSegment[]; truncatedAbove: boolean; truncatedBelow: boolean } {
  const lines = transcriptSegmentLines(segments)
  const size = Math.max(1, pageSize)
  if (lines.length <= size) {
    return { segments, truncatedAbove: false, truncatedBelow: false }
  }
  const offset = Math.min(Math.max(0, offsetFromBottom), lines.length - size)
  const end = lines.length - offset
  const start = Math.max(0, end - size)
  const windowed = lines.slice(start, end)
  const flat: TranscriptSegment[] = []
  for (const line of windowed) {
    for (const segment of line) flat.push(segment)
  }
  return {
    segments: flat,
    truncatedAbove: start > 0,
    truncatedBelow: end < lines.length,
  }
}

// Footer cue when the viewport is above the latest lines. Streaming turns need
// an explicit "follow" hint so operators know End jumps back to the live reply.
export function transcriptBelowCue(options: {
  truncatedBelow: boolean
  streaming: boolean
}): string {
  if (!options.truncatedBelow) return ""
  if (options.streaming) return "\n▼ streaming below · End follows"
  return "\n▼ PgDn · later transcript"
}

/** Distance from the sticky bottom of an OpenTUI scrollbox (0 = following). */
export function scrollOffsetFromBottom(options: {
  scrollTop: number
  scrollHeight: number
  viewportHeight: number
}): number {
  const maxTop = Math.max(0, options.scrollHeight - Math.max(1, options.viewportHeight))
  return Math.max(0, maxTop - Math.max(0, options.scrollTop))
}

// Status-line copy when the operator has paged away from the latest reply.
// Returns undefined when stuck to the bottom so callers keep their idle cue.
export function transcriptScrollStatus(options: {
  offsetFromBottom: number
  streaming: boolean
}): string | undefined {
  if (options.offsetFromBottom <= 0) return undefined
  if (options.streaming) return "scrolled  ·  streaming below · End follows"
  return "scrolled  ·  End sticks to latest"
}

// While a turn streams, PgUp must still advertise End-follow; stick-to-bottom
// keeps the measured streaming busy cue. Callers that previously skipped scroll
// status entirely during send left Esc-cancel-while-scrolled without a cue.
export function liveStreamStatusMessage(options: {
  offsetFromBottom: number
  streaming: boolean
  streamingChars: number
  formatStreaming: (chars: number) => string
}): string | undefined {
  if (!options.streaming) return transcriptScrollStatus({
    offsetFromBottom: options.offsetFromBottom,
    streaming: false,
  })
  const scrolled = transcriptScrollStatus({
    offsetFromBottom: options.offsetFromBottom,
    streaming: true,
  })
  if (scrolled) return scrolled
  return options.formatStreaming(options.streamingChars)
}
