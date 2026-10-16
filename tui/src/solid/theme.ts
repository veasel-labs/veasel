import { themes, type Theme } from "../themes"
import type { TranscriptTone } from "../transcript"

// Mint product tokens for the Solid shell. Keep chrome aligned with themes.ts
// "mint" until the Solid path consumes the full theme loader.

export const solidMint = {
  shellBg: themes.mint.shellBg,
  panelBg: themes.mint.panelBg,
  panelBorder: themes.mint.panelBorder,
  headerBg: themes.mint.headerBg,
  headerBorder: themes.mint.headerBorder,
  headerTitle: themes.mint.headerTitle,
  headerMeta: themes.mint.headerMeta,
  localStatus: themes.mint.localStatus,
  brand: themes.mint.brand,
  body: themes.mint.body,
  muted: themes.mint.muted,
  inputBg: themes.mint.inputBg,
  inputFocusBg: themes.mint.inputFocusBg,
  inputText: themes.mint.inputText,
  cursor: themes.mint.cursor,
} as const

// Map transcript tones to mint colors — same pairing as main.ts
// buildTranscriptStyles, so Solid and imperative paths stay visually aligned.
export function solidToneFg(tone: TranscriptTone, theme: Theme = themes.mint): string {
  switch (tone) {
    case "title":
      return theme.title
    case "meta":
      return theme.meta
    case "notice":
      return theme.notice
    case "diffAdd":
      return theme.diffAdd
    case "diffRemove":
      return theme.diffRemove
    case "diffMeta":
      return theme.diffMeta
    case "diffContext":
      return theme.meta
    case "userLabel":
      return theme.userLabel
    case "userText":
      return theme.userText
    case "assistantLabel":
      return theme.assistantLabel
    case "assistantText":
      return theme.assistantText
    case "systemLabel":
      return theme.systemLabel
    case "systemText":
      return theme.systemText
    case "toolLabel":
      return theme.toolLabel
    case "toolText":
      return theme.toolText
    case "codeFence":
      return theme.diffMeta
    case "codeLang":
      return theme.brand
    case "codeBody":
      return theme.inputText
    case "inlineCode":
      return theme.inputText
    case "strong":
      return theme.assistantText
    case "listMarker":
      return theme.diffMeta
    case "link":
      return theme.brand
    case "heading":
      return theme.title
    case "blockquote":
      return theme.meta
    case "status":
      return theme.status
    case "hint":
      return theme.hint
  }
}

export function solidToneBold(tone: TranscriptTone): boolean {
  return (
    tone === "title" ||
    tone === "diffAdd" ||
    tone === "diffRemove" ||
    tone === "userLabel" ||
    tone === "assistantLabel" ||
    tone === "systemLabel" ||
    tone === "toolLabel" ||
    tone === "codeFence" ||
    tone === "codeLang" ||
    tone === "inlineCode" ||
    tone === "strong" ||
    tone === "listMarker" ||
    tone === "heading"
  )
}
