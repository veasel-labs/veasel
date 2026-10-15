import { describe, expect, test } from "bun:test"
import {
  busyGlyphForMotion,
  busyGlyphFrames,
  prefersReducedMotion,
  streamingCursorForMotion,
  streamingCursorFrames,
  streamingCursorReduced,
} from "./reduced-motion"

describe("reduced motion preference", () => {
  test("honors VEASEL_TUI_REDUCED_MOTION over OS hints", () => {
    expect(prefersReducedMotion({ VEASEL_TUI_REDUCED_MOTION: "1" }, "/tmp")).toBe(true)
    expect(prefersReducedMotion({
      VEASEL_TUI_REDUCED_MOTION: "0",
      PREFERS_REDUCED_MOTION: "1",
    }, "/tmp")).toBe(false)
  })

  test("reads GTK disable-animations when the override is unset", () => {
    const home = "/tmp/veasel-reduced-home"
    const env = { XDG_CONFIG_HOME: `${home}/.config` }
    expect(prefersReducedMotion(env, home, (path) => {
      if (path.endsWith("gtk-3.0/settings.ini")) return "gtk-enable-animations=false\n"
      throw new Error("missing")
    })).toBe(true)
    expect(prefersReducedMotion(env, home, () => {
      throw new Error("missing")
    })).toBe(false)
  })

  test("gates busy glyph and streaming cursor frames", () => {
    expect(busyGlyphForMotion(true, 3)).toBe("◌")
    expect(busyGlyphForMotion(false, 0)).toBe(busyGlyphFrames[0])
    expect(busyGlyphForMotion(false, 1)).toBe(busyGlyphFrames[1])
    expect(streamingCursorForMotion(true, 9)).toBe(streamingCursorReduced)
    expect(streamingCursorForMotion(false, 0)).toBe(streamingCursorFrames[0])
    expect(streamingCursorForMotion(false, 1)).toBe(streamingCursorFrames[1])
  })
})
