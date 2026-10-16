/**
 * Workspace-relative @path frecency for SolidComposer autocomplete.
 * Decay scoring adapted from OpenCode packages/tui/src/prompt/frecency.tsx (MIT).
 */

import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

export const maxPathFrecencyEntries = 1000

export type PathFrecencyEntry = {
  path: string
  frequency: number
  lastOpen: number
}

export type PathFrecencyIo = {
  env?: NodeJS.ProcessEnv
  home?: string
  now?: () => number
  readFile?: (path: string) => string
  writeFile?: (path: string, data: string) => void
  appendFile?: (path: string, data: string) => void
}

export type PathFrecencyStore = {
  get: (path: string) => number
  bump: (path: string) => void
  snapshot: () => Record<string, PathFrecencyEntry>
}

export function normalizePathFrecencyKey(path: string): string {
  return path.replaceAll("\\", "/").replace(/^\.\//, "").trim()
}

export function pathFrecencyFilePath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const xdg = env.XDG_STATE_HOME?.trim()
  if (xdg) return join(xdg, "veasel", "path-frecency.jsonl")
  return join(home, ".local", "state", "veasel", "path-frecency.jsonl")
}

export function calculatePathFrecency(
  entry: { frequency: number; lastOpen: number } | undefined,
  now = Date.now(),
): number {
  if (!entry || entry.frequency <= 0) return 0
  return entry.frequency / (1 + (now - entry.lastOpen) / 86_400_000)
}

export function parsePathFrecency(text: string): Record<string, PathFrecencyEntry> {
  const latest: Record<string, PathFrecencyEntry> = {}
  for (const line of text.split("\n")) {
    if (!line.trim()) continue
    try {
      const value = JSON.parse(line) as Record<string, unknown>
      if (!value || typeof value !== "object") continue
      const path = typeof value.path === "string" ? normalizePathFrecencyKey(value.path) : ""
      const frequency = typeof value.frequency === "number" ? value.frequency : NaN
      const lastOpen = typeof value.lastOpen === "number" ? value.lastOpen : NaN
      if (!path || !Number.isFinite(frequency) || frequency <= 0 || !Number.isFinite(lastOpen)) continue
      latest[path] = { path, frequency, lastOpen }
    } catch {
      // Skip corrupt lines.
    }
  }
  const ordered = Object.values(latest)
    .sort((left, right) => right.lastOpen - left.lastOpen)
    .slice(0, maxPathFrecencyEntries)
  return Object.fromEntries(ordered.map((entry) => [entry.path, entry]))
}

function defaultWrite(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, data, { encoding: "utf8", mode: 0o600 })
}

function defaultAppend(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  appendFileSync(path, data, { encoding: "utf8" })
}

export function createPathFrecencyStore(io: PathFrecencyIo = {}): PathFrecencyStore {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const now = io.now ?? (() => Date.now())
  const readFile = io.readFile ?? ((path) => readFileSync(path, "utf8"))
  const writeFile = io.writeFile ?? defaultWrite
  const appendFile = io.appendFile ?? defaultAppend
  const filePath = pathFrecencyFilePath(env, home)

  let data: Record<string, PathFrecencyEntry> = {}
  try {
    data = parsePathFrecency(readFile(filePath))
  } catch {
    data = {}
  }

  const persistCompact = () => {
    const lines = Object.values(data)
      .sort((left, right) => right.lastOpen - left.lastOpen)
      .slice(0, maxPathFrecencyEntries)
    data = Object.fromEntries(lines.map((entry) => [entry.path, entry]))
    writeFile(
      filePath,
      lines.length === 0 ? "" : `${lines.map((entry) => JSON.stringify(entry)).join("\n")}\n`,
    )
  }

  return {
    get(path: string) {
      const key = normalizePathFrecencyKey(path)
      if (!key) return 0
      return calculatePathFrecency(data[key], now())
    },
    bump(path: string) {
      const key = normalizePathFrecencyKey(path)
      if (!key || key.startsWith("/") || key.includes("\0")) return
      const previous = data[key]
      const entry: PathFrecencyEntry = {
        path: key,
        frequency: (previous?.frequency ?? 0) + 1,
        lastOpen: now(),
      }
      data[key] = entry
      try {
        appendFile(filePath, `${JSON.stringify(entry)}\n`)
      } catch {
        // Best-effort persistence.
      }
      if (Object.keys(data).length > maxPathFrecencyEntries) persistCompact()
    },
    snapshot() {
      return { ...data }
    },
  }
}

let sharedStore: PathFrecencyStore | undefined

/** Process-wide store for SolidComposer (tests can pass an explicit store). */
export function sharedPathFrecencyStore(): PathFrecencyStore {
  if (!sharedStore) sharedStore = createPathFrecencyStore()
  return sharedStore
}

/** Test helper — reset the process singleton. */
export function resetSharedPathFrecencyStoreForTests(): void {
  sharedStore = undefined
}
