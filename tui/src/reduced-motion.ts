import { homedir } from "node:os"
import { readFileSync } from "node:fs"
import { join } from "node:path"

// Prefers quieter TUI chrome: no busy-glyph / streaming-cursor blink.
// Override with VEASEL_TUI_REDUCED_MOTION=1|0. When unset, honor common OS
// hints (GTK disable-animations; macOS reduce-motion env some shells export).

function parseBool(value: string | undefined): boolean | undefined {
  if (value === undefined) return undefined
  const trimmed = value.trim().toLowerCase()
  if (!trimmed) return undefined
  if (["1", "true", "yes", "on"].includes(trimmed)) return true
  if (["0", "false", "no", "off"].includes(trimmed)) return false
  return undefined
}

function gtkAnimationsDisabled(
  env: NodeJS.ProcessEnv,
  home: string,
  readFile: (path: string) => string,
): boolean {
  const base = env.XDG_CONFIG_HOME?.trim() || join(home, ".config")
  for (const relative of ["gtk-4.0/settings.ini", "gtk-3.0/settings.ini"]) {
    try {
      const text = readFile(join(base, relative))
      if (/^\s*gtk-enable-animations\s*=\s*false\s*$/im.test(text)) return true
    } catch {
      // Missing GTK settings is fine.
    }
  }
  return false
}

export function prefersReducedMotion(
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
  readFile: (path: string) => string = (path) => readFileSync(path, "utf8"),
): boolean {
  const forced = parseBool(env.VEASEL_TUI_REDUCED_MOTION)
  if (forced !== undefined) return forced
  // Some desktop/session managers export this; honor when present.
  const desktop = parseBool(env.PREFERS_REDUCED_MOTION)
    ?? parseBool(env.GTK_A11Y_REDUCED_MOTION)
  if (desktop !== undefined) return desktop
  if (gtkAnimationsDisabled(env, home, readFile)) return true
  return false
}

// Hollow busy glyphs that read as motion when cycled; reduced motion keeps one.
export const busyGlyphFrames = ["◌", "◍", "○", "◍"] as const
export const busyGlyphReduced = "◌"

export function busyGlyphForMotion(reducedMotion: boolean, frame = 0): string {
  if (reducedMotion) return busyGlyphReduced
  const index = ((frame % busyGlyphFrames.length) + busyGlyphFrames.length) % busyGlyphFrames.length
  return busyGlyphFrames[index]!
}

// Block cursor blinks when motion is allowed; reduced motion uses a static mid-dot.
export const streamingCursorFrames = ["█", "▌"] as const
export const streamingCursorReduced = "·"

export function streamingCursorForMotion(reducedMotion: boolean, frame = 0): string {
  if (reducedMotion) return streamingCursorReduced
  const index = ((frame % streamingCursorFrames.length) + streamingCursorFrames.length) % streamingCursorFrames.length
  return streamingCursorFrames[index]!
}
