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

export type PathFrecencyLookup = {
  get: (path: string) => number
}

export function filterWorkspacePaths(
  paths: string[],
  query: string,
  limit = maxPathSuggestions,
  pathFrecency?: PathFrecencyLookup,
): PathSuggestion[] {
  const needle = query.trim().toLowerCase().replaceAll("\\", "/")
  const normalized = paths
    .map((path) => path.replaceAll("\\", "/").replace(/^\.\//, ""))
    .filter((path) => path.length > 0 && !path.startsWith("/") && !path.includes("\0"))
  const unique = [...new Set(normalized)]
  if (!needle) {
    const ranked = unique
      .map((path, index) => ({
        path,
        index,
        frecency: pathFrecency?.get(path) ?? 0,
      }))
      .sort(
        (left, right) =>
          right.frecency - left.frecency
          || left.path.localeCompare(right.path)
          || left.index - right.index,
      )
    return ranked.slice(0, limit).map(({ path, frecency }) =>
      pathSuggestion(path, frecency > 0 ? "recent path" : "workspace path"),
    )
  }
  // Rank like provider search: exact/prefix/substring first, then one-typo fuzzy
  // basename hits so `@mein` still finds `src/main.ts` without drowning exacts.
  // OpenCode-style boost: matchScore * (1 + frecencyDecay).
  const scored = unique.flatMap((path, index) => {
    const score = pathMatchScore(needle, path)
    if (score === undefined) return []
    const frecency = pathFrecency?.get(path) ?? 0
    return [{ path, index, score: score * (1 + frecency), base: score }]
  })
  scored.sort((left, right) => right.score - left.score || left.index - right.index)
  return scored.slice(0, limit).map(({ path, base }) => pathSuggestion(path, pathScoreDescription(base)))
}

function pathSuggestion(path: string, description: string): PathSuggestion {
  return {
    name: `@${path}`,
    description: path.includes("/") && description === "workspace path" ? "workspace path" : description,
    path,
  }
}

function pathScoreDescription(score: number): string {
  if (score >= 1_000) return "exact prefix"
  if (score >= 900) return "name match"
  if (score >= 800) return "path match"
  if (score >= 700) return "name match"
  if (score >= 500) return "close match"
  return "workspace path"
}

function pathMatchScore(needle: string, path: string): number | undefined {
  const lower = path.toLowerCase()
  const base = lower.includes("/") ? lower.slice(lower.lastIndexOf("/") + 1) : lower
  if (lower === needle || base === needle) return 1_200 - path.length
  // Cap length penalties so longer paths still keep the prefix band (≥1000).
  if (lower.startsWith(needle)) return 1_050 - Math.min(40, lower.length - needle.length)
  if (base.startsWith(needle)) return 940 - Math.min(30, base.length - needle.length)
  const pathAt = lower.indexOf(needle)
  if (pathAt >= 0) return 820 - pathAt * 4 - (lower.length - needle.length)
  const baseAt = base.indexOf(needle)
  if (baseAt >= 0) return 740 - baseAt * 4 - (base.length - needle.length)

  // Typo-tolerant basename / stem match (same OSA budget as provider search).
  // Prefer the file stem so `@mein` finds `main.ts` without requiring the
  // extension in the query.
  if (needle.length < 4) return undefined
  const stem = base.includes(".") ? base.slice(0, base.lastIndexOf(".")) : base
  const maximumDistance = needle.length < 8 ? 1 : Math.floor(needle.length / 4)
  let best: number | undefined
  for (const candidate of [stem, base]) {
    if (Math.abs(needle.length - candidate.length) > maximumDistance) continue
    const distance = optimalStringAlignmentDistance(needle, candidate)
    if (distance > maximumDistance) continue
    const score = 560 - distance * 32 - Math.abs(candidate.length - needle.length) * 2
    best = Math.max(best ?? 0, score)
  }
  return best
}

function optimalStringAlignmentDistance(left: string, right: string) {
  const rows = left.length + 1
  const columns = right.length + 1
  const distance = Array.from({ length: rows }, () => Array<number>(columns).fill(0))
  for (let row = 0; row < rows; row++) distance[row]![0] = row
  for (let column = 0; column < columns; column++) distance[0]![column] = column

  for (let row = 1; row < rows; row++) {
    for (let column = 1; column < columns; column++) {
      const substitution = left[row - 1] === right[column - 1] ? 0 : 1
      distance[row]![column] = Math.min(
        distance[row - 1]![column]! + 1,
        distance[row]![column - 1]! + 1,
        distance[row - 1]![column - 1]! + substitution,
      )
      if (row > 1 && column > 1 && left[row - 1] === right[column - 2] && left[row - 2] === right[column - 1]) {
        distance[row]![column] = Math.min(distance[row]![column]!, distance[row - 2]![column - 2]! + substitution)
      }
    }
  }
  return distance[left.length]![right.length]!
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
  pathFrecency?: PathFrecencyLookup,
): PathSuggestion[] {
  return filterWorkspacePaths(listPaths(root), query, limit, pathFrecency)
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
