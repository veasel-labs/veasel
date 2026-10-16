import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

/** Default home SESSIONS sidebar width (columns), matching prior LiveHome. */
export const HOME_SIDEBAR_DEFAULT = 28
export const HOME_SIDEBAR_MIN = 18
export const HOME_SIDEBAR_MAX = 56
/** Keep splash/detail readable beside the sidebar. */
export const HOME_CONTENT_MIN = 36

export type PaneLayoutIo = {
  env?: NodeJS.ProcessEnv
  home?: string
  readFile?: (path: string) => string
  writeFile?: (path: string, data: string) => void
}

export function paneLayoutPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const xdg = env.XDG_STATE_HOME?.trim()
  if (xdg) return join(xdg, "veasel", "pane-layout.json")
  return join(home, ".local", "state", "veasel", "pane-layout.json")
}

export function clampHomeSidebarWidth(width: number, totalColumns = 80): number {
  const cols = Math.max(HOME_SIDEBAR_MIN + HOME_CONTENT_MIN, Math.floor(totalColumns))
  const maxForTerminal = Math.max(HOME_SIDEBAR_MIN, cols - HOME_CONTENT_MIN)
  const capped = Math.min(HOME_SIDEBAR_MAX, maxForTerminal)
  const n = Number.isFinite(width) ? Math.floor(width) : HOME_SIDEBAR_DEFAULT
  return Math.max(HOME_SIDEBAR_MIN, Math.min(capped, n))
}

export function stepHomeSidebarWidth(
  width: number,
  delta: number,
  totalColumns = 80,
): number {
  return clampHomeSidebarWidth(width + delta, totalColumns)
}

function defaultWrite(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, data, { encoding: "utf8", mode: 0o600 })
}

export function loadHomeSidebarWidth(io: PaneLayoutIo = {}, totalColumns = 80): number {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const readFile = io.readFile ?? ((path) => readFileSync(path, "utf8"))
  try {
    const raw = JSON.parse(readFile(paneLayoutPath(env, home))) as { homeSidebarWidth?: unknown }
    const value = typeof raw.homeSidebarWidth === "number" ? raw.homeSidebarWidth : HOME_SIDEBAR_DEFAULT
    return clampHomeSidebarWidth(value, totalColumns)
  } catch {
    return clampHomeSidebarWidth(HOME_SIDEBAR_DEFAULT, totalColumns)
  }
}

export function saveHomeSidebarWidth(width: number, io: PaneLayoutIo = {}, totalColumns = 80): void {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const writeFile = io.writeFile ?? defaultWrite
  const next = clampHomeSidebarWidth(width, totalColumns)
  writeFile(paneLayoutPath(env, home), `${JSON.stringify({ homeSidebarWidth: next }, null, 2)}\n`)
}
