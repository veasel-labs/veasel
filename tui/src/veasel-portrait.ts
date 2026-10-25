import type { Theme } from "./themes"

/**
 * Terminal-palette reduction of the shared v8 Veasel companion artwork.
 * Eye pixels are emphasized for legibility at 32×32; no upstream mascot image
 * was used. Source: tui/assets/veasel-companion-pixel-v8.png.
 */
export const VEASEL_PORTRAIT_WIDTH = 32

// D outline · R russet fur · B teal shadow · L teal · K deep shadow ·
// H warm light · N cream fur · W eye shine · C ear/nose coral.
const pixelSprite = [
  "                                ",
  "                                ",
  "                                ",
  "                     K          ",
  "                    KNN         ",
  "                   KRRHR        ",
  "          KDRD   R DNNRN        ",
  "          RRKRKKRRRRHHRN        ",
  "          RRRDRRRRRKKKRR        ",
  "          RRHKRRNRRKWLK         ",
  "          KRHRKKKRRKLKRK        ",
  "           DKRKWLRRRBNNR H      ",
  "            KRKLKKNNNNNRR       ",
  "            RNRNNNNKNN          ",
  "         KK KNHHNNNNH   R       ",
  "       KLLBB  KBLKHHNK          ",
  "        BKLBBKKBBLLHNHK         ",
  "         KLLLLBKRKBLLLK         ",
  "         RKLLLKRRHNKBLK         ",
  "       KNNNKBK RRRNNNNR         ",
  "      KNNHNR KRRRRRNNNR         ",
  "      HHHDKR RRHRRRHNHK         ",
  "      HHRK  RRRNHRRKHRR         ",
  "      KHRDR RRRRNKDRHRNK        ",
  "       RRKKRRRRRNHDDKDHR        ",
  "       KRRKKRRRHHHDDDKR         ",
  "         RRRRRKDDKDDDDDK        ",
  "             KKKKKKDKKKK        ",
  "                                ",
  "                                ",
  "                                ",
  "                                "
]

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
