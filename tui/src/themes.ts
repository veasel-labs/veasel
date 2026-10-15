import { homedir } from "node:os"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

// Visual tokens for the OpenTUI shell. The default "mint" theme matches the
// product mock: charcoal panels, mint accents, and a clear LOCAL cue.
export type ThemeId = "mint" | "ember" | "slate" | "mono" | "aurora" | "day" | "contrast"

export type Theme = {
  id: ThemeId
  name: string
  description: string
  shellBg: string
  panelBg: string
  panelBorder: string
  headerBg: string
  headerBorder: string
  headerTitle: string
  headerMeta: string
  localStatus: string
  sidebarLabel: string
  sidebarFg: string
  sessionSelectedFg: string
  brand: string
  body: string
  muted: string
  statusWarn: string
  statusOk: string
  statusError: string
  inputBg: string
  inputFocusBg: string
  inputText: string
  cursor: string
  title: string
  meta: string
  notice: string
  diffAdd: string
  diffRemove: string
  diffMeta: string
  userLabel: string
  userText: string
  assistantLabel: string
  assistantText: string
  status: string
  hint: string
  portrait: {
    D: string
    B: string
    L: string
    K: string
    H: string
    N: string
    W: string
  }
}

export const themes: Record<ThemeId, Theme> = {
  mint: {
    id: "mint",
    name: "Mint",
    description: "Charcoal panels with mint accents — the Veasel product look",
    shellBg: "#0c0f12",
    panelBg: "#12171c",
    panelBorder: "#2a333c",
    headerBg: "#151a20",
    headerBorder: "#2f3d38",
    headerTitle: "#9af7c9",
    headerMeta: "#7a8794",
    localStatus: "#9af7c9",
    sidebarLabel: "#9af7c9",
    sidebarFg: "#c5d4dc",
    sessionSelectedFg: "#9af7c9",
    brand: "#9af7c9",
    body: "#b7c0c8",
    muted: "#7a8794",
    statusWarn: "#e6c07b",
    statusOk: "#9af7c9",
    statusError: "#f28b82",
    inputBg: "#1a222b",
    inputFocusBg: "#222c36",
    inputText: "#e8ecef",
    cursor: "#9af7c9",
    title: "#eef2f5",
    meta: "#6b7785",
    notice: "#b7c0c8",
    diffAdd: "#86efac",
    diffRemove: "#fca5a5",
    diffMeta: "#93c5fd",
    userLabel: "#c4b5fd",
    userText: "#e6e0f5",
    assistantLabel: "#9af7c9",
    assistantText: "#d6dde3",
    status: "#8a96a3",
    hint: "#8a96a3",
    portrait: {
      D: "#1a2830",
      B: "#3d6a72",
      L: "#7ec8b8",
      K: "#080b0f",
      H: "#ffffff",
      N: "#080b0f",
      W: "#ffffff",
    },
  },
  ember: {
    id: "ember",
    name: "Ember",
    description: "Warm dark panels with amber focus cues",
    shellBg: "#100e0c",
    panelBg: "#181410",
    panelBorder: "#3a3228",
    headerBg: "#1c1712",
    headerBorder: "#4a3c2a",
    headerTitle: "#f0b56a",
    headerMeta: "#8a8074",
    localStatus: "#f0b56a",
    sidebarLabel: "#f0b56a",
    sidebarFg: "#d4ccc2",
    sessionSelectedFg: "#f0b56a",
    brand: "#f0b56a",
    body: "#cbbfb0",
    muted: "#8a8074",
    statusWarn: "#f0b56a",
    statusOk: "#b8d49a",
    statusError: "#e89a8a",
    inputBg: "#241e18",
    inputFocusBg: "#2e261e",
    inputText: "#f2ebe3",
    cursor: "#f0b56a",
    title: "#f7f0e8",
    meta: "#8a8074",
    notice: "#cbbfb0",
    diffAdd: "#b8d49a",
    diffRemove: "#e89a8a",
    diffMeta: "#9ab4d4",
    userLabel: "#e6c07b",
    userText: "#f0e2c8",
    assistantLabel: "#f0b56a",
    assistantText: "#ddd4c8",
    status: "#9a9084",
    hint: "#9a9084",
    portrait: {
      D: "#2a2218",
      B: "#8a6238",
      L: "#d4a06a",
      K: "#100e0c",
      H: "#fff8f0",
      N: "#100e0c",
      W: "#fff8f0",
    },
  },
  slate: {
    id: "slate",
    name: "Slate",
    description: "Cool blue-gray workspace with steel accents",
    shellBg: "#0b0e14",
    panelBg: "#11161f",
    panelBorder: "#2a3444",
    headerBg: "#141a24",
    headerBorder: "#334155",
    headerTitle: "#93c5fd",
    headerMeta: "#8494a8",
    localStatus: "#93c5fd",
    sidebarLabel: "#93c5fd",
    sidebarFg: "#c8d1dc",
    sessionSelectedFg: "#93c5fd",
    brand: "#93c5fd",
    body: "#b4bfcc",
    muted: "#8494a8",
    statusWarn: "#f3c969",
    statusOk: "#86efac",
    statusError: "#f28b82",
    inputBg: "#1a2230",
    inputFocusBg: "#243044",
    inputText: "#e8eef5",
    cursor: "#93c5fd",
    title: "#eef3f8",
    meta: "#6b7a8d",
    notice: "#b4bfcc",
    diffAdd: "#86efac",
    diffRemove: "#fca5a5",
    diffMeta: "#93c5fd",
    userLabel: "#a5b4fc",
    userText: "#dce3f5",
    assistantLabel: "#93c5fd",
    assistantText: "#d0d8e4",
    status: "#8494a8",
    hint: "#8494a8",
    portrait: {
      D: "#1a2433",
      B: "#4b6c88",
      L: "#90b8db",
      K: "#080b0f",
      H: "#ffffff",
      N: "#080b0f",
      W: "#ffffff",
    },
  },
  mono: {
    id: "mono",
    name: "Mono",
    description: "High-contrast black and white with green only for status",
    shellBg: "#000000",
    panelBg: "#0a0a0a",
    panelBorder: "#333333",
    headerBg: "#111111",
    headerBorder: "#444444",
    headerTitle: "#f5f5f5",
    headerMeta: "#9a9a9a",
    localStatus: "#7dffa0",
    sidebarLabel: "#f5f5f5",
    sidebarFg: "#d0d0d0",
    sessionSelectedFg: "#ffffff",
    brand: "#f5f5f5",
    body: "#c8c8c8",
    muted: "#9a9a9a",
    statusWarn: "#f0d060",
    statusOk: "#7dffa0",
    statusError: "#ff6b6b",
    inputBg: "#161616",
    inputFocusBg: "#222222",
    inputText: "#f5f5f5",
    cursor: "#7dffa0",
    title: "#ffffff",
    meta: "#888888",
    notice: "#c8c8c8",
    diffAdd: "#7dffa0",
    diffRemove: "#ff8a8a",
    diffMeta: "#a0c4ff",
    userLabel: "#ffffff",
    userText: "#e8e8e8",
    assistantLabel: "#7dffa0",
    assistantText: "#ececec",
    status: "#9a9a9a",
    hint: "#9a9a9a",
    portrait: {
      D: "#222222",
      B: "#666666",
      L: "#bbbbbb",
      K: "#000000",
      H: "#ffffff",
      N: "#000000",
      W: "#ffffff",
    },
  },
  aurora: {
    id: "aurora",
    name: "Aurora",
    description: "Deep teal field with cyan highlights",
    shellBg: "#061012",
    panelBg: "#0b171a",
    panelBorder: "#1f3a3e",
    headerBg: "#0e1c20",
    headerBorder: "#245055",
    headerTitle: "#5eead4",
    headerMeta: "#7f9a9e",
    localStatus: "#5eead4",
    sidebarLabel: "#5eead4",
    sidebarFg: "#c5d6d8",
    sessionSelectedFg: "#5eead4",
    brand: "#5eead4",
    body: "#b4c9cb",
    muted: "#7f9a9e",
    statusWarn: "#fbbf24",
    statusOk: "#5eead4",
    statusError: "#f87171",
    inputBg: "#122428",
    inputFocusBg: "#1a3238",
    inputText: "#e7f4f5",
    cursor: "#5eead4",
    title: "#ecfeff",
    meta: "#6b8588",
    notice: "#b4c9cb",
    diffAdd: "#6ee7b7",
    diffRemove: "#fca5a5",
    diffMeta: "#67e8f9",
    userLabel: "#a5b4fc",
    userText: "#dde4ff",
    assistantLabel: "#5eead4",
    assistantText: "#d0e4e6",
    status: "#7f9a9e",
    hint: "#7f9a9e",
    portrait: {
      D: "#123038",
      B: "#2a6a72",
      L: "#5eead4",
      K: "#061012",
      H: "#ecfeff",
      N: "#061012",
      W: "#ecfeff",
    },
  },
  day: {
    id: "day",
    name: "Day",
    description: "Light panels with mint accents for bright terminals",
    shellBg: "#f4f7f5",
    panelBg: "#ffffff",
    panelBorder: "#c5d0c9",
    headerBg: "#e8f0eb",
    headerBorder: "#9fc4b0",
    headerTitle: "#0f6b4c",
    headerMeta: "#5a6b63",
    localStatus: "#0f6b4c",
    sidebarLabel: "#0f6b4c",
    sidebarFg: "#2a3530",
    sessionSelectedFg: "#0b5a40",
    brand: "#0f6b4c",
    body: "#2a3530",
    muted: "#5a6b63",
    statusWarn: "#9a6b00",
    statusOk: "#0f6b4c",
    statusError: "#b42318",
    inputBg: "#eef3f0",
    inputFocusBg: "#e0ebe4",
    inputText: "#121a16",
    cursor: "#0f6b4c",
    title: "#0c1410",
    meta: "#5a6b63",
    notice: "#2a3530",
    diffAdd: "#0f6b4c",
    diffRemove: "#b42318",
    diffMeta: "#1d4ed8",
    userLabel: "#5b21b6",
    userText: "#1f1633",
    assistantLabel: "#0f6b4c",
    assistantText: "#1a2420",
    status: "#5a6b63",
    hint: "#5a6b63",
    portrait: {
      D: "#d7e6de",
      B: "#4a9a7a",
      L: "#0f6b4c",
      K: "#0c1410",
      H: "#ffffff",
      N: "#0c1410",
      W: "#ffffff",
    },
  },
  contrast: {
    id: "contrast",
    name: "Contrast",
    description: "Near-black on white with strong status hues for high-contrast displays",
    shellBg: "#ffffff",
    panelBg: "#ffffff",
    panelBorder: "#000000",
    headerBg: "#ffffff",
    headerBorder: "#000000",
    headerTitle: "#000000",
    headerMeta: "#222222",
    localStatus: "#006600",
    sidebarLabel: "#000000",
    sidebarFg: "#000000",
    sessionSelectedFg: "#000000",
    brand: "#000000",
    body: "#000000",
    muted: "#222222",
    statusWarn: "#7a5200",
    statusOk: "#006600",
    statusError: "#990000",
    inputBg: "#f0f0f0",
    inputFocusBg: "#e0e0e0",
    inputText: "#000000",
    cursor: "#000000",
    title: "#000000",
    meta: "#222222",
    notice: "#000000",
    diffAdd: "#006600",
    diffRemove: "#990000",
    diffMeta: "#0000aa",
    userLabel: "#000000",
    userText: "#000000",
    assistantLabel: "#006600",
    assistantText: "#000000",
    status: "#222222",
    hint: "#222222",
    portrait: {
      D: "#dddddd",
      B: "#666666",
      L: "#006600",
      K: "#000000",
      H: "#ffffff",
      N: "#000000",
      W: "#ffffff",
    },
  },
}

export const defaultThemeId: ThemeId = "mint"

export function isThemeId(value: string): value is ThemeId {
  return value in themes
}

export function listThemes(): Theme[] {
  return Object.values(themes)
}

export function themeConfigPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const base = env.XDG_CONFIG_HOME?.trim() || join(home, ".config")
  return join(base, "veasel", "tui-theme")
}

export function loadThemeId(
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
  readFile: (path: string) => string = (path) => readFileSync(path, "utf8"),
): ThemeId {
  const fromEnv = env.VEASEL_TUI_THEME?.trim().toLowerCase()
  if (fromEnv && isThemeId(fromEnv)) return fromEnv
  try {
    const saved = readFile(themeConfigPath(env, home)).trim().toLowerCase()
    if (isThemeId(saved)) return saved
  } catch {
    // Missing config is fine; use the product default.
  }
  return defaultThemeId
}

export function saveThemeId(
  id: ThemeId,
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
  writeFile: (path: string, data: string) => void = (path, data) => {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, `${data}\n`, { encoding: "utf8", mode: 0o600 })
  },
): void {
  writeFile(themeConfigPath(env, home), id)
}

export function resolveTheme(id: string | undefined): Theme {
  if (id && isThemeId(id)) return themes[id]
  return themes[defaultThemeId]
}

export function formatThemeList(activeId: ThemeId): string {
  const lines = ["TUI THEMES", `Active: ${themes[activeId].name} (${activeId})`, ""]
  for (const theme of listThemes()) {
    const marker = theme.id === activeId ? "●" : "○"
    lines.push(`${marker} ${theme.id}  ${theme.name}`, `  ${theme.description}`)
  }
  lines.push("", "Choose with /theme <id>. Preference is stored in ~/.config/veasel/tui-theme.")
  lines.push("While the /theme menu is open, ↑/↓ preview colors live; Enter keeps the choice and Esc restores the saved theme.")
  return lines.join("\n")
}

// Extracts a concrete theme id from a slash suggestion such as "/theme ember".
export function themeIdFromSlashSuggestion(name: string): ThemeId | undefined {
  const match = /^\/theme\s+([a-z]+)$/i.exec(name.trim())
  if (!match) return undefined
  const id = match[1]!.toLowerCase()
  return isThemeId(id) ? id : undefined
}

export function formatThemePreviewStatus(id: ThemeId, savedId: ThemeId): string {
  const preview = themes[id]
  if (id === savedId) return `● theme ${preview.name}  ·  saved`
  return `● preview ${preview.name}  ·  Enter keeps · Esc restores ${themes[savedId].name}`
}
