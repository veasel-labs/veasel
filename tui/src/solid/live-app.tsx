/** @jsxImportSource @opentui/solid */
import { createEffect, createMemo, createSignal, onCleanup, onMount, Show } from "solid-js"
import type { KeyEvent } from "@opentui/core"
import { useKeyboard } from "@opentui/solid"
import {
  appendStreamingDelta,
  type ApiSession,
  type SessionTurnCompletion,
  type VeaselApiClient,
} from "../api-client"
import { formatHomeSessionStatus, formatBusyStatus, formatErrorStatus } from "../status-a11y"
import { homeFooterHint } from "../footer-hints"
import {
  isBuiltinThemeId,
  loadThemeId,
  saveThemeId,
  themes,
  type BuiltinThemeId,
} from "../themes"
import { DialogProvider, useDialog } from "./ui/dialog"
import { ToastProvider, useToast } from "./ui/toast"
import { openDialogHelp } from "./ui/dialog-help"
import { SolidComposer } from "./composer"
import { SolidTranscript, transcriptMessagesFromChatTurns, type ToolAwareMessage } from "./transcript"
import { LiveHome } from "./component/live-home"
import { openProviderSettingsDialog } from "./component/provider-settings-dialog"
import { openCommandPalette } from "./component/command-palette"
import { openStashDialog, type SolidStashEntry } from "./component/stash-dialog"
import { openImagePreviewDialog } from "./component/image-preview-dialog"
import { openSessionDiffDialog } from "./component/session-diff-dialog"
import { openReviewPanel } from "./component/review-panel"
import { decideSolidReviews, loadPendingSolidReviews } from "./reviews-inventory"
import { reviewShortcut } from "./reviews"
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
import { SessionTabs } from "./component/session-tabs"
import { solidMcpServersFromCatalog } from "./mcp-inventory"
import { openDialogExportOptions } from "./ui/dialog-export-options"
import { openDialogExportResult } from "./ui/dialog-export-result"
import { openDialogPrompt } from "./ui/dialog-prompt"
import {
  formatSessionExport,
  formatUsageLine,
  sessionExportPath,
  writeSessionExport,
} from "./session-export"
import type { SolidMcpServer } from "./component/mcp-dialog"
import { moveSessionTabIndex, sessionTabsFromEntries } from "./session-tabs"
import { buildLivePaletteCommands, nextBuiltinThemeId, paletteShortcut } from "./commands"
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
import {
  addComposerAttachment,
  asciiImagePreview,
  createComposerAttachment,
  removeComposerAttachment,
  resolveAttachmentPath,
  type ComposerAttachment,
} from "./composer-attachments"

/** Solid live chrome: Open/Workspaces use session git worktree HTTP. */
const liveFooterHint = `${homeFooterHint} · ${paletteShortcut.label} commands · Ctrl+O open · Ctrl+W worktrees`
import {
  demoOpenProjects,
  groupWorktreesByProject,
  openOpenDialog,
} from "./component/open-dialog"
import { openWorkspacesDialog } from "./component/workspaces-dialog"
import { solidMint } from "./theme"
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
  const dialog = useDialog()
  const toast = useToast()
  const directory = () => props.directory ?? process.env.VEASEL_PROJECT_DIR ?? process.cwd()

  const [sessions, setSessions] = createSignal<SolidSessionEntry[]>([])
  const [selectedIndex, setSelectedIndex] = createSignal(0)
  const [activeSessionId, setActiveSessionId] = createSignal<string | undefined>()
  const [messages, setMessages] = createSignal<ToolAwareMessage[]>([])
  const [status, setStatus] = createSignal(formatBusyStatus("connecting"))
  const [streaming, setStreaming] = createSignal(false)
  const [streamingText, setStreamingText] = createSignal("")
  const [sending, setSending] = createSignal(false)
  const initialTheme = loadThemeId()
  const [themeId, setThemeId] = createSignal<BuiltinThemeId>(
    isBuiltinThemeId(initialTheme) ? initialTheme : "mint",
  )
  const [composerFocused, setComposerFocused] = createSignal(true)
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
  const terminalColumns = () => process.stdout.columns ?? 80
  const [sidebarWidth, setSidebarWidth] = createSignal(
    loadHomeSidebarWidth({}, terminalColumns()),
  )
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

  const stageAttachmentPath = (raw: string) => {
    const resolved = resolveAttachmentPath(raw)
    if (!resolved) {
      toast.info("Path not found · enter an absolute or ~/ path", "Attach")
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

  const openLiveReviews = async () => {
    const sessionId = activeSessionId()
    if (!sessionId) {
      toast.info("Open a session to review pending proposals", "Reviews")
      return
    }
    setComposerFocused(false)
    try {
      const reviews = await loadPendingSolidReviews(props.api, sessionId)
      if (reviews.length === 0) {
        toast.info("No pending edits, shell commands, or MCP calls", "Reviews")
        setComposerFocused(true)
        return
      }
      openReviewPanel(dialog, {
        reviews,
        onDecide: (decision, targets) => {
          void (async () => {
            const result = await decideSolidReviews(props.api, sessionId, decision, targets)
            const verb = decision === "approve" ? "Approved" : "Rejected"
            if (result.ok > 0) {
              toast.success(
                `${verb} ${result.ok} review${result.ok === 1 ? "" : "s"}`,
                "Reviews",
              )
            }
            if (result.failed.length > 0) {
              toast.info(result.failed[0]!, "Reviews")
            }
          })()
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
          status: "connected" as const,
          scope: "session",
        }))
      } catch {
        mcpServers = []
      }
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

  const openLiveSkills = async () => {
    setComposerFocused(false)
    const sessionId = activeSessionId()
    try {
      const [catalog, enabled] = await Promise.all([
        props.api.listPlugins(directory()),
        sessionId
          ? props.api.listSessionSkills(sessionId)
          : Promise.resolve([] as Awaited<ReturnType<typeof props.api.listSessionSkills>>),
      ])
      const skills = skillCatalogFromPlugins(catalog, enabled)
      if (skills.length === 0) {
        toast.info("No skills discovered for this workspace", "Skills")
        setComposerFocused(true)
        return
      }
      openSkillDialog(dialog, {
        skills,
        onSelect: (skill) => {
          const token = `$${skill.key}`
          const current = composerDraft().trimEnd()
          const next = current ? `${current} ${token}` : token
          setRestoreToken({ id: `skill-${skill.key}-${Date.now()}`, text: next })
          toast.success(`Inserted ${token}`, "Skills")
        },
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not list skills",
        "Skills",
      )
      setComposerFocused(true)
    }
  }

  const openLiveMcp = async () => {
    setComposerFocused(false)
    const sessionId = activeSessionId()
    try {
      const [configured, trusted] = await Promise.all([
        props.api.listConfiguredMcpServers(directory()),
        sessionId
          ? props.api.listSessionMcpServers(sessionId)
          : Promise.resolve([] as Awaited<ReturnType<typeof props.api.listSessionMcpServers>>),
      ])
      const servers = solidMcpServersFromCatalog(configured, trusted)
      if (servers.length === 0) {
        toast.info("No configured or trusted MCP servers yet", "MCP")
        setComposerFocused(true)
        return
      }
      openMcpDialog(dialog, {
        servers,
        onSelect: (server) => {
          toast.info(
            server.status === "connected"
              ? `Trusted · ${server.name}`
              : `${server.status} · ${server.name}`,
            "MCP",
          )
        },
      })
    } catch (error) {
      toast.info(
        error instanceof Error ? error.message : "could not list MCP servers",
        "MCP",
      )
      setComposerFocused(true)
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
      setStatus(
        formatErrorStatus(
          `server unavailable  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
      )
    }
  }

  const openSession = async (session: SolidSessionEntry) => {
    setActiveSessionId(session.id)
    setMessages([])
    setStreamingText("")
    setStreaming(false)
    try {
      const turns = await props.api.listMessages(session.id)
      setMessages(transcriptMessagesFromChatTurns(turns))
      setStatus("● connected  ·  listening for activity")
    } catch (error) {
      setStatus(
        formatErrorStatus(
          `could not open session  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
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
      setStatus(
        formatErrorStatus(
          `could not create session  ·  ${error instanceof Error ? error.message : "request failed"}`,
        ),
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
    if (activeTurnId() !== operationId && activeSessionId() !== sessionId) return
    try {
      const latest = await props.api.listMessages(sessionId)
      if (activeSessionId() === sessionId) {
        setMessages(transcriptMessagesFromChatTurns(latest))
      }
    } catch {
      // History reload is best-effort; reopen still works.
    }
    if (activeTurnId() === operationId) {
      setActiveTurnId(undefined)
      turnController = undefined
      setSending(false)
      setStreaming(false)
      setStreamingText("")
      setStatus("● connected  ·  listening for activity")
      setComposerFocused(true)
    }
  }

  const sendMessage = async (text: string) => {
    const content = text.trim()
    const sessionId = activeSessionId()
    if (!content || !sessionId || sending()) return
    const operationId = crypto.randomUUID()
    setSending(true)
    setActiveTurnId(operationId)
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
      setMessages(transcriptMessagesFromChatTurns(result.messages))
      setStreaming(false)
      setStreamingText("")
      setSending(false)
      setActiveTurnId(undefined)
      turnController = undefined
      setStatus("● connected  ·  listening for activity")
      setComposerFocused(true)
    } catch (error) {
      if (turnController?.signal.aborted) {
        setStatus("▲ response cancelled")
      } else {
        setStatus(
          formatErrorStatus(
            `message failed  ·  ${error instanceof Error ? error.message : "request failed"}`,
          ),
        )
      }
      setSending(false)
      setStreaming(false)
      setActiveTurnId(undefined)
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

  const openSettings = async () => {
    setComposerFocused(false)
    try {
      const view = await props.api.getModelSettings()
      openProviderSettingsDialog(dialog, {
        providers: view.providers,
        configuredProviders: view.configured_providers,
        activeProvider: view.active_provider,
        onStatus: (line) => setStatus(line),
        onSelect: (provider) => {
          const profile = view.profiles[provider.id]
          const keySaved = Boolean(profile?.api_key_saved)
          openDialogPrompt(dialog, {
            title: `API key · ${provider.name}`,
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
      let projects = demoOpenProjects()
      let worktreesByProject = groupWorktreesByProject([])
      if (sessionId) {
        const catalog = await props.api.listGitWorktrees(sessionId)
        const mapped = mapApiWorktreesToOpenCatalog(catalog.worktrees)
        projects = mapped.projects
        worktreesByProject = groupWorktreesByProject(mapped.worktrees)
      }
      openOpenDialog(dialog, {
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
        showSkills: () => {
          void openLiveSkills()
        },
        previousUserMessage: () => requestMessageNav({ direction: "prev", userOnly: true }),
        nextUserMessage: () => requestMessageNav({ direction: "next", userOnly: true }),
        lastUserMessage: () => requestMessageNav({ action: "last-user" }),
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
      if (key.name === "s" && !key.ctrl && !key.meta) {
        key.preventDefault()
        void openSettings()
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
    turnController?.abort()
  })

  return (
    <box
      width="100%"
      height="100%"
      flexDirection="column"
      backgroundColor={solidMint.shellBg}
    >
      <box
        width="100%"
        height={3}
        flexShrink={0}
        flexDirection="row"
        justifyContent="space-between"
        alignItems="center"
        backgroundColor={solidMint.headerBg}
        border
        borderColor={solidMint.headerBorder}
        paddingLeft={1}
        paddingRight={1}
      >
        <text fg={solidMint.headerTitle}>
          <strong>VEASEL</strong>
          <span style={{ fg: solidMint.brand }}> / </span>
          <span style={{ fg: solidMint.headerMeta }}>CODE</span>
        </text>
        <text fg={solidMint.localStatus}>{status()}</text>
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
          />
        }
      >
        <SessionTabs
          tabs={sessionTabsFromEntries(sessions())}
          activeId={activeSessionId()}
          onSelect={(id) => {
            const session = sessions().find((item) => item.id === id)
            if (session) void openSession(session)
          }}
          onNew={() => {
            void createSession()
          }}
          onCloseActive={() => {
            setActiveSessionId(undefined)
            setMessages([])
            setAttachments([])
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
          onMessageNavigated={(info) => {
            toast.info(`Jumped to ${info.role} message`, "Transcript")
          }}
          cols={80}
        />
        <SolidComposer
          onSubmit={(text) => {
            setAttachments([])
            void sendMessage(text)
          }}
          focused={composerFocused()}
          restoreToken={restoreToken()}
          onDraftChange={setComposerDraft}
          attachments={attachments()}
          onRemoveAttachment={(id) => setAttachments((current) => removeComposerAttachment(current, id))}
          onPreviewAttachment={previewAttachment}
          onPathPaste={(path) => stageAttachmentPath(path)}
          workspaceRoot={directory()}
        />
        <box width="100%" height={1} flexShrink={0} paddingLeft={1}>
          <text fg={solidMint.muted}>
            {liveFooterHint} · Ctrl+[ / ] tabs · Alt+[ / ] user msgs · Ctrl+T timeline · Ctrl+E export · Ctrl+M MCP · Ctrl+I status · Ctrl+S stash · Ctrl+D diffs · theme {themeId()}
          </text>
        </box>
      </Show>
    </box>
  )
}

/** Production Solid entry: loopback HTTP sessions + SSE + MODEL SETTINGS. */
export function LiveApp(props: LiveAppProps) {
  return (
    <ToastProvider>
      <DialogProvider>
        <LiveAppShell {...props} />
      </DialogProvider>
    </ToastProvider>
  )
}
