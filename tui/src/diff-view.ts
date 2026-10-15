import { SyntaxStyle, type StyleDefinitionInput } from "@opentui/core"
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

// Tree-sitter highlight groups mapped onto the active Veasel theme so DiffRenderable
// filetype coloring tracks /theme instead of OpenTUI's empty default SyntaxStyle.
export function diffSyntaxStyles(theme: Theme): Record<string, StyleDefinitionInput> {
  return {
    default: { fg: theme.body },
    keyword: { fg: theme.brand, bold: true },
    "keyword.function": { fg: theme.brand, bold: true },
    "keyword.operator": { fg: theme.diffMeta },
    "keyword.return": { fg: theme.brand, bold: true },
    comment: { fg: theme.meta, italic: true },
    "comment.documentation": { fg: theme.meta, italic: true },
    string: { fg: theme.diffAdd },
    "string.special": { fg: theme.diffAdd },
    number: { fg: theme.statusWarn },
    boolean: { fg: theme.statusWarn },
    constant: { fg: theme.statusWarn },
    "constant.builtin": { fg: theme.statusWarn },
    function: { fg: theme.diffMeta },
    "function.builtin": { fg: theme.diffMeta },
    "function.call": { fg: theme.diffMeta },
    "function.method": { fg: theme.diffMeta },
    type: { fg: theme.headerTitle },
    "type.builtin": { fg: theme.headerTitle },
    variable: { fg: theme.body },
    "variable.builtin": { fg: theme.statusWarn },
    "variable.parameter": { fg: theme.assistantText },
    property: { fg: theme.userLabel },
    operator: { fg: theme.diffMeta },
    punctuation: { fg: theme.muted },
    "punctuation.bracket": { fg: theme.muted },
    "punctuation.delimiter": { fg: theme.muted },
    tag: { fg: theme.brand },
    attribute: { fg: theme.statusWarn },
    label: { fg: theme.diffMeta },
    module: { fg: theme.diffMeta },
    namespace: { fg: theme.diffMeta },
  }
}

export function createDiffSyntaxStyle(theme: Theme): SyntaxStyle {
  return SyntaxStyle.fromStyles(diffSyntaxStyles(theme))
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
    toml: "toml",
    sh: "bash",
    bash: "bash",
    zsh: "bash",
    c: "c",
    h: "c",
    cpp: "cpp",
    cc: "cpp",
    hpp: "cpp",
    css: "css",
    html: "html",
    vue: "vue",
    svelte: "svelte",
  }
  return map[ext]
}

// OpenTUI keeps CodeRenderable scroll private on DiffRenderable; the fields still
// exist at runtime. Scroll both sides to the visual row for `{`/`}` hunk jumps.
type DiffHunkScrollTarget = {
  getHunkRowOffsets(): number[]
  leftCodeRenderable?: { scrollY: number } | null
  rightCodeRenderable?: { scrollY: number } | null
  clearAllLineColors?: () => void
  highlightLines?: (startLine: number, endLine: number, color: string) => void
}

export function scrollDiffRenderableToHunk(
  diff: DiffHunkScrollTarget,
  hunkIndex: number,
  options: { accent?: string } = {},
): number {
  const offsets = diff.getHunkRowOffsets()
  if (offsets.length === 0) return 0
  const index = Math.min(offsets.length - 1, Math.max(0, hunkIndex))
  const row = offsets[index] ?? 0
  if (diff.leftCodeRenderable) diff.leftCodeRenderable.scrollY = row
  if (diff.rightCodeRenderable) diff.rightCodeRenderable.scrollY = row
  const accent = options.accent
  if (accent && diff.clearAllLineColors && diff.highlightLines) {
    diff.clearAllLineColors()
    const next = offsets[index + 1]
    const end = typeof next === "number" ? Math.max(row, next - 1) : row
    diff.highlightLines(row, end, accent)
  }
  return row
}

// Chrome-only notice while DiffRenderable owns the diff body. Keep counts on the
// first line so they stay above the hotkey hint and the DiffRenderable panel.
export function formatPatchSplitChrome(input: {
  status: string
  path: string
  additions: number
  removals: number
  hunkCount: number
  hunkIndex?: number
  pendingInstruction?: string
}): string {
  const hunkLabel = input.hunkCount > 1
    ? ` · Hunk ${(input.hunkIndex ?? 0) + 1} of ${input.hunkCount}`
    : ""
  const body =
    `REVIEW WORKSPACE EDIT  /  ${input.status}  ·  OpenTUI split  ·  ` +
    `${input.additions} added, ${input.removals} removed${hunkLabel}\n` +
    `${input.path}\nPress v for word-diff segments.`
  if (!input.pendingInstruction) return body
  return `${body}\n${input.pendingInstruction}`
}
