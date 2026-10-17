import { themes, type Theme } from "../themes"
import type { TranscriptTone } from "../transcript"

import { createComponent, createContext, createSignal, useContext, type ParentProps } from "solid-js"
import { isBuiltinThemeId, loadThemeId, type BuiltinThemeId } from "../themes"

type SolidThemeState = {
  colors: Theme
  themeId: () => BuiltinThemeId
  setThemeId: (id: BuiltinThemeId) => void
}

const ThemeContext = createContext<SolidThemeState>()

/** One reactive theme per application root, including overlays and notifications. */
export function SolidThemeProvider(props: ParentProps<{ initialTheme?: BuiltinThemeId }>) {
  const saved = props.initialTheme ?? loadThemeId()
  const [themeId, setThemeId] = createSignal<BuiltinThemeId>(isBuiltinThemeId(saved) ? saved : "mint")
  const colors = new Proxy(themes.mint, {
    get(_target, key: keyof Theme) {
      return themes[themeId()][key]
    },
  })
  return createComponent(ThemeContext.Provider, {
    value: { colors, themeId, setThemeId },
    get children() { return props.children },
  })
}

export function useSolidThemeState(): SolidThemeState {
  const state = useContext(ThemeContext)
  if (!state) throw new Error("SolidThemeProvider is required")
  return state
}

/** Standalone component fixtures retain the default theme without shared global state. */
export function useSolidTheme(): Theme {
  return useContext(ThemeContext)?.colors ?? themes.mint
}

// Map transcript tones to semantic theme colors — same pairing as classic-main.ts
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
