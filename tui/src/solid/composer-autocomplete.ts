// Solid composer autocomplete: reuse classic / @ $ suggestion engines.
// Pure helpers stay free of OpenTUI so unit tests do not need testRender.

import {
  completeSlashCommand,
  jumpSuggestion,
  moveSuggestion,
  runsOnAccept,
  slashCategoryLabel,
  slashSuggestions,
  suggestionWindow,
  type SlashCompletionContext,
  type SlashSuggestion,
} from "../slash-commands"
import {
  completePathMention,
  pathMentionAt,
  suggestWorkspacePaths,
  type PathSuggestion,
} from "../path-autocomplete"
import {
  completeSkillMention,
  skillMentionAt,
  suggestSkills,
  type SkillCatalogEntry,
  type SkillSuggestion,
} from "../skill-autocomplete"

export type ComposerAutocompleteKind = "slash" | "path" | "skill"

export type ComposerAutocompleteItem = {
  name: string
  description: string
  category?: string
  usage?: string
}

export type ComposerAutocompleteMenu = {
  kind: ComposerAutocompleteKind
  items: ComposerAutocompleteItem[]
  selected: number
  /** Visible slice indices into `items`. */
  window: { start: number; end: number }
  footer: string
}

export type ComposerAutocompleteDismissed = {
  kind: ComposerAutocompleteKind
  value: string
}

export type ResolveComposerAutocompleteOptions = {
  value: string
  cursor: number
  skills?: SkillCatalogEntry[]
  slashContext?: SlashCompletionContext
  workspaceRoot?: string
  listPaths?: (root: string) => string[]
  dismissed?: ComposerAutocompleteDismissed
  selected?: number
}

/** Fixture skills for Solid demos / tests (`source/skill` keys). */
export function demoComposerSkills(): SkillCatalogEntry[] {
  return [
    { key: "demo/code-review", description: "Review the current diff with severity-ranked findings" },
    { key: "demo/tdd-guide", description: "Drive red-green-refactor for the focused change" },
    { key: "demo/docs-generator", description: "Generate README / CHANGELOG / API docs from code" },
    { key: "demo/security-review", description: "App-surface hardening pass (OWASP-oriented)" },
  ]
}

export function resolveComposerAutocomplete(
  options: ResolveComposerAutocompleteOptions,
): ComposerAutocompleteMenu | undefined {
  const value = options.value
  const cursor = Math.min(Math.max(0, options.cursor), value.length)
  const root = options.workspaceRoot ?? process.cwd()
  const dismissed = options.dismissed

  const pathMention = pathMentionAt(value, cursor)
  if (pathMention && !value.trimStart().startsWith("/")) {
    if (dismissed?.kind === "path" && dismissed.value === value) return undefined
    const items = suggestWorkspacePaths(pathMention.query, root, options.listPaths)
    return menuFromItems("path", items.map(pathItem), options.selected, pathFooter)
  }

  const skillMention = skillMentionAt(value, cursor)
  if (skillMention && !value.trimStart().startsWith("/")) {
    if (dismissed?.kind === "skill" && dismissed.value === value) return undefined
    const items = suggestSkills(skillMention.query, options.skills ?? [])
    return menuFromItems("skill", items.map(skillItem), options.selected, skillFooter)
  }

  const slash = slashSuggestions(value, undefined, options.slashContext)
  if (slash.length === 0) return undefined
  if (dismissed?.kind === "slash" && dismissed.value === value) return undefined
  return menuFromItems("slash", slash.map(slashItem), options.selected, slashFooter)
}

function menuFromItems(
  kind: ComposerAutocompleteKind,
  items: ComposerAutocompleteItem[],
  selected: number | undefined,
  footerFor: (selected: number, count: number, windowSize: number) => string,
): ComposerAutocompleteMenu | undefined {
  if (items.length === 0) return undefined
  const index = Math.min(Math.max(0, selected ?? 0), items.length - 1)
  const window = suggestionWindow(index, items.length)
  return {
    kind,
    items,
    selected: index,
    window,
    footer: footerFor(index, items.length, window.end - window.start),
  }
}

function pathItem(item: PathSuggestion): ComposerAutocompleteItem {
  return { name: item.name, description: item.description }
}

function skillItem(item: SkillSuggestion): ComposerAutocompleteItem {
  return { name: item.name, description: item.description }
}

function slashItem(item: SlashSuggestion): ComposerAutocompleteItem {
  return {
    name: item.name,
    description: item.description,
    category: slashCategoryLabel(item),
    usage: item.usage,
  }
}

function pathFooter(selected: number, count: number, windowSize: number): string {
  const more = count > windowSize ? `${selected + 1}/${count} · ` : ""
  return `${more}Tab · ↑/↓ · Enter inserts · Esc`
}

function skillFooter(selected: number, count: number, windowSize: number): string {
  const more = count > windowSize ? `${selected + 1}/${count} · ` : ""
  return `${more}Tab · ↑/↓ · Enter inserts · Esc`
}

function slashFooter(selected: number, count: number, windowSize: number): string {
  const more = count > windowSize ? `${selected + 1}/${count} · ` : ""
  return `${more}Tab · ↑/↓ · Home/End · PgUp/PgDn · Enter · Esc`
}

export type AcceptComposerAutocompleteResult = {
  value: string
  cursor: number
  /** When true, the host should submit the completed slash command. */
  submit?: boolean
}

export function acceptComposerAutocomplete(
  options: ResolveComposerAutocompleteOptions & { selected: number },
): AcceptComposerAutocompleteResult | undefined {
  const menu = resolveComposerAutocomplete(options)
  if (!menu) return undefined
  const index = Math.min(Math.max(0, options.selected), menu.items.length - 1)
  const value = options.value
  const cursor = Math.min(Math.max(0, options.cursor), value.length)

  if (menu.kind === "path") {
    const mention = pathMentionAt(value, cursor)
    if (!mention) return undefined
    const path = menu.items[index]!.name.replace(/^@/, "")
    const suggestion: PathSuggestion = {
      name: menu.items[index]!.name,
      description: menu.items[index]!.description,
      path,
    }
    return completePathMention(value, cursor, suggestion)
  }

  if (menu.kind === "skill") {
    const mention = skillMentionAt(value, cursor)
    if (!mention) return undefined
    const key = menu.items[index]!.name.replace(/^\$/, "")
    const suggestion: SkillSuggestion = {
      name: menu.items[index]!.name,
      description: menu.items[index]!.description,
      key,
    }
    return completeSkillMention(value, cursor, suggestion)
  }

  // Slash: rebuild from live suggestions so insert/run flags stay accurate.
  const slash = slashSuggestions(value, undefined, options.slashContext)
  const selected = slash[index]
  if (!selected) return undefined
  const completion = completeSlashCommand(selected)
  if (!runsOnAccept(selected)) {
    return { value: completion, cursor: completion.length }
  }
  const normalized = value.trim().replace(/\s+/g, " ")
  if (normalized === completion) {
    // Already completed — let Enter fall through to submit.
    return undefined
  }
  return { value: completion, cursor: completion.length, submit: true }
}

export function moveComposerAutocomplete(
  selected: number,
  delta: number,
  count: number,
): number {
  return moveSuggestion(selected, delta, count)
}

export function jumpComposerAutocomplete(
  selected: number,
  count: number,
  where: "home" | "end" | "pageup" | "pagedown",
): number {
  return jumpSuggestion(selected, count, where)
}

/** Visible rows for the current selection window. */
export function windowedComposerItems(menu: ComposerAutocompleteMenu): ComposerAutocompleteItem[] {
  return menu.items.slice(menu.window.start, menu.window.end)
}
