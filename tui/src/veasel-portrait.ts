import type { Theme } from "./themes"

/**
 * Pixel portrait of Veasel (V language mascot adaptation).
 * License: CC BY-NC 4.0 — see THIRD_PARTY_NOTICES.md. Not covered by MIT.
 *
 * Legend: D dark outline · B body · L leaf · K/H eyes · N nose · W muzzle · space empty
 */
export const VEASEL_PORTRAIT_ROWS = [
  "    DDDDD     DDDDD    ",
  "   DLLLLD     DLLLLD   ",
  "  DLLLLLDDDDDDDLLLLLD  ",
  "  DLLLDDDDDDDDDDDLLLDD ",
  " DDDDDDDDBBBBBBDDDDDDD ",
  "DDDDDDBBBBBBBBBBBBBBDDDD",
  "DDDDBBBBBBBBBBBBBBBBBBDDD",
  "DDBBBBBBBBBBBBBBBBBBBBBBDD",
  "DBBBBKBBBBBBBBBBBBKBBBBBBBD",
  "DBBBBHKBBBBBBBBBBHKBBBBBBBD",
  "DBBBBBBBBBBNNBBBBBBBBBBBBBD",
  " DDBBWWWWWNNNNNWWWWWWBBBBDD ",
  "  DDBBWWWWWWWWWWWWBBBBDD  ",
  "   DDDBBWWWWWWWWBBBDDD   ",
  "     DDDBBBBBBBDDD     ",
  "       DDDDDD       ",
] as const

export type PortraitKey = keyof Theme["portrait"]

export type PortraitCell = {
  /** Display glyph (two columns wide for block pixels). */
  glyph: string
  color: string
}

export function portraitCellColor(theme: Theme, pixel: string): string {
  if (pixel === " ") return theme.panelBg
  const key = pixel as PortraitKey
  return theme.portrait[key] ?? theme.panelBg
}

/** Expand one portrait row into colored double-width cells for TUI rendering. */
export function portraitRowCells(theme: Theme, row: string): PortraitCell[] {
  return [...row].map((pixel) => ({
    glyph: pixel === " " ? "  " : "██",
    color: portraitCellColor(theme, pixel),
  }))
}

export function portraitRowPlain(row: string): string {
  return [...row].map((pixel) => (pixel === " " ? "  " : "██")).join("")
}
