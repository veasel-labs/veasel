import { renderHelp } from "../help"
import { slashCommands } from "../slash-commands"
import { themes, type BuiltinThemeId } from "../themes"
import { activityToggleShortcut } from "./activity-group"
import { reviewShortcut } from "./reviews"
import { messageNavShortcut } from "./transcript-nav"
import type { TranscriptVerbosity } from "./transcript-verbosity"
import { thinkingToggleShortcut } from "./thinking-blocks"

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
  /** Jump to the previous user message in the transcript. */
  previousUserMessage: () => void
  /** Jump to the next user message in the transcript. */
  nextUserMessage: () => void
  /** Jump to the last user message in the transcript. */
  lastUserMessage: () => void
  /** Cycle transcript verbosity (quiet → default → everything). */
  cycleVerbosity: () => TranscriptVerbosity
  /** Expand or collapse the latest thinking fence. */
  toggleThinking: () => void
  /** Open the Solid pending-review panel (Ctrl+R owns the real shortcut). */
  openReviews: () => void
  /** Demo / cue the non-modal toast host. */
  showToast: () => void
  /** Open a confirm dialog smoke (approve / cancel). */
  showConfirm: () => void
  /** Open the builtin theme list dialog (DialogSelect). */
  showThemeList: () => void
  /** Open model favorites / recents / catalog dialog. */
  showModelPicker: () => void
  /** Open composer stash list. */
  showStash: () => void
  /** Open structured error details dialog. */
  showErrorDetails: () => void
  /** Open shell output viewer dialog. */
  showShellOutput: () => void
  /** Open MCP servers dialog. */
  showMcp: () => void
  /** Open Agent Plugin links dialog. */
  showPlugins: () => void
  /** Open skill selector dialog. */
  showSkills: () => void
  /** Open session export options dialog. */
  showExport: () => void
  /** Open recent sessions / projects (Ctrl+O). */
  showOpen: () => void
  /** Rich status dialog (MCP, model, usage). */
  showStatus: () => void
  /** Open durable executions for the active session. */
  showRuns: () => void
  /** Open agent picker dialog. */
  showAgent: () => void
  /** Open model variant picker dialog. */
  showVariant: () => void
  /** Open workspaces / worktree move dialog. */
  showWorkspaces: () => void
  /** Changelog / update stub dialog. */
  showUpdate: () => void
  /** Device pairing N/A dialog. */
  showPair: () => void
  /** Release highlights dialog. */
  showHighlights: () => void
  /** Image preview stub dialog. */
  showImagePreview: () => void
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
      description: "Rotate through builtin TUI themes",
      group: "setup",
      keywords: ["theme", "mint", "colors", "cycle"],
      run: () => {
        handlers.cycleTheme()
      },
    },
    {
      id: "veasel.theme.list",
      title: "Theme list",
      description: "Pick a builtin TUI theme (DialogSelect)",
      group: "setup",
      keywords: ["theme", "mint", "colors", "list", "dialog"],
      run: () => handlers.showThemeList(),
    },
    {
      id: "veasel.session.list",
      title: "Session list",
      description: "Browse, filter, rename, or create sessions",
      group: "session",
      keywords: ["sessions", "home", "list", "rename"],
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
      id: "veasel.message.user.previous",
      title: "Previous user message",
      description: `Jump to the previous user turn (${messageNavShortcut.previousUser.label})`,
      group: "session",
      keywords: ["message", "user", "previous", "prev", "jump", "anchor", "navigate"],
      shortcut: messageNavShortcut.previousUser.label,
      run: () => handlers.previousUserMessage(),
    },
    {
      id: "veasel.message.user.next",
      title: "Next user message",
      description: `Jump to the next user turn (${messageNavShortcut.nextUser.label})`,
      group: "session",
      keywords: ["message", "user", "next", "jump", "anchor", "navigate"],
      shortcut: messageNavShortcut.nextUser.label,
      run: () => handlers.nextUserMessage(),
    },
    {
      id: "veasel.message.user.last",
      title: "Last user message",
      description: `Jump to the latest user turn (${messageNavShortcut.lastUser.label})`,
      group: "session",
      keywords: ["message", "user", "last", "end", "jump", "anchor", "navigate"],
      shortcut: messageNavShortcut.lastUser.label,
      run: () => handlers.lastUserMessage(),
    },
    {
      id: "veasel.transcript.verbosity",
      title: "Cycle transcript verbosity",
      description: "Quiet (hide tools/thinking) → Default → Everything (expand tools)",
      group: "session",
      keywords: ["verbosity", "quiet", "tools", "thinking", "transcript", "density"],
      run: () => {
        handlers.cycleVerbosity()
      },
    },
    {
      id: "veasel.thinking.toggle",
      title: "Toggle thinking block",
      description: `Expand or collapse the latest thinking fence (${thinkingToggleShortcut.label})`,
      group: "session",
      keywords: ["thinking", "reasoning", "collapse", "expand", "fence"],
      shortcut: thinkingToggleShortcut.label,
      run: () => handlers.toggleThinking(),
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
    {
      id: "veasel.toast.demo",
      title: "Show demo toast",
      description: "Non-modal mint toast (queue, hover-pause, click dismiss)",
      group: "guide",
      keywords: ["toast", "notice", "notification"],
      run: () => handlers.showToast(),
    },
    {
      id: "veasel.confirm.demo",
      title: "Show confirm dialog",
      description: "Modal confirm / cancel (DialogConfirm smoke)",
      group: "guide",
      keywords: ["confirm", "dialog", "modal", "yes", "no"],
      run: () => handlers.showConfirm(),
    },
    {
      id: "veasel.model.picker",
      title: "Select model",
      description: "Favorites, recents, and catalog (DialogSelect)",
      group: "setup",
      keywords: ["model", "favorites", "recents", "provider", "llm"],
      run: () => handlers.showModelPicker(),
    },
    {
      id: "veasel.stash.list",
      title: "Prompt stash",
      description: "Restore a stashed composer draft",
      group: "session",
      keywords: ["stash", "draft", "prompt", "history"],
      run: () => handlers.showStash(),
    },
    {
      id: "veasel.error.details",
      title: "Error details",
      description: "Structured error modal with copy (demo)",
      group: "guide",
      keywords: ["error", "details", "copy", "diagnostic"],
      run: () => handlers.showErrorDetails(),
    },
    {
      id: "veasel.shell.output",
      title: "Shell output",
      description: "Scrollable shell command output (demo)",
      group: "session",
      keywords: ["shell", "output", "terminal", "stdout"],
      run: () => handlers.showShellOutput(),
    },
    {
      id: "veasel.mcp.list",
      title: "MCP servers",
      description: "Browse MCP status; open error details when failed",
      group: "setup",
      keywords: ["mcp", "servers", "tools", "stdio", "oauth"],
      run: () => handlers.showMcp(),
    },
    {
      id: "veasel.plugins.list",
      title: "Plugins",
      description: "Browse linked Agent Plugin packages (/plugins)",
      group: "setup",
      keywords: ["plugin", "plugins", "agent plugin", "package", "link"],
      run: () => handlers.showPlugins(),
    },
    {
      id: "veasel.skills.list",
      title: "Skills",
      description: "Pick a skill from the discovered catalog",
      group: "session",
      keywords: ["skills", "skill", "catalog", "$"],
      run: () => handlers.showSkills(),
    },
    {
      id: "veasel.session.export",
      title: "Export session",
      description: "Copy or export the session as Markdown or JSON",
      group: "session",
      keywords: ["export", "copy", "markdown", "json", "download"],
      run: () => handlers.showExport(),
    },
    {
      id: "veasel.open.dialog",
      title: "Open…",
      description: "Recent sessions and project worktrees (Ctrl+O)",
      group: "session",
      keywords: ["open", "recent", "projects", "worktree", "ctrl+o"],
      shortcut: "Ctrl+O",
      run: () => handlers.showOpen(),
    },
    {
      id: "veasel.status.dialog",
      title: "Status",
      description: "Session, model, MCP, and usage summary",
      group: "guide",
      keywords: ["status", "mcp", "usage", "connection"],
      run: () => handlers.showStatus(),
    },
    {
      id: "veasel.execution.history",
      title: "Execution history",
      description: "Inspect durable runs for the active session",
      group: "session",
      keywords: ["runs", "history", "operations", "executions"],
      run: () => handlers.showRuns(),
    },
    {
      id: "veasel.agent.picker",
      title: "Select agent",
      description: "Execution policy or demo agent profile",
      group: "setup",
      keywords: ["agent", "build", "plan", "review", "policy", "ask"],
      run: () => handlers.showAgent(),
    },
    {
      id: "veasel.variant.picker",
      title: "Select variant",
      description: "Output-budget preset (fast / default / max → max_output_tokens)",
      group: "setup",
      keywords: ["variant", "effort", "fast", "max", "budget", "tokens"],
      run: () => handlers.showVariant(),
    },
    {
      id: "veasel.workspaces.list",
      title: "Workspaces",
      description: "Switch or create a git worktree",
      group: "session",
      keywords: ["workspace", "worktree", "move", "git"],
      run: () => handlers.showWorkspaces(),
    },
    {
      id: "veasel.update.dialog",
      title: "Check for updates",
      description: "Changelog stub until release channel is wired",
      group: "guide",
      keywords: ["update", "changelog", "version", "release"],
      run: () => handlers.showUpdate(),
    },
    {
      id: "veasel.pair.dialog",
      title: "Device pairing",
      description: "Not available — see compatibility doc",
      group: "guide",
      keywords: ["pair", "device", "mobile", "qr"],
      run: () => handlers.showPair(),
    },
    {
      id: "veasel.highlights.dialog",
      title: "What's new",
      description: "Release highlights (stub)",
      group: "guide",
      keywords: ["highlights", "release", "notes", "new"],
      run: () => handlers.showHighlights(),
    },
    {
      id: "veasel.image.preview",
      title: "Image preview",
      description: "Attachment preview stub (ASCII fallback)",
      group: "session",
      keywords: ["image", "preview", "attachment", "screenshot"],
      run: () => handlers.showImagePreview(),
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

export type LivePaletteHandlers = {
  cancelTurn: () => void
  showHelp: () => void
  openSettings: () => void
  showModelPicker: () => void
  showVariant: () => void
  showAgent: () => void
  showSessions: () => void
  showUpdate: () => void
  showHighlights: () => void
  showPair: () => void
  createSession: () => void
  openRecent: () => void
  openWorkspaces: () => void
  stashDraft: () => void
  showStash: () => void
  cycleTheme: () => void
  showThemeList: () => void
  renameSession: () => void
  attachFile: () => void
  showSessionDiffs: () => void
  showReviews: () => void
  showShellOutput: () => void
  showSessionTimeline: () => void
  showStatus: () => void
  showRuns: () => void
  showExport: () => void
  showMcp: () => void
  showPlugins: () => void
  showSkills: () => void
  showErrorDetails: () => void
  previousUserMessage: () => void
  nextUserMessage: () => void
  lastUserMessage: () => void
  cycleVerbosity: () => TranscriptVerbosity
  toggleThinking: () => void
  nextSessionTab: () => void
  prevSessionTab: () => void
  widenSidebar: () => void
  narrowSidebar: () => void
  resetSidebar: () => void
  quit: () => void
}

/** Live HTTP shell palette — subset wired to real session/settings actions. */
export function buildLivePaletteCommands(handlers: LivePaletteHandlers): PaletteCommand[] {
  return [
    {
      id: "veasel.turn.cancel",
      title: "Stop active turn",
      description: "Request server cancellation of the active operation",
      group: "session",
      keywords: ["stop", "cancel", "interrupt"],
      shortcut: "Ctrl+X",
      run: () => handlers.cancelTurn(),
    },
    {
      id: "veasel.help",
      title: "Show quick help",
      description: "Open the compact /help guide",
      group: "guide",
      keywords: ["help", "?", "guide"],
      shortcut: "?",
      run: () => handlers.showHelp(),
    },
    {
      id: "veasel.settings",
      title: "Provider settings",
      description: "Connect Meta / models · paste API key · pick muse-wonder",
      group: "setup",
      keywords: ["connect", "provider", "meta", "settings", "api"],
      shortcut: "s",
      run: () => handlers.openSettings(),
    },
    {
      id: "veasel.model.picker",
      title: "Select model",
      description: "Pick the active provider model from the HTTP catalog",
      group: "setup",
      keywords: ["model", "models", "llm", "provider", "catalog"],
      shortcut: "F2",
      run: () => handlers.showModelPicker(),
    },
    {
      id: "veasel.variant.picker",
      title: "Select variant",
      description: "Output-budget preset (fast / default / max → max_output_tokens)",
      group: "setup",
      keywords: ["variant", "effort", "fast", "max", "budget", "tokens"],
      shortcut: "F3",
      run: () => handlers.showVariant(),
    },
    {
      id: "veasel.agent.picker",
      title: "Select agent",
      description: "Per-turn execution policy (ask / auto-edit / sandbox-auto)",
      group: "setup",
      keywords: ["agent", "policy", "ask", "auto-edit", "sandbox", "yolo"],
      shortcut: "F4",
      run: () => handlers.showAgent(),
    },
    {
      id: "veasel.theme.cycle",
      title: "Cycle theme",
      description: "Advance builtin theme and persist to config",
      group: "setup",
      keywords: ["theme", "colors", "mint", "ember"],
      shortcut: "t",
      run: () => handlers.cycleTheme(),
    },
    {
      id: "veasel.theme.list",
      title: "Theme list",
      description: "Pick a builtin theme with live preview",
      group: "setup",
      keywords: ["theme", "colors", "list", "picker", "mint", "ember"],
      run: () => handlers.showThemeList(),
    },
    {
      id: "veasel.update.dialog",
      title: "Check for updates",
      description: "Show the running backend version from GET /v1/health",
      group: "guide",
      keywords: ["update", "version", "changelog", "release"],
      run: () => handlers.showUpdate(),
    },
    {
      id: "veasel.highlights.dialog",
      title: "What's new",
      description: "LiveApp release highlights for tip Solid features",
      group: "guide",
      keywords: ["highlights", "release", "notes", "new", "whats"],
      run: () => handlers.showHighlights(),
    },
    {
      id: "veasel.pair.dialog",
      title: "Device pairing",
      description: "Explain Veasel loopback-only pairing stance",
      group: "guide",
      keywords: ["pair", "device", "mobile", "qr"],
      run: () => handlers.showPair(),
    },
    {
      id: "veasel.session.new",
      title: "New session",
      description: "Create a session in the current workspace",
      group: "session",
      keywords: ["new", "session", "create"],
      shortcut: "n",
      run: () => handlers.createSession(),
    },
    {
      id: "veasel.session.list",
      title: "Session list",
      description: "Browse, filter, rename, or open sessions",
      group: "session",
      keywords: ["sessions", "home", "list", "rename", "filter"],
      shortcut: "Ctrl+L",
      run: () => handlers.showSessions(),
    },
    {
      id: "veasel.session.rename",
      title: "Rename session",
      description: "Edit the selected or active session title",
      group: "session",
      keywords: ["rename", "title", "session", "edit"],
      shortcut: "r",
      run: () => handlers.renameSession(),
    },
    {
      id: "veasel.open",
      title: "Open recent / projects",
      description: "Browse sessions and git worktrees (Ctrl+O)",
      group: "session",
      keywords: ["open", "recent", "projects", "worktrees"],
      shortcut: "Ctrl+O",
      run: () => handlers.openRecent(),
    },
    {
      id: "veasel.workspaces",
      title: "Workspaces",
      description: "List or add linked git worktrees (Ctrl+W)",
      group: "session",
      keywords: ["workspaces", "worktree", "git"],
      shortcut: "Ctrl+W",
      run: () => handlers.openWorkspaces(),
    },
    {
      id: "veasel.stash.push",
      title: "Stash composer draft",
      description: "Save the current compose text to the prompt stash",
      group: "session",
      keywords: ["stash", "draft", "save", "prompt"],
      shortcut: "Ctrl+S",
      run: () => handlers.stashDraft(),
    },
    {
      id: "veasel.stash.list",
      title: "Prompt stash",
      description: "Restore a stashed composer draft",
      group: "session",
      keywords: ["stash", "draft", "prompt", "history", "restore"],
      run: () => handlers.showStash(),
    },
    {
      id: "veasel.attach.file",
      title: "Attach file / image",
      description: "Stage a local path for the next message (@mention on submit)",
      group: "session",
      keywords: ["attach", "file", "image", "screenshot", "upload", "paste"],
      run: () => handlers.attachFile(),
    },
    {
      id: "veasel.session.diff",
      title: "Session diffs",
      description: "Browse workspace edit proposals with split DiffRenderable",
      group: "session",
      keywords: ["diff", "patch", "edits", "files", "review"],
      shortcut: "Ctrl+D",
      run: () => handlers.showSessionDiffs(),
    },
    {
      id: "veasel.reviews.open",
      title: "Pending reviews",
      description: `Approve or reject edits, shell, and MCP (${reviewShortcut.label})`,
      group: "session",
      keywords: ["review", "approve", "reject", "patch", "shell", "mcp"],
      shortcut: reviewShortcut.label,
      run: () => handlers.showReviews(),
    },
    {
      id: "veasel.shell.output",
      title: "Shell output",
      description: "Browse completed shell command output for this session",
      group: "session",
      keywords: ["shell", "output", "terminal", "stdout", "command"],
      run: () => handlers.showShellOutput(),
    },
    {
      id: "veasel.session.timeline",
      title: "Session timeline",
      description: "Jump user turns and restore a prompt into Compose",
      group: "session",
      keywords: ["timeline", "history", "turns", "messages", "restore"],
      shortcut: "Ctrl+T",
      run: () => handlers.showSessionTimeline(),
    },
    {
      id: "veasel.message.user.previous",
      title: "Previous user message",
      description: `Jump to the previous user turn (${messageNavShortcut.previousUser.label})`,
      group: "session",
      keywords: ["message", "user", "previous", "prev", "jump", "anchor", "navigate"],
      shortcut: messageNavShortcut.previousUser.label,
      run: () => handlers.previousUserMessage(),
    },
    {
      id: "veasel.message.user.next",
      title: "Next user message",
      description: `Jump to the next user turn (${messageNavShortcut.nextUser.label})`,
      group: "session",
      keywords: ["message", "user", "next", "jump", "anchor", "navigate"],
      shortcut: messageNavShortcut.nextUser.label,
      run: () => handlers.nextUserMessage(),
    },
    {
      id: "veasel.message.user.last",
      title: "Last user message",
      description: `Jump to the latest user turn (${messageNavShortcut.lastUser.label})`,
      group: "session",
      keywords: ["message", "user", "last", "end", "jump", "anchor", "navigate"],
      shortcut: messageNavShortcut.lastUser.label,
      run: () => handlers.lastUserMessage(),
    },
    {
      id: "veasel.transcript.verbosity",
      title: "Cycle transcript verbosity",
      description: "Quiet (hide tools/thinking) → Default → Everything (expand tools)",
      group: "session",
      keywords: ["verbosity", "quiet", "tools", "thinking", "transcript", "density"],
      run: () => {
        handlers.cycleVerbosity()
      },
    },
    {
      id: "veasel.thinking.toggle",
      title: "Toggle thinking block",
      description: `Expand or collapse the latest thinking fence (${thinkingToggleShortcut.label})`,
      group: "session",
      keywords: ["thinking", "reasoning", "collapse", "expand", "fence"],
      shortcut: thinkingToggleShortcut.label,
      run: () => handlers.toggleThinking(),
    },
    {
      id: "veasel.status",
      title: "Status",
      description: "Session, model, and connection snapshot",
      group: "guide",
      keywords: ["status", "info", "usage", "connection", "mcp"],
      shortcut: "Ctrl+I",
      run: () => handlers.showStatus(),
    },
    {
      id: "veasel.execution.history",
      title: "Execution history",
      description: "Inspect durable runs for the active session",
      group: "session",
      keywords: ["runs", "history", "operations", "executions"],
      run: () => handlers.showRuns(),
    },
    {
      id: "veasel.error.details",
      title: "Error details",
      description: "Inspect the latest LiveApp failure (copyable)",
      group: "guide",
      keywords: ["error", "details", "failure", "stack", "copy"],
      run: () => handlers.showErrorDetails(),
    },
    {
      id: "veasel.session.export",
      title: "Export session",
      description: "Copy or write Markdown/JSON of the current session",
      group: "session",
      keywords: ["export", "copy", "markdown", "json", "download"],
      shortcut: "Ctrl+E",
      run: () => handlers.showExport(),
    },
    {
      id: "veasel.mcp.list",
      title: "MCP servers",
      description: "Browse configured and session-trusted MCP servers",
      group: "setup",
      keywords: ["mcp", "servers", "tools", "trust"],
      shortcut: "Ctrl+M",
      run: () => handlers.showMcp(),
    },
    {
      id: "veasel.plugins.list",
      title: "Plugins",
      description: "Browse linked Agent Plugin packages (/plugins)",
      group: "setup",
      keywords: ["plugin", "plugins", "agent plugin", "package", "link"],
      run: () => handlers.showPlugins(),
    },
    {
      id: "veasel.skills.list",
      title: "Skills",
      description: "Browse discovered skills and insert $source/skill into Compose",
      group: "setup",
      keywords: ["skills", "agents", "invoke", "$"],
      run: () => handlers.showSkills(),
    },
    {
      id: "veasel.session.tab.next",
      title: "Next session tab",
      description: "Switch to the next open session in the tab rail",
      group: "session",
      keywords: ["tab", "session", "next", "switch"],
      shortcut: "Ctrl+]",
      run: () => handlers.nextSessionTab(),
    },
    {
      id: "veasel.session.tab.prev",
      title: "Previous session tab",
      description: "Switch to the previous open session in the tab rail",
      group: "session",
      keywords: ["tab", "session", "previous", "prev", "switch"],
      shortcut: "Ctrl+[",
      run: () => handlers.prevSessionTab(),
    },
    {
      id: "veasel.layout.sidebar.widen",
      title: "Widen sessions sidebar",
      description: "Grow the home SESSIONS column (persisted)",
      group: "setup",
      keywords: ["sidebar", "resize", "wider", "layout", "pane"],
      shortcut: "Alt+→",
      run: () => handlers.widenSidebar(),
    },
    {
      id: "veasel.layout.sidebar.narrow",
      title: "Narrow sessions sidebar",
      description: "Shrink the home SESSIONS column (persisted)",
      group: "setup",
      keywords: ["sidebar", "resize", "narrower", "layout", "pane"],
      shortcut: "Alt+←",
      run: () => handlers.narrowSidebar(),
    },
    {
      id: "veasel.layout.sidebar.reset",
      title: "Reset sessions sidebar width",
      description: "Restore the default home sidebar width (double-click grip)",
      group: "setup",
      keywords: ["sidebar", "resize", "reset", "default", "layout"],
      run: () => handlers.resetSidebar(),
    },
    {
      id: "veasel.quit",
      title: "Quit",
      description: "Exit the Solid TUI",
      group: "session",
      keywords: ["quit", "exit"],
      shortcut: "q",
      run: () => handlers.quit(),
    },
  ]
}
