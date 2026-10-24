import type { Theme } from "./themes"

/**
 * Terminal-palette encoding of the Veasel Code companion.
 * Source artwork was generated from a text-only prompt; no upstream image was
 * used.
 * Source: tui/assets/veasel-companion-v3.png.
 */
export const VEASEL_PORTRAIT_WIDTH = 32

// D outline · R russet fur · L teal · K deep shadow · H warm light ·
// N cream fur · W sparkle · C ear/nose coral.
const pixelSprite = [
  "                                ",
  "                                ",
  "                     D          ",
  "                    HNN         ",
  "          KD       KNCH         ",
  "          DDDD   RKHHCCD        ",
  "         KRKDDKRRRRCCNRD        ",
  "         KRDKDRRRRRCCCR         ",
  "         KRDKRRRNRRCNKD         ",
  "          DRDRNKNRRRKNCD        ",
  "           KDRKKNRRCRNNNH       ",
  "            DRKKNRNKKNNK        ",
  "           KDNNNNDNRNHD         ",
  "            DDNHHHNNH           ",
  "       KWWW   KKLLHHNDL         ",
  "        KLLLK KLLKLWKKKK        ",
  "         KKKLKKDRKLKLKWK        ",
  "        KKKLKKKRRRNHCKW         ",
  "           KK  RRDNNNHD         ",
  "        NND   KKRDDNNNDR        ",
  "       NHHK  KRDDKDDNDDK        ",
  "      KHHDD  RRRNHDDNKD         ",
  "       HHKKR RRRNNHNHR          ",
  "       DDKKRKRRRCNNNHN          ",
  "       KDKKDKRRRRHNHHRK         ",
  "        DDKKKDRRNHHCHD          ",
  "         KDKKDKDHHHHD           ",
  "            KKKH  KKKDD         ",
  "            KDDD     DDK        ",
  "              K                 ",
  "                                ",
  "                                ",
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
