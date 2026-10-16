import { describe, expect, test } from "bun:test"
import {
  jumpTranscriptScroll,
  liveStreamStatusMessage,
  moveTranscriptScroll,
  scrollOffsetFromBottom,
  transcriptBelowCue,
  transcriptPageSize,
  transcriptScrollStatus,
  transcriptSegmentLines,
  windowTranscriptSegments,
} from "./transcript-scroll"
import type { TranscriptSegment } from "./transcript"

describe("transcript page scroll", () => {
  test("pages without wrapping past the ends", () => {
    expect(transcriptPageSize(40)).toBe(26)
    expect(moveTranscriptScroll(0, 1, 100, 20)).toBe(20)
    expect(moveTranscriptScroll(20, 1, 100, 20)).toBe(40)
    expect(moveTranscriptScroll(80, 1, 100, 20)).toBe(80)
    expect(moveTranscriptScroll(20, -1, 100, 20)).toBe(0)
    expect(jumpTranscriptScroll("end", 100, 20)).toBe(0)
    expect(jumpTranscriptScroll("home", 100, 20)).toBe(80)
  })

  test("windows tone segments by line while preserving markers", () => {
    const segments: TranscriptSegment[] = [
      { text: "one\n", tone: "assistantText" },
      { text: "two\n", tone: "assistantText" },
      { text: "three\n", tone: "strong" },
      { text: "four", tone: "assistantText" },
    ]
    expect(transcriptSegmentLines(segments)).toHaveLength(4)
    const windowed = windowTranscriptSegments(segments, 0, 2)
    expect(windowed.truncatedAbove).toBe(true)
    expect(windowed.truncatedBelow).toBe(false)
    expect(windowed.segments.map((segment) => segment.text).join("")).toBe("three\nfour")
    expect(windowed.segments).toContainEqual({ text: "three\n", tone: "strong" })
    const upper = windowTranscriptSegments(segments, 2, 2)
    expect(upper.truncatedAbove).toBe(false)
    expect(upper.truncatedBelow).toBe(true)
    expect(upper.segments.map((segment) => segment.text).join("")).toBe("one\ntwo\n")
  })

  test("measures scrollbox distance from the sticky bottom", () => {
    expect(scrollOffsetFromBottom({ scrollTop: 80, scrollHeight: 100, viewportHeight: 20 })).toBe(0)
    expect(scrollOffsetFromBottom({ scrollTop: 40, scrollHeight: 100, viewportHeight: 20 })).toBe(40)
    expect(scrollOffsetFromBottom({ scrollTop: 0, scrollHeight: 100, viewportHeight: 20 })).toBe(80)
    expect(scrollOffsetFromBottom({ scrollTop: 0, scrollHeight: 10, viewportHeight: 20 })).toBe(0)
  })

  test("names End as the follow key while streaming above the live reply", () => {
    expect(transcriptBelowCue({ truncatedBelow: false, streaming: true })).toBe("")
    expect(transcriptBelowCue({ truncatedBelow: true, streaming: false })).toBe("\n▼ PgDn · later transcript")
    expect(transcriptBelowCue({ truncatedBelow: true, streaming: true })).toBe("\n▼ streaming below · End follows")
  })

  test("status names End when the transcript is scrolled up", () => {
    expect(transcriptScrollStatus({ offsetFromBottom: 0, streaming: true })).toBeUndefined()
    expect(transcriptScrollStatus({ offsetFromBottom: 12, streaming: false })).toBe(
      "scrolled  ·  End sticks to latest",
    )
    expect(transcriptScrollStatus({ offsetFromBottom: 12, streaming: true })).toBe(
      "scrolled  ·  streaming below · End follows",
    )
  })

  test("live stream status prefers scroll-follow over busy growth while paged up", () => {
    const formatStreaming = (chars: number) => `streaming  ·  ${chars} chars`
    expect(liveStreamStatusMessage({
      offsetFromBottom: 0,
      streaming: true,
      streamingChars: 42,
      formatStreaming,
    })).toBe("streaming  ·  42 chars")
    expect(liveStreamStatusMessage({
      offsetFromBottom: 20,
      streaming: true,
      streamingChars: 42,
      formatStreaming,
    })).toBe("scrolled  ·  streaming below · End follows")
    expect(liveStreamStatusMessage({
      offsetFromBottom: 20,
      streaming: false,
      streamingChars: 0,
      formatStreaming,
    })).toBe("scrolled  ·  End sticks to latest")
  })
})
