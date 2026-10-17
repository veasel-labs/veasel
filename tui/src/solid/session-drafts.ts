import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import type { ComposerAttachment } from "./composer-attachments"

/** Per-session composer drafts that survive a TUI restart. */
export type SessionDraft = { text: string; attachments: ComposerAttachment[] }

type StoredDraft = SessionDraft & { updatedAt: number }

export const sessionDraftLimit = 50
export const sessionDraftTextLimit = 100_000

export type SessionDraftIo = {
  env?: NodeJS.ProcessEnv
  home?: string
  readFile?: (path: string) => string
  writeFile?: (path: string, data: string) => void
}

export function sessionDraftsPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const xdg = env.XDG_STATE_HOME?.trim()
  if (xdg) return join(xdg, "veasel", "session-drafts.json")
  return join(home, ".local", "state", "veasel", "session-drafts.json")
}

function defaultWrite(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, data, { encoding: "utf8", mode: 0o600 })
}

function validAttachment(value: unknown): ComposerAttachment | undefined {
  if (!value || typeof value !== "object") return undefined
  const item = value as Record<string, unknown>
  if (typeof item.id !== "string" || typeof item.path !== "string" || typeof item.name !== "string") return undefined
  if (item.kind !== "image" && item.kind !== "file") return undefined
  const attachment: ComposerAttachment = { id: item.id, path: item.path, name: item.name, kind: item.kind }
  if (typeof item.bytes === "number" && Number.isFinite(item.bytes)) attachment.bytes = item.bytes
  return attachment
}

export function parseSessionDrafts(text: string): Map<string, SessionDraft> {
  const drafts = new Map<string, SessionDraft>()
  try {
    const value = JSON.parse(text) as unknown
    if (!value || typeof value !== "object" || Array.isArray(value)) return drafts
    for (const [id, raw] of Object.entries(value as Record<string, unknown>)) {
      if (!id || !raw || typeof raw !== "object") continue
      const entry = raw as Record<string, unknown>
      if (typeof entry.text !== "string" || !entry.text) continue
      if (entry.text.length > sessionDraftTextLimit) continue
      const attachments = Array.isArray(entry.attachments)
        ? entry.attachments.map(validAttachment).filter((item): item is ComposerAttachment => Boolean(item))
        : []
      drafts.set(id, { text: entry.text, attachments })
    }
  } catch {
    return new Map()
  }
  return drafts
}

export function serializeSessionDrafts(drafts: Map<string, StoredDraft>): string {
  return `${JSON.stringify(Object.fromEntries(drafts))}\n`
}

export function upsertSessionDraft(
  drafts: Map<string, SessionDraft>,
  id: string,
  draft: SessionDraft,
  now = Date.now(),
): Map<string, SessionDraft> {
  const next = new Map(drafts)
  if (!draft.text && draft.attachments.length === 0) {
    next.delete(id)
    return next
  }
  if (draft.text.length > sessionDraftTextLimit) return next
  next.set(id, { text: draft.text, attachments: [...draft.attachments] })
  // Remember recency on the stored copy only; callers keep plain drafts.
  ;(next.get(id) as StoredDraft).updatedAt = now
  if (next.size > sessionDraftLimit) {
    const oldest = [...next.entries()]
      .sort((a, b) => ((a[1] as StoredDraft).updatedAt ?? 0) - ((b[1] as StoredDraft).updatedAt ?? 0))
      .slice(0, next.size - sessionDraftLimit)
    for (const [oldId] of oldest) next.delete(oldId)
  }
  return next
}

export function loadSessionDrafts(io: SessionDraftIo = {}): Map<string, SessionDraft> {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const readFile = io.readFile ?? ((path) => readFileSync(path, "utf8"))
  try {
    return parseSessionDrafts(readFile(sessionDraftsPath(env, home)))
  } catch {
    return new Map()
  }
}

export function saveSessionDrafts(drafts: Map<string, SessionDraft>, io: SessionDraftIo = {}): void {
  const env = io.env ?? process.env
  const home = io.home ?? homedir()
  const writeFile = io.writeFile ?? defaultWrite
  const stored = new Map<string, StoredDraft>()
  for (const [id, draft] of drafts) {
    stored.set(id, { ...draft, updatedAt: (draft as StoredDraft).updatedAt ?? 0 })
  }
  writeFile(sessionDraftsPath(env, home), serializeSessionDrafts(stored))
}
