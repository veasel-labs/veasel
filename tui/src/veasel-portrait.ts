import type { Theme } from "./themes"

/** Original MIT-licensed pixel weasel for the Veasel Code terminal client. */
export const VEASEL_PORTRAIT_WIDTH = 24

function centerSpriteRow(row: string): string {
  const left = Math.max(0, Math.floor((VEASEL_PORTRAIT_WIDTH - row.length) / 2))
  return row.padStart(left + row.length, " ").padEnd(VEASEL_PORTRAIT_WIDTH, " ")
}

const pixelSprite = [
  "       DDD    DDD      ",
  "      DBBBD  DBBBD     ",
  "     DBBBBLDDLBLBBBBBD ",
  "    DBBBBBBDDDDBBBBBBD ",
  "   DBBBBBBBBBBBBBBBBD  ",
  "  DBBBBBBBBBBBBBBBBBD  ",
  " DBBBBBBBBBBBBBBBBBBBD ",
  "DBBBBLLBBBBBBBBLLBBBBD",
  "DBBBLLLBBBBBBBBLLLBBBD",
  ["D", "BBB", "WWLKH", "BBB", "HKLWW", "BBB", "D"].join(""),
  ["D", "BBB", "WWLLK", "BBB", "KLLWW", "BBB", "D"].join(""),
  " DBBBBBBLLLLBBBBBBBBBD",
  "  DBBBBBBLLKKLLBBBBBBD",
  "   DBBBBBBBLKKLBBBBBBD",
  "    DBBBBBBBLLBBBBBBD",
  "     DBBBBBBBBBBBBBD",
  "      DDDDDDDDDDDDD",
].map(centerSpriteRow)

export const VEASEL_PORTRAIT_ROWS = pixelSprite

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

/** Expand one sprite row into colored double-width cells for TUI rendering. */
export function portraitRowCells(theme: Theme, row: string): PortraitCell[] {
  return [...row.padEnd(VEASEL_PORTRAIT_WIDTH, " ")].map((pixel) => ({
    glyph: pixel === " " ? "  " : "██",
    color: portraitCellColor(theme, pixel),
  }))
}

export function portraitRowPlain(row: string): string {
  return [...row.padEnd(VEASEL_PORTRAIT_WIDTH, " ")]
    .map((pixel) => (pixel === " " ? "  " : "██"))
    .join("")
}
