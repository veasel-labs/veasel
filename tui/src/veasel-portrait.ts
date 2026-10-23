import type { Theme } from "./themes"

/**
 * Original pixel companion for the Veasel Code terminal client.
 * This geometric terminal sprite was drawn for this project and is covered by
 * the repository MIT license. It does not reuse the V mascot artwork.
 *
 * Legend: D outline · B shell · L status light · K visor · H gleam · N signal · W display
 */
export const VEASEL_PORTRAIT_WIDTH = 24

function centerSpriteRow(row: string): string {
  const left = Math.max(0, Math.floor((VEASEL_PORTRAIT_WIDTH - row.length) / 2))
  return row.padStart(left + row.length, " ").padEnd(VEASEL_PORTRAIT_WIDTH, " ")
}

const pixelSprite = [
  "DDDDDDD",
  "DBBBBBBD",
  "DBLHLBD",
  "DDD",
  "BBB",
  `D${"B".repeat(21)}D`,
  `D${"B".repeat(4)}${"K".repeat(13)}${"B".repeat(4)}D`,
  `D${"B".repeat(4)}KLLHKKKKKHLLK${"B".repeat(4)}D`,
  `D${"B".repeat(4)}${"K".repeat(13)}${"B".repeat(4)}D`,
  `D${"B".repeat(4)}KKKKKLLLKKKKK${"B".repeat(4)}D`,
  `D${"B".repeat(21)}D`,
  `D${"B".repeat(3)}DD${"B".repeat(11)}DD${"B".repeat(3)}D`,
  `  D${"B".repeat(5)}L${"B".repeat(5)}D  `,
  `   D${"B".repeat(4)}LLL${"B".repeat(4)}D   `,
  `   D${"B".repeat(3)}DDDDD${"B".repeat(3)}D   `,
  `  DDD${"B".repeat(3)}D D${"B".repeat(3)}DDD  `,
  `  DDDDDLLL DDDDD  `,
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
