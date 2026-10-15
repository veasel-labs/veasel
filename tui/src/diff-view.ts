import type { Theme } from "./themes"

// Review surfaces for workspace diffs. "segments" keeps the existing TextRenderable
// word-diff chrome; "split" mounts OpenTUI DiffRenderable (view=split) when the
// pinned @opentui/core supports it — without rewriting the whole review stack.
export type ReviewDiffSurface = "segments" | "split"

export function cycleReviewDiffSurface(current: ReviewDiffSurface): ReviewDiffSurface {
  return current === "segments" ? "split" : "segments"
}

export function reviewDiffSurfaceHint(surface: ReviewDiffSurface): string {
  return surface === "split" ? " · v word-diff" : " · v split view"
}

// Colors for DiffRenderable so split view tracks /theme without a custom SyntaxStyle
// rewrite. Backgrounds stay charcoal-adjacent so mint/ember/day remain readable.
export function diffRenderableTheme(theme: Theme): {
  fg: string
  addedSignColor: string
  removedSignColor: string
  lineNumberFg: string
  addedBg: string
  removedBg: string
  contextBg: string
  showLineNumbers: boolean
  syncScroll: boolean
  wrapMode: "none"
} {
  return {
    fg: theme.body,
    addedSignColor: theme.diffAdd,
    removedSignColor: theme.diffRemove,
    lineNumberFg: theme.meta,
    addedBg: "#1a3328",
    removedBg: "#33201f",
    contextBg: "transparent",
    showLineNumbers: true,
    syncScroll: true,
    wrapMode: "none",
  }
}

export function filetypeFromReviewPath(path: string): string | undefined {
  const base = path.split(/[/\\]/).pop() ?? path
  const dot = base.lastIndexOf(".")
  if (dot <= 0 || dot === base.length - 1) return undefined
  const ext = base.slice(dot + 1).toLowerCase()
  const map: Record<string, string> = {
    ts: "typescript",
    tsx: "tsx",
    js: "javascript",
    jsx: "javascript",
    mjs: "javascript",
    cjs: "javascript",
    py: "python",
    go: "go",
    rs: "rust",
    v: "v",
    md: "markdown",
    json: "json",
    yaml: "yaml",
    yml: "yaml",
    c: "c",
    h: "c",
    cpp: "cpp",
    cc: "cpp",
    hpp: "cpp",
  }
  return map[ext]
}

// Chrome-only notice while DiffRenderable owns the diff body. Keep counts on the
// first line so they stay above the hotkey hint and the DiffRenderable panel.
export function formatPatchSplitChrome(input: {
  status: string
  path: string
  additions: number
  removals: number
  hunkCount: number
  pendingInstruction?: string
}): string {
  const hunkLabel = input.hunkCount > 1 ? ` · ${input.hunkCount} hunks` : ""
  const body =
    `REVIEW WORKSPACE EDIT  /  ${input.status}  ·  OpenTUI split  ·  ` +
    `${input.additions} added, ${input.removals} removed${hunkLabel}\n` +
    `${input.path}\nPress v for word-diff segments.`
  if (!input.pendingInstruction) return body
  return `${body}\n${input.pendingInstruction}`
}
