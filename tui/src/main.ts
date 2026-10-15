import {
  BoxRenderable,
  InputRenderable,
  InputRenderableEvents,
  SelectRenderable,
  SelectRenderableEvents,
  StyledText,
  TextRenderable,
  bold,
  createCliRenderer,
  fg,
  type KeyEvent,
  type TextChunk,
} from "@opentui/core"
import { mergeChatTurns, pageMayHaveOlder, type ChatTurn } from "./chat-history"
import { isConnectCommand, isModelSettingsCommand, renderHelp, unknownSlashCommand } from "./help"
import { filterModelCatalog, filterModelProviders, moveProviderPickerScope, providerPickerScopeLabel, prioritizeModelProviders, safeModelCatalogText, type ModelCatalogEntry, type ModelProvider, type ProviderPickerScope } from "./model-providers"
import { formatTuiHelp, formatTuiVersion, parseTuiCliAction } from "./cli"
import {
  activeReviewIndex,
  moveActiveReviewIndex,
  pendingReviewsOfKind,
  resolveSelectedReviews,
  reviewHotkey,
  reviewSelectionKey,
  toggleReviewSelection,
  withReviewHotkeyHint,
  type ActiveReview,
} from "./active-review"
import { homeFooterHint, sessionFooterHint } from "./footer-hints"
import { shouldQuitOnKey } from "./keyboard"
import { initialOutputTokenBudget, parseOutputTokenBudget } from "./model-settings"
import { adjacentSettingsStep, credentialStepCopy, endpointHost, providerHasKnownEndpoint, settingsBackTarget, settingsPath, settingsProgress } from "./settings-flow"
import { formatSessionList, moveSessionSelection, sessionListCapacity, sessionListColumns, sessionSidebarWidth } from "./session-list"
import { completeSlashCommand, jumpSuggestion, moveSuggestion, runsOnAccept, slashCategoryLabel, slashCommands, slashContextApplies, slashContextNeeded, slashSuggestions, suggestionWindow, type SlashCompletionContext, type SlashSuggestion } from "./slash-commands"
import { formatMcpReview, mcpReviewLineBudget } from "./mcp-review"
import { formatReviewDiff, moveReviewHunkIndex, reviewDiffLineBudget } from "./review-diff"
import {
  formatBoundedBlock,
  formatShellReview,
  shellReviewLineBudget,
  type ApprovedShellSandboxCapability,
} from "./shell-review"
import { transcriptSegments, type TranscriptTone } from "./transcript"
import { formatPendingReviewStatus, pendingReviewOpenCommand, statusWithPendingReviews, totalPendingReviews, type PendingReviewCounts } from "./pending-reviews"
import {
  formatCatalogFilterEmpty,
  formatCatalogFilterHeader,
  isMcpManageRest,
  matchesCatalogFilter,
} from "./catalog-filter"

import {
  formatReportedCacheUsage,
  formatReportedUsage,
  formatSessionUsageSummary,
  statusWithUsage,
  type SessionUsageSummary,
} from "./usage"
import {
  formatRepositoryMapSummary,
  type WorkspaceRepositoryMap,
} from "./repository-map"
import {
  formatThemeList,
  formatThemePreviewStatus,
  isThemeId,
  loadThemeId,
  resolveTheme,
  saveThemeId,
  themeIdFromSlashSuggestion,
  type Theme,
  type ThemeId,
} from "./themes"

let theme: Theme = resolveTheme(loadThemeId())
let committedThemeId: ThemeId = theme.id
let themePreviewActive = false

function pendingReviewStatusColor(counts: PendingReviewCounts): string {
  return totalPendingReviews(counts) > 0 ? theme.statusWarn : theme.statusOk
}

function shortHomePath(value: string): string {
  const home = process.env.HOME?.trim()
  if (home && (value === home || value.startsWith(`${home}/`))) {
    return `~${value.slice(home.length)}`
  }
  return value
}

function headerMetaContent(): string {
  const directory = activeSession?.directory
    ?? process.env.VEASEL_PROJECT_DIR
    ?? process.cwd()
  return `${shortHomePath(directory)}  ·  ● LOCAL`
}

function buildPortraitText(active: Theme): StyledText {
  return new StyledText(portrait.flatMap((row) => [
    ...[...row].map((pixel) => fg(active.portrait[pixel as keyof Theme["portrait"]] ?? active.panelBg)(pixel === " " ? "  " : "██")),
    fg(active.panelBg)("\n"),
  ]))
}

function buildTranscriptStyles(active: Theme): Record<TranscriptTone, (text: string) => TextChunk> {
  return {
    title: (text) => fg(active.title)(bold(text)),
    meta: (text) => fg(active.meta)(text),
    notice: (text) => fg(active.notice)(text),
    diffAdd: (text) => fg(active.diffAdd)(text),
    diffRemove: (text) => fg(active.diffRemove)(text),
    diffMeta: (text) => fg(active.diffMeta)(text),
    userLabel: (text) => fg(active.userLabel)(bold(text)),
    userText: (text) => fg(active.userText)(text),
    assistantLabel: (text) => fg(active.assistantLabel)(bold(text)),
    assistantText: (text) => fg(active.assistantText)(text),
    systemLabel: (text) => fg(active.meta)(bold(text)),
    systemText: (text) => fg(active.meta)(text),
    toolLabel: (text) => fg(active.statusWarn)(bold(text)),
    toolText: (text) => fg(active.notice)(text),
    codeFence: (text) => fg(active.diffMeta)(bold(text)),
    codeBody: (text) => fg(active.inputText)(text),
    inlineCode: (text) => fg(active.inputText)(text),
    strong: (text) => fg(active.assistantText)(bold(text)),
    listMarker: (text) => fg(active.diffMeta)(bold(text)),
    link: (text) => fg(active.brand)(text),
    status: (text) => fg(active.status)(text),
    hint: (text) => fg(active.hint)(text),
  }
}

function composerStyle() {
  return {
    backgroundColor: theme.inputBg,
    focusedBackgroundColor: theme.inputFocusBg,
    textColor: theme.inputText,
    cursorColor: theme.cursor,
  }
}

function selectStyle() {
  return {
    backgroundColor: theme.panelBg,
    focusedBackgroundColor: theme.inputBg,
    selectedBackgroundColor: theme.inputFocusBg,
    selectedTextColor: theme.brand,
    descriptionColor: theme.muted,
  }
}

const tuiVersion = process.env.VEASEL_TUI_VERSION ?? "development"
const tuiCliAction = parseTuiCliAction(process.argv)
if (tuiCliAction === "help") {
  console.log(formatTuiHelp(tuiVersion))
  process.exit(0)
}
if (tuiCliAction === "version") {
  console.log(formatTuiVersion(tuiVersion))
  process.exit(0)
}

type Session = {
  id: string
  title: string
  directory: string
  created_at: string
}

type ModelProfileView = { model: string; base_url: string; api_key_saved: boolean; max_output_tokens: number }
type ModelSettingsView = { active_provider: string; profiles: Record<string, ModelProfileView>; providers: ModelProvider[]; configured_providers?: string[] }

type ChatExchange = {
  messages: ChatTurn[]
  provider: string
  model: string
  usage_reported?: boolean
  input_tokens?: number
  output_tokens?: number
  cache_reported?: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
}

type SessionTurnAccepted = {
  operation_id: string
  status: "running"
}

type SessionTurnCompletion = {
  operation_id?: string
  status?: string
  provider?: string
  model?: string
  error?: string
  usage_reported?: boolean
  input_tokens?: number
  output_tokens?: number
  cache_reported?: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
}

type PluginCatalog = {
  plugins: Array<{
    name: string
    origin?: string
    veasel_extension?: { display_name?: string; has_directory?: boolean }
    skills: Array<{
      name: string
      description: string
      allowed_tools_declared: boolean
      allowed_tools: string[]
      source?: string
      scope?: string
    }>
    mcp_servers: Array<{ name: string; transport: string; command: string; url_origin: string; header_count: number; header_names: string[] }>
  }>
}

type SessionPluginSkill = {
  plugin_name: string
  skill_name: string
}

type SessionPluginMCPServer = {
  plugin_name: string
  server_name: string
}

type PluginMCPToolCallApproval = {
  id: string
  operation_id: string
  plugin_name: string
  server_name: string
  tool_name: string
  arguments_json: string
  status: "pending" | "approved" | "running" | "completed" | "rejected" | "failed" | "cancelled" | "uncertain"
  reviewed_at: string
  created_at: string
  updated_at: string
}

type PluginMCPToolCallSummary = Omit<PluginMCPToolCallApproval, "arguments_json"> & {
  arguments_bytes: number
}

type WorkspaceEditSummary = {
  id: string
  path: string
  status: "pending" | "applying" | "applied" | "rejected" | "conflict" | "interrupted"
  created_at: string
  updated_at: string
}

type WorkspaceEditProposal = WorkspaceEditSummary & { session_id: string; diff: string }

type ShellCommandSummary = {
  id: string
  command: string
  cwd: string
  timeout_seconds: number
  status: "pending" | "running" | "succeeded" | "failed" | "timed_out" | "output_limited" | "rejected" | "uncertain"
  exit_code: number
  output: string
  created_at: string
  updated_at: string
}

const port = process.env.VEASEL_PORT ?? "4097"
const configuredApi = process.env.VEASEL_API_URL ?? `http://127.0.0.1:${port}`
const apiUrl = new URL(configuredApi)
if (
  apiUrl.protocol !== "http:" ||
  !["localhost", "127.0.0.1", "[::1]", "::1"].includes(apiUrl.hostname) ||
  apiUrl.username !== "" ||
  apiUrl.password !== "" ||
  apiUrl.pathname !== "/" ||
  apiUrl.search !== "" ||
  apiUrl.hash !== ""
) {
  throw new Error("Veasel TUI only connects to an unauthenticated loopback API")
}
const apiBase = apiUrl.origin
const renderer = await createCliRenderer({ exitOnCtrlC: true })
const controller = new AbortController()
const chatHistoryPageSize = 100

const portrait = [
  "    DDDDD     DDDDD    ",
  "   DLLLLD     DLLLLD   ",
  "  DLLLLLDDDDDDDLLLLLD  ",
  "  DLLLDDDDDDDDDDDLLLDD ",
  " DDDDDDDDBBBBBBDDDDDDD ",
  "DDDDDDBBBBBBBBBBBBBBDDDD",
  "DDDDBBBBBBBBBBBBBBBBBBDDD",
  "DDBBBBBBBBBBBBBBBBBBBBBBDD",
  "DBBBBKBBBBBBBBBBBBKBBBBBBBD",
  "DBBBBHKBBBBBBBBBBHKBBBBBBBD",
  "DBBBBBBBBBBNNBBBBBBBBBBBBBD",
  " DDBBWWWWWNNNNNWWWWWWBBBBDD ",
  "  DDBBWWWWWWWWWWWWBBBBDD  ",
  "   DDDBBWWWWWWWWBBBDDD   ",
  "     DDDBBBBBBBDDD     ",
  "       DDDDDD       ",
]

const shell = new BoxRenderable(renderer, {
  width: "100%",
  height: "100%",
  flexDirection: "column",
  backgroundColor: theme.shellBg,
  padding: 1,
  gap: 1,
})
const header = new BoxRenderable(renderer, {
  height: 3,
  flexDirection: "row",
  alignItems: "center",
  justifyContent: "space-between",
  paddingLeft: 1,
  paddingRight: 1,
  backgroundColor: theme.headerBg,
  borderStyle: "rounded",
  borderColor: theme.headerBorder,
})
const headerTitle = new TextRenderable(renderer, { content: " VEASEL  /  CODE", fg: theme.headerTitle })
const headerMeta = new TextRenderable(renderer, { content: "● LOCAL", fg: theme.headerMeta })
header.add(headerTitle)
header.add(headerMeta)

const body = new BoxRenderable(renderer, {
  flexGrow: 1,
  flexDirection: "row",
  gap: 1,
})
const sidebar = new BoxRenderable(renderer, {
  width: sessionSidebarWidth(process.stdout.columns ?? 80),
  flexDirection: "column",
  padding: 1,
  gap: 1,
  overflow: "hidden",
  backgroundColor: theme.panelBg,
  borderStyle: "rounded",
  borderColor: theme.panelBorder,
})
const sessionsLabel = new TextRenderable(renderer, { content: "SESSIONS", fg: theme.sidebarLabel, wrapMode: "none" })
sidebar.add(sessionsLabel)
const sessionList = new TextRenderable(renderer, {
  content: "Connecting to Veasel…",
  fg: theme.sidebarFg,
  wrapMode: "none",
})
sidebar.add(sessionList)
const sidebarBrand = new TextRenderable(renderer, {
  content: "VEASEL CODE\nyour local workspace",
  fg: theme.muted,
  wrapMode: "word",
})
sidebar.add(sidebarBrand)
const detail = new BoxRenderable(renderer, {
  flexGrow: 1,
  flexDirection: "column",
  padding: 2,
  gap: 1,
  backgroundColor: theme.panelBg,
  borderStyle: "rounded",
  borderColor: theme.panelBorder,
})
let portraitText = buildPortraitText(theme)
const portraitRenderable = new TextRenderable(renderer, { content: portraitText })
detail.add(portraitRenderable)
const brandLabel = new TextRenderable(renderer, { content: "VEASEL CODE", fg: theme.brand })
detail.add(brandLabel)
const sessionDetail = new TextRenderable(renderer, {
  content: "Your V-powered coding companion.\n\nConnect provider · /connect\nPaste an API key, save it on this machine, then pick a model. Or press s for full provider settings.",
  fg: theme.body,
  wrapMode: "word",
})
detail.add(sessionDetail)
body.add(sidebar)
body.add(detail)

// TextRenderable.content returns StyledText, so `+=` would render "[object Object]".
function appendSessionDetail(text: string) {
  sessionDetail.content = sessionDetail.plainText + text
}

function homeDetailContent(providersConfigured: boolean): string {
  if (!providersConfigured) {
    return "Your V-powered coding companion.\n\nConnect provider · /connect\nPaste an API key, save it on this machine, then pick a model. Or press s for full provider settings."
  }
  return "Your V-powered coding companion.\n\nChoose a session on the left, press n to start a workspace, or use /connect · s to manage providers."
}

function settingsFooterHint(step: number, endpoint: boolean, budget: boolean): string {
  if (step === 0) return "Tab group · Enter configure · Esc close"
  const parts = [
    step === 2 ? "Enter discovers" : step === 4 ? "Enter saves budget" : step === 1 ? "Enter keeps endpoint" : "Enter selects",
    "Ctrl+B back",
  ]
  if (endpoint) parts.push("Ctrl+U endpoint")
  if (budget) parts.push("Ctrl+O budget")
  parts.push("Esc")
  return parts.join(" · ")
}
const footer = new BoxRenderable(renderer, {
  height: 4,
  flexDirection: "column",
  justifyContent: "center",
  paddingLeft: 1,
  paddingRight: 1,
  overflow: "hidden",
  backgroundColor: theme.headerBg,
  borderStyle: "rounded",
  borderColor: theme.panelBorder,
})
const status = new TextRenderable(renderer, { content: "● connecting", fg: theme.statusWarn, wrapMode: "none" })
footer.add(status)
const footerHint = new TextRenderable(renderer, {
  content: homeFooterHint,
  fg: theme.muted,
  wrapMode: "none",
})
footer.add(footerHint)
shell.add(header)
shell.add(body)
shell.add(footer)
renderer.root.add(shell)

let sessions: Session[] = []
let selected = 0
let creating = false
let slashMenu: TextRenderable | undefined
let slashMatches: SlashSuggestion[] = []
let slashSelected = 0
let slashDismissedFor: string | undefined
let titleInput: InputRenderable | undefined
let activeSession: Session | undefined
let chatInput: InputRenderable | undefined
let sendingMessage = false
let activeTurnId: string | undefined
let activeTurnController: AbortController | undefined
let activeTurnCancelled = false
let pendingUserMessage = ""
let lastPendingCounts: PendingReviewCounts = { edits: 0, commands: 0, mcp: 0 }
let pendingReviewQueue: ActiveReview[] = []
let activeReview: ActiveReview | undefined
let selectedReviewKeys = new Set<string>()
let activePatchDiff = ""
let activePatchPath = ""
let activePatchStatus = ""
let activePatchHunkIndex = 0
let chatMessages: ChatTurn[] = []
let chatHistoryHasOlder = false
let chatHistoryLoading = false
let settingsOpen = false
let settingsMode: "connect" | "models" = "models"
let settingsInput: InputRenderable | undefined
let settingsSecretIndicator: TextRenderable | undefined
let settingsProviderSelect: SelectRenderable | undefined
let settingsModelSelect: SelectRenderable | undefined
let settingsProviderQuery = ""
let settingsProviderScope: ProviderPickerScope = "all"
let settingsModelSearchQuery = ""
let settingsModelCatalog: ModelCatalogEntry[] | undefined
let settingsModelHint = ""
let settingsManualModel = false
let settingsStep = 0
let settingsView: ModelSettingsView | undefined
let settingsCatalogRequestId = 0
let settingsCatalogController: AbortController | undefined
const settingsValues = { provider: "", model: "", base_url: "", api_key: "", clear_api_key: false, max_output_tokens: 4096 }
let settingsEditEndpoint = false
let settingsEditBudget = false
let settingsDetourFrom: number | undefined
let providersConfigured = false
let slashContext: SlashCompletionContext = {}
let slashContextLoading = false
let slashContextAt = 0
let slashContextRequest = 0
let streamingAssistantText = ""
let skillNotice = ""
let shellSandboxCapability: ApprovedShellSandboxCapability = null

function approvedShellSandboxHint(): string {
  if (shellSandboxCapability === "bubblewrap") {
    return "On Linux, approved commands run inside Bubblewrap when available (read-only host, writable workspace, network isolated by default)."
  }
  if (shellSandboxCapability === "seatbelt") {
    return "On macOS, approved commands run inside Seatbelt when sandbox-exec is available (writable workspace, home/Volumes restricted, network isolated by default)."
  }
  if (shellSandboxCapability === "windows") {
    return "On Windows, approved commands run inside AppContainer + Job Object when available (workspace ACL grant, network isolated by default, process-tree/resource caps; not Codex WFP/LPAC)."
  }
  return "Commands run with your OS user permissions without an OS sandbox when the platform sandbox is unavailable or VEASEL_SHELL_SANDBOX=off."
}

function pendingShellSandboxNotice(count: number): string {
  const plural = count === 1 ? "" : "s"
  if (shellSandboxCapability === "bubblewrap") {
    return `${count} shell command proposal${plural} need review. Type /commands to inspect them. Approval runs inside Bubblewrap (read-only host, writable workspace, network isolated by default); inherited environment may still carry credentials.`
  }
  if (shellSandboxCapability === "seatbelt") {
    return `${count} shell command proposal${plural} need review. Type /commands to inspect them. Approval runs inside Seatbelt (writable workspace, home/Volumes restricted, network isolated by default); inherited environment may still carry credentials.`
  }
  if (shellSandboxCapability === "windows") {
    return `${count} shell command proposal${plural} need review. Type /commands to inspect them. Approval runs inside Windows AppContainer + Job Object (workspace ACL grant, network isolated by default, process-tree/resource caps; not Codex WFP/LPAC); inherited environment may still carry credentials.`
  }
  return `${count} shell command proposal${plural} need review. Type /commands to inspect them. Approval runs commands with your OS user permissions and inherited environment, without an OS sandbox.`
}
const reviewedEditIds = new Set<string>()
const reviewedShellCommandIds = new Set<string>()
const handledTurnCompletionIds = new Set<string>()

function renderSessions() {
  const terminalColumns = process.stdout.columns ?? 80
  sidebar.width = sessionSidebarWidth(terminalColumns)
  const count = String(sessions.length).padStart(2, "0")
  sessionsLabel.content = sessions.length > 0 ? `SESSIONS  ${count}` : "SESSIONS"
  sessionsLabel.fg = theme.sidebarLabel
  const text = formatSessionList(sessions, selected, {
    rows: process.stdout.rows ?? 40,
    columns: sessionListColumns(terminalColumns),
  })
  const chunks = text.split("\n").flatMap((line, index, lines) => {
    const selectedLine = line.startsWith("●")
    const color = selectedLine ? theme.sessionSelectedFg : theme.sidebarFg
    const chunk = selectedLine ? fg(color)(bold(line)) : fg(color)(line)
    return index < lines.length - 1 ? [chunk, fg(theme.sidebarFg)("\n")] : [chunk]
  })
  sessionList.content = new StyledText(chunks)
  headerMeta.content = headerMetaContent()
  headerMeta.fg = theme.headerMeta
}

function applyTheme(next: Theme) {
  theme = next
  shell.backgroundColor = theme.shellBg
  header.backgroundColor = theme.headerBg
  header.borderColor = theme.headerBorder
  headerTitle.fg = theme.headerTitle
  headerMeta.fg = theme.headerMeta
  headerMeta.content = headerMetaContent()
  sidebar.backgroundColor = theme.panelBg
  sidebar.borderColor = theme.panelBorder
  sessionsLabel.fg = theme.sidebarLabel
  sidebarBrand.fg = theme.muted
  detail.backgroundColor = theme.panelBg
  detail.borderColor = theme.panelBorder
  brandLabel.fg = theme.brand
  sessionDetail.fg = theme.body
  footer.backgroundColor = theme.headerBg
  footer.borderColor = theme.panelBorder
  footerHint.fg = theme.muted
  portraitText = buildPortraitText(theme)
  transcriptStyles = buildTranscriptStyles(theme)
  if (!activeSession) portraitRenderable.content = portraitText
  if (chatInput) {
    const style = composerStyle()
    chatInput.backgroundColor = style.backgroundColor
    chatInput.focusedBackgroundColor = style.focusedBackgroundColor
    chatInput.textColor = style.textColor
    chatInput.cursorColor = style.cursorColor
  }
  if (titleInput) {
    const style = composerStyle()
    titleInput.backgroundColor = style.backgroundColor
    titleInput.focusedBackgroundColor = style.focusedBackgroundColor
    titleInput.textColor = style.textColor
    titleInput.cursorColor = style.cursorColor
  }
  renderSessions()
  renderChat(chatMessages)
}

function setTheme(id: ThemeId) {
  saveThemeId(id)
  committedThemeId = id
  themePreviewActive = false
  applyTheme(resolveTheme(id))
  skillNotice = formatThemeList(id)
  renderChat(chatMessages)
  status.content = `● theme ${resolveTheme(id).name}`
  status.fg = theme.statusOk
}

function restoreCommittedTheme() {
  if (!themePreviewActive && theme.id === committedThemeId) return
  themePreviewActive = false
  applyTheme(resolveTheme(committedThemeId))
  // Prefer the pending-review cue over a theme-restored status when approvals wait.
  if (totalPendingReviews(lastPendingCounts) > 0) {
    status.content = statusWithPendingReviews(`● theme ${resolveTheme(committedThemeId).name}`, lastPendingCounts)
    status.fg = theme.statusWarn
    return
  }
  status.content = `● theme ${resolveTheme(committedThemeId).name}`
  status.fg = theme.statusOk
}

// Live-preview the highlighted /theme suggestion without writing the preference.
function previewThemeFromSlashSelection() {
  const selected = slashMatches[slashSelected]
  const previewId = selected ? themeIdFromSlashSuggestion(selected.name) : undefined
  if (!previewId) {
    if (themePreviewActive) restoreCommittedTheme()
    return
  }
  themePreviewActive = true
  if (theme.id !== previewId) applyTheme(resolveTheme(previewId))
  status.content = formatThemePreviewStatus(previewId, committedThemeId)
  status.fg = previewId === committedThemeId ? theme.statusOk : theme.statusWarn
}

async function refreshProviderSetupHint() {
  try {
    const response = await fetch(`${apiBase}/v1/config/model`, { signal: controller.signal })
    if (!response.ok) return
    const view = await response.json() as ModelSettingsView
    providersConfigured = (view.configured_providers?.length ?? 0) > 0
      || Object.keys(view.profiles ?? {}).length > 0
    if (!settingsOpen && !activeSession) {
      sessionDetail.content = homeDetailContent(providersConfigured)
    }
  } catch {
    // Home still works without the settings probe.
  }
}

async function refreshShellSandboxCapability() {
  try {
    const response = await fetch(`${apiBase}/v1/capabilities`, { signal: controller.signal })
    if (!response.ok) {
      shellSandboxCapability = null
      return
    }
    const body = await response.json() as { features?: string[] }
    const features = Array.isArray(body.features) ? body.features : []
    if (features.includes("shell.sandbox.bubblewrap")) {
      shellSandboxCapability = "bubblewrap"
    } else if (features.includes("shell.sandbox.seatbelt")) {
      shellSandboxCapability = "seatbelt"
    } else if (features.includes("shell.sandbox.windows")) {
      shellSandboxCapability = "windows"
    } else {
      shellSandboxCapability = null
    }
  } catch {
    shellSandboxCapability = null
  }
}

async function refreshSessions() {
  try {
    const response = await fetch(`${apiBase}/v1/sessions`, { signal: controller.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    sessions = await response.json() as Session[]
    selected = Math.min(selected, Math.max(0, sessions.length - 1))
    renderSessions()
    status.content = `● connected  ·  ${sessions.length} session${sessions.length === 1 ? "" : "s"}`
    status.fg = theme.statusOk
    if (!settingsOpen && !activeSession) {
      sessionDetail.content = homeDetailContent(providersConfigured)
      void refreshProviderSetupHint()
      void refreshShellSandboxCapability()
    }
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● server unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = theme.statusError
  }
}

async function createSession(title: string) {
  const response = await fetch(`${apiBase}/v1/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      title,
      directory: process.env.VEASEL_PROJECT_DIR ?? process.cwd(),
    }),
    signal: controller.signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
  const created = await response.json() as Session
  await refreshSessions()
  selected = sessions.findIndex((session) => session.id === created.id)
  renderSessions()
}

function renderChat(messages: ChatTurn[]) {
  chatMessages = messages
  const helpVisible = skillNotice.startsWith("VEASEL CODE / QUICK HELP")
  header.visible = !helpVisible
  sidebar.visible = !helpVisible
  portraitRenderable.content = activeSession ? "" : portraitText
  brandLabel.content = activeSession ? "" : "VEASEL CODE"
  const segments = transcriptSegments({
    session: activeSession && !helpVisible
      ? { title: safeTerminalText(activeSession.title), directory: safeTerminalText(activeSession.directory) }
      : undefined,
    notice: skillNotice ? safeTerminalText(skillNotice) : undefined,
    messages: messages.map((message) => ({ role: message.role, content: safeTerminalText(message.content) })),
    pendingUserMessage: safeTerminalText(pendingUserMessage),
    streamingText: safeTerminalText(streamingAssistantText),
    streaming: Boolean(activeTurnId),
    hasOlder: chatHistoryHasOlder,
    showMessages: !helpVisible,
  })
  sessionDetail.content = new StyledText(segments.map(({ text, tone }) => transcriptStyles[tone](text)))
}

let transcriptStyles: Record<TranscriptTone, (text: string) => TextChunk> = buildTranscriptStyles(theme)

function safeTerminalText(value: string) {
  return value.replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
}

function safeTerminalReviewText(value: string) {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/gu,
    (character) => `\\u${character.codePointAt(0)!.toString(16).padStart(4, "0")}`)
}

async function openSession(session: Session) {
  resetSlashContext()
  activeSession = session
  chatHistoryHasOlder = false
  chatHistoryLoading = false
  chatMessages = []
  streamingAssistantText = ""
  pendingUserMessage = ""
  reviewedShellCommandIds.clear()
  skillNotice = ""
  reviewedEditIds.clear()
  renderChat([])
  const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(session.id)}/messages`, {
    signal: controller.signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const messages = await response.json() as ChatTurn[]
  chatHistoryHasOlder = pageMayHaveOlder(messages, chatHistoryPageSize)
  renderChat(messages)
  await notifyPendingProposals()
  footerHint.content = sessionFooterHint
  if (!chatInput) {
    const input = new InputRenderable(renderer, {
      id: "chat-composer",
      width: "100%",
      placeholder: "Ask Veasel to explain or propose a workspace change…  ·  type / for commands",
      ...composerStyle(),
      maxLength: 1_048_576,
    })
    chatInput = input
    detail.add(input)
    mountSlashMenu()
    input.on(InputRenderableEvents.INPUT, () => updateSlashMenu(input.value))
    input.on(InputRenderableEvents.ENTER, (value) => {
      resetSlashMenu()
      if (isConnectCommand(value)) {
        input.value = ""
        void openSettings("connect")
        return
      }
      if (isModelSettingsCommand(value)) {
        input.value = ""
        void openSettings("models")
        return
      }
      void sendMessage(value)
    })
  }
  chatInput.focus()
}

async function sendMessage(value: string) {
  const content = value.trim()
  const mcpCallCommand = /^\/mcp (calls|call (show|approve|reject) [0-9a-f-]{36})$/.test(content)
  if (!content || !activeSession || !chatInput || sendingMessage && !mcpCallCommand) return
  if (content === "/help" || content === "/?" || content === "/help advanced") {
    skillNotice = renderHelp(content === "/help" && (process.stdout.rows ?? 40) < 30)
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/history older") {
    chatInput.value = ""
    await loadOlderChatHistory()
    chatInput.focus()
    return
  }
  if (content === "/usage") {
    await showSessionUsage()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/map" || content.startsWith("/map ")) {
    const hint = content === "/map" ? "" : content.slice("/map ".length).trim()
    await showRepositoryMap(hint)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/theme") {
    skillNotice = formatThemeList(theme.id)
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const themeMatch = content.match(/^\/theme\s+([a-z]+)$/i)
  if (themeMatch) {
    const id = themeMatch[1]!.toLowerCase()
    if (!isThemeId(id)) {
      skillNotice = `Unknown theme "${id}".\n\n${formatThemeList(theme.id)}`
      renderChat(chatMessages)
      chatInput.value = ""
      chatInput.focus()
      return
    }
    setTheme(id)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (/^\/history(?:\s|$)/.test(content)) {
    skillNotice = "Use /history older to load the preceding page of this session's chat history."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/skills" || content.startsWith("/skills ")) {
    const filter = content === "/skills" ? "" : content.slice("/skills ".length).trim()
    await showSkills(filter)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/plugins" || content.startsWith("/plugins ")) {
    const filter = content === "/plugins" ? "" : content.slice("/plugins ".length).trim()
    await showPluginLinks(filter)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/plugin add ")) {
    await addPluginLink(content.slice("/plugin add ".length).trim())
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/plugin remove ")) {
    await removePluginLink(content.slice("/plugin remove ".length).trim())
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/plugin")) {
    skillNotice = "Use /plugins to list managed links, /plugin add <absolute-path> to link a local package, or /plugin remove <name> to unlink. Only symlinks are removed; PLUGIN_DATA stays on disk."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/mcp") {
    await showMcpServers()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/mcp ") && !isMcpManageRest(content.slice("/mcp ".length))) {
    await showMcpServers(content.slice("/mcp ".length).trim())
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/mcp calls") {
    await showMcpToolCalls()
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpToolCallCommand = /^\/mcp call (show|approve|reject) ([0-9a-f-]{36})$/.exec(content)
  if (mcpToolCallCommand) {
    const action = mcpToolCallCommand[1]
    const callId = mcpToolCallCommand[2]
    if (action === "show") await showMcpToolCall(callId)
    else if (action === "approve" || action === "reject") await actOnMcpToolCall(callId, action)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpAddStdio = /^\/mcp add(?:\s+(user|project))?\s+stdio\s+([a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])\s+(\S+)(?:\s+(.+))?$/.exec(content)
  if (mcpAddStdio) {
    await addConfiguredMcpServer({
      name: mcpAddStdio[2],
      transport: "stdio",
      command: mcpAddStdio[3],
      args: mcpAddStdio[4] ? splitMcpArgs(mcpAddStdio[4]) : [],
      scope: mcpAddStdio[1] === "project" ? "project" : "user",
    })
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpAddHttp = /^\/mcp add(?:\s+(user|project))?\s+http\s+([a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])\s+(\S+)$/.exec(content)
  if (mcpAddHttp) {
    await addConfiguredMcpServer({
      name: mcpAddHttp[2],
      transport: "streamable-http",
      url: mcpAddHttp[3],
      scope: mcpAddHttp[1] === "project" ? "project" : "user",
    })
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpToggle = /^\/mcp\s+(remove|enable|disable)(?:\s+(user|project))?\s+([a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])$/.exec(content)
  if (mcpToggle) {
    const action = mcpToggle[1]
    const scope = mcpToggle[2] === "project" ? "project" : "user"
    const name = mcpToggle[3]
    if (action === "remove") await removeConfiguredMcpServer(name, scope)
    else await setConfiguredMcpEnabled(name, action === "enable", scope)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const mcpCommand = /^\/mcp\s+(trust|untrust)\s+([a-z0-9.-]+)\/([^\r\n]+)$/.exec(content)
  if (mcpCommand) {
    await setMcpServerTrust(mcpCommand[1] === "trust", mcpCommand[2], mcpCommand[3].trim())
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/mcp ")) {
    skillNotice = "Use /mcp to list servers. Add with /mcp add [user|project] stdio <name> <command> [args…] or /mcp add [user|project] http <name> <url>. Toggle with /mcp enable|disable [user|project] <name>, remove with /mcp remove [user|project] <name>, then /mcp trust configured/<name>. Project scope writes <workspace>/.veasel/mcp-servers.json."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/patches" || content.startsWith("/patches ")) {
    const filter = content === "/patches" ? "" : content.slice("/patches ".length).trim()
    await showWorkspaceEdits(filter)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const editCommand = /^\/patch\s+(approve|reject)\s+([0-9a-f-]{36})$/.exec(content)
  if (editCommand) {
    await actOnWorkspaceEdit(editCommand[1] === "approve" ? "approve" : "reject", editCommand[2])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const showEditCommand = /^\/patch\s+show\s+([0-9a-f-]{36})$/.exec(content)
  if (showEditCommand) {
    await showWorkspaceEdit(showEditCommand[1])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/patch ")) {
    skillNotice = "Use /patches to find an ID, /patch show <id> to inspect its diff, then approve or reject it."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content === "/commands" || content.startsWith("/commands ")) {
    const filter = content === "/commands" ? "" : content.slice("/commands ".length).trim()
    await showShellCommands(filter)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const shellAction = /^\/command\s+(approve|reject)\s+([0-9a-f-]{36})$/.exec(content)
  if (shellAction) {
    await actOnShellCommand(shellAction[1] as "approve" | "reject", shellAction[2])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const showShellAction = /^\/command\s+show\s+([0-9a-f-]{36})$/.exec(content)
  if (showShellAction) {
    await showShellCommand(showShellAction[1])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/command ")) {
    skillNotice = `Use /commands to list proposals, /command show <id> to inspect one, then /command approve <id> or /command reject <id>. ${approvedShellSandboxHint()}`
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  const skillCommand = /^\/skill\s+(on|off)\s+([a-z0-9.-]+)\/([a-z0-9-]+)$/.exec(content)
  if (skillCommand) {
    await setSkill(skillCommand[1] === "on", skillCommand[2], skillCommand[3])
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (content.startsWith("/skill ")) {
    skillNotice = "Use /skill on <plugin>/<skill> or /skill off <plugin>/<skill>."
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  if (unknownSlashCommand(content)) {
    skillNotice = `Unknown command: ${safeTerminalText(content)}\n\nType /help to see available commands. Messages to the model should start with normal text.`
    renderChat(chatMessages)
    chatInput.value = ""
    chatInput.focus()
    return
  }
  skillNotice = ""
  sendingMessage = true
  activeTurnId = crypto.randomUUID()
  activeTurnController = new AbortController()
  activeTurnCancelled = false
  pendingUserMessage = content
  streamingAssistantText = ""
  renderChat(chatMessages)
  const operationId = activeTurnId
  const turnController = activeTurnController
  let awaitingAsyncCompletion = false
  chatInput.value = ""
  chatInput.blur()
  status.content = "● Veasel is thinking…"
  status.fg = theme.statusWarn
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-veasel-operation-id": operationId,
        prefer: "respond-async",
      },
      body: JSON.stringify({ content }),
      signal: AbortSignal.any([controller.signal, turnController.signal]),
    })
    if (response.status === 202) {
      const accepted = await response.json() as SessionTurnAccepted
      if (accepted.operation_id !== operationId) throw new Error("Server returned a different operation ID")
      if (activeTurnId === operationId) awaitingAsyncCompletion = true
      return
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const exchange = await response.json() as ChatExchange
    const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/messages`, {
      signal: controller.signal,
    })
    if (!historyResponse.ok) throw new Error(`HTTP ${historyResponse.status}`)
    streamingAssistantText = ""
    const latest = await historyResponse.json() as ChatTurn[]
    chatHistoryHasOlder ||= pageMayHaveOlder(latest, chatHistoryPageSize)
    renderChat(mergeChatTurns(chatMessages, latest))
    await notifyPendingProposals()
    const completedStatus = statusWithUsage(exchange.provider, exchange.model, exchange)
    const pendingCounts = await countPendingReviews()
    status.content = statusWithPendingReviews(completedStatus, pendingCounts)
    status.fg = pendingReviewStatusColor(pendingCounts)
  } catch (error) {
    if (activeTurnCancelled) {
      status.content = "● response cancelled"
      status.fg = theme.statusWarn
      return
    }
    if (controller.signal.aborted) return
    status.content = `● message failed  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = theme.statusError
  } finally {
    if (!awaitingAsyncCompletion && activeTurnId === operationId) {
      sendingMessage = false
      pendingUserMessage = ""
      activeTurnId = undefined
      activeTurnController = undefined
      if (streamingAssistantText) renderChat(chatMessages)
      chatInput?.focus()
    }
  }
}

async function showSessionUsage() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/usage`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const summary = await response.json() as SessionUsageSummary
    skillNotice = formatSessionUsageSummary(summary)
    renderChat(chatMessages)
    if (summary.usage_reported) {
      let usageLine = `● session usage  ·  ${formatReportedUsage(summary.input_tokens, summary.output_tokens)}`
      if (summary.cache_reported) {
        usageLine += `  ·  ${formatReportedCacheUsage(summary.cache_read_tokens ?? 0, summary.cache_creation_tokens ?? 0)}`
      }
      status.content = usageLine
    } else {
      status.content = "● session usage  ·  no provider-reported tokens yet"
    }
    status.fg = theme.statusOk
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● usage unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = theme.statusError
  }
}

async function showRepositoryMap(hint = "") {
  if (!activeSession) return
  try {
    const query = hint.length > 0 ? `?hint=${encodeURIComponent(hint)}` : ""
    const response = await fetch(
      `${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/map${query}`,
      { signal: controller.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const map = await response.json() as WorkspaceRepositoryMap
    skillNotice = formatRepositoryMapSummary(map, hint)
    renderChat(chatMessages)
    const truncated = map.truncated ? " · truncated" : ""
    status.content = `● repository map  ·  ${map.bytes} B · ${map.file_count} files · ${map.symbol_count} symbols${truncated}`
    status.fg = theme.statusOk
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● repository map unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = theme.statusError
  }
}

async function loadOlderChatHistory() {
  if (!activeSession || chatHistoryLoading) return
  if (!chatHistoryHasOlder || chatMessages.length === 0) {
    status.content = "● no earlier chat messages"
    status.fg = theme.muted
    return
  }
  const sessionId = activeSession.id
  const before = chatMessages[0].id
  chatHistoryLoading = true
  status.content = "● loading earlier messages…"
  status.fg = theme.statusWarn
  try {
    const response = await fetch(
      `${apiBase}/v1/sessions/${encodeURIComponent(sessionId)}/messages?before=${before}&limit=${chatHistoryPageSize}`,
      { signal: controller.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const older = await response.json() as ChatTurn[]
    if (activeSession?.id !== sessionId) return
    chatHistoryHasOlder = pageMayHaveOlder(older, chatHistoryPageSize)
    const previousCount = chatMessages.length
    renderChat(mergeChatTurns(chatMessages, older))
    const loadedCount = chatMessages.length - previousCount
    status.content = loadedCount > 0
      ? `● loaded ${loadedCount} earlier messages`
      : "● no earlier chat messages"
    status.fg = theme.statusOk
  } catch (error) {
    if (controller.signal.aborted) return
    status.content = `● history load failed  ·  ${error instanceof Error ? error.message : "request failed"}`
    status.fg = theme.statusError
  } finally {
    chatHistoryLoading = false
  }
}

async function finishAsyncSessionTurn(sessionId: string, completion: SessionTurnCompletion) {
  const operationId = completion.operation_id
  if (!operationId || handledTurnCompletionIds.has(operationId)) return
  handledTurnCompletionIds.add(operationId)
  if (handledTurnCompletionIds.size > 128) {
    const oldest = handledTurnCompletionIds.values().next().value
    if (oldest) handledTurnCompletionIds.delete(oldest)
  }
  if (activeTurnId !== operationId) {
    if (activeSession?.id === sessionId) {
      if (completion.status === "uncertain") {
        status.content = "● operation outcome uncertain · inspect the workspace before retrying"
        status.fg = theme.statusWarn
      }
      try {
        const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(sessionId)}/messages`, {
          signal: controller.signal,
        })
        if (historyResponse.ok) {
          const latest = await historyResponse.json() as ChatTurn[]
          chatHistoryHasOlder ||= pageMayHaveOlder(latest, chatHistoryPageSize)
          renderChat(mergeChatTurns(chatMessages, latest))
        }
      } catch {
        // Reopening the session reloads its durable history if this refresh fails.
      }
    }
    return
  }
  if (activeSession?.id !== sessionId) {
    pendingUserMessage = ""
    streamingAssistantText = ""
    sendingMessage = false
    activeTurnId = undefined
    activeTurnController = undefined
    activeTurnCancelled = false
    return
  }
  const userCancelled = activeTurnCancelled
  let historyLoaded = false
  try {
    const historyResponse = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(sessionId)}/messages`, {
      signal: controller.signal,
    })
    if (!historyResponse.ok) throw new Error(`HTTP ${historyResponse.status}`)
    if (activeSession?.id !== sessionId) {
      sendingMessage = false
      activeTurnId = undefined
      activeTurnController = undefined
      activeTurnCancelled = false
      return
    }
    const latest = await historyResponse.json() as ChatTurn[]
    chatHistoryHasOlder ||= pageMayHaveOlder(latest, chatHistoryPageSize)
    pendingUserMessage = ""
    streamingAssistantText = ""
    renderChat(mergeChatTurns(chatMessages, latest))
    historyLoaded = true
    if (completion.status === "completed") await notifyPendingProposals()
  } catch (error) {
    if (activeSession?.id === sessionId) renderChat(chatMessages)
    if (completion.status === "completed") {
      status.content = `● turn completed  ·  ${error instanceof Error ? error.message : "history refresh failed"}`
      status.fg = theme.statusWarn
    }
  }
  if (activeSession?.id !== sessionId) {
    sendingMessage = false
    activeTurnId = undefined
    activeTurnController = undefined
    activeTurnCancelled = false
    return
  }
  sendingMessage = false
  activeTurnId = undefined
  activeTurnController = undefined
  activeTurnCancelled = false
  if (completion.status === "completed") {
    if (historyLoaded) {
      const completedStatus = statusWithUsage(completion.provider ?? "provider", completion.model ?? "assistant", completion)
      const pendingCounts = await countPendingReviews()
      status.content = statusWithPendingReviews(completedStatus, pendingCounts)
      status.fg = pendingReviewStatusColor(pendingCounts)
    }
  } else if (completion.status === "uncertain") {
    status.content = "● operation outcome uncertain · inspect the workspace before retrying"
    status.fg = theme.statusWarn
  } else if (completion.status === "cancelled") {
    status.content = userCancelled ? "● response cancelled" : "● turn cancelled"
    status.fg = theme.statusWarn
  } else {
    status.content = `● message failed  ·  ${completion.error ?? "assistant turn failed"}`
    status.fg = theme.statusError
  }
  chatInput?.focus()
}

async function cancelActiveTurn() {
  if (!activeSession || !activeTurnId || !activeTurnController || activeTurnCancelled) return
  activeTurnCancelled = true
  status.content = "● cancelling response…"
  status.fg = theme.statusWarn
  void fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/operations/${activeTurnId}/cancel`, {
    method: "POST",
  }).catch(() => undefined)
  activeTurnController.abort()
}

async function showSkills(filter = "") {
  if (!activeSession) return
  try {
    const directory = encodeURIComponent(activeSession.directory || "")
    const [catalogResponse, activeResponse] = await Promise.all([
      fetch(`${apiBase}/v1/plugins?directory=${directory}`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/skills`, { signal: controller.signal }),
    ])
    if (!catalogResponse.ok || !activeResponse.ok) throw new Error("plugin catalog is unavailable")
    const catalog = await catalogResponse.json() as PluginCatalog
    const active = await activeResponse.json() as SessionPluginSkill[]
    const enabled = new Set(active.map((item) => `${item.plugin_name}/${item.skill_name}`))
    const entries = catalog.plugins.flatMap((plugin) => plugin.skills.map((skill) => {
      const key = `${plugin.name}/${skill.name}`
      const origin = plugin.origin === "standalone" || skill.source
        ? `\n  Source: ${safeTerminalText(skill.source || plugin.name)} · ${safeTerminalText(skill.scope || "plugin")}`
        : ""
      const displayName = plugin.veasel_extension?.display_name
      const label = displayName ? `\n  Shown as: ${safeTerminalText(displayName)}` : ""
      const restriction = skill.allowed_tools_declared
        ? `\n  Tool access: ${skill.allowed_tools.length > 0 ? skill.allowed_tools.join(", ") : "none"}`
        : ""
      const haystack = `${key} ${skill.description} ${skill.source || ""} ${skill.scope || ""} ${plugin.origin || ""} ${displayName || ""}`
      return {
        haystack,
        line: `${enabled.has(key) ? "● enabled" : "○ available"}  ${key}${origin}${label}\n  ${skill.description}${restriction}`,
      }
    }))
    const matched = entries.filter((entry) => matchesCatalogFilter(entry.haystack, filter))
    const header = formatCatalogFilterHeader("AGENT SKILLS", matched.length, entries.length, filter)
    skillNotice = matched.length > 0
      ? `${header}\n${matched.map((entry) => entry.line).join("\n\n")}\n\nEnable with /skill on <source>/<skill>. Disable with /skill off <source>/<skill>. Filter with /skills <text> (all tokens must match). Standalone SKILL.md folders are discovered automatically from project and user agent skill directories. /skill on injects the body into later turns; the model can also load a discovered skill on demand with agent_skill_load without enabling it first, then read bounded text resources from that folder for the rest of the turn. Files are not executed. A declared tool list only restricts tools already available to this session; approval rules still apply.`
      : filter
        ? formatCatalogFilterEmpty("skills", safeTerminalText(filter))
        : "No skills found. Add a plugin.json package under VEASEL_PLUGIN_DIR, or place SKILL.md folders under .agents/skills, .claude/skills, .cursor/skills, and the other discovered agent skill roots."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load skills: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

type PluginLinkCatalog = {
  links: Array<{ name: string; path: string }>
  diagnostics?: Array<{ component: string; message: string }>
}

async function showPluginLinks(filter = "") {
  try {
    const response = await fetch(`${apiBase}/v1/plugins/links`, { signal: controller.signal })
    if (!response.ok) throw new Error("plugin links are unavailable")
    const catalog = await response.json() as PluginLinkCatalog
    const entries = catalog.links.map((link) => {
      const name = safeTerminalText(link.name)
      const path = safeTerminalText(link.path)
      return {
        haystack: `${link.name} ${link.path}`,
        line: `● ${name}\n  ${path}`,
      }
    })
    const matched = entries.filter((entry) => matchesCatalogFilter(entry.haystack, filter))
    const diagnostics = (catalog.diagnostics ?? [])
      .map((item) => `! ${safeTerminalText(item.component)}: ${safeTerminalText(item.message)}`)
    const header = formatCatalogFilterHeader("PLUGIN LINKS", matched.length, entries.length, filter)
    skillNotice = matched.length > 0
      ? `${header}\n${matched.map((entry) => entry.line).join("\n\n")}${diagnostics.length > 0 ? `\n\n${diagnostics.join("\n")}` : ""}\n\nAdd with /plugin add <absolute-path>. Remove with /plugin remove <name>. Filter with /plugins <text>. Only managed symlinks are removed; PLUGIN_DATA for that name is kept.`
      : filter
        ? formatCatalogFilterEmpty("plugin links", safeTerminalText(filter))
        : "No managed plugin links. Use /plugin add <absolute-path> to link a local Agent Plugin package into VEASEL_PLUGIN_DIR."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load plugin links: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function addPluginLink(path: string) {
  if (!path) {
    skillNotice = "Use /plugin add <absolute-path> with a local Agent Plugin package directory."
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/plugins/links`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path }),
      signal: controller.signal,
    })
    const body = await response.json().catch(() => ({})) as { name?: string; path?: string; error?: string }
    if (!response.ok) throw new Error(body.error || "unable to add plugin link")
    skillNotice = `Linked ${safeTerminalText(body.name || "plugin")} → ${safeTerminalText(body.path || path)}. Use /plugins to review, then /skill or /mcp as needed.`
    slashContextAt = 0
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not add plugin link: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function removePluginLink(name: string) {
  if (!name) {
    skillNotice = "Use /plugin remove <name> with a managed plugin link name from /plugins."
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/plugins/links/${encodeURIComponent(name)}`, {
      method: "DELETE",
      signal: controller.signal,
    })
    const body = await response.json().catch(() => ({})) as { removed?: string; error?: string }
    if (!response.ok) throw new Error(body.error || "unable to remove plugin link")
    skillNotice = `Removed plugin link ${safeTerminalText(body.removed || name)}. PLUGIN_DATA for that name remains on disk.`
    slashContextAt = 0
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not remove plugin link: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

type ConfiguredMcpCatalog = {
  scope?: string
  path?: string
  project_path?: string
  import_paths?: string[]
  servers: Array<{
    name: string
    scope?: string
    config_file?: string
    enabled: boolean
    transport: string
    command?: string
    args?: string[]
    cwd?: string
    url_origin?: string
    header_names?: string[]
  }>
}

function splitMcpArgs(raw: string): string[] {
  const args: string[] = []
  const matcher = /"([^"\\]*(?:\\.[^"\\]*)*)"|'([^'\\]*(?:\\.[^'\\]*)*)'|(\S+)/g
  for (const match of raw.matchAll(matcher)) {
    args.push((match[1] ?? match[2] ?? match[3] ?? "").replace(/\\(["'\\])/g, "$1"))
  }
  return args
}

async function showMcpServers(filter = "") {
  if (!activeSession) return
  try {
    const directory = encodeURIComponent(activeSession.directory || "")
    const [catalogResponse, activeResponse, configuredResponse] = await Promise.all([
      fetch(`${apiBase}/v1/plugins?directory=${directory}`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-servers`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/mcp-servers?directory=${directory}`, { signal: controller.signal }),
    ])
    if (!catalogResponse.ok || !activeResponse.ok) throw new Error("plugin catalog is unavailable")
    const catalog = await catalogResponse.json() as PluginCatalog
    const active = await activeResponse.json() as SessionPluginMCPServer[]
    const configured = configuredResponse.ok
      ? await configuredResponse.json() as ConfiguredMcpCatalog
      : { servers: [] as ConfiguredMcpCatalog["servers"] }
    const trusted = new Set(active.map((item) => `${item.plugin_name}/${item.server_name}`))
    const configuredEntries = configured.servers.map((server) => {
      const key = `configured/${server.name}`
      const scopeLabel = server.scope === "project"
        ? "project scope"
        : server.scope === "project-import"
          ? "project-import (read-only)"
          : "user scope"
      const configFile = server.config_file ? `\n  config: ${safeTerminalText(server.config_file)}` : ""
      const command = server.command
        ? `\n  command: ${safeTerminalText([server.command, ...(server.args ?? [])].join(" "))}`
        : ""
      const endpoint = server.url_origin ? `\n  endpoint: ${safeTerminalText(server.url_origin)}` : ""
      const cwd = server.cwd ? `\n  cwd: ${safeTerminalText(server.cwd)}` : ""
      const headers = server.header_names?.length
        ? `\n  configured headers: ${server.header_names.map(safeTerminalText).join(", ")}`
        : ""
      const state = !server.enabled
        ? "○ disabled"
        : trusted.has(key)
          ? "● trusted"
          : "○ available"
      const line = `${state}  ${safeTerminalText(key)} [${safeTerminalText(server.transport)}] · ${scopeLabel}${configFile}${command}${cwd}${endpoint}${headers}`
      const haystack = `${key} ${server.transport} ${scopeLabel} ${server.command || ""} ${(server.args ?? []).join(" ")} ${server.url_origin || ""} ${server.cwd || ""} ${(server.header_names ?? []).join(" ")} ${state}`
      return { haystack, line }
    })
    const pluginEntries = catalog.plugins
      .filter((plugin) => plugin.origin !== "configured")
      .flatMap((plugin) => plugin.mcp_servers.map((server) => {
        const key = `${plugin.name}/${server.name}`
        const command = server.command ? `\n  command: ${safeTerminalText(server.command)}` : ""
        const endpoint = server.url_origin ? `\n  endpoint: ${safeTerminalText(server.url_origin)}` : ""
        const headers = server.header_count
          ? `\n  configured headers: ${server.header_names.map(safeTerminalText).join(", ")}`
          : ""
        const support = ["stdio", "streamable-http"].includes(server.transport)
          ? server.transport
          : `${server.transport} (unsupported)`
        const state = trusted.has(key) ? "● trusted" : "○ available"
        const line = `${state}  ${safeTerminalText(key)} [${safeTerminalText(support)}]${command}${endpoint}${headers}`
        const haystack = `${key} ${support} ${server.command || ""} ${server.url_origin || ""} ${server.header_names.join(" ")} ${state}`
        return { haystack, line }
      }))
    const entries = [...configuredEntries, ...pluginEntries]
    const matched = entries.filter((entry) => matchesCatalogFilter(entry.haystack, filter))
    const header = formatCatalogFilterHeader("MCP SERVERS", matched.length, entries.length, filter)
    const inventory = matched.length > 0
      ? matched.map((entry) => entry.line).join("\n\n")
      : filter
        ? formatCatalogFilterEmpty("MCP servers", safeTerminalText(filter))
        : "No MCP servers yet. Add one with /mcp add stdio <name> <command> [args…] or /mcp add project http <name> <url>, or link an Agent Plugin package that includes mcp.json."
    const configPath = configured.path ? `\nUser-scope file: ${safeTerminalText(configured.path)}` : ""
    const projectPath = configured.project_path ? `\nProject-scope file: ${safeTerminalText(configured.project_path)}` : ""
    const importPaths = configured.import_paths?.length
      ? `\nImported project files: ${configured.import_paths.map(safeTerminalText).join(", ")}`
      : ""
    skillNotice = `${header}\n${inventory}${filter ? "" : `${configPath}${projectPath}${importPaths}`}\n\nFilter with /mcp <text> (all tokens must match). Add: /mcp add [user|project] stdio <name> <command> [args…] · /mcp add [user|project] http <name> <url>\nManage: /mcp enable|disable|remove [user|project] <name>\nTrust: /mcp trust configured/<name> or /mcp trust <plugin>/<server>. Precedence for the same name: project (.veasel) > project-import (.mcp.json, then .cursor/mcp.json) > user. Imports are read-only. Trust connects on the next model turn; every tool call still needs /mcp call show then approve. Stdio runs with your OS privileges. Streamable HTTP stays pinned to its origin (redirects refused). MCP inputs/results go to your model provider. No install scripts are auto-executed.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load MCP servers: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function addConfiguredMcpServer(input: {
  name: string
  transport: "stdio" | "streamable-http"
  command?: string
  args?: string[]
  url?: string
  scope?: "user" | "project"
}) {
  try {
    const scope = input.scope === "project" ? "project" : "user"
    if (scope === "project" && !activeSession?.directory) {
      throw new Error("project-scoped MCP requires an active session workspace")
    }
    const response = await fetch(`${apiBase}/v1/mcp-servers`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: input.name,
        transport: input.transport,
        command: input.command,
        args: input.args,
        url: input.url,
        enabled: true,
        scope,
        directory: scope === "project" ? activeSession?.directory : undefined,
      }),
      signal: controller.signal,
    })
    const body = await response.json().catch(() => ({})) as { name?: string; error?: string; transport?: string; scope?: string }
    if (!response.ok) throw new Error(body.error || "unable to add MCP server")
    slashContextAt = 0
    const resolvedScope = body.scope === "project" ? "project" : "user"
    skillNotice = `Added configured/${safeTerminalText(body.name || input.name)} [${safeTerminalText(body.transport || input.transport)}] (${resolvedScope} scope). Trust with /mcp trust configured/${safeTerminalText(body.name || input.name)} after reviewing the command or origin. Every tool call still needs explicit approval.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not add MCP server: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function removeConfiguredMcpServer(name: string, scope: "user" | "project" = "user") {
  try {
    if (scope === "project" && !activeSession?.directory) {
      throw new Error("project-scoped MCP requires an active session workspace")
    }
    const query = scope === "project"
      ? `?scope=project&directory=${encodeURIComponent(activeSession!.directory)}`
      : ""
    const response = await fetch(`${apiBase}/v1/mcp-servers/${encodeURIComponent(name)}${query}`, {
      method: "DELETE",
      signal: controller.signal,
    })
    const body = await response.json().catch(() => ({})) as { removed?: string; error?: string }
    if (!response.ok) throw new Error(body.error || "unable to remove MCP server")
    slashContextAt = 0
    skillNotice = `Removed ${scope}-scope configured MCP server ${safeTerminalText(body.removed || name)}. Session trust rows for configured/${safeTerminalText(name)} stop loading on the next turn when no other scope still defines it.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not remove MCP server: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function setConfiguredMcpEnabled(name: string, enabled: boolean, scope: "user" | "project" = "user") {
  try {
    if (scope === "project" && !activeSession?.directory) {
      throw new Error("project-scoped MCP requires an active session workspace")
    }
    const query = scope === "project"
      ? `?scope=project&directory=${encodeURIComponent(activeSession!.directory)}`
      : ""
    const response = await fetch(`${apiBase}/v1/mcp-servers/${encodeURIComponent(name)}${query}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled }),
      signal: controller.signal,
    })
    const body = await response.json().catch(() => ({})) as { name?: string; enabled?: boolean; error?: string }
    if (!response.ok) throw new Error(body.error || "unable to update MCP server")
    slashContextAt = 0
    skillNotice = `${enabled ? "Enabled" : "Disabled"} ${scope}-scope configured/${safeTerminalText(body.name || name)}. ${enabled ? "Trust it with /mcp trust configured/" + safeTerminalText(body.name || name) + " when ready." : "It stays on disk but will not connect until enabled again."}`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not update MCP server: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showMcpToolCalls() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const calls = await response.json() as PluginMCPToolCallSummary[]
    const lines = calls.map((call) => {
      const pending = call.status === "pending"
        ? `\n  Inspect with /mcp call show ${call.id}`
        : ""
      return `${call.status.toUpperCase()}  ${call.id}\n  ${safeTerminalReviewText(call.plugin_name)}/${safeTerminalReviewText(call.server_name)} · ${safeTerminalReviewText(call.tool_name)}\n  arguments: ${call.arguments_bytes} bytes${pending}`
    })
    skillNotice = calls.length > 0
      ? `MCP TOOL CALLS\n${lines.join("\n\n")}\n\nA pending call has not reached its MCP server. Inspect its arguments before approval.`
      : "No MCP tool calls have been recorded in this session."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load MCP tool call history: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showMcpToolCall(callId: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls/${callId}`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const call = await response.json() as PluginMCPToolCallApproval
    const args = JSON.stringify(JSON.parse(call.arguments_json) as unknown, null, 2)
    const review = formatMcpReview({
      plugin: safeTerminalReviewText(call.plugin_name),
      server: safeTerminalReviewText(call.server_name),
      tool: safeTerminalReviewText(call.tool_name),
      operationId: safeTerminalReviewText(call.operation_id),
      id: call.id,
      pending: call.status === "pending",
      argumentsText: args,
      maxLines: mcpReviewLineBudget(process.stdout.rows ?? 40),
    })
    const reviewState: ActiveReview = { kind: "mcp", id: call.id, pending: call.status === "pending" }
    setActiveReview(reviewState)
    skillNotice = withReviewHotkeyHint(
      `REVIEW MCP TOOL CALL  /  ${call.status.toUpperCase()}\n${review}`,
      reviewState,
      reviewHintOptions(),
    )
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not inspect MCP tool call: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function actOnMcpToolCall(callId: string, action: "approve" | "reject") {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls/${callId}/${action}`, {
      method: "POST",
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    skillNotice = action === "approve"
      ? `Approved MCP call ${callId}. The server call may now run; the active Veasel turn will continue when it returns.`
      : `Rejected MCP call ${callId}. The server was not called.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not ${action} MCP tool call: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function countPendingReviews(): Promise<PendingReviewCounts> {
  const counts: PendingReviewCounts = { edits: 0, commands: 0, mcp: 0 }
  const queue: ActiveReview[] = []
  if (!activeSession) {
    lastPendingCounts = counts
    pendingReviewQueue = queue
    return counts
  }
  try {
    const [editsResponse, commandsResponse, mcpResponse] = await Promise.all([
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits`, {
        signal: controller.signal,
      }),
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands`, {
        signal: controller.signal,
      }),
      fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls`, {
        signal: controller.signal,
      }),
    ])
    if (editsResponse.ok) {
      const edits = await editsResponse.json() as WorkspaceEditSummary[]
      const pending = edits.filter((edit) => edit.status === "pending")
      counts.edits = pending.length
      for (const edit of pending) queue.push({ kind: "patch", id: edit.id, pending: true })
    }
    if (commandsResponse.ok) {
      const commands = await commandsResponse.json() as ShellCommandSummary[]
      const pending = commands.filter((item) => item.status === "pending")
      counts.commands = pending.length
      for (const item of pending) queue.push({ kind: "command", id: item.id, pending: true })
    }
    if (mcpResponse.ok) {
      const calls = await mcpResponse.json() as PluginMCPToolCallSummary[]
      const pending = calls.filter((call) => call.status === "pending")
      counts.mcp = pending.length
      for (const call of pending) queue.push({ kind: "mcp", id: call.id, pending: true })
    }
  } catch {
    // Optional counts must not break the active turn.
  }
  lastPendingCounts = counts
  pendingReviewQueue = queue
  return counts
}

function setActiveReview(review: ActiveReview | undefined) {
  activeReview = review
}

function reviewHintOptions(hunkCount?: number) {
  return {
    hunkCount,
    selectedCount: selectedReviewKeys.size,
    currentSelected: activeReview ? selectedReviewKeys.has(reviewSelectionKey(activeReview)) : false,
  }
}

function refreshActiveReviewHint() {
  if (!activeReview?.pending || !skillNotice) return
  if (activeReview.kind === "patch" && activePatchDiff) {
    renderActivePatchDiff()
    return
  }
  skillNotice = withReviewHotkeyHint(skillNotice, activeReview, reviewHintOptions())
  renderChat(chatMessages)
}

async function openActiveReview(review: ActiveReview) {
  setActiveReview(review)
  if (review.kind === "patch") await showWorkspaceEdit(review.id)
  else if (review.kind === "command") await showShellCommand(review.id)
  else await showMcpToolCall(review.id)
}

function renderActivePatchDiff() {
  if (!activeReview || activeReview.kind !== "patch" || !activePatchDiff) return
  const review = formatReviewDiff(activePatchDiff, reviewDiffLineBudget(process.stdout.rows ?? 40), {
    hunkIndex: activePatchHunkIndex,
  })
  activePatchHunkIndex = review.hunkIndex
  skillNotice = withReviewHotkeyHint(
    `REVIEW WORKSPACE EDIT  /  ${activePatchStatus}\n${safeTerminalText(activePatchPath)}\n${safeTerminalText(review.text)}${activeReview.pending ? `\nAfter inspecting the diff, type /patch approve ${activeReview.id} or /patch reject ${activeReview.id}.` : ""}`,
    activeReview,
    reviewHintOptions(review.hunkCount),
  )
  renderChat(chatMessages)
}

async function actOnReviewItems(action: "approve" | "reject", items: ActiveReview[]) {
  for (const item of items) {
    if (item.kind === "patch") await actOnWorkspaceEdit(action, item.id)
    else if (item.kind === "command") await actOnShellCommand(action, item.id)
    else await actOnMcpToolCall(item.id, action)
  }
}

async function handleReviewHotkey(action: "approve" | "approveAll" | "reject" | "toggleSelect" | "next" | "prev" | "hunkNext" | "hunkPrev") {
  if (!activeReview?.pending) return
  if (action === "toggleSelect") {
    selectedReviewKeys = toggleReviewSelection(selectedReviewKeys, activeReview)
    refreshActiveReviewHint()
    return
  }
  if (action === "hunkNext" || action === "hunkPrev") {
    if (activeReview.kind !== "patch" || !activePatchDiff) return
    const probe = formatReviewDiff(activePatchDiff, reviewDiffLineBudget(process.stdout.rows ?? 40), {
      hunkIndex: activePatchHunkIndex,
    })
    activePatchHunkIndex = moveReviewHunkIndex(
      probe.hunkIndex,
      action === "hunkNext" ? 1 : -1,
      probe.hunkCount,
    )
    renderActivePatchDiff()
    return
  }
  if (action === "approveAll") {
    const kind = activeReview.kind
    if (pendingReviewQueue.length === 0) await countPendingReviews()
    const batch = pendingReviewsOfKind(pendingReviewQueue, kind)
    await actOnReviewItems("approve", batch)
    selectedReviewKeys = new Set()
    setActiveReview(undefined)
    await countPendingReviews()
    const label = kind === "patch" ? "edit" : kind === "command" ? "shell command" : "MCP call"
    skillNotice = batch.length > 0
      ? `Approved ${batch.length} pending ${label}${batch.length === 1 ? "" : "s"} of the same kind (Shift+A).`
      : `No pending ${label}s left to approve.`
    renderChat(chatMessages)
    return
  }
  if (action === "approve" || action === "reject") {
    if (pendingReviewQueue.length === 0) await countPendingReviews()
    const selected = resolveSelectedReviews(pendingReviewQueue, selectedReviewKeys)
    const batch = selected.length > 0 ? selected : [activeReview]
    await actOnReviewItems(action, batch)
    selectedReviewKeys = new Set()
    setActiveReview(undefined)
    await countPendingReviews()
    if (selected.length > 0) {
      const verb = action === "approve" ? "Approved" : "Rejected"
      skillNotice = `${verb} ${batch.length} selected review${batch.length === 1 ? "" : "s"} (Space multi-select).`
      renderChat(chatMessages)
    }
    return
  }
  if (pendingReviewQueue.length === 0) await countPendingReviews()
  if (pendingReviewQueue.length === 0) return
  const index = activeReviewIndex(pendingReviewQueue, activeReview)
  const nextIndex = moveActiveReviewIndex(index, action === "next" ? 1 : -1, pendingReviewQueue.length)
  const next = pendingReviewQueue[nextIndex]
  if (next) await openActiveReview(next)
}

async function notifyPendingMcpToolCalls() {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-tool-calls`, {
      signal: controller.signal,
    })
    if (!response.ok) return
    const calls = await response.json() as PluginMCPToolCallSummary[]
    const pending = calls.filter((call) => call.status === "pending")
    if (pending.length === 0) return
    skillNotice = `${pending.length} MCP tool call${pending.length === 1 ? "" : "s"} need review. The model turn is waiting and no pending call has reached its server. Type /mcp calls, inspect with /mcp call show <id>, then approve or reject.`
    const counts = await countPendingReviews()
    const pendingStatus = formatPendingReviewStatus(counts)
    if (pendingStatus) {
      status.content = pendingStatus
      status.fg = theme.statusWarn
    }
    chatInput?.focus()
    renderChat(chatMessages)
  } catch {
    // Keep the model turn usable if the optional approval notice cannot be loaded.
  }
}

async function showWorkspaceEdits(filter = "") {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const edits = await response.json() as WorkspaceEditSummary[]
    const entries = edits.map((edit) => {
      const commands = edit.status === "pending"
        ? `\nInspect diff: /patch show ${edit.id}`
        : ""
      const recovery = edit.status === "interrupted"
        ? "\nApplication stopped unexpectedly. Inspect the file manually; Veasel will not replay this edit."
        : ""
      return {
        haystack: `${edit.status} ${edit.path} ${edit.id}`,
        line: `${edit.status.toUpperCase()}  ${safeTerminalText(edit.path)}\n${edit.id}${commands}${recovery}`,
      }
    })
    const matched = entries.filter((entry) => matchesCatalogFilter(entry.haystack, filter))
    const header = formatCatalogFilterHeader("WORKSPACE EDIT PROPOSALS", matched.length, entries.length, filter)
    skillNotice = matched.length > 0
      ? `${header}\n${matched.map((entry) => entry.line).join("\n\n")}\n\nFilter with /patches <text> (path, status, or id tokens).`
      : filter
        ? formatCatalogFilterEmpty("edit proposals", safeTerminalText(filter))
        : "No workspace edit proposals. Ask Veasel to make a change; it will show a diff for your review before writing any file."
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load workspace edit proposals: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function notifyPendingProposals() {
  if (!activeSession) return
  try {
    const counts = await countPendingReviews()
    const notices: string[] = []
    if (counts.edits > 0) {
      notices.push(`${counts.edits} workspace edit proposal${counts.edits === 1 ? "" : "s"} need review. Type /patches to inspect them. No files have changed.`)
    }
    if (counts.commands > 0) {
      notices.push(pendingShellSandboxNotice(counts.commands))
    }
    if (counts.mcp > 0) {
      notices.push(`${counts.mcp} MCP tool call${counts.mcp === 1 ? "" : "s"} need review. Type /mcp calls, inspect with /mcp call show <id>, then approve or reject.`)
    }
    if (notices.length === 0) return
    skillNotice = notices.join("\n\n")
    const pendingStatus = formatPendingReviewStatus(counts)
    if (pendingStatus) {
      status.content = pendingStatus
      status.fg = theme.statusWarn
    }
    renderChat(chatMessages)
  } catch {
    // Keep chat usable when the optional proposal notification cannot be loaded.
  }
}

async function showWorkspaceEdit(editId: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits/${editId}`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const edit = await response.json() as WorkspaceEditProposal
    if (edit.status === "pending") reviewedEditIds.add(edit.id)
    activePatchDiff = edit.diff
    activePatchPath = edit.path
    activePatchStatus = edit.status.toUpperCase()
    activePatchHunkIndex = 0
    const reviewState: ActiveReview = { kind: "patch", id: edit.id, pending: edit.status === "pending" }
    setActiveReview(reviewState)
    renderActivePatchDiff()
  } catch (error) {
    skillNotice = `Could not load workspace edit diff: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function actOnWorkspaceEdit(action: "approve" | "reject", editId: string) {
  if (!activeSession) return
  if (!reviewedEditIds.has(editId)) {
    skillNotice = `Inspect this proposal first with /patch show ${editId}.`
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/edits/${editId}/${action}`, {
      method: "POST",
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const result = await response.json() as { status: string }
    reviewedEditIds.delete(editId)
    skillNotice = action === "approve" && result.status === "applied"
      ? `Applied the reviewed workspace edit (${editId}). Use /patches to inspect the outcome.`
      : `Rejected the workspace edit (${editId}). Use /patches to review remaining proposals.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not ${action} workspace edit: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showShellCommands(filter = "") {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands`, { signal: controller.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const commands = await response.json() as ShellCommandSummary[]
    const entries = commands.map((item) => {
      const detail = item.status === "pending"
        ? `\nInspect: /command show ${item.id}`
        : item.status === "uncertain"
          ? "\nExecution was interrupted. Inspect workspace state; Veasel will not rerun it."
          : ""
      return {
        haystack: `${item.status} ${item.id} ${item.command} ${item.cwd}`,
        line: `${item.status.toUpperCase()}  ${item.id}\n${safeTerminalText(item.command)}\nCWD: ${safeTerminalText(item.cwd)} · timeout ${item.timeout_seconds}s${detail}`,
      }
    })
    const matched = entries.filter((entry) => matchesCatalogFilter(entry.haystack, filter))
    const header = formatCatalogFilterHeader("SHELL COMMAND PROPOSALS", matched.length, entries.length, filter)
    skillNotice = matched.length > 0
      ? `${header}\n${matched.map((entry) => entry.line).join("\n\n")}\n\nFilter with /commands <text> (command, cwd, status, or id tokens).`
      : filter
        ? formatCatalogFilterEmpty("shell command proposals", safeTerminalText(filter))
        : `No shell command proposals. Veasel shows the exact command and waits for explicit approval. ${approvedShellSandboxHint()}`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not load shell command proposals: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function showShellCommand(commandId: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands/${commandId}`, { signal: controller.signal })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const item = await response.json() as ShellCommandSummary
    if (item.status === "pending") reviewedShellCommandIds.add(item.id)
    const review = formatShellReview({
      command: safeTerminalText(item.command),
      cwd: safeTerminalText(item.cwd),
      timeoutSeconds: item.timeout_seconds,
      runner: process.platform === "win32" ? "COMSPEC" : "/bin/sh",
      id: item.id,
      pending: item.status === "pending",
      output: safeTerminalText(item.output),
      maxLines: shellReviewLineBudget(process.stdout.rows ?? 40),
      sandboxCapability: shellSandboxCapability,
    })
    const reviewState: ActiveReview = { kind: "command", id: item.id, pending: item.status === "pending" }
    setActiveReview(reviewState)
    skillNotice = withReviewHotkeyHint(
      `REVIEW SHELL COMMAND  /  ${item.status.toUpperCase()}\n${review}`,
      reviewState,
      reviewHintOptions(),
    )
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not inspect shell command: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function actOnShellCommand(action: "approve" | "reject", commandId: string) {
  if (!activeSession) return
  if (!reviewedShellCommandIds.has(commandId)) {
    skillNotice = `Inspect the exact command first with /command show ${commandId}.`
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/workspace/commands/${commandId}/${action}`, { method: "POST", signal: controller.signal })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    const result = await response.json() as ShellCommandSummary
    reviewedShellCommandIds.delete(commandId)
    const output = formatBoundedBlock(safeTerminalText(result.output || "(no output)"), shellReviewLineBudget(process.stdout.rows ?? 40))
    skillNotice = action === "approve"
      ? `Command ${result.status} · exit ${result.exit_code}\n${output.text}\n\nInspect workspace effects before continuing with the agent.`
      : `Rejected shell command ${commandId}. It was not executed.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not ${action} shell command: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function setSkill(enabled: boolean, pluginName: string, skillName: string) {
  if (!activeSession) return
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/skills`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ plugin_name: pluginName, skill_name: skillName, enabled }),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    skillNotice = `${enabled ? "Enabled" : "Disabled"} ${pluginName}/${skillName} for this session. Use /skills to review active skills.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not update skill: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function setMcpServerTrust(trusted: boolean, pluginName: string, serverName: string) {
  if (!activeSession) return
  if (!serverName || serverName.length > 256) {
    skillNotice = "MCP server name must contain 1 to 256 characters."
    renderChat(chatMessages)
    return
  }
  try {
    const response = await fetch(`${apiBase}/v1/sessions/${encodeURIComponent(activeSession.id)}/mcp-servers`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ plugin_name: pluginName, server_name: serverName, trusted }),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`)
    skillNotice = trusted
      ? `Trusted ${safeTerminalText(pluginName)}/${safeTerminalText(serverName)} for this session. It connects or launches on the next model turn. Use /mcp to review the command or remote origin and revoke trust.`
      : `Revoked MCP trust for ${safeTerminalText(pluginName)}/${safeTerminalText(serverName)}. It will not start on future model turns.`
    renderChat(chatMessages)
  } catch (error) {
    skillNotice = `Could not update MCP trust: ${error instanceof Error ? error.message : "request failed"}`
    renderChat(chatMessages)
  }
}

async function consumeEvents() {
  let lastEventId = "0"
  while (!controller.signal.aborted) {
    try {
      const response = await fetch(`${apiBase}/v1/events`, {
        headers: { "Last-Event-ID": lastEventId, accept: "text/event-stream" },
        signal: controller.signal,
      })
      if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`)
      status.content = "● connected  ·  listening for activity"
      status.fg = theme.statusOk
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ""
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const blocks = buffer.split(/\r?\n\r?\n/)
        buffer = blocks.pop() ?? ""
        for (const block of blocks) {
          let refreshSessionsForEvent = false
          for (const line of block.split(/\r?\n/)) {
            if (line.startsWith("id:")) lastEventId = line.slice(3).trim()
            if (line.startsWith("event:") && line.slice(6).trim() !== "heartbeat") {
              const eventType = line.slice(6).trim()
              refreshSessionsForEvent ||= eventType !== "assistant.delta"
              status.content = `● live  ·  ${eventType}`
              if (eventType === "assistant.delta" || eventType === "plugin.mcp_tool_call_pending"
                || eventType === "session.turn_completed") {
                const data = block.split(/\r?\n/).filter((item) => item.startsWith("data:"))
                  .map((item) => item.slice(5).trimStart()).join("\n")
                try {
                  const event = JSON.parse(data) as {
                    session_id?: string
                    data?: SessionTurnCompletion & { delta?: string }
                  }
                  if (eventType === "plugin.mcp_tool_call_pending" && event.session_id === activeSession?.id) {
                    void notifyPendingMcpToolCalls()
                  } else if (eventType === "assistant.delta" && activeSession && activeTurnId) {
                    const delta = event.data?.delta
                    if (event.session_id === activeSession.id
                      && event.data?.operation_id === activeTurnId
                      && typeof delta === "string" && delta.length > 0) {
                      streamingAssistantText += delta
                      renderChat(chatMessages)
                    }
                  } else if (eventType === "session.turn_completed" && event.session_id) {
                    void finishAsyncSessionTurn(event.session_id, event.data ?? {})
                  }
                } catch {
                  // Ignore malformed event payloads; the persisted turn remains authoritative.
                }
              }
            }
          }
          if (refreshSessionsForEvent) void refreshSessions()
        }
      }
      if (!controller.signal.aborted) {
        status.content = "● reconnecting to event stream…"
        status.fg = theme.statusWarn
        await new Promise((resolve) => setTimeout(resolve, 1200))
      }
    } catch {
      if (controller.signal.aborted) return
      status.content = "● reconnecting to event stream…"
      status.fg = theme.statusWarn
      await new Promise((resolve) => setTimeout(resolve, 1200))
    }
  }
}

function beginCreate() {
  if (creating) return
  creating = true
  sessionList.content = "Name this workspace session:"
  const input = new InputRenderable(renderer, {
    id: "session-title",
    width: 48,
    placeholder: "e.g. Refactor the parser",
    ...composerStyle(),
    maxLength: 200,
  })
  titleInput = input
  sidebar.add(input)
  input.focus()
  input.on(InputRenderableEvents.ENTER, (value) => {
    const title = value.trim()
    if (!title) return
    input.blur()
    sidebar.remove(input)
    titleInput = undefined
    creating = false
    void createSession(title).catch((error) => {
      status.content = `● could not create session  ·  ${error instanceof Error ? error.message : "request failed"}`
      status.fg = theme.statusError
    })
  })
}

const settingPrompts = [
	"Choose a provider. Veasel fills in the endpoint it already knows.",
	"Custom endpoint. Enter keeps the endpoint Veasel is using. HTTPS is required except for loopback HTTP.",
	"Paste your API key. Veasel saves it for this provider on this machine.",
	"Choose a model returned by this provider, or enter an ID manually.",
	"Maximum generated tokens (0 uses the default: 4,096 tokens, or Meta's own limit for Meta; Meta counts reasoning tokens in it):",
]

function currentSettingsProvider() {
  return settingsView?.providers.find((provider) => provider.id === settingsValues.provider)
}

function currentSettingsPath() {
  return settingsPath(currentSettingsProvider(), { editEndpoint: settingsEditEndpoint, editBudget: settingsEditBudget })
}

function settingsTitle(step: number) {
  const progress = settingsProgress(currentSettingsPath(), step)
  const label = settingsMode === "connect" ? "CONNECT" : "MODEL SETTINGS"
  return `${label}  /  ${progress.index} OF ${progress.total}`
}

function knownEndpointNote() {
  if (settingsStep === 0 || settingsStep === 1 || settingsEditEndpoint) return ""
  const provider = currentSettingsProvider()
  if (!provider || !providerHasKnownEndpoint(provider)) return ""
  const host = endpointHost(settingsValues.base_url)
  return host ? `\n\nEndpoint · ${host} · Ctrl+U to change` : ""
}

function advanceSettings() {
  settingsDetourFrom = undefined
  settingsStep = adjacentSettingsStep(currentSettingsPath(), settingsStep, 1)
  showSettingsStep()
}

function finishModelChoice() {
  if (currentSettingsPath().includes(4)) {
    settingsStep = 4
    showSettingsStep()
    return
  }
  void saveModelSettings()
}

function closeSettings(message = "Settings unchanged.") {
  settingsCatalogRequestId++
  settingsCatalogController?.abort()
  settingsCatalogController = undefined
  if (settingsProviderSelect) detail.remove(settingsProviderSelect)
  if (settingsModelSelect) detail.remove(settingsModelSelect)
  if (settingsInput) detail.remove(settingsInput)
  if (settingsSecretIndicator) detail.remove(settingsSecretIndicator)
  settingsInput = undefined
  settingsSecretIndicator = undefined
  settingsProviderSelect = undefined
  settingsModelSelect = undefined
  settingsProviderQuery = ""
  settingsProviderScope = "all"
  settingsModelSearchQuery = ""
  settingsModelCatalog = undefined
  settingsModelHint = ""
  settingsManualModel = false
  settingsEditEndpoint = false
  settingsEditBudget = false
  settingsDetourFrom = undefined
  settingsValues.api_key = ""
  settingsOpen = false
  settingsMode = "models"
  sidebar.visible = true
  portraitRenderable.visible = !activeSession
  brandLabel.visible = !activeSession
  footerHint.content = homeFooterHint
  sessionDetail.content = homeDetailContent(providersConfigured)
  status.content = `● ${message}`
  status.fg = theme.statusOk
  if (!activeSession) void refreshProviderSetupHint()
  if (activeSession) {
    const session = activeSession
    chatInput = undefined
    void openSession(session).catch(() => {
      status.content = "● settings saved · unable to restore session view"
      status.fg = theme.statusWarn
    })
  }
}

function showSettingsStep(manualModel = false) {
  if (settingsProviderSelect) detail.remove(settingsProviderSelect)
  if (settingsModelSelect) detail.remove(settingsModelSelect)
  if (settingsInput) detail.remove(settingsInput)
  if (settingsSecretIndicator) detail.remove(settingsSecretIndicator)
  settingsInput = undefined
  settingsSecretIndicator = undefined
  settingsProviderSelect = undefined
  settingsModelSelect = undefined
  const active = settingsView?.active_provider ?? "openai-compatible"
  const providerInfo = settingsView?.providers.find((provider) => provider.id === settingsValues.provider)
  const prior = settingsView?.profiles[settingsValues.provider]
  const providerGuide = providerInfo?.documentation_url ? `\n\nProvider docs · ${providerInfo.documentation_url}` : ""
  const credential = settingsStep === 2
    ? credentialStepCopy({
      apiKeySaved: Boolean(prior?.api_key_saved),
      environmentKey: providerInfo?.environment_key || undefined,
    })
    : undefined
  const hint = credential?.hint ?? ""
  const stepPrompt = settingsStep === 2 && credential ? credential.prompt : settingPrompts[settingsStep]
  const providerSearchHint = settingsStep === 0
    ? `\n\n${providerPickerScopeLabel(settingsProviderScope)} providers · ${settingsProviderQuery ? `Filter: ${settingsProviderQuery}` : "search by name, model, or key"}`
    : ""
  const navigationHint = settingsStep === 0
    ? "Enter selects · Esc cancels"
    : "Enter continues · Ctrl+B goes back · Esc cancels"
  sessionDetail.content = `${settingsTitle(settingsStep)}\n\n${stepPrompt}${knownEndpointNote()}${providerSearchHint}${providerGuide}${hint}\n\n${navigationHint}`
  const modeLabel = settingsMode === "connect" ? "connect" : "provider settings"
  status.content = `● ${modeLabel} · ${settingsTitle(settingsStep).replace(/^CONNECT  \/  |^MODEL SETTINGS  \/  /, "")}`
  status.fg = theme.statusOk
  const endpointShortcut = settingsStep > 0 && !settingsEditEndpoint && providerHasKnownEndpoint(providerInfo ?? { base_url: "" })
  const budgetShortcut = settingsStep > 0 && settingsStep !== 4
  footerHint.content = settingsFooterHint(settingsStep, endpointShortcut, budgetShortcut)
  if (settingsStep === 0) {
    const catalog = settingsView?.providers ?? []
    if (catalog.length === 0) {
      appendSessionDetail("\n\nThe server did not return a provider catalog. Update or restart the Veasel server.")
      footerHint.content = "Provider catalog unavailable · Esc closes"
      return
    }
    const configuredProviders = new Set(settingsView?.configured_providers ?? [])
    const matches = filterModelProviders(catalog, settingsProviderQuery, settingsProviderScope, configuredProviders, settingsView?.profiles)
    const providers = prioritizeModelProviders(matches, active, configuredProviders)
    sessionDetail.content = `${settingsTitle(0)}  ·  ${providerPickerScopeLabel(settingsProviderScope)}  ·  ${matches.length}/${catalog.length}\n\n${settingPrompts[0]}${providerSearchHint}`
    status.content = `● ${providerPickerScopeLabel(settingsProviderScope)} ${matches.length}/${catalog.length}`
    if (providers.length === 0) {
      appendSessionDetail("\n\nNo providers match this filter. Backspace clears characters.")
      return
    }
    const activeIndex = Math.max(0, providers.findIndex((provider) => provider.id === active))
    const select = new SelectRenderable(renderer, {
      id: "model-provider-select",
      width: "100%",
      height: Math.min(10, providers.length * 2 + 1),
      options: providers.map((provider) => ({
        name: `${provider.id === active ? "●" : configuredProviders.has(provider.id) ? "◆" : "◇"}  ${provider.name}`,
        description: `${provider.id === active ? `Active${settingsView?.profiles[provider.id]?.model ? ` · ${settingsView.profiles[provider.id].model}` : ""}` : configuredProviders.has(provider.id) ? "Credential available" : provider.requires_api_key ? "Credential needed" : "No key needed"} · ${provider.description.slice(0, 52)}${provider.description.length > 52 ? "…" : ""}${provider.environment_key ? ` · ${provider.environment_key}` : ""}`,
        value: provider.id,
      })),
      selectedIndex: activeIndex,
      ...selectStyle(),
      showDescription: true,
      showScrollIndicator: true,
    })
    settingsProviderSelect = select
    detail.add(select)
    select.focus()
    select.on(SelectRenderableEvents.ITEM_SELECTED, (_index, option) => {
      const providerId = String(option.value ?? "")
      const provider = providers.find((item) => item.id === providerId)
      if (!provider) return
      if (settingsValues.provider !== provider.id) {
        settingsValues.api_key = ""
        settingsValues.clear_api_key = false
      }
      settingsValues.provider = provider.id
      const profile = settingsView?.profiles[provider.id]
      settingsValues.model = profile?.model ?? ""
      settingsValues.base_url = profile?.base_url || provider.base_url
      settingsEditEndpoint = !providerHasKnownEndpoint(provider)
      settingsValues.max_output_tokens = initialOutputTokenBudget(provider.id, profile?.max_output_tokens)
      settingsModelCatalog = undefined
      settingsModelSearchQuery = ""
      settingsModelHint = ""
      settingsManualModel = false
      advanceSettings()
    })
    return
  }
  if (settingsStep === 3 && manualModel) settingsManualModel = true
  if (settingsStep === 3 && !settingsManualModel) {
    if (settingsModelCatalog === undefined) {
      void loadProviderModels()
      return
    }
    if (settingsModelCatalog.length > 0) {
      const matches = filterModelCatalog(settingsModelCatalog, settingsModelSearchQuery)
      sessionDetail.content = `${settingsTitle(3)}\n\n${settingPrompts[3]}${knownEndpointNote()}${providerGuide}\n\nFilter  ${settingsModelSearchQuery || "type a model name or ID"}\n\nEnter selects · Ctrl+B goes back · Esc cancels`
      footerHint.content = `Models ${matches.length}/${settingsModelCatalog.length} · Enter select · Ctrl+B back · Esc cancel`
      const selectedIndex = matches.findIndex((model) => model.id === settingsValues.model)
      const options = matches.map((model) => ({
        name: safeModelCatalogText(model.name === model.id ? model.id : model.name),
        description: model.name === model.id ? "Provider model ID" : safeModelCatalogText(model.id),
        value: model.id,
      }))
      options.push({ name: "Enter a model ID manually", description: "Use a model not returned by the provider catalog", value: "__manual_model_id__" })
      const select = new SelectRenderable(renderer, {
        id: "model-id-select",
        width: "100%",
        height: Math.min(10, options.length * 2 + 1),
        options,
        selectedIndex: selectedIndex >= 0 && selectedIndex < matches.length ? selectedIndex : 0,
        ...selectStyle(),
        showDescription: true,
        showScrollIndicator: true,
      })
      settingsModelSelect = select
      detail.add(select)
      select.focus()
      select.on(SelectRenderableEvents.ITEM_SELECTED, (_index, option) => {
        if (option.value === "__manual_model_id__") {
          showSettingsStep(true)
          return
        }
        settingsValues.model = String(option.value ?? "")
        settingsModelHint = ""
        finishModelChoice()
      })
      return
    }
    appendSessionDetail(`\n\n${settingsModelHint}`)
  }
  if (settingsStep === 2) {
    settingsSecretIndicator = new TextRenderable(renderer, {
      content: "•".repeat([...settingsValues.api_key].length),
      fg: theme.brand,
    })
    detail.add(settingsSecretIndicator)
    return
  }
  if (settingsStep === 4) {
    const input = new InputRenderable(renderer, {
      id: "model-output-token-budget",
      width: 24,
      placeholder: "0, 4096, 8192…",
      ...composerStyle(),
      focusedTextColor: "#ffffff",
      maxLength: 7,
    })
    settingsInput = input
    detail.add(input)
    input.focus()
    input.on(InputRenderableEvents.ENTER, (value) => {
      const clean = value.trim()
      const budget = clean ? parseOutputTokenBudget(clean) : settingsValues.max_output_tokens
      if (budget === undefined) {
        settingsModelHint = "Use 0 or a whole number from 16 to 131072."
        showSettingsStep()
        return
      }
      settingsValues.max_output_tokens = budget
      void saveModelSettings()
    })
    appendSessionDetail(`\n\nCurrent budget: ${settingsValues.max_output_tokens === 0 ? (settingsValues.provider === "meta" ? "Meta default (field omitted)" : "default (4,096 tokens)") : `${settingsValues.max_output_tokens.toLocaleString()} tokens`}${settingsModelHint ? `\n\n${settingsModelHint}` : ""}`)
    return
  }
  const input = new InputRenderable(renderer, {
    id: `model-setting-${settingsStep}`,
    width: 58,
    placeholder: settingsStep === 3 ? "e.g. claude-sonnet-4-5 or gpt-5" : "https://api.example.com/v1",
    ...composerStyle(),
    focusedTextColor: "#ffffff",
    maxLength: 512,
  })
  settingsInput = input
  detail.add(input)
  input.focus()
  input.on(InputRenderableEvents.ENTER, (value) => {
    const clean = value.trim()
    if (settingsStep === 1) settingsValues.base_url = clean || settingsValues.base_url
    else if (settingsStep === 3) {
      settingsValues.model = clean || settingsValues.model
      if (!settingsValues.model) {
        settingsModelHint = "Enter a model ID or go back and choose a provider model."
        showSettingsStep(true)
        return
      }
      settingsModelHint = ""
      finishModelChoice()
      return
    }
    advanceSettings()
  })
}

async function loadProviderModels() {
  if (!settingsOpen) return
  settingsCatalogController?.abort()
  const requestId = ++settingsCatalogRequestId
  const requestController = new AbortController()
  settingsCatalogController = requestController
  const provider = settingsValues.provider
  const providerInfo = settingsView?.providers.find((item) => item.id === provider)
  const providerName = providerInfo?.name ?? provider
  const providerGuide = providerInfo?.documentation_url ? `\n\nProvider docs · ${providerInfo.documentation_url}` : ""
  sessionDetail.content = `${settingsTitle(3)}\n\nChecking ${providerName} and discovering models…${knownEndpointNote()}${providerGuide}\n\nCtrl+B goes back · Esc cancels`
  footerHint.content = "Discovering models · Esc cancels"
  try {
    const response = await fetch(`${apiBase}/v1/config/models`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider,
        base_url: settingsValues.base_url,
        api_key: settingsValues.clear_api_key ? "" : settingsValues.api_key,
        clear_api_key: settingsValues.clear_api_key,
      }),
      signal: requestController.signal,
    })
    if (!response.ok) {
      const body = await response.json().catch(() => ({})) as { error?: string }
      throw new Error(body.error ?? `HTTP ${response.status}`)
    }
    const catalog = await response.json() as { provider: string; models: ModelCatalogEntry[] }
    if (requestId !== settingsCatalogRequestId || !settingsOpen || settingsStep !== 3 || settingsValues.provider !== provider) return
    settingsModelCatalog = catalog.provider === provider ? catalog.models : []
    settingsModelHint = settingsModelCatalog.length === 0
      ? "The connection worked, but no model IDs were returned. Enter a model ID manually."
      : "Connected · model IDs are ready. Type to filter the list."
  } catch (error) {
    if (requestId !== settingsCatalogRequestId || !settingsOpen || settingsStep !== 3 || settingsValues.provider !== provider) return
    settingsModelCatalog = []
    settingsModelHint = `Model discovery failed: ${error instanceof Error ? error.message.replace(/\.$/, "") : "request failed"}. Enter a model ID manually.`
  }
  if (requestId !== settingsCatalogRequestId || !settingsOpen || settingsStep !== 3) return
  settingsCatalogController = undefined
  showSettingsStep()
}

async function openSettings(mode: "connect" | "models" = "models") {
  if (settingsOpen || creating || sendingMessage) return
  settingsOpen = true
  settingsMode = mode
  status.content = mode === "connect" ? "● connect" : "● provider settings"
  status.fg = theme.statusOk
  sidebar.visible = false
  portraitRenderable.visible = false
  brandLabel.visible = false
  if (chatInput) {
    detail.remove(chatInput)
    chatInput = undefined
    unmountSlashMenu()
  }
  try {
    const response = await fetch(`${apiBase}/v1/config/model`, { signal: controller.signal })
    if (!response.ok) throw new Error("settings API unavailable")
    settingsView = await response.json() as ModelSettingsView
    providersConfigured = (settingsView.configured_providers?.length ?? 0) > 0
      || Object.keys(settingsView.profiles ?? {}).length > 0
    settingsStep = 0
    settingsValues.provider = settingsView.active_provider
    settingsValues.model = ""
    settingsValues.base_url = ""
    settingsValues.api_key = ""
    settingsValues.clear_api_key = false
    settingsValues.max_output_tokens = initialOutputTokenBudget(settingsView.active_provider, settingsView.profiles[settingsView.active_provider]?.max_output_tokens)
    settingsProviderQuery = ""
    settingsProviderScope = "all"
    settingsModelCatalog = undefined
    settingsModelSearchQuery = ""
    settingsModelHint = ""
    settingsManualModel = false
    settingsEditEndpoint = false
    settingsEditBudget = false
    settingsDetourFrom = undefined
    showSettingsStep()
  } catch (error) {
    closeSettings(`could not load model settings · ${error instanceof Error ? error.message : "request failed"}`)
  }
}

async function saveModelSettings() {
  try {
    const response = await fetch(`${apiBase}/v1/config/model`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        ...settingsValues,
        api_key: settingsValues.clear_api_key ? "" : settingsValues.api_key,
      }),
      signal: controller.signal,
    })
    if (!response.ok) {
      const body = await response.json().catch(() => ({})) as { error?: string }
      throw new Error(body.error ?? "settings were rejected")
    }
    settingsValues.api_key = ""
    providersConfigured = true
    const savedMessage = settingsMode === "connect"
      ? `connected ${settingsValues.provider}`
      : `saved ${settingsValues.provider} · ${settingsValues.model}`
    closeSettings(savedMessage)
  } catch (error) {
    settingsValues.api_key = ""
    closeSettings(`could not save settings · ${error instanceof Error ? error.message : "request failed"}`)
  }
}

function mountSlashMenu() {
  unmountSlashMenu()
  slashMenu = new TextRenderable(renderer, { id: "slash-menu", content: "", visible: false, wrapMode: "none" })
  detail.add(slashMenu)
}

function unmountSlashMenu() {
  if (slashMenu) detail.remove(slashMenu)
  slashMenu = undefined
  slashMatches = []
  slashSelected = 0
  slashDismissedFor = undefined
}

function resetSlashMenu() {
  slashMatches = []
  slashSelected = 0
  slashDismissedFor = undefined
  if (slashMenu) slashMenu.visible = false
}

function resetSlashContext() {
  slashContext = {}
  slashContextAt = 0
  slashContextRequest += 1
  slashContextLoading = false
}

function updateSlashMenu(value: string) {
  if (!slashMenu) return
  if (slashDismissedFor !== undefined && value !== slashDismissedFor) slashDismissedFor = undefined
  const selectedName = slashMatches[slashSelected]?.name
  slashMatches = slashDismissedFor === undefined ? slashSuggestions(value, slashCommands, slashContext) : []
  const kept = slashMatches.findIndex((command) => command.name === selectedName)
  slashSelected = kept >= 0 ? kept : 0
  renderSlashMenu()
  previewThemeFromSlashSelection()
  if (slashContextNeeded(value) && !slashContextLoading && Date.now() - slashContextAt > 1500) {
    void refreshSlashContext(value)
  }
}

async function refreshSlashContext(typed: string) {
  if (!activeSession || slashContextLoading) return
  const requestedSessionId = activeSession.id
  const request = ++slashContextRequest
  slashContextLoading = true
  const sessionId = encodeURIComponent(requestedSessionId)
  let nextContext: SlashCompletionContext | undefined
  try {
    const [editsResponse, commandsResponse, callsResponse, pluginsResponse, serversResponse, linksResponse, configuredResponse] = await Promise.all([
      fetch(`${apiBase}/v1/sessions/${sessionId}/workspace/edits`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${sessionId}/workspace/commands`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${sessionId}/mcp-tool-calls`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/plugins`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/sessions/${sessionId}/mcp-servers`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/plugins/links`, { signal: controller.signal }),
      fetch(`${apiBase}/v1/mcp-servers?directory=${encodeURIComponent(activeSession?.directory || "")}`, { signal: controller.signal }),
    ])
    const edits = editsResponse.ok ? await editsResponse.json() as WorkspaceEditSummary[] : []
    const commands = commandsResponse.ok ? await commandsResponse.json() as ShellCommandSummary[] : []
    const calls = callsResponse.ok ? await callsResponse.json() as PluginMCPToolCallSummary[] : []
    const plugins = pluginsResponse.ok ? await pluginsResponse.json() as PluginCatalog : { plugins: [] }
    const trustedServers = serversResponse.ok ? await serversResponse.json() as SessionPluginMCPServer[] : []
    const links = linksResponse.ok ? await linksResponse.json() as PluginLinkCatalog : { links: [] }
    const configured = configuredResponse.ok
      ? await configuredResponse.json() as ConfiguredMcpCatalog
      : { servers: [] as ConfiguredMcpCatalog["servers"] }
    const trusted = new Set(trustedServers.map((server) => `${server.plugin_name}/${server.server_name}`))
    nextContext = {
      patches: edits.filter((edit) => edit.status === "pending").map((edit) => ({ value: edit.id, description: `pending · ${edit.path}` })),
      commands: commands.filter((item) => item.status === "pending").map((item) => ({ value: item.id, description: `pending · ${item.command}` })),
      mcpCalls: calls.filter((call) => call.status === "pending").map((call) => ({ value: call.id, description: `pending · ${call.plugin_name}/${call.tool_name}` })),
      skills: plugins.plugins.flatMap((plugin) => plugin.skills.map((skill) => ({ value: `${plugin.name}/${skill.name}`, description: skill.description }))),
      pluginLinks: links.links.map((link) => ({ value: link.name, description: link.path })),
      configuredMcpServers: configured.servers.map((server) => ({
        value: server.name,
        description: `${server.scope === "project" ? "project" : "user"} · ${server.enabled ? "enabled" : "disabled"} · ${server.transport}`,
      })),
      mcpServers: plugins.plugins.flatMap((plugin) => plugin.mcp_servers.map((server) => {
        const value = `${plugin.name}/${server.name}`
        return { value, description: trusted.has(value) ? `trusted · ${server.transport}` : server.transport }
      })),
    }
  } catch {
    // Subcommands still complete when the session lists cannot be loaded.
  } finally {
    if (request === slashContextRequest) slashContextLoading = false
  }
  if (request !== slashContextRequest || !slashContextApplies(requestedSessionId, activeSession?.id)) return
  if (nextContext) slashContext = nextContext
  slashContextAt = Date.now()
  if (chatInput?.value === typed) updateSlashMenu(typed)
}

function renderSlashMenu() {
  if (!slashMenu) return
  if (slashMatches.length === 0) {
    slashMenu.visible = false
    return
  }
  const { start, end } = suggestionWindow(slashSelected, slashMatches.length)
  const width = Math.max(...slashMatches.map((command) => command.name.length))
  const chunks: TextChunk[] = []
  let lastCategory = ""
  slashMatches.slice(start, end).forEach((command, offset) => {
    const selected = start + offset === slashSelected
    const category = slashCategoryLabel(command)
    if (category !== lastCategory) {
      chunks.push(fg(theme.meta)(`   ── ${category} ──\n`))
      lastCategory = category
    }
    const name = command.name.padEnd(width + 2)
    if (selected) {
      chunks.push(
        fg(theme.brand)(bold(` › ${name}`)),
        fg(theme.inputText)(command.description),
        fg(theme.meta)(command.usage ? `  ${command.usage}` : ""),
        fg(theme.meta)("\n"),
      )
    } else {
      chunks.push(fg(theme.body)(`   ${name}`), fg(theme.meta)(`${command.description}\n`))
    }
  })
  const more = slashMatches.length > end - start ? `${slashSelected + 1}/${slashMatches.length} · ` : ""
  chunks.push(fg(theme.meta)(`   ${more}Tab · ↑/↓ · Home/End · PgUp/PgDn · Enter · Esc`))
  slashMenu.content = new StyledText(chunks)
  slashMenu.visible = true
}

function setComposerValue(input: InputRenderable, value: string) {
  input.value = value
  input.cursorOffset = value.length
  updateSlashMenu(value)
}

// Returns true when the key was consumed by the slash-command menu.
function handleSlashMenuKey(key: KeyEvent, input: InputRenderable): boolean {
  const selected = slashMatches[slashSelected]
  if (!selected) return false
  const consume = () => {
    key.preventDefault()
    key.stopPropagation()
    return true
  }
  const alreadyCompleted = input.value.trim() === completeSlashCommand(selected).trim()
  // Tab completes the selection; once completed, further Tabs cycle through matches.
  if (key.name === "down" || (key.name === "tab" && !key.shift && alreadyCompleted && slashMatches.length > 1)) {
    slashSelected = moveSuggestion(slashSelected, 1, slashMatches.length)
    renderSlashMenu()
    previewThemeFromSlashSelection()
    return consume()
  }
  if (key.name === "up" || (key.name === "tab" && key.shift)) {
    slashSelected = moveSuggestion(slashSelected, -1, slashMatches.length)
    renderSlashMenu()
    previewThemeFromSlashSelection()
    return consume()
  }
  if (key.name === "home") {
    slashSelected = jumpSuggestion(slashSelected, slashMatches.length, "home")
    renderSlashMenu()
    previewThemeFromSlashSelection()
    return consume()
  }
  if (key.name === "end") {
    slashSelected = jumpSuggestion(slashSelected, slashMatches.length, "end")
    renderSlashMenu()
    previewThemeFromSlashSelection()
    return consume()
  }
  if (key.name === "pageup") {
    slashSelected = jumpSuggestion(slashSelected, slashMatches.length, "pageup")
    renderSlashMenu()
    previewThemeFromSlashSelection()
    return consume()
  }
  if (key.name === "pagedown") {
    slashSelected = jumpSuggestion(slashSelected, slashMatches.length, "pagedown")
    renderSlashMenu()
    previewThemeFromSlashSelection()
    return consume()
  }
  if (key.name === "tab") {
    setComposerValue(input, completeSlashCommand(selected))
    return consume()
  }
  if (key.name === "escape") {
    slashDismissedFor = input.value
    slashMatches = []
    renderSlashMenu()
    restoreCommittedTheme()
    return consume()
  }
  if (key.name === "return" || key.name === "kpenter") {
    const completion = completeSlashCommand(selected)
    if (!runsOnAccept(selected)) {
      setComposerValue(input, completion)
      return consume()
    }
    if (input.value.trim().replace(/\s+/g, " ") === completion) return false
    setComposerValue(input, completion)
    consume()
    input.submit()
    return true
  }
  return false
}

renderer.keyInput.on("keypress", (key) => {
  if (settingsOpen) {
    if (key.name === "escape") closeSettings()
    else if (key.ctrl && key.name === "o" && settingsStep > 0 && settingsStep !== 4) {
      key.stopPropagation()
      settingsDetourFrom = settingsStep
      settingsEditBudget = true
      settingsStep = 4
      showSettingsStep()
    }
    else if (key.ctrl && key.name === "u" && settingsStep > 0 && settingsStep !== 1) {
      key.stopPropagation()
      settingsDetourFrom = settingsStep
      settingsEditEndpoint = true
      settingsStep = 1
      showSettingsStep()
    }
    else if (key.ctrl && key.name === "b" && settingsStep > 0) {
      key.stopPropagation()
      settingsCatalogRequestId++
      settingsCatalogController?.abort()
      settingsCatalogController = undefined
      const back = settingsBackTarget(currentSettingsPath(), settingsStep, settingsDetourFrom)
      if (back.cancelDetour && settingsStep === 1) settingsEditEndpoint = false
      if (back.cancelDetour && settingsStep === 4) settingsEditBudget = false
      settingsDetourFrom = back.cancelDetour ? undefined : settingsDetourFrom
      if (back.step !== settingsStep) settingsStep = back.step
      settingsModelCatalog = undefined
      settingsModelSearchQuery = ""
      if (settingsStep < 3) settingsManualModel = false
      showSettingsStep()
    }
    else if (settingsStep === 0) {
      if (key.name === "tab") {
        key.stopPropagation()
        settingsProviderScope = moveProviderPickerScope(settingsProviderScope, key.shift ? -1 : 1)
        showSettingsStep()
      } else if (key.name === "backspace") {
        key.stopPropagation()
        settingsProviderQuery = [...settingsProviderQuery].slice(0, -1).join("")
        showSettingsStep()
      } else if (!key.ctrl && !key.meta && /^[\x20-\x7e]+$/.test(key.sequence)) {
        key.stopPropagation()
        settingsProviderQuery = (settingsProviderQuery + key.sequence).slice(0, 200)
        showSettingsStep()
      }
      return
    }
    else if (settingsStep === 3 && settingsModelSelect) {
      if (key.name === "backspace") {
        key.stopPropagation()
        settingsModelSearchQuery = [...settingsModelSearchQuery].slice(0, -1).join("")
        showSettingsStep()
      } else if (!key.ctrl && !key.meta && /^[\x20-\x7e]+$/.test(key.sequence)) {
        key.stopPropagation()
        settingsModelSearchQuery = (settingsModelSearchQuery + key.sequence).slice(0, 200)
        showSettingsStep()
      }
      return
    }
    else if (settingsStep === 2) {
      key.stopPropagation()
      if (key.name === "return" || key.name === "kpenter") {
        settingsValues.clear_api_key = settingsValues.api_key === "!clear"
        settingsModelCatalog = undefined
        settingsModelSearchQuery = ""
        advanceSettings()
      } else if (key.name === "backspace") {
        settingsValues.api_key = settingsValues.clear_api_key
          ? ""
          : [...settingsValues.api_key].slice(0, -1).join("")
        settingsValues.clear_api_key = false
        if (settingsSecretIndicator) settingsSecretIndicator.content = "•".repeat([...settingsValues.api_key].length)
      } else if (!key.ctrl && !key.meta && /^[\x20-\x7e]+$/.test(key.sequence)) {
        if (settingsValues.clear_api_key) {
          settingsValues.api_key = ""
          settingsValues.clear_api_key = false
        }
        const remaining = Math.max(0, 4096 - settingsValues.api_key.length)
        settingsValues.api_key += key.sequence.slice(0, remaining)
        if (settingsSecretIndicator) settingsSecretIndicator.content = "•".repeat([...settingsValues.api_key].length)
      }
    }
    return
  }
  if (shouldQuitOnKey(key, { creatingSession: creating, composerActive: Boolean(chatInput && activeSession) })) {
    key.stopPropagation()
    void cancelActiveTurn()
    controller.abort()
    renderer.destroy()
    return
  }
  if (creating) {
    if (key.name === "escape") {
      if (titleInput) sidebar.remove(titleInput)
      titleInput = undefined
      creating = false
      renderSessions()
    }
    return
  }
  if (chatInput && activeSession) {
    if (slashMatches.length > 0 && handleSlashMenuKey(key, chatInput)) return
    if (key.ctrl && key.name === "r") {
      const open = pendingReviewOpenCommand(lastPendingCounts)
      if (open) {
        key.preventDefault()
        key.stopPropagation()
        setComposerValue(chatInput, open)
        chatInput.submit()
        return
      }
    }
    const hotkey = reviewHotkey(key, {
      composerEmpty: chatInput.value.trim() === "",
      review: activeReview,
    })
    if (hotkey) {
      key.preventDefault()
      key.stopPropagation()
      void handleReviewHotkey(hotkey.action)
      return
    }
    if (key.name === "escape") {
      if (sendingMessage) {
        key.stopPropagation()
        void cancelActiveTurn()
        return
      }
      detail.remove(chatInput)
      chatInput = undefined
      unmountSlashMenu()
      resetSlashContext()
      activeSession = undefined
      selectedReviewKeys = new Set()
      setActiveReview(undefined)
      portraitRenderable.visible = true
      brandLabel.visible = true
      footerHint.content = homeFooterHint
      sessionDetail.content = homeDetailContent(providersConfigured)
      status.content = "● connected"
      status.fg = theme.statusOk
      void refreshProviderSetupHint()
    }
    return
  }
  if (key.name === "n") {
    key.stopPropagation()
    beginCreate()
  }
  else if (key.name === "r") void refreshSessions()
  else if (key.name === "s") void openSettings("models")
  else if (key.name === "up" || key.name === "k") {
    selected = moveSessionSelection(selected, sessions.length, "up", 1)
    renderSessions()
  } else if (key.name === "down" || key.name === "j") {
    selected = moveSessionSelection(selected, sessions.length, "down", 1)
    renderSessions()
  } else if (key.name === "home") {
    selected = moveSessionSelection(selected, sessions.length, "home", 1)
    renderSessions()
  } else if (key.name === "end") {
    selected = moveSessionSelection(selected, sessions.length, "end", 1)
    renderSessions()
  } else if (key.name === "pageup") {
    selected = moveSessionSelection(
      selected,
      sessions.length,
      "pageup",
      sessionListCapacity(process.stdout.rows ?? 40, sessions.length),
    )
    renderSessions()
  } else if (key.name === "pagedown") {
    selected = moveSessionSelection(
      selected,
      sessions.length,
      "pagedown",
      sessionListCapacity(process.stdout.rows ?? 40, sessions.length),
    )
    renderSessions()
  } else if (key.name === "return" && sessions[selected]) {
    const session = sessions[selected]
    void openSession(session).catch((error) => {
      status.content = `● unable to open session  ·  ${error instanceof Error ? error.message : "request failed"}`
      status.fg = theme.statusError
    })
  }
})

renderer.keyInput.on("paste", (event) => {
  if (!settingsOpen || settingsStep !== 2) return
  event.preventDefault()
  event.stopPropagation()
  if (settingsValues.clear_api_key) {
    settingsValues.api_key = ""
    settingsValues.clear_api_key = false
  }
  const pasted = new TextDecoder().decode(event.bytes).replace(/[\x00-\x1f\x7f-\x9f]/g, "")
  const remaining = Math.max(0, 4096 - settingsValues.api_key.length)
  settingsValues.api_key += pasted.slice(0, remaining)
  if (settingsSecretIndicator) settingsSecretIndicator.content = "•".repeat([...settingsValues.api_key].length)
})

renderer.on("destroy", () => controller.abort())
await refreshSessions()
void consumeEvents()
