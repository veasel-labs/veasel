/** @jsxImportSource @opentui/solid */
import { createEffect, createMemo, createSignal, onCleanup, onMount, Show } from "solid-js"
import type { KeyEvent } from "@opentui/core"
import { useKeyboard, useRenderer } from "@opentui/solid"
import {
  appendStreamingDelta,
  type ApiSession,
  type SessionTurnCompletion,
  type VeaselApiClient,
} from "../api-client"
import {
  formatHomeSessionStatus,
  formatBusyStatus,
  formatErrorStatus,
  formatStreamingBusyStatus,
  formatWarnStatus,
} from "../status-a11y"
import { liveStreamStatusMessage } from "../transcript-scroll"
import { homeFooterHint } from "../footer-hints"
import {
  isBuiltinThemeId,
  saveThemeId,
  themes,
} from "../themes"
import { DialogProvider, useDialog } from "./ui/dialog"
import { ToastProvider, useToast } from "./ui/toast"
import { openDialogHelp } from "./ui/dialog-help"
import { openDialogAlert } from "./ui/dialog-alert"
import { SolidComposer } from "./composer"
import { SolidTranscript, transcriptMessagesFromChatTurns, type ToolAwareMessage } from "./transcript"
import {
  cycleTranscriptVerbosity,
  transcriptVerbosityLabel,
  type TranscriptVerbosity,
} from "./transcript-verbosity"
import { LiveHome } from "./component/live-home"
import { openProviderSettingsDialog } from "./component/provider-settings-dialog"
import { openCommandPalette } from "./component/command-palette"
import { openStashDialog, type SolidStashEntry } from "./component/stash-dialog"
import { openImagePreviewDialog } from "./component/image-preview-dialog"
import { openSessionDiffDialog } from "./component/session-diff-dialog"
import { openReviewPanel } from "./component/review-panel"
import { decideSolidReviews, loadPendingSolidReviews, inspectSolidReview } from "./reviews-inventory"
import { reviewShortcut, reviewSummaryLine, type SolidReviewItem } from "./reviews"
import type { ActiveReviewKind } from "../active-review"
import { openAgentDialog } from "./component/agent-dialog"
import {
  EXECUTION_POLICY_AGENTS,
  agentPolicyLabel,
  executionPolicyForAgent,
  type ExecutionPolicyId,
} from "./agent-policy"
import { openSessionTimelineDialog } from "./component/session-timeline-dialog"
import { openMcpDialog } from "./component/mcp-dialog"
import { openSkillDialog } from "./component/skill-dialog"
import { openStatusDialog } from "./component/status-dialog"
import { openErrorDetailsDialog } from "./component/error-details-dialog"
import {
  recordLiveLastError,
  resolveLiveErrorDetails,
  type LiveLastError,
} from "./last-error"
import { openDialogThemeList } from "./component/dialog-theme-list"
import {
  catalogEntryToSolidModel,
  openModelDialog,
  type SolidModelRef,
} from "./component/model-dialog"
import { openVariantDialog } from "./component/variant-dialog"
import { openSessionListDialog } from "./component/session-list-dialog"
import { SessionRenameDialog } from "./component/session-rename-dialog"
import { openUpdateDialog } from "./component/update-dialog"
import { openHighlightsDialog } from "./component/highlights-dialog"
import { openPairDialog } from "./component/pair-dialog"
import { openShellOutputDialog } from "./component/shell-output-dialog"
import { openDialogSelect } from "./ui/dialog-select"
import { liveReleaseHighlights } from "./release-highlights"
import { shellCommandsWithOutput } from "./shell-output-live"
import { formatActiveModelLabel } from "../session-model"
import { safeModelCatalogText, type ModelProvider } from "../model-providers"
import {
  modelVariantIds,
  outputBudgetForVariant,
  variantBudgetLabel,
  variantForOutputBudget,
  type ModelVariantId,
} from "./variant-budget"
import { skillCatalogFromPlugins } from "./skills-inventory"
import { type SkillCatalogEntry } from "../skill-autocomplete"
import { SessionTabs } from "./component/session-tabs"
import { solidMcpServersFromCatalog } from "./mcp-inventory"
import { openDialogExportOptions } from "./ui/dialog-export-options"
import { openDialogExportResult } from "./ui/dialog-export-result"
import { openDialogPrompt } from "./ui/dialog-prompt"
import { openDialogConfirm } from "./ui/dialog-confirm"
import {
  formatGlobalUsageLine,
  formatSessionExport,
  formatUsageLine,
  sessionExportPath,
  writeSessionExport,
} from "./session-export"
import type { SolidMcpServer } from "./component/mcp-dialog"
import {
  clearSessionUnread,
  markSessionUnread,
  moveSessionTabIndex,
  sessionTabsFromEntries,
} from "./session-tabs"
import { buildLivePaletteCommands, nextBuiltinThemeId, paletteShortcut } from "./commands"
import { resolveLiveSlash, splitMcpArgs } from "./live-slash"
import { createAttentionNotifier } from "./attention"
import { pageMayHaveOlder, type ChatTurn } from "../chat-history"
import { formatRepositoryMapSummary } from "../repository-map"
import type { SlashArgument } from "../slash-commands"
import {
  HOME_SIDEBAR_DEFAULT,
  clampHomeSidebarWidth,
  loadHomeSidebarWidth,
  saveHomeSidebarWidth,
  stepHomeSidebarWidth,
} from "./ui/pane-layout"
import {
  loadDraftStash,
  pushDraftStash,
  removeDraftStash,
  saveDraftStash,
} from "./draft-stash"
import { loadSessionDrafts, saveSessionDrafts, upsertSessionDraft } from "./session-drafts"
import {
  addComposerAttachment,
  asciiImagePreview,
  createComposerAttachment,
  removeComposerAttachment,
  resolveAttachmentPath,
  type ComposerAttachment,
} from "./composer-attachments"

/** Solid live chrome: Open/Workspaces use session git worktree HTTP. */
const liveFooterHint = `Ctrl+X stop turn · ${homeFooterHint} · ${paletteShortcut.label} commands · Ctrl+O open · Ctrl+W worktrees`
const historyPageSize = 100
import {
  type SolidOpenProject,
  groupWorktreesByProject,
  openOpenDialog,
} from "./component/open-dialog"
import { openWorkspacesDialog } from "./component/workspaces-dialog"
import { useSolidTheme, useSolidThemeState, SolidThemeProvider } from "./theme"
import type { SolidSessionEntry } from "./component/session-list-dialog"
import {
  findSessionForDirectory,
  mapApiWorktreesToOpenCatalog,
  mapApiWorktreesToSolidWorkspaces,
  suggestedLinkedWorktreePath,
  sanitizeWorktreeName,
} from "./workspace-git"

export type LiveAppProps = {
  api: VeaselApiClient
  directory?: string
  onQuit?: () => void
}

function sessionEntry(session: ApiSession): SolidSessionEntry {
  return {
    id: session.id,
    title: session.title,
    directory: session.directory,
  }
}

function LiveAppShell(props: LiveAppProps) {
  const attention = createAttentionNotifier(useRenderer())
  const colors = useSolidTheme()
  const dialog = useDialog()
  const toast = useToast()
  const launchDirectory = () => props.directory ?? process.env.VEASEL_PROJECT_DIR ?? process.cwd()
  const [sessionDirectory, setSessionDirectory] = createSignal<string | undefined>()
  const directory = () => sessionDirectory() ?? launchDirectory()

  const [sessions, setSessions] = createSignal<SolidSessionEntry[]>([])
  const [selectedIndex, setSelectedIndex] = createSignal(0)
  const [activeSessionId, setActiveSessionId] = createSignal<string | undefined>()
  /** Session ids with background turn completions while another tab is focused. */
  const [unreadSessionIds, setUnreadSessionIds] = createSignal<Record<string, true>>({})
  // Invalidates history reads when navigating, including A -> B -> A.
  let sessionViewRevision = 0
  let historyRevision = 0
  let disposed = false
  const [messages, setMessages] = createSignal<ToolAwareMessage[]>([])
  const [lastError, setLastError] = createSignal<LiveLastError | undefined>()
  const [oldestTurnId, setOldestTurnId] = createSignal<number | undefined>()
  const [historyHasOlder, setHistoryHasOlder] = createSignal(false)
  const [status, setStatus] = createSignal(formatBusyStatus("connecting"))
  const noteError = (
    source: string,
    message: string,
    context?: string,
    title = "Request failed",
  ) => {
    setLastError((previous) =>
      recordLiveLastError(previous, {
        title,
        source,
        context,
        error: message,
      }),
    )
    setStatus(formatErrorStatus(message))
  }
  const [streaming, setStreaming] = createSignal(false)
  const [streamingText, setStreamingText] = createSignal("")
  const [sending, setSending] = createSignal(false)
  const { themeId, setThemeId } = useSolidThemeState()
  /**
   * Home keeps session-nav hotkeys (s/n/q/j/k) until `/` opens the slash bar.
   * Always-on home composer stole `s` from the standalone smoke / classic bindings.
   */
  const [composerFocused, setComposerFocused] = createSignal(false)
  const [homeComposerOpen, setHomeComposerOpen] = createSignal(false)

  const applyHistoryPage = (turns: ChatTurn[], mode: "replace" | "prepend") => {
    historyRevision++
    const mapped = transcriptMessagesFromChatTurns(turns)
    if (mode === "replace") {
      setMessages(mapped)
      setOldestTurnId(turns[0]?.id)
    } else if (turns.length > 0) {
      setMessages((prev) => [...mapped, ...prev])
      setOldestTurnId(turns[0]!.id)
    }
    setHistoryHasOlder(pageMayHaveOlder(turns, historyPageSize))
  }
  const [composerDraft, setComposerDraft] = createSignal("")
  const [restoreToken, setRestoreToken] = createSignal<{ id: string; text: string } | undefined>()
  const [stashEntries, setStashEntries] = createSignal<SolidStashEntry[]>(loadDraftStash())
  const [messageNavRequest, setMessageNavRequest] = createSignal<
    | { tick: number; direction: "next" | "prev"; userOnly?: boolean }
    | { tick: number; action: "last-user" }
    | undefined
  >(undefined)
  let messageNavTick = 0
  const requestMessageNav = (
    request:
      | { direction: "next" | "prev"; userOnly?: boolean }
      | { action: "last-user" },
  ) => {
    messageNavTick += 1
    if ("action" in request) {
      setMessageNavRequest({ tick: messageNavTick, action: request.action })
      return
    }
    setMessageNavRequest({
      tick: messageNavTick,
      direction: request.direction,
      userOnly: request.userOnly,
    })
  }
  const [verbosity, setVerbosity] = createSignal<TranscriptVerbosity>("default")
  const [thinkingToggleTick, setThinkingToggleTick] = createSignal(0)
  const terminalColumns = () => process.stdout.columns ?? 80
  const [sidebarWidth, setSidebarWidth] = createSignal(
    loadHomeSidebarWidth({}, terminalColumns()),
  )
  const [cancelling, setCancelling] = createSignal(false)
  let activeTurnSessionId: string | undefined
  const [activeTurnId, setActiveTurnId] = createSignal<string | undefined>()
  const [executionPolicy, setExecutionPolicy] = createSignal<ExecutionPolicyId>("ask")
  let turnController: AbortController | undefined
  const handledCompletions = new Set<string>()

  const commitSidebarWidth = (width: number) => {
    const next = clampHomeSidebarWidth(width, terminalColumns())
    setSidebarWidth(next)
    saveHomeSidebarWidth(next, {}, terminalColumns())
  }

  const persistStash = (entries: SolidStashEntry[]) => {
    setStashEntries(entries)
    saveDraftStash(entries)
  }

  const stashComposerDraft = () => {
    const next = pushDraftStash(stashEntries(), composerDraft())
    if (next.length === stashEntries().length) {
      toast.info("Composer is empty — nothing to stash", "Stash")
      return
    }
    persistStash(next)
    toast.success(`Stashed draft · ${next.length} saved`, "Stash")
  }

  const openLiveStash = () => {
    const entries = stashEntries()
    if (entries.length === 0) {
      toast.info("No stashed drafts yet · Ctrl+S or palette → Stash composer draft", "Stash")
      return
    }
    setComposerFocused(false)
    openStashDialog(dialog, {
      entries,
      onSelect: (entry) => {
        setRestoreToken({ id: entry.id, text: entry.text })
        setComposerDraft(entry.text)
        setComposerFocused(true)
        toast.success("Restored stash into composer", "Stash")
      },
      onDelete: (entry) => {
        persistStash(removeDraftStash(stashEntries(), entry.id))
      },
    })
  }

  const cycleTheme = () => {
    const next = nextBuiltinThemeId(themeId())
    setThemeId(next)
    saveThemeId(next)
    toast.success(`Theme · ${next}`, "Theme")
  }

  const openThemeList = () => {
    setComposerFocused(false)
    const previous = themeId()
    openDialogThemeList(dialog, {
      current: previous,
      onPreview: (id) => setThemeId(id),
      onSelect: (id) => {
        setThemeId(id)
        saveThemeId(id)
        toast.success(`Theme · ${id}`, "Theme")
      },
    })
  }

  const openRenameSession = (session?: SolidSessionEntry) => {
    const target =
      session
      ?? (inSession()
        ? sessions().find((item) => item.id === activeSessionId())
        : sessions()[selectedIndex()])
    if (!target) {
      toast.info("Select a session to rename", "Rename")
      return
    }
    setComposerFocused(false)
    dialog.replace(
      () => (
        <SessionRenameDialog
          session={target}
          onConfirm={(title) => {
            void (async () => {
              try {
                const updated = await props.api.renameSession(target.id, title)
                await refreshSessions()
                toast.success(`Renamed · ${updated.title}`, "Rename")
              } catch (error) {
                toast.info(
                  error instanceof Error ? error.message : "could not rename session",
                  "Rename",
                )
              }
            })()
          }}
        />
      ),
      { size: "medium" },
    )
  }

  const [attachments, setAttachments] = createSignal<ComposerAttachment[]>([])
  let sessionDrafts = loadSessionDrafts()
  let draftRevision = 0

  // Drafts are scoped to the session's workspace so reused session ids on
  // other servers or directories never restore each other's text.
  const draftKey = (id: string) => `${directory()}\n${id}`

  const rememberSessionDraft = () => {
    const id = activeSessionId()
    if (!id) return
    sessionDrafts = upsertSessionDraft(sessionDrafts, draftKey(id), { text: composerDraft(), attachments: [...attachments()] })
    saveSessionDrafts(sessionDrafts)
  }

  // Persist while typing (debounced) so a crash or restart keeps the draft.
  createEffect(() => {
    composerDraft()
    attachments()
    activeSessionId()
    const timer = setTimeout(rememberSessionDraft, 250)
    onCleanup(() => clearTimeout(timer))
  })

  const restoreSessionDraft = (id: string) => {
    const draft = sessionDrafts.get(draftKey(id))
    const text = draft?.text ?? ""
    setComposerDraft(text)
    setAttachments(draft?.attachments ?? [])
    setRestoreToken({ id: `session-draft-${++draftRevision}`, text })
  }

  const stageAttachmentPath = (raw: string) => {
    const resolved = resolveAttachmentPath(raw, { cwd: directory() })
    if (!resolved) {
      toast.info("Path not found · use ./project-path, an absolute path, or ~/", "Attach")
      return false
    }
    const next = createComposerAttachment(resolved)
    let staged = false
    setAttachments((current) => {
      const merged = addComposerAttachment(current, next)
      if (merged.length === current.length) toast.info("Already attached", "Attach")
      else {
        staged = true
        toast.success(`Attached · ${next.name}`, "Attach")
      }
      return merged
    })
    return staged
  }

  const openAttachPrompt = () => {
    setComposerFocused(false)
    openDialogPrompt(dialog, {
      title: "Attach file / image",
      description: "Local path staged for the next message (sent as @path).",
      placeholder: "/path/to/file.png",
      confirmLabel: "Attach",
      onConfirm: (value) => {
        stageAttachmentPath(value)
        setComposerFocused(true)
      },
      onCancel: () => setComposerFocused(true),
    })
  }

  const previewAttachment = (attachment: ComposerAttachment) => {
    setComposerFocused(false)
    openImagePreviewDialog(dialog, {
      path: attachment.path,
      alt: attachment.name,
      preview:
        attachment.kind === "image"
          ? asciiImagePreview(attachment)
          : `file · ${attachment.name}\n${attachment.path}`,
    })
  }

  const openSessionDiffs = async () => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      toast.info("Open a session first", "Diffs")
      return
    }
    setComposerFocused(false)
    try {
      const edits = await props.api.listWorkspaceEdits(sessionId)
      if (edits.length === 0) {
        toast.info("No workspace edit proposals yet", "Diffs")
        setComposerFocused(true)
        return
      }
      openSessionDiffDialog(dialog, {
        edits,
        loadDiff: (editId) => props.api.getWorkspaceEdit(sessionId, editId),
        onError: (message) => toast.info(message, "Diffs"),
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not list workspace edits",
        "Diffs",
      )
      setComposerFocused(true)
    }
  }

  const openLiveAgentPicker = () => {
    setComposerFocused(false)
    openAgentDialog(dialog, {
      agents: EXECUTION_POLICY_AGENTS,
      current: executionPolicy(),
      onSelect: (agent) => {
        const policy = executionPolicyForAgent(agent.id)
        setExecutionPolicy(policy)
        toast.success(`Agent · ${agentPolicyLabel(policy)}`, "Agents")
        setComposerFocused(true)
      },
      onCancel: () => setComposerFocused(true),
    })
  }

  const openLiveSessionList = () => {
    setComposerFocused(false)
    void (async () => {
      try {
        await refreshSessions()
        openSessionListDialog(dialog, {
          sessions: sessions(),
          activeId: activeSessionId(),
          onSelect: (session) => {
            void openSession(session)
          },
          onRename: (session, title) => {
            void (async () => {
              try {
                const updated = await props.api.renameSession(session.id, title)
                await refreshSessions()
                toast.success(`Renamed · ${updated.title}`, "Sessions")
              } catch (error) {
                toast.info(
                  error instanceof Error ? error.message : "could not rename session",
                  "Sessions",
                )
              }
            })()
          },
          onDelete: (session) => {
            void (async () => {
              try {
                await props.api.deleteSession(session.id)
                if (activeSessionId() === session.id) {
                  setActiveSessionId(undefined)
                  setMessages([])
                }
                await refreshSessions()
                toast.success(`Deleted · ${session.title}`, "Sessions")
              } catch (error) {
                toast.info(
                  error instanceof Error ? error.message : "could not delete session",
                  "Sessions",
                )
              }
            })()
          },
          onCreate: () => {
            void createSession()
          },
        })
      } catch (error) {
        toast.info(
          error instanceof Error ? error.message : "could not list sessions",
          "Sessions",
        )
        setComposerFocused(true)
      }
    })()
  }

  const openLiveUpdate = async () => {
    setComposerFocused(false)
    openUpdateDialog(dialog, { state: { type: "checking" } })
    try {
      const health = await props.api.getHealth()
      openUpdateDialog(dialog, {
        state: {
          type: "current",
          version: health.version || "unknown",
        },
        onSkip: () => setComposerFocused(true),
      })
    } catch (error) {
      openUpdateDialog(dialog, {
        state: {
          type: "current",
          version: error instanceof Error ? `unavailable · ${error.message}` : "unavailable",
        },
        onSkip: () => setComposerFocused(true),
      })
    }
  }

  const openLiveHighlights = () => {
    setComposerFocused(false)
    openHighlightsDialog(dialog, liveReleaseHighlights())
  }

  const openLivePair = () => {
    setComposerFocused(false)
    openPairDialog(dialog)
  }

  const openLiveShellOutput = async () => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      toast.info("Open a session to browse shell output", "Shell")
      return
    }
    setComposerFocused(false)
    try {
      const commands = await props.api.listWorkspaceCommands(sessionId)
      const withOutput = shellCommandsWithOutput(commands)
      if (withOutput.length === 0) {
        toast.info("No completed shell command output yet", "Shell")
        setComposerFocused(true)
        return
      }
      const openOne = (item: (typeof withOutput)[number]) => {
        openShellOutputDialog(dialog, {
          command: item.command,
          output: item.output ?? "",
          status: item.status,
          exitCode: item.exit_code,
          onClose: () => setComposerFocused(true),
        })
      }
      if (withOutput.length === 1) {
        openOne(withOutput[0]!)
        return
      }
      openDialogSelect(dialog, {
        title: "Shell output",
        placeholder: "Filter commands…",
        options: withOutput.map((item) => ({
          title: item.command.split("\n")[0] ?? item.command,
          value: item.id,
          description: `${item.status}${item.exit_code !== undefined ? ` · ${item.exit_code}` : ""}`,
          searchText: `${item.command} ${item.status} ${item.id}`,
        })),
        onSelect: (option) => {
          const item = withOutput.find((entry) => entry.id === option.value)
          if (item) openOne(item)
          else setComposerFocused(true)
        },
        onCancel: () => setComposerFocused(true),
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not list shell commands",
        "Shell",
      )
      setComposerFocused(true)
    }
  }

  const openLiveReviews = async (target?: { kind: ActiveReviewKind; id: string }) => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      toast.info("Open a session to review pending proposals", "Reviews")
      return
    }
    setComposerFocused(false)
    try {
      const reviews = await loadPendingSolidReviews(props.api, sessionId)
      if (sessionId !== activeSessionId()) return
      if (reviews.length === 0) {
        openDialogAlert(dialog, {
          title: "Reviews",
          message: "No pending edits, shell commands, or MCP calls.",
          onConfirm: () => setComposerFocused(true),
        })
        return
      }
      const targetIndex = target
        ? reviews.findIndex((item) => item.kind === target.kind && item.id === target.id)
        : 0
      if (target && targetIndex < 0) {
        toast.info(`Review ${target.kind}:${target.id.slice(0, 8)} is no longer pending`, "Reviews")
        setComposerFocused(true)
        return
      }
      openReviewPanel(dialog, {
        reviews,
        initialIndex: Math.max(0, targetIndex),
        onClose: () => setComposerFocused(true),
        onInspect: (target) => inspectSolidReview(props.api, sessionId, target),
        onDecide: async (decision, targets) => {
          const result = await decideSolidReviews(props.api, sessionId, decision, targets)
          const verb = decision === "approve" ? "Approved" : "Rejected"
          if (result.settled.length > 0) {
            toast.success(
              `${verb} ${result.settled.length} review${result.settled.length === 1 ? "" : "s"}`,
              "Reviews",
            )
          }
          if (result.failed.length > 0) {
            toast.info(result.failed[0]!, "Reviews")
          }
          return result
        },
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not load pending reviews",
        "Reviews",
      )
      setComposerFocused(true)
    }
  }

  const inSession = createMemo(() => Boolean(activeSessionId()))
  const composerVisible = createMemo(() => inSession() || homeComposerOpen())
  const sessionTitle = createMemo(() => {
    const id = activeSessionId()
    return sessions().find((item) => item.id === id)?.title ?? "Session"
  })

  const openSessionTimeline = () => {
    if (!inSession()) {
      toast.info("Open a session to browse the timeline", "Timeline")
      return
    }
    setComposerFocused(false)
    openSessionTimelineDialog(dialog, {
      messages: messages(),
      onRestore: (entry) => {
        setRestoreToken({ id: `timeline-${entry.id}-${Date.now()}`, text: entry.content })
        toast.success(`Restored turn ${entry.turn}`, "Timeline")
      },
    })
  }

  const openLiveStatus = async () => {
    setComposerFocused(false)
    let provider: string | undefined
    let model: string | undefined
    let usageLine: string | undefined
    let mcpServers: SolidMcpServer[] = []
    try {
      const settings = await props.api.getModelSettings()
      provider = settings.active_provider
      const profile = settings.profiles[settings.active_provider]
      model = profile?.model
      if (profile) {
        usageLine = `max out ${profile.max_output_tokens} · key ${profile.api_key_saved ? "saved" : "missing"}`
      }
    } catch {
      // Status still useful without model settings.
    }
    const sessionId = activeSessionId()
    if (sessionId) {
      try {
        const usage = await props.api.getSessionUsage(sessionId)
        const fromUsage = formatUsageLine(usage)
        if (fromUsage) usageLine = fromUsage
      } catch {
        // Keep model settings fallback line.
      }
      try {
        const trusted = await props.api.listSessionMcpServers(sessionId)
        mcpServers = trusted.map((server) => ({
          name: `${server.plugin_name}/${server.server_name}`,
          transport: "plugin",
          status: "trusted" as const,
          scope: "session",
        }))
      } catch {
        mcpServers = []
      }
    }
    try {
      const globalLine = formatGlobalUsageLine(await props.api.getUsage())
      if (globalLine) usageLine = usageLine ? `${usageLine} · ${globalLine}` : globalLine
    } catch {
      // Global usage is additive; model/session status still stands on its own.
    }
    openStatusDialog(dialog, {
      sessionTitle: inSession() ? sessionTitle() : "Home",
      directory: directory(),
      provider,
      model,
      usageLine,
      connection: "LOCAL · loopback",
      mcpServers,
    })
  }

  const [composerSkills, setComposerSkills] = createSignal<SkillCatalogEntry[]>([])
  const [skillCatalogStatus, setSkillCatalogStatus] = createSignal<string>()
  const [mcpArgumentServers, setMcpArgumentServers] = createSignal<SlashArgument[]>([])
  const [configuredMcpArguments, setConfiguredMcpArguments] = createSignal<SlashArgument[]>([])
  const [reviewArgumentItems, setReviewArgumentItems] = createSignal<SolidReviewItem[]>([])
  const [pluginLinkArguments, setPluginLinkArguments] = createSignal<SlashArgument[]>([])
  const wantsSkillSuggestions = createMemo(() => {
    const draft = composerDraft()
    return /(^|\s)\$/.test(draft) || /^\/skill\s+(?:on|off|run)\s+/.test(draft)
  })
  const mcpTrustCompletionAction = createMemo(() => {
    const match = /^\/mcp\s+(trust|untrust)\s+/i.exec(composerDraft())
    const action = match?.[1]?.toLowerCase()
    return action === "trust" || action === "untrust" ? action : undefined
  })
  const configuredMcpCompletionScope = createMemo(() => {
    const match = /^\/mcp\s+(?:remove|enable|disable)(?:\s+(user|project))?\s+/i.exec(composerDraft())
    if (!match) return undefined
    return match[1]?.toLowerCase() === "project" ? "project" : "user"
  })
  const reviewCompletionKind = createMemo(() => {
    const draft = composerDraft()
    if (/^\/patch\s+(?:show|approve|reject)\s+/i.test(draft)) return "patch"
    if (/^\/command\s+(?:show|approve|reject)\s+/i.test(draft)) return "command"
    if (/^\/mcp\s+call\s+(?:show|approve|reject)\s+/i.test(draft)) return "mcp"
    return undefined
  })
  const wantsPluginRemovalSuggestions = createMemo(() =>
    /^\/plugin\s+remove\s+/i.test(composerDraft()),
  )
  const skillDirectory = createMemo(() =>
    sessions().find((session) => session.id === activeSessionId())?.directory ?? directory(),
  )
  createEffect(() => {
    const root = skillDirectory()
    const sessionId = activeSessionId()
    const wanted = wantsSkillSuggestions()
    setComposerSkills([])
    setSkillCatalogStatus(undefined)
    if (!wanted) return
    let current = true
    onCleanup(() => { current = false })
    setSkillCatalogStatus("Loading workspace Skills…")
    void props.api.listPlugins(root).then((catalog) => {
      if (!current || sessionId !== activeSessionId()) return
      const entries = skillCatalogFromPlugins(catalog)
      setComposerSkills(entries)
      setSkillCatalogStatus(entries.length ? undefined : "No workspace Skills · /plugins to add one")
    }).catch(() => {
      if (!current) return
      setSkillCatalogStatus("Skills unavailable · use /skills to retry")
    })
  })
  createEffect(() => {
    const scope = configuredMcpCompletionScope()
    const root = directory()
    const sessionId = activeSessionId()
    setConfiguredMcpArguments([])
    if (!scope) return
    let current = true
    onCleanup(() => { current = false })
    void props.api.listConfiguredMcpServers(root).then((catalog) => {
      if (!current || sessionId !== activeSessionId() || root !== directory()) return
      setConfiguredMcpArguments(catalog.servers
        .filter((server) => server.scope === scope)
        .map((server) => ({
          value: server.name,
          description: `${server.scope} · ${server.enabled ? "enabled" : "disabled"} · ${server.transport}`,
        })))
    }).catch(() => {
      if (current) setConfiguredMcpArguments([])
    })
  })
  createEffect(() => {
    const sessionId = activeSessionId()
    const root = directory()
    const action = mcpTrustCompletionAction()
    setMcpArgumentServers([])
    if (!action || !sessionId) return
    let current = true
    onCleanup(() => { current = false })
    void Promise.all([
      props.api.listConfiguredMcpServers(root),
      props.api.listSessionMcpServers(sessionId),
    ]).then(([configured, trusted]) => {
      if (!current || sessionId !== activeSessionId()) return
      const rows = solidMcpServersFromCatalog(configured, trusted)
      const eligible = rows.filter((server) =>
        action === "untrust"
          ? server.status === "trusted"
          : server.status === "available",
      )
      setMcpArgumentServers(
        eligible.map((server) => ({
          value: server.name,
          description: `${server.transport} · ${server.status}`,
        })),
      )
    }).catch(() => {
      if (current) setMcpArgumentServers([])
    })
  })
  createEffect(() => {
    const sessionId = activeSessionId()
    const kind = reviewCompletionKind()
    setReviewArgumentItems([])
    if (!kind || !sessionId) return
    let current = true
    onCleanup(() => { current = false })
    void loadPendingSolidReviews(props.api, sessionId).then((items) => {
      if (!current || sessionId !== activeSessionId()) return
      setReviewArgumentItems(items)
    }).catch(() => {
      if (current) setReviewArgumentItems([])
    })
  })
  createEffect(() => {
    const wanted = wantsPluginRemovalSuggestions()
    setPluginLinkArguments([])
    if (!wanted) return
    let current = true
    onCleanup(() => { current = false })
    void props.api.listPluginLinks().then((catalog) => {
      if (!current) return
      setPluginLinkArguments(catalog.links.map((link) => ({
        value: link.name,
        description: link.path,
      })))
    }).catch(() => {
      if (current) setPluginLinkArguments([])
    })
  })

  const openLiveSkills = async (filter = "") => {
    setComposerFocused(false)
    const sessionId = activeSessionId()
    try {
      const [catalog, enabled] = await Promise.all([
        props.api.listPlugins(skillDirectory()),
        sessionId
          ? props.api.listSessionSkills(sessionId)
          : Promise.resolve([] as Awaited<ReturnType<typeof props.api.listSessionSkills>>),
      ])
      const entries = skillCatalogFromPlugins(catalog, enabled)
      const needle = filter.trim().toLowerCase()
      const skills = entries.filter((skill) => {
        if (!needle) return true
        const haystack = `${skill.key} ${skill.description}`.toLowerCase()
        return needle.split(/\s+/).every((token) => haystack.includes(token))
      })
      if (skills.length === 0) {
        openDialogAlert(dialog, {
          title: "Skills",
          message: needle
            ? `No skills match “${filter.trim()}”. Link a plugin with /plugins, then retry.`
            : "No skills discovered for this workspace. Link an Agent Plugin package (/plugins) or open a session with skills enabled.",
          onConfirm: () => setComposerFocused(true),
        })
        return
      }
      openSkillDialog(dialog, {
        skills,
        onSelect: (skill) => {
          const token = `$${skill.key}`
          const current = composerDraft().trimEnd()
          const next = current ? `${current} ${token}` : token
          setRestoreToken({ id: `skill-${skill.key}-${Date.now()}`, text: next })
          setComposerFocused(true)
          toast.success(`Inserted ${token}`, "Skills")
        },
      })
    } catch (error) {
      openDialogAlert(dialog, {
        title: "Skills",
        message: error instanceof Error ? error.message : "could not list skills",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const openLiveMcp = async (filter = "") => {
    setComposerFocused(false)
    const sessionId = activeSessionId()
    try {
      const [configured, trusted] = await Promise.all([
        props.api.listConfiguredMcpServers(directory()),
        sessionId
          ? props.api.listSessionMcpServers(sessionId)
          : Promise.resolve([] as Awaited<ReturnType<typeof props.api.listSessionMcpServers>>),
      ])
      const needle = filter.trim().toLowerCase()
      const servers = solidMcpServersFromCatalog(configured, trusted).filter((server) => {
        if (!needle) return true
        const haystack = `${server.name} ${server.transport} ${server.status} ${server.scope ?? ""}`.toLowerCase()
        return needle.split(/\s+/).every((token) => haystack.includes(token))
      })
      if (servers.length === 0) {
        openDialogAlert(dialog, {
          title: "MCP",
          message: needle
            ? `No MCP servers match “${filter.trim()}”.`
            : "No configured or trusted MCP servers yet. Add with /mcp add [user|project] stdio|http … or configure ~/.config/veasel, then review and /mcp trust.",
          onConfirm: () => setComposerFocused(true),
        })
        return
      }
      openMcpDialog(dialog, {
        servers,
        onSelect: (server) => {
          const configuredScope = server.scope === "user" || server.scope === "project"
          const trusted = server.status === "trusted" || server.status === "connected"
          const options = [
            ...(server.status === "disabled" ? [] : [{ title: trusted ? "Revoke session trust" : "Trust for this session", value: trusted ? "untrust" : "trust", description: "MCP calls still require per-call review" }]),
            ...(configuredScope ? [
              { title: server.status === "disabled" ? "Enable server" : "Disable server", value: server.status === "disabled" ? "enable" : "disable", description: `${server.scope} configuration` },
              { title: "Remove server…", value: "remove", description: `${server.scope} configuration · confirmation required` },
            ] : []),
          ]
          if (options.length === 0) {
            toast.info(`${server.status} · ${server.name}`, "MCP")
            setComposerFocused(true)
            return
          }
          openDialogSelect(dialog, {
            title: `MCP · ${server.name}`,
            options,
            dismissOnSelect: false,
            onCancel: () => setComposerFocused(true),
            onSelect: (option) => {
              dialog.clear()
              if (option.value === "trust" || option.value === "untrust") {
                void runLiveMcpTrustAction(option.value === "trust", server.name)
              } else if (option.value === "enable" || option.value === "disable" || option.value === "remove") {
                void runLiveMcpConfigure(option.value, server.scope as "user" | "project", server.name.slice("configured/".length))
              }
            },
            footer: "Trust permits connection only · review each tool call",
          })
        },
      })
    } catch (error) {
      openDialogAlert(dialog, {
        title: "MCP",
        message: error instanceof Error ? error.message : "could not list MCP servers",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const openLivePlugins = async (filter = "") => {
    setComposerFocused(false)
    try {
      const catalog = await props.api.listPluginLinks()
      const needle = filter.trim().toLowerCase()
      const links = catalog.links.filter((link) => {
        if (!needle) return true
        const haystack = `${link.name} ${link.path} ${link.display_name ?? ""} ${link.description ?? ""}`.toLowerCase()
        return needle.split(/\s+/).every((token) => haystack.includes(token))
      })
      if (links.length === 0) {
        openDialogAlert(dialog, {
          title: "Plugins",
          message: needle
            ? `No plugin links match “${filter.trim()}”.`
            : "No managed plugin links. Use /plugin add [--replace] <absolute-path> (headless) to link a local Agent Plugin package.",
          onConfirm: () => setComposerFocused(true),
        })
        return
      }
      openDialogSelect(dialog, {
        title: "Plugin links",
        placeholder: "Filter plugins…",
        options: links.map((link) => ({
          title: link.display_name?.trim() || link.name,
          value: link.name,
          description: link.path,
          searchText: `${link.name} ${link.path} ${link.display_name ?? ""} ${link.description ?? ""}`,
        })),
        onSelect: (option) => {
          toast.info(`Linked · ${option.value}`, "Plugins")
          setComposerFocused(true)
        },
        onCancel: () => setComposerFocused(true),
        footer: "Enter selects · /plugin add|remove stays headless for now",
      })
    } catch (error) {
      openDialogAlert(dialog, {
        title: "Plugins",
        message: error instanceof Error ? error.message : "could not list plugin links",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const requestPluginRemoval = async (name: string) => {
    setComposerFocused(false)
    try {
      const catalog = await props.api.listPluginLinks()
      const link = catalog.links.find((item) => item.name === name)
      if (!link) {
        toast.info(`Plugin link ${name} is no longer managed`, "Plugins")
        setComposerFocused(true)
        return
      }
      openDialogConfirm(dialog, {
        title: "Remove plugin link?",
        message: `Remove ${link.name} from Veasel's managed plugins? This removes only its managed symlink and registry entry; package files remain untouched.\n${link.path}`,
        label: { confirm: "Remove link", cancel: "Keep link" },
        onClose: () => setComposerFocused(true),
        onConfirm: () => {
          void props.api.removePluginLink(link.name).then(() => {
            toast.success(`Removed plugin link · ${link.name}`, "Plugins")
          }).catch((error) => {
            openDialogAlert(dialog, {
              title: "Plugin removal failed",
              message: error instanceof Error ? error.message : "could not remove plugin link",
              onConfirm: () => setComposerFocused(true),
            })
          }).finally(() => setComposerFocused(true))
        },
      })
    } catch (error) {
      openDialogAlert(dialog, {
        title: "Plugin removal failed",
        message: error instanceof Error ? error.message : "could not load plugin link",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const requestPluginAdd = (rawPath?: string, replace = false) => {
    const path = rawPath?.trim()
    if (!path) {
      setComposerFocused(false)
      openDialogPrompt(dialog, {
        title: "Add local Agent Plugin",
        description: "Choose an absolute path to an existing package directory. Veasel links it without copying or downloading files.",
        placeholder: "/absolute/path/to/plugin",
        confirmLabel: "Validate and link",
        onConfirm: (value) => queueMicrotask(() => requestPluginAdd(value, replace)),
        onCancel: () => setComposerFocused(true),
      })
      return
    }

    const add = () => {
      void props.api.addPluginLink(path, replace).then((link) => {
        toast.success(`Linked plugin · ${link.name}`, "Plugins")
      }).catch((error) => {
        openDialogAlert(dialog, {
          title: "Plugin link failed",
          message: error instanceof Error ? error.message : "could not link plugin package",
          onConfirm: () => setComposerFocused(true),
        })
      }).finally(() => setComposerFocused(true))
    }

    if (!replace) {
      add()
      return
    }
    setComposerFocused(false)
    openDialogConfirm(dialog, {
      title: "Replace plugin link?",
      message: `The validated package at this path may replace an existing managed link. Existing package files are not deleted.\n${path}`,
      label: { confirm: "Replace link", cancel: "Keep current link" },
      onClose: () => setComposerFocused(true),
      onConfirm: add,
    })
  }

  const openLiveMap = async (hint = "") => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      openDialogAlert(dialog, {
        title: "Repository map",
        message: "Open a session first, then run /map [hint].",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    setComposerFocused(false)
    try {
      const map = await props.api.getWorkspaceMap(sessionId, hint)
      openDialogAlert(dialog, {
        title: "Repository map",
        message: formatRepositoryMapSummary(map, hint),
        onConfirm: () => setComposerFocused(true),
      })
      setStatus(
        `● repository map  ·  ${map.bytes} B · ${map.file_count} files · ${map.symbol_count} symbols${map.truncated ? " · truncated" : ""}`,
      )
    } catch (error) {
      openDialogAlert(dialog, {
        title: "Repository map",
        message: error instanceof Error ? error.message : "repository map unavailable",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const loadOlderHistory = async () => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      openDialogAlert(dialog, {
        title: "History",
        message: "Open a session first, then run /history older.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const before = oldestTurnId()
    if (!historyHasOlder() || before === undefined) {
      toast.info("No earlier chat messages", "History")
      return
    }
    const viewRevision = sessionViewRevision
    const pageRevision = historyRevision
    const isCurrent = () => !disposed
      && viewRevision === sessionViewRevision
      && pageRevision === historyRevision
    setStatus(formatBusyStatus("loading earlier messages…"))
    try {
      const older = await props.api.listMessages(sessionId, {
        before,
        limit: historyPageSize,
      })
      if (!isCurrent()) return
      applyHistoryPage(older, "prepend")
      toast.success(
        older.length > 0
          ? `Loaded ${older.length} earlier message${older.length === 1 ? "" : "s"}`
          : "No earlier chat messages",
        "History",
      )
      setStatus("● connected  ·  listening for activity")
    } catch (error) {
      if (!isCurrent()) return
      setStatus(
        formatErrorStatus(
          `history load failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
      )
    }
  }

  const openLiveExport = () => {
    if (!inSession()) {
      toast.info("Open a session to export", "Export")
      return
    }
    setComposerFocused(false)
    openDialogExportOptions(dialog, {
      defaultThinking: true,
      onConfirm: async (options) => {
        const body = formatSessionExport(
          messages(),
          {
            title: sessionTitle(),
            directory: directory(),
            sessionId: activeSessionId(),
          },
          {
            format: options.format,
            tools: options.tools,
            thinking: options.thinking,
            sanitize: options.sanitize,
          },
        )
        if (options.action === "copy") {
          const clipboard = globalThis.navigator?.clipboard
          if (clipboard?.writeText) {
            try {
              await clipboard.writeText(body)
              dialog.clear()
              toast.success(`Copied · ${options.format} (${body.length} chars)`, "Export")
              return
            } catch {
              // Fall through to file export hint.
            }
          }
          dialog.clear()
          toast.info("Clipboard unavailable — use Export to file", "Export")
          return
        }
        const path = sessionExportPath(options.format)
        try {
          writeSessionExport(path, body)
          openDialogExportResult(dialog, { path })
        } catch (error) {
          dialog.clear()
          toast.info(
            error instanceof Error ? error.message : "could not write export",
            "Export",
          )
        }
      },
    })
  }

  const refreshSessions = async () => {
    try {
      const listed = await props.api.listSessions()
      setSessions(listed.map(sessionEntry))
      setSelectedIndex((index) => Math.min(index, Math.max(0, listed.length - 1)))
      if (!activeSessionId()) {
        setStatus(formatHomeSessionStatus(selectedIndex(), listed.length))
      }
    } catch (error) {
      noteError(
        "sessions.list",
        `server unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`,
        directory(),
        "Session list failed",
      )
    }
  }

  const openSession = async (session: SolidSessionEntry) => {
    rememberSessionDraft()
    setSessionDirectory(session.directory)
    const viewRevision = ++sessionViewRevision
    setActiveSessionId(session.id)
    restoreSessionDraft(session.id)
    setUnreadSessionIds((current) => clearSessionUnread(current, session.id))
    setMessages([])
    setOldestTurnId(undefined)
    setHistoryHasOlder(false)
    setStreamingText("")
    setStreaming(false)
    setHomeComposerOpen(false)
    setComposerFocused(true)
    try {
      const turns = await props.api.listMessages(session.id, { limit: historyPageSize })
      if (disposed || viewRevision !== sessionViewRevision) return
      applyHistoryPage(turns, "replace")
      setStatus("● connected  ·  listening for activity")
    } catch (error) {
      if (disposed || viewRevision !== sessionViewRevision) return
      noteError(
        "sessions.open",
        `could not open session  ·  ${error instanceof Error ? error.message : "request failed"}`,
        session.id,
        "Open session failed",
      )
    }
  }

  const createSession = async () => {
    try {
      const created = await props.api.createSession("New session", directory())
      await refreshSessions()
      await openSession(sessionEntry(created))
      toast.success(`Created · ${created.title}`, "Session")
    } catch (error) {
      noteError(
        "sessions.create",
        `could not create session  ·  ${error instanceof Error ? error.message : "request failed"}`,
        directory(),
        "Create session failed",
      )
    }
  }

  const forkCurrentSession = async () => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      toast.info("Open a session first, then /fork it", "Session")
      return
    }
    try {
      const forked = await props.api.forkSession(sessionId)
      await refreshSessions()
      await openSession(sessionEntry(forked))
      toast.success(`Forked · ${forked.title}`, "Session")
    } catch (error) {
      noteError(
        "sessions.fork",
        `could not fork session  ·  ${error instanceof Error ? error.message : "request failed"}`,
        sessionId,
        "Fork session failed",
      )
    }
  }

  const finishTurn = async (sessionId: string, completion: SessionTurnCompletion) => {
    const operationId = completion.operation_id
    if (!operationId || handledCompletions.has(operationId)) return
    handledCompletions.add(operationId)
    if (handledCompletions.size > 128) {
      const oldest = handledCompletions.values().next().value
      if (oldest) handledCompletions.delete(oldest)
    }
    const viewRevision = sessionViewRevision
    const focused = activeSessionId() === sessionId
    if (!focused) {
      setUnreadSessionIds((current) => markSessionUnread(current, sessionId, activeSessionId()))
      if (activeTurnId() !== operationId) return
    }
    try {
      const latest = await props.api.listMessages(sessionId, { limit: historyPageSize })
      if (!disposed && viewRevision === sessionViewRevision && activeSessionId() === sessionId) {
        applyHistoryPage(latest, "replace")
      }
    } catch {
      // History reload is best-effort; reopen still works.
    }
    if (activeTurnId() === operationId) {
      setActiveTurnId(undefined)
      activeTurnSessionId = undefined
      setCancelling(false)
      turnController = undefined
      setSending(false)
      setStreaming(false)
      setStreamingText("")
      if (activeSessionId() === sessionId) {
        if (completion.status === "completed") {
          setStatus("● connected  ·  listening for activity")
        } else if (completion.status === "cancelled") {
          setStatus(formatWarnStatus("Turn cancelled"))
        } else if (completion.status === "uncertain") {
          setStatus(formatWarnStatus("Outcome uncertain; inspect the workspace before retrying"))
        } else {
          noteError("turns.complete", completion.error ?? "Assistant turn failed", sessionId)
        }
        setComposerFocused(true)
      }
      attention.notifyTurnFinished(
        completion.status ?? "",
        sessions().find((session) => session.id === sessionId)?.title,
      )
    }
  }

  const cancelActiveTurn = async () => {
    const operationId = activeTurnId()
    const sessionId = activeTurnSessionId
    if (!operationId || !sessionId) {
      toast.info("No active turn to stop", "Turn")
      return
    }
    if (cancelling()) return
    setCancelling(true)
    setStatus(formatBusyStatus("Requesting cancellation…"))
    try {
      const result = await props.api.cancelOperation(sessionId, operationId)
      if (activeTurnId() !== operationId) return
      if (["completed", "failed", "cancelled", "uncertain"].includes(result.status ?? "")) {
        await finishTurn(sessionId, result)
      } else {
        setStatus(formatBusyStatus("Cancellation requested; waiting for the server…"))
      }
    } catch (error) {
      if (activeTurnId() !== operationId) return
      setCancelling(false)
      noteError("turns.cancel", error instanceof Error ? error.message : "Cancellation failed", sessionId)
    }
  }

  const dismissHomeComposer = () => {
    if (homeComposerOpen()) setHomeComposerOpen(false)
  }

  const runLiveSkillAction = async (action: "on" | "off" | "run", key?: string) => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      openDialogAlert(dialog, {
        title: "Session required",
        message: "Open a session before enabling or invoking a Skill.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    if (!key) {
      openDialogAlert(dialog, {
        title: "Skill name required",
        message: `Use /skill ${action} <source>/<skill>. Open /skills to browse available Skills.`,
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const separator = key.indexOf("/")
    if (separator <= 0 || separator === key.length - 1) {
      openDialogAlert(dialog, {
        title: "Invalid Skill name",
        message: "Use the source/skill key shown by /skills, for example /skill run local-kit/review.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const pluginName = key.slice(0, separator)
    const skillName = key.slice(separator + 1)
    try {
      if (action === "run") {
        await props.api.invokeSessionSkill(sessionId, pluginName, skillName)
        toast.success(`Queued ${pluginName}/${skillName} for the next turn`, "Skill")
      } else {
        await props.api.setSessionSkill(sessionId, pluginName, skillName, action === "on")
        toast.success(`${action === "on" ? "Enabled" : "Disabled"} ${pluginName}/${skillName} for this session`, "Skill")
      }
      setComposerFocused(true)
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Could not update Skill", "Skill")
      setComposerFocused(true)
    }
  }

  const runLiveMcpTrustAction = async (trusted: boolean, key?: string) => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      openDialogAlert(dialog, {
        title: "Session required",
        message: "Open a session before trusting an MCP server.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    if (!key) {
      openDialogAlert(dialog, {
        title: "MCP server name required",
        message: `Use /mcp ${trusted ? "trust" : "untrust"} <plugin>/<server>. Open /mcp to review available and trusted servers.`,
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const separator = key.indexOf("/")
    if (separator <= 0 || separator === key.length - 1) {
      openDialogAlert(dialog, {
        title: "Invalid MCP server name",
        message: "Use the plugin/server key shown by /mcp, for example /mcp trust configured/echo-tools.",
        onConfirm: () => setComposerFocused(true),
      })
      return
    }
    const pluginName = key.slice(0, separator)
    const serverName = key.slice(separator + 1)
    try {
      await props.api.setSessionMcpServerTrust(sessionId, pluginName, serverName, trusted)
      toast.success(
        trusted
          ? `Trusted ${pluginName}/${serverName}; it connects on the next turn. Each tool call still needs review.`
          : `Revoked trust for ${pluginName}/${serverName}; it will not connect on future turns.`,
        "MCP",
      )
      setComposerFocused(true)
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Could not update MCP trust", "MCP")
      setComposerFocused(true)
    }
  }

  const runLiveMcpAdd = async (input: Extract<ReturnType<typeof resolveLiveSlash>, { kind: "mcp-add" }>) => {
    const root = directory()
    if (input.scope === "project" && (!activeSessionId() || !root)) {
      openDialogAlert(dialog, { title: "Workspace required", message: "Open a workspace before adding a project-scoped MCP server.", onConfirm: () => setComposerFocused(true) })
      return
    }
    const add = async () => {
      try {
        const server = await props.api.addConfiguredMcpServer({
          name: input.name,
          transport: input.transport,
          command: input.command,
          args: input.args,
          url: input.url,
          scope: input.scope,
          directory: input.scope === "project" ? root : undefined,
        })
        toast.success(`Added configured/${server.name} · ${server.scope ?? input.scope}. Review it, then use /mcp trust configured/${server.name}; tool calls still need approval.`, "MCP")
      } catch (error) {
        openDialogAlert(dialog, { title: "MCP server could not be added", message: error instanceof Error ? error.message : "request failed", onConfirm: () => setComposerFocused(true) })
      } finally {
        setComposerFocused(true)
      }
    }
    try {
      const catalog = await props.api.listConfiguredMcpServers(root)
      const existing = catalog.servers.find((server) => server.name === input.name && server.scope === input.scope)
      if (existing) {
        openDialogConfirm(dialog, {
          title: "Replace configured MCP server?",
          message: `${input.name} already exists in ${input.scope} scope (${existing.transport}${existing.command ? ` · ${existing.command}` : existing.url_origin ? ` · ${existing.url_origin}` : ""}). Replace its saved configuration?`,
          label: { confirm: "Replace server", cancel: "Keep existing" },
          onClose: () => setComposerFocused(true),
          onConfirm: () => { void add() },
        })
      } else await add()
    } catch (error) {
      openDialogAlert(dialog, { title: "MCP configuration unavailable", message: error instanceof Error ? error.message : "could not check existing servers", onConfirm: () => setComposerFocused(true) })
      setComposerFocused(true)
    }
  }

  const openLiveMcpAddWizard = () => {
    setComposerFocused(false)
    const choices = [
      { title: "User · stdio", value: "user stdio", description: "Local process · available to your user" },
      { title: "User · Streamable HTTP", value: "user http", description: "HTTPS remote or loopback HTTP endpoint" },
      ...(activeSessionId() ? [
        { title: "Project · stdio", value: "project stdio", description: "Local process · saved in this workspace" },
        { title: "Project · Streamable HTTP", value: "project http", description: "HTTPS remote or loopback HTTP endpoint · saved in this workspace" },
      ] : []),
    ]
    openDialogSelect(dialog, {
      title: "Add MCP server",
      options: choices,
      dismissOnSelect: false,
      onCancel: () => setComposerFocused(true),
      onSelect: (choice) => {
        dialog.clear()
        const [scope, transport] = choice.value.split(" ") as ["user" | "project", "stdio" | "http"]
        const description = transport === "stdio"
          ? "Enter a server name, executable, and optional arguments. Nothing is launched until you trust the server."
          : "Enter a server name and endpoint. Remote servers require HTTPS; HTTP is accepted only for loopback. Nothing connects until trust."
        openDialogPrompt(dialog, {
          title: transport === "stdio" ? "Configure stdio MCP" : "Configure Streamable HTTP MCP",
          description,
          placeholder: transport === "stdio" ? "name npx -y package-name" : "name https://example.com/mcp",
          confirmLabel: "Validate and add",
          onCancel: () => setComposerFocused(true),
          onConfirm: (value) => queueMicrotask(() => {
            const parts = splitMcpArgs(value.trim())
            const minimum = transport === "stdio" ? 2 : 2
            if (parts.length < minimum) {
              openDialogAlert(dialog, {
                title: "MCP server details required",
                message: transport === "stdio"
                  ? "Enter a server name and executable, for example: docs npx -y @example/docs-mcp."
                  : "Enter a server name and an HTTPS MCP endpoint, for example: docs https://example.com/mcp.",
                onConfirm: () => setComposerFocused(true),
              })
              return
            }
            if (transport === "stdio") {
              void runLiveMcpAdd({ kind: "mcp-add", scope, transport, name: parts[0]!, command: parts[1]!, args: parts.slice(2) })
            } else {
              void runLiveMcpAdd({ kind: "mcp-add", scope, transport: "streamable-http", name: parts[0]!, url: parts[1]! })
            }
          }),
        })
      },
    })
  }

  const runLiveMcpConfigure = async (action: "remove" | "enable" | "disable", scope: "user" | "project", name: string) => {
    const root = directory()
    if (scope === "project" && (!activeSessionId() || !root)) {
      openDialogAlert(dialog, { title: "Workspace required", message: "Open the workspace that owns this project-scoped MCP server.", onConfirm: () => setComposerFocused(true) })
      return
    }
    const perform = async () => {
      try {
        if (action === "remove") await props.api.removeConfiguredMcpServer(name, scope, scope === "project" ? root : undefined)
        else await props.api.updateConfiguredMcpServer(name, { enabled: action === "enable", scope, directory: scope === "project" ? root : undefined })
        toast.success(`${action === "remove" ? "Removed" : action === "enable" ? "Enabled" : "Disabled"} ${scope}-scope MCP server · ${name}`, "MCP")
      } catch (error) {
        openDialogAlert(dialog, { title: "MCP server update failed", message: error instanceof Error ? error.message : "request failed", onConfirm: () => setComposerFocused(true) })
      } finally {
        setComposerFocused(true)
      }
    }
    if (action === "remove") {
      openDialogConfirm(dialog, {
        title: "Remove configured MCP server?",
        message: `Remove ${name} from ${scope} configuration? This does not remove its executable or remote service.`,
        label: { confirm: "Remove server", cancel: "Keep server" },
        onClose: () => setComposerFocused(true),
        onConfirm: () => { void perform() },
      })
    } else await perform()
  }

  const handleComposerSubmit = (text: string) => {
    const action = resolveLiveSlash(text)
    switch (action.kind) {
      case "passthrough":
        if (!activeSessionId()) {
          // Home `/` can race the textarea mount so the leading slash is lost
          // (`connect` instead of `/connect`). Recover known slash names.
          const trimmed = text.trim()
          if (trimmed && !trimmed.startsWith("/")) {
            const recovered = resolveLiveSlash(`/${trimmed}`)
            if (recovered.kind !== "passthrough" && recovered.kind !== "unknown") {
              handleComposerSubmit(`/${trimmed}`)
              return
            }
          }
          openDialogAlert(dialog, {
            title: "Session required",
            message: "Open a session (n or Enter) before chatting. Slash commands like /connect and /skills work from home — press / first, then type the command.",
            onConfirm: () => setComposerFocused(true),
          })
          return
        }
        void sendMessage(text)
        return
      case "connect":
        dismissHomeComposer()
        void openSettings("connect")
        return
      case "models":
        dismissHomeComposer()
        void openSettings("models")
        return
      case "skills":
        dismissHomeComposer()
        void openLiveSkills(action.filter)
        return
      case "skill-action":
        dismissHomeComposer()
        void runLiveSkillAction(action.action, action.key)
        return
      case "mcp":
        dismissHomeComposer()
        void openLiveMcp(action.filter)
        return
      case "mcp-trust":
        dismissHomeComposer()
        void runLiveMcpTrustAction(action.trusted, action.key)
        return
      case "mcp-add":
        dismissHomeComposer()
        void runLiveMcpAdd(action)
        return
      case "mcp-add-wizard":
        dismissHomeComposer()
        openLiveMcpAddWizard()
        return
      case "mcp-configure":
        dismissHomeComposer()
        void runLiveMcpConfigure(action.action, action.scope, action.name)
        return
      case "plugins":
        dismissHomeComposer()
        void openLivePlugins(action.filter)
        return
      case "plugin-add":
        dismissHomeComposer()
        requestPluginAdd(action.path, action.replace)
        return
      case "plugin-remove":
        dismissHomeComposer()
        void requestPluginRemoval(action.name)
        return
      case "map":
        dismissHomeComposer()
        void openLiveMap(action.hint)
        return
      case "history-older":
        void loadOlderHistory()
        return
      case "history-hint":
        openDialogAlert(dialog, {
          title: "History",
          message: "Use /history older to load the preceding page of this session's chat history.",
          onConfirm: () => setComposerFocused(true),
        })
        return
      case "help":
        dismissHomeComposer()
        setComposerFocused(false)
        openDialogHelp(dialog, { compact: !action.advanced })
        return
      case "theme":
        dismissHomeComposer()
        if (action.mode === "list") {
          openThemeList()
          return
        }
        if (action.mode === "id" && action.id && isBuiltinThemeId(action.id)) {
          setThemeId(action.id)
          saveThemeId(action.id)
          toast.success(`Theme · ${action.id}`, "Theme")
          return
        }
        toast.info(`Unknown theme · ${action.id ?? "?"}`, "Theme")
        return
      case "status":
        dismissHomeComposer()
        void openLiveStatus()
        return
      case "reviews":
        dismissHomeComposer()
        void openLiveReviews(action.target)
        return
      case "export":
        dismissHomeComposer()
        openLiveExport()
        return
      case "session-list":
        dismissHomeComposer()
        openLiveSessionList()
        return
      case "fork":
        dismissHomeComposer()
        void forkCurrentSession()
        return
      case "unsupported":
        openDialogAlert(dialog, {
          title: "Slash",
          message: `${action.command} is not wired in LiveApp yet. Try Ctrl+P for the matching dialog, or the headless CLI for manage subcommands.`,
          onConfirm: () => setComposerFocused(true),
        })
        return
      case "unknown":
        openDialogAlert(dialog, {
          title: "Slash",
          message: `Unknown command · ${action.command}\n\nType /help to see available commands.`,
          onConfirm: () => setComposerFocused(true),
        })
        return
    }
  }

  const sendMessage = async (text: string) => {
    const content = text.trim()
    const sessionId = activeSessionId()
    if (!content || !sessionId || sending()) return
    const operationId = crypto.randomUUID()
    setSending(true)
    setActiveTurnId(operationId)
    activeTurnSessionId = sessionId
    setCancelling(false)
    turnController = new AbortController()
    setStreamingText("")
    setStreaming(true)
    setMessages((prev) => [...prev, { role: "user", content }])
    setStatus(formatBusyStatus("Veasel is thinking…"))
    try {
      const result = await props.api.sendMessage(
        sessionId,
        content,
        operationId,
        turnController.signal,
        executionPolicyForAgent(executionPolicy()),
      )
      if (result.kind === "async") return
      if (!disposed && activeSessionId() === sessionId) {
        applyHistoryPage(result.messages, "replace")
      }
      setStreaming(false)
      setStreamingText("")
      setSending(false)
      setActiveTurnId(undefined)
      activeTurnSessionId = undefined
      setCancelling(false)
      turnController = undefined
      setStatus("● connected  ·  listening for activity")
      setComposerFocused(true)
    } catch (error) {
      if (turnController?.signal.aborted) {
        setStatus("▲ response cancelled")
      } else {
        noteError(
          "messages.send",
          `message failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
          sessionId,
          "Send failed",
        )
      }
      setSending(false)
      setStreaming(false)
      setActiveTurnId(undefined)
      activeTurnSessionId = undefined
      setCancelling(false)
      turnController = undefined
      setComposerFocused(true)
    }
  }

  const finishProviderConnect = (
    provider: ModelProvider,
    apiKey: string,
    profileModel: string | undefined,
    profileMaxOut: number | undefined,
  ) => {
    void (async () => {
      try {
        toast.info(`Discovering models · ${provider.name}…`, "MODEL SETTINGS")
        const catalog = await props.api.discoverProviderModels({
          provider: provider.id,
          base_url: provider.base_url,
          api_key: apiKey,
        })
        const models = catalog.models.map((model) =>
          catalogEntryToSolidModel(provider.id, provider.name, {
            ...model,
            id: safeModelCatalogText(model.id) || model.id,
            name: safeModelCatalogText(model.name) || model.name,
          }),
        )
        if (models.length === 0) {
          if (profileModel) {
            await props.api.updateModelSettings({
              provider: provider.id,
              model: profileModel,
              base_url: provider.base_url,
              api_key: apiKey || undefined,
              max_output_tokens: profileMaxOut,
            })
            toast.success(`Connected · ${provider.name} (kept ${profileModel})`, "MODEL SETTINGS")
          } else {
            toast.info("No models returned — paste a key and pick a model with F2", "MODEL SETTINGS")
          }
          setComposerFocused(true)
          return
        }
        const current = profileModel
          ? {
              providerID: provider.id,
              modelID: profileModel,
              name: profileModel,
              providerName: provider.name,
            }
          : undefined
        openModelDialog(dialog, {
          models,
          current,
          onSelect: (model) => {
            void (async () => {
              try {
                const saved = await props.api.updateModelSettings({
                  provider: model.providerID,
                  model: model.modelID,
                  base_url: provider.base_url,
                  api_key: apiKey || undefined,
                  max_output_tokens: profileMaxOut,
                })
                const label =
                  formatActiveModelLabel(saved) ?? `${model.providerID}/${model.modelID}`
                toast.success(`Connected · ${label}`, "MODEL SETTINGS")
              } catch (error) {
                toast.info(
                  error instanceof Error ? error.message : "could not save provider",
                  "MODEL SETTINGS",
                )
              } finally {
                setComposerFocused(true)
              }
            })()
          },
          onCancel: () => setComposerFocused(true),
        })
      } catch (error) {
        toast.info(
          error instanceof Error ? error.message : "model discovery failed",
          "MODEL SETTINGS",
        )
        setComposerFocused(true)
      }
    })()
  }

  const openSettings = async (mode: "connect" | "models" = "models") => {
    dismissHomeComposer()
    setComposerFocused(false)
    try {
      const view = await props.api.getModelSettings()
      openProviderSettingsDialog(dialog, {
        mode,
        providers: view.providers,
        configuredProviders: view.configured_providers,
        activeProvider: view.active_provider,
        onStatus: (line) => setStatus(line),
        onSelect: (provider) => {
          const profile = view.profiles[provider.id]
          const keySaved = Boolean(profile?.api_key_saved)
          openDialogPrompt(dialog, {
            title: `API key · ${provider.name}`,
            secret: true,
            description: keySaved
              ? `Key already saved for ${provider.id}. Leave blank to keep it, or paste a new key.`
              : `Paste the ${provider.environment_key || "API"} key for ${provider.name}.`,
            placeholder: keySaved ? "(keep saved key)" : "sk-…",
            confirmLabel: "Continue",
            onConfirm: (value) => {
              finishProviderConnect(
                provider,
                value.trim(),
                profile?.model,
                profile?.max_output_tokens,
              )
            },
            onCancel: () => {
              setStatus(formatHomeSessionStatus(selectedIndex(), sessions().length))
              setComposerFocused(true)
            },
          })
        },
        onCancel: () => {
          setStatus(formatHomeSessionStatus(selectedIndex(), sessions().length))
          setComposerFocused(true)
        },
      })
    } catch (error) {
      setStatus(
        formatErrorStatus(
          `settings unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
      )
      setComposerFocused(true)
    }
  }

  const openLiveModelPicker = async () => {
    setComposerFocused(false)
    try {
      const settings = await props.api.getModelSettings()
      const provider = settings.active_provider
      const providerInfo = settings.providers.find((item) => item.id === provider)
      const providerName = providerInfo?.name ?? provider
      const profile = settings.profiles[provider]
      let catalogModels: SolidModelRef[] = []
      try {
        const catalog = await props.api.listProviderModels(provider)
        catalogModels = catalog.models.map((model) =>
          catalogEntryToSolidModel(provider, providerName, {
            ...model,
            id: safeModelCatalogText(model.id) || model.id,
            name: safeModelCatalogText(model.name) || model.name,
          }),
        )
      } catch (error) {
        toast.info(
          error instanceof Error
            ? error.message
            : "Model catalog unavailable — configure credentials first",
          "Models",
        )
      }
      if (catalogModels.length === 0 && profile?.model) {
        catalogModels = [
          {
            providerID: provider,
            modelID: profile.model,
            name: profile.model,
            providerName,
          },
        ]
      }
      if (catalogModels.length === 0) {
        toast.info("No models for the active provider — open Provider settings", "Models")
        setComposerFocused(true)
        return
      }
      const current: SolidModelRef | undefined = profile?.model
        ? {
            providerID: provider,
            modelID: profile.model,
            name: profile.model,
            providerName,
          }
        : undefined
      openModelDialog(dialog, {
        models: catalogModels,
        current,
        onSelect: (model) => {
          void (async () => {
            try {
              const saved = await props.api.updateModelSettings({
                provider: model.providerID,
                model: model.modelID,
                base_url: profile?.base_url || providerInfo?.base_url || "",
                max_output_tokens: profile?.max_output_tokens,
              })
              const label =
                formatActiveModelLabel(saved) ?? `${model.providerID}/${model.modelID}`
              toast.success(`Model · ${label}`, "Models")
            } catch (error) {
              toast.info(
                error instanceof Error ? error.message : "could not save model",
                "Models",
              )
            } finally {
              setComposerFocused(true)
            }
          })()
        },
        onCancel: () => setComposerFocused(true),
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not load model settings",
        "Models",
      )
      setComposerFocused(true)
    }
  }

  const openLiveVariantPicker = async () => {
    setComposerFocused(false)
    try {
      const settings = await props.api.getModelSettings()
      const provider = settings.active_provider
      const providerInfo = settings.providers.find((item) => item.id === provider)
      const profile = settings.profiles[provider]
      if (!profile?.model) {
        toast.info("Configure a model first (F2 or Provider settings)", "Variant")
        setComposerFocused(true)
        return
      }
      const current = variantForOutputBudget(profile.max_output_tokens)
      openVariantDialog(dialog, {
        variants: [...modelVariantIds],
        current,
        onSelect: (variant) => {
          const id = (variant ?? "default") as ModelVariantId
          const budget = outputBudgetForVariant(id)
          void (async () => {
            try {
              await props.api.updateModelSettings({
                provider,
                model: profile.model,
                base_url: profile.base_url || providerInfo?.base_url || "",
                max_output_tokens: budget,
              })
              toast.success(`Variant · ${variantBudgetLabel(id)}`, "Variant")
            } catch (error) {
              toast.info(
                error instanceof Error ? error.message : "could not save variant",
                "Variant",
              )
            } finally {
              setComposerFocused(true)
            }
          })()
        },
        onCancel: () => setComposerFocused(true),
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not load model settings",
        "Variant",
      )
      setComposerFocused(true)
    }
  }

  const sessionIdForWorktrees = () =>
    activeSessionId() ?? sessions()[selectedIndex()]?.id ?? sessions()[0]?.id

  const openLiveOpenDialog = async () => {
    setComposerFocused(false)
    const sessionId = sessionIdForWorktrees()
    try {
      const listed = await props.api.listSessions()
      setSessions(listed.map(sessionEntry))
      let projects: SolidOpenProject[] = []
      let worktreesByProject = groupWorktreesByProject([])
      if (sessionId) {
        const catalog = await props.api.listGitWorktrees(sessionId)
        const mapped = mapApiWorktreesToOpenCatalog(catalog.worktrees)
        projects = mapped.projects
        worktreesByProject = groupWorktreesByProject(mapped.worktrees)
      }
      openOpenDialog(dialog, {
        currentDirectory: directory(),
        onCreateSession: () => { void createSession() },
        recentSessions: listed.map(sessionEntry),
        projects,
        worktreesByProject,
        onOpenSession: (session) => {
          void openSession(session)
          toast.info(`Opened · ${session.title}`, "Open")
        },
        onOpenWorktree: (worktree) => {
          void (async () => {
            const match = findSessionForDirectory(listed, worktree.path)
            if (match) {
              await openSession(sessionEntry(match))
              toast.success(`Opened session · ${match.title}`, "Open")
              return
            }
            const created = await props.api.createSession(
              `Worktree · ${worktree.name}`,
              worktree.path,
            )
            await refreshSessions()
            await openSession(sessionEntry(created))
            toast.success(`Session in · ${worktree.name}`, "Open")
          })().catch((error) => {
            setStatus(
              formatErrorStatus(
                `open worktree failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
              ),
            )
          })
        },
      })
    } catch (error) {
      setStatus(
        formatErrorStatus(
          `open dialog failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
      )
      setComposerFocused(true)
    }
  }

  const openLiveWorkspacesDialog = async () => {
    const sessionId = sessionIdForWorktrees()
    if (!sessionId) {
      toast.info("Create or select a session first", "Workspaces")
      return
    }
    setComposerFocused(false)
    try {
      const catalog = await props.api.listGitWorktrees(sessionId)
      const workspaces = mapApiWorktreesToSolidWorkspaces(catalog.worktrees)
      const main = catalog.worktrees.find((tree) => tree.is_main) ?? catalog.worktrees[0]
      const current =
        workspaces.find((item) => item.path === directory())?.id ?? workspaces[0]?.id
      openWorkspacesDialog(dialog, {
        workspaces,
        current,
        onSelect: (workspace) => {
          void (async () => {
            const listed = await props.api.listSessions()
            const match = findSessionForDirectory(listed, workspace.path)
            if (match) {
              await openSession(sessionEntry(match))
              toast.info(`Workspace · ${workspace.name}`, "Workspaces")
              return
            }
            const created = await props.api.createSession(
              `Workspace · ${workspace.name}`,
              workspace.path,
            )
            await refreshSessions()
            await openSession(sessionEntry(created))
            toast.success(`Session · ${workspace.name}`, "Workspaces")
          })().catch((error) => {
            setStatus(
              formatErrorStatus(
                `workspace switch failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
              ),
            )
          })
        },
        onCreateWorktree: (name) => {
          if (!main) {
            toast.info("No main checkout to attach a worktree", "Workspaces")
            return
          }
          const branch = sanitizeWorktreeName(name)
          const path = suggestedLinkedWorktreePath(main.path, branch)
          void (async () => {
            const created = await props.api.addGitWorktree(sessionId, {
              path,
              new_branch: branch,
            })
            toast.success(`Worktree · ${created.path}`, "Workspaces")
            await openLiveWorkspacesDialog()
          })().catch((error) => {
            setStatus(
              formatErrorStatus(
                `worktree add failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
              ),
            )
            setComposerFocused(true)
          })
        },
      })
    } catch (error) {
      setStatus(
        formatErrorStatus(
          `workspaces unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
      )
      setComposerFocused(true)
    }
  }

  onMount(() => {
    void refreshSessions()
    void props.api.consumeEvents(
      {
        onConnected: () => {
          if (!activeSessionId() && !dialog.open()) {
            setStatus(formatHomeSessionStatus(selectedIndex(), sessions().length))
          }
        },
        onReconnect: () => setStatus(formatBusyStatus("reconnecting to event stream…")),
        onAssistantDelta: (delta) => {
          setStreamingText((current) => appendStreamingDelta(current, delta))
          setStreaming(true)
        },
        onTurnCompleted: (sessionId, completion) => {
          void finishTurn(sessionId, completion)
          void refreshSessions()
        },
        onEvent: () => {
          void refreshSessions()
        },
      },
      {
        activeSessionId: () => activeSessionId(),
        activeTurnId: () => activeTurnId(),
      },
    )
  })

  createEffect(() => {
    if (!dialog.open()) setComposerFocused(true)
  })

  const switchSessionTab = (delta: number) => {
    const list = sessions()
    if (list.length === 0) return
    const current = Math.max(
      0,
      list.findIndex((item) => item.id === activeSessionId()),
    )
    const session = list[moveSessionTabIndex(current, delta, list.length)]
    if (session) void openSession(session)
  }

  const openPalette = () => {
    setComposerFocused(false)
    openCommandPalette(
      dialog,
      buildLivePaletteCommands({
        cancelTurn: () => { void cancelActiveTurn() },
        showHelp: () => openDialogHelp(dialog, { compact: true }),
        openSettings: () => {
          void openSettings()
        },
        showModelPicker: () => {
          void openLiveModelPicker()
        },
        showVariant: () => {
          void openLiveVariantPicker()
        },
        showAgent: () => openLiveAgentPicker(),
        showSessions: () => openLiveSessionList(),
        showUpdate: () => {
          void openLiveUpdate()
        },
        showHighlights: () => openLiveHighlights(),
        showPair: () => openLivePair(),
        createSession: () => {
          void createSession()
        },
        openRecent: () => {
          void openLiveOpenDialog()
        },
        openWorkspaces: () => {
          void openLiveWorkspacesDialog()
        },
        stashDraft: () => stashComposerDraft(),
        showStash: () => openLiveStash(),
        cycleTheme: () => cycleTheme(),
        showThemeList: () => openThemeList(),
        renameSession: () => openRenameSession(),
        attachFile: () => openAttachPrompt(),
        showSessionDiffs: () => {
          void openSessionDiffs()
        },
        showReviews: () => {
          void openLiveReviews()
        },
        showShellOutput: () => {
          void openLiveShellOutput()
        },
        showSessionTimeline: () => openSessionTimeline(),
        showStatus: () => {
          void openLiveStatus()
        },
        showExport: () => openLiveExport(),
        showMcp: () => {
          void openLiveMcp()
        },
        showPlugins: () => {
          void openLivePlugins()
        },
        showSkills: () => {
          void openLiveSkills()
        },
        showErrorDetails: () => {
          setComposerFocused(false)
          const details = resolveLiveErrorDetails(lastError())
          openErrorDetailsDialog(dialog, {
            ...details,
            onCopy: () => toast.success("Error details copied", "Error"),
            onClose: () => setComposerFocused(true),
          })
        },
        previousUserMessage: () => requestMessageNav({ direction: "prev", userOnly: true }),
        nextUserMessage: () => requestMessageNav({ direction: "next", userOnly: true }),
        lastUserMessage: () => requestMessageNav({ action: "last-user" }),
        cycleVerbosity: () => {
          const next = cycleTranscriptVerbosity(verbosity())
          setVerbosity(next)
          toast.info(`Verbosity · ${transcriptVerbosityLabel(next)}`, "Transcript")
          return next
        },
        toggleThinking: () => {
          setThinkingToggleTick((tick) => tick + 1)
          toast.info("Toggled latest thinking block", "Transcript")
        },
        nextSessionTab: () => switchSessionTab(1),
        prevSessionTab: () => switchSessionTab(-1),
        widenSidebar: () => {
          const next = stepHomeSidebarWidth(sidebarWidth(), 2, terminalColumns())
          commitSidebarWidth(next)
          toast.success(`Sidebar · ${next} cols`, "Layout")
        },
        narrowSidebar: () => {
          const next = stepHomeSidebarWidth(sidebarWidth(), -2, terminalColumns())
          commitSidebarWidth(next)
          toast.success(`Sidebar · ${next} cols`, "Layout")
        },
        resetSidebar: () => {
          commitSidebarWidth(HOME_SIDEBAR_DEFAULT)
          toast.success(`Sidebar · ${HOME_SIDEBAR_DEFAULT} cols (default)`, "Layout")
        },
        quit: () => props.onQuit?.(),
      }),
    )
  }

  useKeyboard((key: KeyEvent) => {
    if (dialog.open()) return
    if (key.ctrl && key.name === "x" && !key.meta) {
      key.preventDefault()
      void cancelActiveTurn()
      return
    }
    // Classic parity: empty composer + `?` opens quick help (same as /help).
    if (
      inSession()
      && composerDraft().trim() === ""
      && !key.ctrl
      && !key.meta
      && (key.name === "?" || key.sequence === "?")
    ) {
      key.preventDefault()
      setComposerFocused(false)
      openDialogHelp(dialog, { compact: true })
      return
    }
    if (key.ctrl && key.name === paletteShortcut.name && !key.meta) {
      key.preventDefault()
      openPalette()
      return
    }
    if (key.ctrl && key.name === "o" && !key.meta) {
      key.preventDefault()
      void openLiveOpenDialog()
      return
    }
    if (key.ctrl && key.name === "w" && !key.meta) {
      key.preventDefault()
      void openLiveWorkspacesDialog()
      return
    }
    if (key.ctrl && key.name === "s" && !key.meta) {
      key.preventDefault()
      stashComposerDraft()
      return
    }
    if (key.ctrl && key.name === "d" && !key.meta) {
      key.preventDefault()
      void openSessionDiffs()
      return
    }
    if (
      key.ctrl
      && key.name === reviewShortcut.name
      && !key.meta
      && Boolean(reviewShortcut.ctrl)
    ) {
      key.preventDefault()
      void openLiveReviews()
      return
    }
    if (key.ctrl && key.name === "t" && !key.meta) {
      key.preventDefault()
      openSessionTimeline()
      return
    }
    if (key.ctrl && key.name === "i" && !key.meta) {
      key.preventDefault()
      void openLiveStatus()
      return
    }
    if (key.ctrl && key.name === "e" && !key.meta) {
      key.preventDefault()
      openLiveExport()
      return
    }
    if (key.ctrl && key.name === "m" && !key.meta) {
      key.preventDefault()
      void openLiveMcp()
      return
    }
    if (key.name === "f2" && !key.ctrl && !key.meta) {
      key.preventDefault()
      void openLiveModelPicker()
      return
    }
    if (key.name === "f3" && !key.ctrl && !key.meta) {
      key.preventDefault()
      void openLiveVariantPicker()
      return
    }
    if (key.name === "f4" && !key.ctrl && !key.meta) {
      key.preventDefault()
      openLiveAgentPicker()
      return
    }
    if (key.ctrl && key.name === "l" && !key.meta) {
      key.preventDefault()
      openLiveSessionList()
      return
    }
    if (inSession() && key.ctrl && (key.name === "]" || key.name === "[")) {
      key.preventDefault()
      switchSessionTab(key.name === "]" ? 1 : -1)
      return
    }
    if (!inSession()) {
      if (key.meta && (key.name === "left" || key.name === "right") && !key.ctrl) {
        key.preventDefault()
        commitSidebarWidth(
          stepHomeSidebarWidth(sidebarWidth(), key.name === "right" ? 2 : -2, terminalColumns()),
        )
        return
      }
      // Slash composer on home: `/` mounts it; Esc dismisses back to session nav.
      if (key.name === "/" && !key.ctrl && !key.meta && !homeComposerOpen()) {
        key.preventDefault()
        setHomeComposerOpen(true)
        setRestoreToken({ id: `home-slash-${Date.now()}`, text: "/" })
        setComposerFocused(true)
        return
      }
      if (key.name === "escape" && homeComposerOpen()) {
        key.preventDefault()
        setHomeComposerOpen(false)
        setComposerFocused(false)
        return
      }
      if (homeComposerOpen()) return
      if (key.name === "s" && !key.ctrl && !key.meta) {
        key.preventDefault()
        void openSettings("models")
        return
      }
      if (key.name === "q" && !key.ctrl && !key.meta) {
        key.preventDefault()
        props.onQuit?.()
        return
      }
      if (key.name === "n" && !key.ctrl && !key.meta) {
        key.preventDefault()
        void createSession()
        return
      }
      if (key.name === "r" && !key.ctrl && !key.meta) {
        key.preventDefault()
        openRenameSession()
        return
      }
      if (key.name === "j" || key.name === "down") {
        key.preventDefault()
        const next = Math.min(selectedIndex() + 1, Math.max(0, sessions().length - 1))
        setSelectedIndex(next)
        setStatus(formatHomeSessionStatus(next, sessions().length))
        return
      }
      if (key.name === "k" || key.name === "up") {
        key.preventDefault()
        const next = Math.max(0, selectedIndex() - 1)
        setSelectedIndex(next)
        setStatus(formatHomeSessionStatus(next, sessions().length))
        return
      }
      if (key.name === "return" || key.name === "kpenter") {
        const session = sessions()[selectedIndex()]
        if (session) {
          key.preventDefault()
          void openSession(session)
        }
        return
      }
    }
  })

  onCleanup(() => {
    disposed = true
    attention.dispose()
    sessionViewRevision++
    turnController?.abort()
  })

  return (
    <box
      width="100%"
      height="100%"
      flexDirection="column"
      backgroundColor={colors.shellBg}
    >
      <box
        width="100%"
        height={3}
        flexShrink={0}
        flexDirection="row"
        justifyContent="space-between"
        alignItems="center"
        backgroundColor={colors.headerBg}
        border
        borderColor={colors.headerBorder}
        paddingLeft={1}
        paddingRight={1}
      >
        <text fg={colors.headerTitle}>
          <strong>VEASEL</strong>
          <span style={{ fg: colors.brand }}> / </span>
          <span style={{ fg: colors.headerMeta }}>CODE</span>
        </text>
        <text fg={colors.localStatus}>{status()}</text>
      </box>

      <Show
        when={inSession()}
        fallback={
          <LiveHome
            sessions={sessions()}
            selectedIndex={selectedIndex()}
            directory={directory()}
            theme={themes[themeId()] ?? themes.mint}
            sidebarWidth={sidebarWidth()}
            terminalColumns={terminalColumns()}
            onSidebarWidthChange={commitSidebarWidth}
            showFooter={!homeComposerOpen()}
          />
        }
      >
        <SessionTabs
          tabs={sessionTabsFromEntries(sessions(), unreadSessionIds())}
          activeId={activeSessionId()}
          onSelect={(id) => {
            const session = sessions().find((item) => item.id === id)
            if (session) void openSession(session)
          }}
          onNew={() => {
            void createSession()
          }}
          onCloseActive={() => {
            rememberSessionDraft()
            sessionViewRevision++
            setActiveSessionId(undefined)
            setSessionDirectory(undefined)
            setComposerDraft("")
            setRestoreToken({ id: `home-draft-${++draftRevision}`, text: "" })
            setMessages([])
            setOldestTurnId(undefined)
            setHistoryHasOlder(false)
            setAttachments([])
            setHomeComposerOpen(false)
            setComposerFocused(false)
            setStatus(formatHomeSessionStatus(selectedIndex(), sessions().length))
          }}
        />
        <SolidTranscript
          messages={messages}
          session={{ title: sessionTitle(), directory: directory() }}
          streaming={streaming()}
          streamingText={streamingText()}
          followTail={true}
          enableActivityKeys={!dialog.open()}
          messageNavRequest={messageNavRequest}
          verbosity={verbosity}
          thinkingToggleTick={thinkingToggleTick()}
          onMessageNavigated={(info) => {
            toast.info(`Jumped to ${info.role} message`, "Transcript")
          }}
          onScrollViewport={({ offsetFromBottom }) => {
            const live = liveStreamStatusMessage({
              followKey: "Ctrl+End",
              offsetFromBottom,
              streaming: streaming() || Boolean(activeTurnId()),
              streamingChars: streamingText().length,
              formatStreaming: (chars) => formatStreamingBusyStatus(chars),
            })
            if (!live) return
            if (cancelling()) return
            setStatus(offsetFromBottom > 0 ? formatWarnStatus(live) : live)
          }}
          cols={80}
          hasOlder={historyHasOlder()}
        />
      </Show>
      <Show when={composerVisible()}>
        <SolidComposer
          placeholder={
            inSession()
              ? undefined
              : "Type /connect · /skills · /help  (Esc dismisses)"
          }
          onSubmit={(text) => {
            setAttachments([])
            handleComposerSubmit(text)
          }}
          focused={composerFocused()}
          restoreToken={restoreToken()}
          onDraftChange={setComposerDraft}
          skills={composerSkills()}
          skillCatalogStatus={skillCatalogStatus()}
          slashContext={{
            skills: composerSkills().map((skill) => ({
              value: skill.key,
              description: skill.description,
            })),
            mcpServers: mcpArgumentServers(),
            configuredMcpServers: configuredMcpArguments(),
            patches: reviewArgumentItems()
              .filter((item) => item.kind === "patch")
              .map((item) => ({ value: item.id, description: reviewSummaryLine(item) })),
            commands: reviewArgumentItems()
              .filter((item) => item.kind === "command")
              .map((item) => ({ value: item.id, description: reviewSummaryLine(item) })),
            mcpCalls: reviewArgumentItems()
              .filter((item) => item.kind === "mcp")
              .map((item) => ({ value: item.id, description: reviewSummaryLine(item) })),
            pluginLinks: pluginLinkArguments(),
          }}
          attachments={inSession() ? attachments() : []}
          onRemoveAttachment={(id) => setAttachments((current) => removeComposerAttachment(current, id))}
          onPreviewAttachment={previewAttachment}
          onPathPaste={(path) => stageAttachmentPath(path)}
          workspaceRoot={directory()}
        />
      </Show>
      <Show when={inSession() || homeComposerOpen()}>
        <box width="100%" height={1} flexShrink={0} paddingLeft={1}>
          <text fg={colors.muted}>
            <Show
              when={inSession()}
              fallback={`${homeFooterHint} · Esc dismiss slash · drag │ · Alt+←/→ resize`}
            >
              {liveFooterHint} · Ctrl+[ / ] tabs · Alt+[ / ] user msgs · Ctrl+T timeline · Ctrl+E export · Ctrl+M MCP · Ctrl+I status · Ctrl+S stash · Ctrl+D diffs · theme {themeId()}
            </Show>
          </text>
        </box>
      </Show>
    </box>
  )
}

/** Production Solid entry: loopback HTTP sessions + SSE + MODEL SETTINGS. */
export function LiveApp(props: LiveAppProps) {
  return (
    <SolidThemeProvider>
      <ToastProvider>
        <DialogProvider>
          <LiveAppShell {...props} />
        </DialogProvider>
      </ToastProvider>
    </SolidThemeProvider>
  )
}
