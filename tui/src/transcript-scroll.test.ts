import { describe, expect, test } from "bun:test"
import {
  jumpTranscriptScroll,
  moveTranscriptScroll,
  transcriptBelowCue,
  transcriptPageSize,
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

  test("names End as the follow key while streaming above the live reply", () => {
    expect(transcriptBelowCue({ truncatedBelow: false, streaming: true })).toBe("")
    expect(transcriptBelowCue({ truncatedBelow: true, streaming: false })).toBe("\n▼ PgDn · later transcript")
    expect(transcriptBelowCue({ truncatedBelow: true, streaming: true })).toBe("\n▼ streaming below · End follows")
  })
})
