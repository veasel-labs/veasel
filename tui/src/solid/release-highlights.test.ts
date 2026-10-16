import { describe, expect, test } from "bun:test"
import { liveReleaseHighlights } from "./release-highlights"

describe("liveReleaseHighlights", () => {
  test("lists current LiveApp capability notes", () => {
    const entries = liveReleaseHighlights()
    expect(entries.length).toBeGreaterThanOrEqual(3)
    expect(entries.some((entry) => /review/i.test(entry.title + entry.body))).toBe(true)
    expect(entries.some((entry) => /provider|connect|F2/i.test(entry.title + entry.body))).toBe(
      true,
    )
  })
})
