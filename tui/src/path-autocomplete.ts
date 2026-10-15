import { readdirSync, statSync } from "node:fs"
import { join, relative, sep } from "node:path"

// @-mention path completion for the session composer. Suggestions stay relative
// to the workspace root and never escape it.

export const maxPathSuggestions = 6

export type PathMention = {
  start: number
  end: number
  query: string
}

export type PathSuggestion = {
  name: string
  description: string
  path: string
}

const ignoredDirNames = new Set([
  ".git",
  "node_modules",
  "dist",
  "build",
  ".venv",
  "venv",
  "__pycache__",
  ".turbo",
  ".next",
  "coverage",
])

// Finds the @path token that contains the cursor (or sits just before it).
// Does not treat emails (word@host) as mentions: the @ must start a token.
export function pathMentionAt(value: string, cursor: number): PathMention | undefined {
  const pos = Math.min(Math.max(0, cursor), value.length)
  let start = pos
  while (start > 0) {
    const ch = value[start - 1]!
    if (ch === "@") break
    if (/\s/.test(ch)) return undefined
    start -= 1
  }
  if (start <= 0 || value[start - 1] !== "@") return undefined
  const at = start - 1
  if (at > 0 && !/\s/.test(value[at - 1]!)) return undefined
  let end = pos
  while (end < value.length && !/\s/.test(value[end]!)) end += 1
  return {
    start: at,
    end,
    query: value.slice(at + 1, end),
  }
}

export function filterWorkspacePaths(paths: string[], query: string, limit = maxPathSuggestions): PathSuggestion[] {
  const needle = query.trim().toLowerCase().replaceAll("\\", "/")
  const normalized = paths
    .map((path) => path.replaceAll("\\", "/").replace(/^\.\//, ""))
    .filter((path) => path.length > 0 && !path.startsWith("/") && !path.includes("\0"))
  const unique = [...new Set(normalized)]
  const prefix = unique.filter((path) => path.toLowerCase().startsWith(needle))
  const contains = unique.filter((path) => !prefix.includes(path) && path.toLowerCase().includes(needle))
  const basename = unique.filter((path) => {
    if (prefix.includes(path) || contains.includes(path)) return false
    const base = path.includes("/") ? path.slice(path.lastIndexOf("/") + 1) : path
    return base.toLowerCase().startsWith(needle) || base.toLowerCase().includes(needle)
  })
  return [...prefix, ...contains, ...basename].slice(0, limit).map((path) => ({
    name: `@${path}`,
    description: path.includes("/") ? "workspace path" : "workspace file",
    path,
  }))
}

// Bounded recursive listing under root. Paths are relative with `/` separators.
export function listWorkspacePaths(
  root: string,
  readDir: (path: string) => string[] = (path) => readdirSync(path),
  isDirectory: (path: string) => boolean = (path) => {
    try {
      return statSync(path).isDirectory()
    } catch {
      return false
    }
  },
  maxEntries = 400,
  maxDepth = 4,
): string[] {
  const out: string[] = []
  const walk = (dir: string, depth: number) => {
    if (out.length >= maxEntries || depth > maxDepth) return
    let names: string[]
    try {
      names = readDir(dir)
    } catch {
      return
    }
    names.sort((a, b) => a.localeCompare(b))
    for (const name of names) {
      if (out.length >= maxEntries) return
      if (name === "." || name === ".." || name.startsWith(".")) {
        if (name !== ".agents" && name !== ".veasel") continue
      }
      if (ignoredDirNames.has(name)) continue
      const absolute = join(dir, name)
      const rel = relative(root, absolute).split(sep).join("/")
      if (!rel || rel.startsWith("..")) continue
      if (isDirectory(absolute)) {
        walk(absolute, depth + 1)
      } else {
        out.push(rel)
      }
    }
  }
  walk(root, 0)
  return out
}

export function suggestWorkspacePaths(
  query: string,
  root: string,
  listPaths: (root: string) => string[] = listWorkspacePaths,
  limit = maxPathSuggestions,
): PathSuggestion[] {
  return filterWorkspacePaths(listPaths(root), query, limit)
}

export function completePathMention(
  value: string,
  cursor: number,
  suggestion: PathSuggestion,
): { value: string; cursor: number } | undefined {
  const mention = pathMentionAt(value, cursor)
  if (!mention) return undefined
  const insert = `@${suggestion.path}`
  const next = value.slice(0, mention.start) + insert + value.slice(mention.end)
  const nextCursor = mention.start + insert.length
  // Add a trailing space when the mention ends the draft so the operator can keep typing.
  if (mention.end >= value.length || /\s/.test(value[mention.end]!)) {
    if (mention.end >= value.length) {
      return { value: `${next} `, cursor: nextCursor + 1 }
    }
  }
  return { value: next, cursor: nextCursor }
}
