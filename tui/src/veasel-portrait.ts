import type { Theme } from "./themes"

/**
 * Terminal-palette encoding of Veasel Labs' original MIT pixel companion.
 * Source artwork: veasel-labs/website/public/veasel-companion.png.
 */
export const VEASEL_PORTRAIT_WIDTH = 24

const pixelSprite = [
  "                        ",
  "            DK  KBK",
  "           DHBKBBBH",
  "           HLDBHBBH",
  "           DHBLKBBD",
  "           KBBDKBLHDL",
  "            KHHHHHK",
  "        LL   LHHHL",
  "       HLHLK KBHHK",
  "         BHDKLHHHL",
  "      K  LBB KHLHL",
  "    HHHH    KBLKHHBL",
  "   BHHHHH   KBBHHLHH",
  "   BLBKHH   KBBLHDHHK",
  "  KBBB K    DBBKBBLKD",
  "  KDBB     KDLBBDLDD",
  "   DBB    KDBLDDHH",
  "   KDBB   DBBBLHHLB",
  "   KDBBD KDBBBLHHHB",
  "    DKDBDKDBBBBHHHB",
  "    KKKDDKDDBDKHHBB",
  "      KKKKKDDKLHDKHK",
  "           KKKDD KDK",
  "                        ",
].map((row) => row.padEnd(VEASEL_PORTRAIT_WIDTH, " "))

export const VEASEL_PORTRAIT_ROWS = pixelSprite

export type PortraitKey = keyof Theme["portrait"]

export type PortraitCell = {
  /** A single terminal cell encoding the upper and lower sprite pixels. */
  glyph: string
  color: string
  background: string
}

export function portraitCellColor(theme: Theme, pixel: string): string {
  if (pixel === " ") return theme.panelBg
  const key = pixel as PortraitKey
  return theme.portrait[key] ?? theme.panelBg
}

/** Pair two sprite rows into single-cell half blocks for crisp square pixels. */
export function portraitRowCells(theme: Theme, topRow: string, bottomRow: string): PortraitCell[] {
  const top = [...topRow.padEnd(VEASEL_PORTRAIT_WIDTH, " ")]
  const bottom = [...bottomRow.padEnd(VEASEL_PORTRAIT_WIDTH, " ")]
  return Array.from({ length: VEASEL_PORTRAIT_WIDTH }, (_, index) => {
    const upper = top[index] ?? " "
    const lower = bottom[index] ?? " "
    const upperColor = portraitCellColor(theme, upper)
    const lowerColor = portraitCellColor(theme, lower)
    if (upper === " " && lower === " ") {
      return { glyph: " ", color: theme.panelBg, background: theme.panelBg }
    }
    if (upper === " ") return { glyph: "▄", color: lowerColor, background: theme.panelBg }
    if (lower === " ") return { glyph: "▀", color: upperColor, background: theme.panelBg }
    if (upperColor === lowerColor) return { glyph: "█", color: upperColor, background: upperColor }
    return { glyph: "▀", color: upperColor, background: lowerColor }
  })
}
