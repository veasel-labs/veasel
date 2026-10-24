import type { Theme } from "./themes"

/**
 * Hand-authored terminal-palette portrait of the Veasel Code companion.
 * Related full-color art is a pixel-art reinterpretation of project-owned
 * concept artwork; no upstream mascot image was used.
 * Source: tui/assets/veasel-companion-pixel-v4.png.
 */
export const VEASEL_PORTRAIT_WIDTH = 32

// D outline · R russet fur · B teal shadow · L teal · K deep shadow ·
// H warm light · N cream fur · W eye shine · C ear/nose coral.
const pixelSprite = [
  "                                ",
  "       KKKD            DKKK     ",
  "      KRRRKD          DKNHHK    ",
  "     KRRRRRKD        DKNNNHK    ",
  "     KRRRRRRKD      DKNNNNHK    ",
  "     KRRRRRRRKDDDDDDKNNNNNNK    ",
  "      KRRRRRRRRRRRRRRRRRNNK     ",
  "       KRRRRRRRRRRRRRRRRNK      ",
  "      KRRKKKKRRRRKKKKRRK         ",
  "      KRRKWWKRRRRKWWKRRK         ",
  "      KRRKLLKRKKRLLKRRRK         ",
  "       KRRKBBKRRKBBKRRK          ",
  "       KRRRRNNNNRRRRRK           ",
  "        KRRNNCCNNNNRRK           ",
  "         KNNNNNNNNNNK            ",
  "          KNNNNNNNNK             ",
  "           KKKKKKKK              ",
  "       KKKKBBBBBBBBBBBBKKKK       ",
  "      KRRRBBBBLLWLLBBBBRRRK       ",
  "       KKKKBBBBBBBBBBBBKKK        ",
  "          KRRRRRRRRRRK            ",
  "         KRRRRRNNRRRRRK           ",
  "        KRRRRRNNNNRRRRRK          ",
  "       KRRRRRNNNNNNRRRRRK         ",
  "      KRRRRRNNNNNNNNRRRRRK        ",
  "     KRRRRRNNNNNNNNNNRRRRRK       ",
  "    KRRRRRNNNNNNNNNNNNRRRRRK      ",
  "   KRRRRRNNNNNNNNNNNNNNRRRRRK     ",
  "  KRRRRKKKNNNNNNNNNNNNKKKRRRK     ",
  "  KKKK   KKKKNNNNNNKKKK   KKKK    ",
  "         KRRRK    KRRRK           ",
  "         KKKKK    KKKKK           ",
].map((row) => row.slice(0, VEASEL_PORTRAIT_WIDTH).padEnd(VEASEL_PORTRAIT_WIDTH, " "))

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
