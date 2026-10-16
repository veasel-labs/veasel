import { renderHelp } from "../help"
import { slashCommands } from "../slash-commands"
import { themes, type BuiltinThemeId } from "../themes"
import { activityToggleShortcut } from "./activity-group"
import { reviewShortcut } from "./reviews"

/** Discoverable palette binding. Ctrl+K stays readline kill-line in the composer. */
export const paletteShortcut = {
  name: "p",
  ctrl: true,
  label: "Ctrl+P",
} as const

export type PaletteCommand = {
  id: string
  title: string
  description: string
  group: string
  keywords?: string[]
  shortcut?: string
  run: () => void
}

export type PaletteActionHandlers = {
  showHelp: (compact?: boolean) => void
  /** Insert a slash command into the composer (or run it later via HTTP). */
  runSlash: (command: string) => void
  /** Cycle builtin themes; returns the next id for status copy. */
  cycleTheme: () => string
  /** Session list stub until home route lands on Solid. */
  showSessions: () => void
  /** Document / cue activity-group toggle (Ctrl+G owns the real toggle). */
  toggleActivity: () => void
  /** Open the Solid pending-review panel (Ctrl+R owns the real shortcut). */
  openReviews: () => void
}

const builtinThemeIds = Object.keys(themes) as BuiltinThemeId[]

/** Pure filter used by the Solid palette and unit tests. */
export function filterPaletteCommands(
  commands: readonly PaletteCommand[],
  query: string,
): PaletteCommand[] {
  const trimmed = query.trim().toLowerCase()
  if (!trimmed) return [...commands]
  const tokens = trimmed.split(/\s+/).filter(Boolean)
  return commands.filter((command) => {
    const haystack = [
      command.id,
      command.title,
      command.description,
      command.group,
      ...(command.keywords ?? []),
    ]
      .join(" ")
      .toLowerCase()
    return tokens.every((token) => haystack.includes(token))
  })
}

export function nextBuiltinThemeId(current: BuiltinThemeId): BuiltinThemeId {
  const index = builtinThemeIds.indexOf(current)
  const next = index < 0 ? 0 : (index + 1) % builtinThemeIds.length
  return builtinThemeIds[next]!
}

/** Build Veasel-owned palette actions from existing pure helpers. */
export function buildPaletteCommands(handlers: PaletteActionHandlers): PaletteCommand[] {
  const guide: PaletteCommand[] = [
    {
      id: "veasel.help",
      title: "Show quick help",
      description: "Open the compact /help guide",
      group: "guide",
      keywords: ["help", "?", "guide"],
      shortcut: "?",
      run: () => handlers.showHelp(true),
    },
    {
      id: "veasel.help.advanced",
      title: "Show full help",
      description: "Open the full /help advanced guide",
      group: "guide",
      keywords: ["help", "advanced", "syntax"],
      run: () => handlers.showHelp(false),
    },
  ]

  const chrome: PaletteCommand[] = [
    {
      id: "veasel.theme.cycle",
      title: "Cycle theme",
      description: "Rotate through builtin TUI themes (stub until theme dialog)",
      group: "setup",
      keywords: ["theme", "mint", "colors"],
      run: () => {
        handlers.cycleTheme()
      },
    },
    {
      id: "veasel.session.list",
      title: "Session list",
      description: "Home session list (stub on Solid path)",
      group: "session",
      keywords: ["sessions", "home", "list"],
      run: () => handlers.showSessions(),
    },
    {
      id: "veasel.activity.toggle",
      title: "Toggle activity group",
      description: `Expand or collapse the latest tool/activity group (${activityToggleShortcut.label})`,
      group: "session",
      keywords: ["activity", "tools", "group", "collapse", "expand"],
      shortcut: activityToggleShortcut.label,
      run: () => handlers.toggleActivity(),
    },
    {
      id: "veasel.reviews.open",
      title: "Open pending reviews",
      description: `Review file edits, shell commands, and MCP calls (${reviewShortcut.label})`,
      group: "session",
      keywords: ["review", "approve", "reject", "patch", "shell", "mcp", "diff"],
      shortcut: reviewShortcut.label,
      run: () => handlers.openReviews(),
    },
  ]

  const slash: PaletteCommand[] = slashCommands.map((command) => ({
    id: `veasel.slash.${command.name.replace(/^\//, "").replace(/\s+/g, ".")}`,
    title: command.name,
    description: command.description,
    group: command.category,
    keywords: [command.name, command.usage ?? ""],
    run: () => handlers.runSlash(command.name),
  }))

  return [...guide, ...chrome, ...slash]
}

/** Compact help text reused by the palette help action. */
export function paletteHelpText(compact = true): string {
  return renderHelp(compact)
}
