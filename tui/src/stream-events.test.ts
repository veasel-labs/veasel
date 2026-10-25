import { describe, expect, test } from "bun:test"
import {
  admitAssistantDelta,
  appendStreamingDelta,
  createStreamDeltaBatcher,
  isAssistantDeltaEvent,
  parseSseBlock,
} from "./stream-events"

describe("stream event helpers", () => {
  test("parses one SSE frame without replaying duplicate event lines", () => {
    const frame = [
      "id: 7",
      "event: assistant.delta",
      "event: assistant.delta",
      "data: {\"session_id\":\"s\",\"data\":{\"operation_id\":\"op\",\"delta\":\"ab\"}}",
      "",
    ].join("\n")
    const parsed = parseSseBlock(frame)
    expect(parsed.id).toBe("7")
    expect(parsed.event).toBe("assistant.delta")
    expect(JSON.parse(parsed.data).data.delta).toBe("ab")
    expect(isAssistantDeltaEvent(parsed.event)).toBe(true)
  })

  test("admits deltas only for the active session turn", () => {
    expect(admitAssistantDelta({
      sessionId: "s1",
      activeSessionId: "s1",
      operationId: "op1",
      activeTurnId: "op1",
      delta: "hello",
    })).toBe("hello")
    expect(admitAssistantDelta({
      sessionId: "other",
      activeSessionId: "s1",
      operationId: "op1",
      activeTurnId: "op1",
      delta: "hello",
    })).toBeUndefined()
    expect(admitAssistantDelta({
      sessionId: "s1",
      activeSessionId: "s1",
      operationId: "stale",
      activeTurnId: "op1",
      delta: "hello",
    })).toBeUndefined()
    expect(admitAssistantDelta({
      sessionId: "s1",
      activeSessionId: "s1",
      operationId: "op1",
      activeTurnId: "op1",
      delta: "",
    })).toBeUndefined()
  })

  test("appends multi-delta races in arrival order", () => {
    let text = ""
    for (const delta of ["stream line 01\n", "stream line 02\n", "STREAM-TAIL\n"]) {
      text = appendStreamingDelta(text, delta)
    }
    expect(text).toContain("stream line 01")
    expect(text).toContain("stream line 02")
    expect(text.endsWith("STREAM-TAIL\n")).toBe(true)
  })

  test("batches SSE fragments in order and flushes once", () => {
    const flushed: string[] = []
    const scheduled: Array<() => void> = []
    let cancelled = 0
    const batcher = createStreamDeltaBatcher(
      (text) => flushed.push(text),
      (callback) => {
        scheduled.push(callback)
        return scheduled.length
      },
      () => { cancelled++ },
    )

    batcher.push("first ")
    batcher.push("second")
    expect(scheduled).toHaveLength(1)
    expect(flushed).toEqual([])
    batcher.flush()
    expect(flushed).toEqual(["first second"])
    expect(cancelled).toBe(1)
    scheduled[0]!()
    expect(flushed).toEqual(["first second"])
  })

  test("clear drops stale fragments when changing sessions", () => {
    const flushed: string[] = []
    const scheduled: Array<() => void> = []
    let cancelled = 0
    const batcher = createStreamDeltaBatcher(
      (text) => flushed.push(text),
      (callback) => {
        scheduled.push(callback)
        return scheduled.length
      },
      () => { cancelled++ },
    )

    batcher.push("old session")
    batcher.clear()
    scheduled[0]!()
    expect(flushed).toEqual([])
    expect(cancelled).toBe(1)
  })
})
