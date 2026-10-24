import { homedir } from "node:os"
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { formatOkStatus, formatWarnStatus } from "./status-a11y"

// Slash actions that are not theme ids. Keep these out of the custom-id shape
// so /theme reload|open never collide with a user JSON file named reload.json.
export const themeActionChoices = [
  { value: "reload", description: "Rescan custom theme JSON without restarting the TUI" },
  { value: "open", description: "Create and show the user/workspace theme directories" },
] as const

export type ThemeActionId = (typeof themeActionChoices)[number]["value"]

export function isThemeActionId(value: string): value is ThemeActionId {
  return value === "reload" || value === "open"
}

// Visual tokens for the OpenTUI shell. The default "mint" theme matches the
// product mock: charcoal panels, mint accents, and a clear LOCAL cue.
// Builtin ids stay fixed; custom JSON under ~/.config/veasel/themes/ (and
// <workspace>/.veasel/themes/) may add kebab-case ids at runtime.
export type BuiltinThemeId = "mint" | "ember" | "slate" | "mono" | "aurora" | "day" | "contrast"
export type ThemeId = string

export type ThemePortrait = {
  D: string
  B: string
  L: string
  K: string
  H: string
  N: string
  W: string
  C: string
  R: string
}

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
  systemLabel: string
  systemText: string
  toolLabel: string
  toolText: string
  status: string
  hint: string
  portrait: ThemePortrait
}

const portraitKeys = ["D", "B", "L", "K", "H", "N", "W", "C", "R"] as const
const colorKeys = [
  "shellBg",
  "panelBg",
  "panelBorder",
  "headerBg",
  "headerBorder",
  "headerTitle",
  "headerMeta",
  "localStatus",
  "sidebarLabel",
  "sidebarFg",
  "sessionSelectedFg",
  "brand",
  "body",
  "muted",
  "statusWarn",
  "statusOk",
  "statusError",
  "inputBg",
  "inputFocusBg",
  "inputText",
  "cursor",
  "title",
  "meta",
  "notice",
  "diffAdd",
  "diffRemove",
  "diffMeta",
  "userLabel",
  "userText",
  "assistantLabel",
  "assistantText",
  "systemLabel",
  "systemText",
  "toolLabel",
  "toolText",
  "status",
  "hint",
] as const

export const themes: Record<BuiltinThemeId, Theme> = {
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
    muted: "#919ca6",
    statusWarn: "#e6c07b",
    statusOk: "#9af7c9",
    statusError: "#f28b82",
    inputBg: "#1a222b",
    inputFocusBg: "#222c36",
    inputText: "#e8ecef",
    cursor: "#9af7c9",
    title: "#eef2f5",
    meta: "#919ca6",
    notice: "#b7c0c8",
    diffAdd: "#86efac",
    diffRemove: "#fca5a5",
    diffMeta: "#93c5fd",
    userLabel: "#c4b5fd",
    userText: "#e6e0f5",
    assistantLabel: "#9af7c9",
    assistantText: "#d6dde3",
    systemLabel: "#7dd3fc",
    systemText: "#a8b8c4",
    toolLabel: "#e6c07b",
    toolText: "#d4c4a8",
    status: "#8a96a3",
    hint: "#8a96a3",
    portrait: {
      D: "#0b2631",
      B: "#086d83",
      L: "#35d9bf",
      K: "#07131d",
      H: "#f4d79d",
      N: "#fff2cf",
      W: "#ffffff",
      R: "#a44e37",
      C: "#f2796f",
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
    muted: "#9d9181",
    statusWarn: "#f0b56a",
    statusOk: "#b8d49a",
    statusError: "#e89a8a",
    inputBg: "#241e18",
    inputFocusBg: "#2e261e",
    inputText: "#f2ebe3",
    cursor: "#f0b56a",
    title: "#f7f0e8",
    meta: "#9d9181",
    notice: "#cbbfb0",
    diffAdd: "#b8d49a",
    diffRemove: "#e89a8a",
    diffMeta: "#9ab4d4",
    userLabel: "#e6c07b",
    userText: "#f0e2c8",
    assistantLabel: "#f0b56a",
    assistantText: "#ddd4c8",
    systemLabel: "#9ab4d4",
    systemText: "#b8aea0",
    toolLabel: "#d4a06a",
    toolText: "#dcc8a8",
    status: "#9a9084",
    hint: "#9a9084",
    portrait: {
      D: "#302116",
      B: "#805b3b",
      L: "#d99b5c",
      K: "#100e0c",
      H: "#e9c58e",
      N: "#fff1dc",
      W: "#fff8f0",
      R: "#9d4630",
      C: "#d77258",
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
    muted: "#93a2b5",
    statusWarn: "#f3c969",
    statusOk: "#86efac",
    statusError: "#f28b82",
    inputBg: "#1a2230",
    inputFocusBg: "#243044",
    inputText: "#e8eef5",
    cursor: "#93c5fd",
    title: "#eef3f8",
    meta: "#93a2b5",
    notice: "#b4bfcc",
    diffAdd: "#86efac",
    diffRemove: "#fca5a5",
    diffMeta: "#93c5fd",
    userLabel: "#a5b4fc",
    userText: "#dce3f5",
    assistantLabel: "#93c5fd",
    assistantText: "#d0d8e4",
    systemLabel: "#cbd5e1",
    systemText: "#94a3b8",
    toolLabel: "#f3c969",
    toolText: "#c8b896",
    status: "#8494a8",
    hint: "#8494a8",
    portrait: {
      D: "#1a2433",
      B: "#4b6c88",
      L: "#90b8db",
      K: "#080b0f",
      H: "#e6c07b",
      N: "#eff6fb",
      W: "#ffffff",
      R: "#a8543a",
      C: "#dd8c8c",
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
    meta: "#8b8b8b",
    notice: "#c8c8c8",
    diffAdd: "#7dffa0",
    diffRemove: "#ff8a8a",
    diffMeta: "#a0c4ff",
    userLabel: "#ffffff",
    userText: "#e8e8e8",
    assistantLabel: "#7dffa0",
    assistantText: "#ececec",
    systemLabel: "#a0c4ff",
    systemText: "#b0b0b0",
    toolLabel: "#f0d060",
    toolText: "#d0c090",
    status: "#9a9a9a",
    hint: "#9a9a9a",
    portrait: {
      D: "#222222",
      B: "#666666",
      L: "#bbbbbb",
      K: "#000000",
      H: "#dddddd",
      N: "#000000",
      W: "#ffffff",
      R: "#aaaaaa",
      C: "#aaaaaa",
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
    meta: "#8da8ac",
    notice: "#b4c9cb",
    diffAdd: "#6ee7b7",
    diffRemove: "#fca5a5",
    diffMeta: "#67e8f9",
    userLabel: "#a5b4fc",
    userText: "#dde4ff",
    assistantLabel: "#5eead4",
    assistantText: "#d0e4e6",
    systemLabel: "#67e8f9",
    systemText: "#9bb5b8",
    toolLabel: "#fbbf24",
    toolText: "#d4c08a",
    status: "#7f9a9e",
    hint: "#7f9a9e",
    portrait: {
      D: "#123038",
      B: "#126978",
      L: "#5eead4",
      K: "#061012",
      H: "#a7f3d0",
      N: "#e6fff9",
      W: "#ecfeff",
      R: "#ad573c",
      C: "#ff8a83",
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
    statusWarn: "#8c6000",
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
    systemLabel: "#1d4ed8",
    systemText: "#334155",
    toolLabel: "#9a6b00",
    toolText: "#44403c",
    status: "#5a6b63",
    hint: "#5a6b63",
    portrait: {
      D: "#17382c",
      B: "#39876c",
      L: "#0f6b4c",
      K: "#0c1410",
      H: "#e3c991",
      N: "#f3efe2",
      W: "#ffffff",
      R: "#a44e37",
      C: "#bd6554",
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
    systemLabel: "#0000aa",
    systemText: "#000000",
    toolLabel: "#7a5200",
    toolText: "#000000",
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
      R: "#7a3f2d",
      C: "#ff00ff",
    },
  },
}

export const defaultThemeId: BuiltinThemeId = "mint"

// Runtime registry of custom themes loaded from JSON. Builtin entries always win
// for the same id; later load dirs overwrite earlier custom ids (project > user).
const customThemes = new Map<string, Theme>()

export function isBuiltinThemeId(value: string): value is BuiltinThemeId {
  return value in themes
}

export function isThemeId(value: string): value is ThemeId {
  return isBuiltinThemeId(value) || customThemes.has(value)
}

export function isThemeIdShape(value: string): boolean {
  return /^[a-z][a-z0-9-]{0,31}$/.test(value)
}

export function listThemes(): Theme[] {
  return [...Object.values(themes), ...customThemes.values()]
}

export function listThemeChoices(): Array<{ value: string; description: string }> {
  return [
    ...themeActionChoices.map((action) => ({ value: action.value, description: action.description })),
    ...listThemes().map((theme) => ({
      value: theme.id,
      description: theme.description,
    })),
  ]
}

export function clearCustomThemes(): void {
  customThemes.clear()
}

export function themeConfigPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const base = env.XDG_CONFIG_HOME?.trim() || join(home, ".config")
  return join(base, "veasel", "tui-theme")
}

export function themeThemesDir(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  return join(dirname(themeConfigPath(env, home)), "themes")
}

export function projectThemesDir(projectDir: string): string {
  return join(projectDir, ".veasel", "themes")
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
  if (id && customThemes.has(id)) return customThemes.get(id)!
  if (id && isBuiltinThemeId(id)) return themes[id]
  return themes[defaultThemeId]
}

function isHexColor(value: unknown): value is string {
  return typeof value === "string" && /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value)
}

type ThemeJson = {
  id?: unknown
  name?: unknown
  description?: unknown
  extends?: unknown
  portrait?: unknown
} & Record<string, unknown>

export function parseThemeJson(
  raw: string,
  sourcePath: string,
  resolveBase: (id: string) => Theme | undefined = (id) => {
    if (customThemes.has(id)) return customThemes.get(id)
    if (isBuiltinThemeId(id)) return themes[id]
    return undefined
  },
): { theme?: Theme; error?: string } {
  let parsed: ThemeJson
  try {
    parsed = JSON.parse(raw) as ThemeJson
  } catch {
    return { error: `${sourcePath}: invalid JSON` }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { error: `${sourcePath}: theme root must be an object` }
  }
  const id = typeof parsed.id === "string" ? parsed.id.trim().toLowerCase() : ""
  if (!isThemeIdShape(id)) {
    return { error: `${sourcePath}: id must match [a-z][a-z0-9-]{0,31}` }
  }
  if (isBuiltinThemeId(id)) {
    return { error: `${sourcePath}: cannot replace builtin theme "${id}"` }
  }
  if (isThemeActionId(id)) {
    return { error: `${sourcePath}: "${id}" is reserved for /theme ${id}` }
  }
  const name = typeof parsed.name === "string" ? parsed.name.trim() : ""
  if (!name) return { error: `${sourcePath}: name is required` }
  const description = typeof parsed.description === "string" ? parsed.description.trim() : `Custom theme ${id}`
  const extendsId = typeof parsed.extends === "string" ? parsed.extends.trim().toLowerCase() : defaultThemeId
  const base = resolveBase(extendsId)
  if (!base) return { error: `${sourcePath}: unknown extends "${extendsId}"` }

  const next: Theme = {
    ...base,
    id,
    name,
    description,
    portrait: { ...base.portrait },
  }
  for (const key of colorKeys) {
    const value = parsed[key]
    if (value === undefined) continue
    if (!isHexColor(value)) return { error: `${sourcePath}: ${key} must be a #hex color` }
    next[key] = value
  }
  if (parsed.portrait !== undefined) {
    if (!parsed.portrait || typeof parsed.portrait !== "object" || Array.isArray(parsed.portrait)) {
      return { error: `${sourcePath}: portrait must be an object` }
    }
    const portrait = parsed.portrait as Record<string, unknown>
    for (const key of portraitKeys) {
      const value = portrait[key]
      if (value === undefined) continue
      if (!isHexColor(value)) return { error: `${sourcePath}: portrait.${key} must be a #hex color` }
      next.portrait[key] = value
    }
  }
  return { theme: next }
}

export type ThemeScanDir = {
  path: string
  label: "user" | "workspace"
  present: boolean
  files: string[]
}

export type LoadCustomThemesResult = {
  loaded: Theme[]
  errors: string[]
  scans: ThemeScanDir[]
}

export function loadCustomThemes(options: {
  env?: NodeJS.ProcessEnv
  home?: string
  projectDir?: string
  readDir?: (path: string) => string[]
  readFile?: (path: string) => string
  replace?: boolean
} = {}): LoadCustomThemesResult {
  const env = options.env ?? process.env
  const home = options.home ?? homedir()
  const readDir = options.readDir ?? ((path) => readdirSync(path))
  const readFile = options.readFile ?? ((path) => readFileSync(path, "utf8"))
  if (options.replace !== false) customThemes.clear()

  const userDir = themeThemesDir(env, home)
  const dirs: Array<{ path: string; label: "user" | "workspace" }> = [{ path: userDir, label: "user" }]
  const projectDir = options.projectDir?.trim()
  if (projectDir) dirs.push({ path: projectThemesDir(projectDir), label: "workspace" })

  const loaded: Theme[] = []
  const errors: string[] = []
  const scans: ThemeScanDir[] = []
  const byId = new Map<string, Theme>()

  for (const dir of dirs) {
    let names: string[] = []
    let present = true
    try {
      names = readDir(dir.path).filter((name) => name.endsWith(".json")).sort()
    } catch {
      present = false
      names = []
    }
    scans.push({ path: dir.path, label: dir.label, present, files: names })
    if (!present) continue
    for (const name of names) {
      const path = join(dir.path, name)
      let raw = ""
      try {
        raw = readFile(path)
      } catch (error) {
        errors.push(`${path}: ${error instanceof Error ? error.message : "unreadable"}`)
        continue
      }
      const parsed = parseThemeJson(raw, path, (id) => {
        if (byId.has(id)) return byId.get(id)
        if (isBuiltinThemeId(id)) return themes[id]
        return undefined
      })
      if (parsed.error || !parsed.theme) {
        errors.push(parsed.error ?? `${path}: unknown parse failure`)
        continue
      }
      byId.set(parsed.theme.id, parsed.theme)
    }
  }

  for (const theme of byId.values()) {
    customThemes.set(theme.id, theme)
    loaded.push(theme)
  }
  return { loaded, errors, scans }
}

function displayThemePath(path: string, home = homedir()): string {
  const prefix = home.endsWith("/") ? home : `${home}/`
  if (path === home) return "~"
  if (path.startsWith(prefix)) return `~/${path.slice(prefix.length)}`
  return path
}

export type FormatThemeListOptions = {
  errors?: string[]
  scans?: ThemeScanDir[]
  home?: string
}

export function formatThemeList(activeId: ThemeId, options: FormatThemeListOptions = {}): string {
  const active = resolveTheme(activeId)
  const home = options.home ?? homedir()
  const lines = ["TUI THEMES", `Active: ${active.name} (${active.id})`, ""]
  for (const theme of listThemes()) {
    const marker = theme.id === activeId ? "●" : "○"
    const custom = isBuiltinThemeId(theme.id) ? "" : "  (custom)"
    lines.push(`${marker} ${theme.id}  ${theme.name}${custom}`, `  ${theme.description}`)
  }

  const scans = options.scans ?? []
  if (scans.length > 0) {
    lines.push("", "Custom theme directories:")
    for (const scan of scans) {
      const shown = displayThemePath(scan.path, home)
      if (!scan.present) {
        lines.push(`  ${shown}  (${scan.label}, missing — create to add JSON)`)
        continue
      }
      if (scan.files.length === 0) {
        lines.push(`  ${shown}  (${scan.label}, empty)`)
        continue
      }
      lines.push(`  ${shown}  (${scan.label}, ${scan.files.join(", ")})`)
    }
  } else {
    lines.push("", "Add custom themes as JSON under ~/.config/veasel/themes/*.json or <workspace>/.veasel/themes/*.json (optional \"extends\" builtin id).")
  }

  const errors = options.errors ?? []
  if (errors.length > 0) {
    lines.push("", `Theme JSON errors (${errors.length}):`)
    for (const error of errors) {
      lines.push(`  ✖ ${displayThemePath(error, home)}`)
    }
  } else if (scans.length > 0 && !listThemes().some((theme) => !isBuiltinThemeId(theme.id))) {
    lines.push("", "No custom themes loaded yet. Drop a *.json file into either directory (optional \"extends\" builtin id).")
  }

  lines.push("", "Choose with /theme <id>. Preference is stored in ~/.config/veasel/tui-theme.")
  lines.push("Reload custom JSON with /theme reload (no restart). Create/show dirs with /theme open.")
  lines.push("While the /theme menu is open, ↑/↓ preview colors live; Enter keeps the choice and Esc restores the saved theme.")
  return lines.join("\n")
}

export type EnsureThemeDirsResult = {
  userDir: string
  workspaceDir?: string
  created: string[]
  alreadyPresent: string[]
}

// Ensures the user themes directory exists so operators can drop JSON without
// leaving the TUI. Optionally creates the workspace themes dir when a project
// root is known. Does not launch a file manager (SSH/headless safe).
export function ensureThemeDirs(options: {
  env?: NodeJS.ProcessEnv
  home?: string
  projectDir?: string
  mkdir?: (path: string) => void
  existsDir?: (path: string) => boolean
} = {}): EnsureThemeDirsResult {
  const env = options.env ?? process.env
  const home = options.home ?? homedir()
  const mkdir =
    options.mkdir ??
    ((path: string) => {
      mkdirSync(path, { recursive: true, mode: 0o700 })
    })
  const existsDir =
    options.existsDir ??
    ((path: string) => {
      try {
        return readdirSync(path) !== undefined
      } catch {
        return false
      }
    })

  const userDir = themeThemesDir(env, home)
  const created: string[] = []
  const alreadyPresent: string[] = []
  if (existsDir(userDir)) {
    alreadyPresent.push(userDir)
  } else {
    mkdir(userDir)
    created.push(userDir)
  }

  const projectDir = options.projectDir?.trim()
  let workspaceDir: string | undefined
  if (projectDir) {
    workspaceDir = projectThemesDir(projectDir)
    if (existsDir(workspaceDir)) {
      alreadyPresent.push(workspaceDir)
    } else {
      mkdir(workspaceDir)
      created.push(workspaceDir)
    }
  }

  return { userDir, workspaceDir, created, alreadyPresent }
}

export function formatThemeOpenNotice(result: EnsureThemeDirsResult, home = homedir()): string {
  const lines = [
    "THEME DIRECTORIES",
    "",
    `User: ${displayThemePath(result.userDir, home)}`,
  ]
  if (result.workspaceDir) {
    lines.push(`Workspace: ${displayThemePath(result.workspaceDir, home)}`)
  }
  lines.push("")
  if (result.created.length > 0) {
    lines.push("Created:")
    for (const path of result.created) {
      lines.push(`  + ${displayThemePath(path, home)}`)
    }
    lines.push("")
  }
  lines.push("Drop *.json theme files into either directory (optional \"extends\" builtin id),")
  lines.push("then run /theme reload to pick them up without restarting.")
  return lines.join("\n")
}

export function formatThemeReloadStatus(loaded: number, errors: number): string {
  const parts = [`reloaded ${loaded} custom theme${loaded === 1 ? "" : "s"}`]
  if (errors > 0) parts.push(`${errors} JSON error${errors === 1 ? "" : "s"}`)
  const message = `${parts.join("  ·  ")}  ·  /theme`
  return errors > 0 ? formatWarnStatus(message) : formatOkStatus(message)
}

export function formatThemeLoadStatusHint(errors: string[]): string | undefined {
  if (errors.length === 0) return undefined
  if (errors.length === 1) return "1 theme JSON error · /theme"
  return `${errors.length} theme JSON errors · /theme`
}

// Extracts a concrete theme id from a slash suggestion such as "/theme ember".
// Action tokens (/theme reload|open) are never theme ids, so preview stays off.
export function themeIdFromSlashSuggestion(name: string): ThemeId | undefined {
  const match = /^\/theme\s+([a-z][a-z0-9-]*)$/i.exec(name.trim())
  if (!match) return undefined
  const id = match[1]!.toLowerCase()
  if (isThemeActionId(id)) return undefined
  return isThemeId(id) ? id : undefined
}

export function formatThemePreviewStatus(id: ThemeId, savedId: ThemeId): string {
  const preview = resolveTheme(id)
  if (id === savedId) return formatOkStatus(`theme ${preview.name}  ·  saved`)
  return formatWarnStatus(`preview ${preview.name}  ·  Enter keeps · Esc restores ${resolveTheme(savedId).name}`)
}
