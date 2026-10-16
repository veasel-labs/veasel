import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import type { SolidStashEntry } from "./component/stash-dialog"

/** Cap matches OpenCode prompt stash depth without importing OC types. */
export const draftStashLimit = 50

export type DraftStashIo = {
  env?: NodeJS.ProcessEnv
  home?: string
  readFile?: (path: string) => string
  writeFile?: (path: string, data: string) => void
}

export function draftStashPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const xdg = env.XDG_STATE_HOME?.trim()
  if (xdg) return join(xdg, "veasel", "prompt-stash.jsonl")
  return join(home, ".local", "state", "veasel", "prompt-stash.jsonl")
}

function defaultWrite(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, data, { encoding: "utf8", mode: 0o600 })
}

export function parseDraftStash(text: string): SolidStashEntry[] {
  const entries: SolidStashEntry[] = []
  for (const line of text.split("\n")) {
    if (!line.trim()) continue
    try {
      const value = JSON.parse(line) as Record<string, unknown>
      if (!value || typeof value !== "object") continue
      const textValue = typeof value.text === "string" ? value.text : ""
      const timestamp = typeof value.timestamp === "number" ? value.timestamp : NaN
      const id = typeof value.id === "string" ? value.id : ""
      if (!textValue.trim() || !Number.isFinite(timestamp) || !id) continue
      entries.push({ id, text: textValue, timestamp })
    } catch {
      // Skip corrupt lines; keep usable stash.
    }
  }
  return entries.slice(-draftStashLimit)
}

export function serializeDraftStash(entries: SolidStashEntry[]): string {
  if (entries.length === 0) return ""
  return `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`
}

export function loadDraftStash(io: DraftStashIo = {}): SolidStashEntry[] {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const readFile = io.readFile ?? ((path) => readFileSync(path, "utf8"))
  try {
    return parseDraftStash(readFile(draftStashPath(env, home)))
  } catch {
    return []
  }
}

export function saveDraftStash(entries: SolidStashEntry[], io: DraftStashIo = {}): void {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const writeFile = io.writeFile ?? defaultWrite
  const trimmed = entries.slice(-draftStashLimit)
  writeFile(draftStashPath(env, home), serializeDraftStash(trimmed))
}

export function pushDraftStash(
  entries: SolidStashEntry[],
  text: string,
  now = Date.now(),
): SolidStashEntry[] {
  const trimmed = text.trimEnd()
  if (!trimmed.trim()) return entries
  const entry: SolidStashEntry = {
    id: `stash-${now.toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    text: trimmed,
    timestamp: now,
  }
  return [...entries, entry].slice(-draftStashLimit)
}

export function removeDraftStash(entries: SolidStashEntry[], id: string): SolidStashEntry[] {
  return entries.filter((entry) => entry.id !== id)
}
