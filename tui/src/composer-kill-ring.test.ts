import { describe, expect, test } from "bun:test"
import { emptyKillRing, latestKill, pushKill, yankAtCursor } from "./composer-kill-ring"

describe("composer kill ring", () => {
  test("ignores empty kills and returns the latest entry", () => {
    let ring = emptyKillRing()
    ring = pushKill(ring, "")
    expect(latestKill(ring)).toBeUndefined()
    ring = pushKill(ring, "one")
    ring = pushKill(ring, "two")
    expect(latestKill(ring)).toBe("two")
  })

  test("yanks at the cursor without dropping surrounding text", () => {
    expect(yankAtCursor("ab", 1, "XY")).toEqual({ value: "aXYb", cursor: 3 })
    expect(yankAtCursor("", 0, "hi")).toEqual({ value: "hi", cursor: 2 })
    expect(yankAtCursor("keep", 4, "")).toEqual({ value: "keep", cursor: 4 })
  })
})
