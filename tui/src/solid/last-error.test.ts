import { describe, expect, test } from "bun:test"
import { recordLiveLastError, resolveLiveErrorDetails } from "./last-error"

describe("live last error", () => {
  test("records trimmed fields with timestamp", () => {
    const recorded = recordLiveLastError(undefined, {
      title: " Message failed ",
      source: " send ",
      context: " session-1 ",
      error: "  timeout  ",
      at: 42,
    })
    expect(recorded).toEqual({
      title: "Message failed",
      source: "send",
      context: "session-1",
      error: "timeout",
      at: 42,
    })
  })

  test("resolves empty-state copy when nothing recorded", () => {
    const empty = resolveLiveErrorDetails(undefined)
    expect(empty.title).toBe("No recent errors")
    expect(empty.error).toContain("No failures recorded")
    const last = recordLiveLastError(undefined, {
      title: "Boom",
      source: "api",
      error: "nope",
      at: 1,
    })
    expect(resolveLiveErrorDetails(last).error).toBe("nope")
  })
})
