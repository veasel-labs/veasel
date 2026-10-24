import type { Theme } from "./themes"

/**
 * Terminal-palette encoding of Veasel Labs' original MIT pixel companion.
 * Source artwork: tui/assets/veasel-portrait-v2.png.
 */
export const VEASEL_PORTRAIT_WIDTH = 32

// D outline · B fur shadow · L teal · K deep shadow · H warm light ·
// N cream fur · W sparkle · C ear/nose coral.
const pixelSprite = [
  "                      KK",
  "        KKK         KBLNNK",
  "      KBBBLLK      KBBBDCNK",
  "     KBNNNBBLK     BBBBDCNK",
  "     BNNCNNBBLKKKKKBBBBKCCN",
  "    KNNCCCNNBBKBBBLLLKBKCCNK",
  "   KBNCCCCKNNBBBDBBLBLLKKCNK",
  "   KBNCCCDCNNKBBBBBBBBBBKNK",
  "   KBNNCCCKKKBBBNNBBBBBBNKK",
  "    BLNCCKKBBBBNNNNBBBBNKN",
  "    KBNNCCKBBBNKKKNBBBBLKDK",
  "     KBNWKBBBBKDKKKBBBBNNKD",
  "      KKKBBBBKKNKKDKBBBNKBKK",
  "     KBBKBBBNNKNBKKKBBBBBNNNK",
  "     KBKBBBNNNKNLBNKBBNNNNNNDNNK",
  "      KKBBNNNNNNNWKBNNNDCCKKNK",
  "      BKKNNHNNNNNNNNNNNNKKNKNNK",
  "      KBKDHNHNNNNNNNKNNNHNBNN KK",
  "       KBKKHNNNNHNNNNNNNND  KNK",
  "        KKKKBHBHHNNNNNNHD    KN",
  "         LNKBBHLNNHHHKK",
  "        KLKKBBBBNNNHHKLLKK",
  "    KK  KLLNKBBBBNNNHKBKLB",
  "  KNNNK  KDLNNNKBNNNNHKNLBNK",
  " KLLLLLLKLLLBLLNNWKNDDNLNNNL",
  " LDKLLLDKLLLLNLLLLNNNLLNNNNNK",
  "KK KLLLLLKKKKLNNLLLLLLLLWNNLK",
  "    LLLLKBBBHKLNNLLLLLKBLLWLKK",
  "    KLKKBKBBBNHBLNNLBNNNLLWKNN",
  "       KDBBBBNNHKLNKLNNNNNNNNBK",
  "        BDBBBBNNHHKLBBBNNLLHNBK",
  "         KBBBBNNNKLBBBBHKLKKHB",
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
