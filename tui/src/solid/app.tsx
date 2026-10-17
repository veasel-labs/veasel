/** @jsxImportSource @opentui/solid */
import { createEffect, createMemo, createSignal, Show } from "solid-js"
import type { KeyEvent, ScrollBoxRenderable } from "@opentui/core"
import { useKeyboard } from "@opentui/solid"
import { SolidComposer } from "./composer"
import { SolidTranscript, type ToolAwareMessage } from "./transcript"
import { activityToggleShortcut } from "./activity-group"
import {
  cycleTranscriptVerbosity,
  transcriptVerbosityLabel,
  type TranscriptVerbosity,
} from "./transcript-verbosity"
import { HomeSplash } from "./component/home-splash"
import { useSolidTheme, useSolidThemeState, SolidThemeProvider } from "./theme"
import { themes } from "../themes"
import {
  buildPaletteCommands,
  nextBuiltinThemeId,
  paletteShortcut,
} from "./commands"
import { DialogProvider, useDialog } from "./ui/dialog"
import { openDialogAlert } from "./ui/dialog-alert"
import { openDialogThemeList } from "./component/dialog-theme-list"
import {
  demoFavoriteModels,
  demoModels,
  demoRecentModels,
  openModelDialog,
  type SolidModelRef,
} from "./component/model-dialog"
import { demoStashEntries, openStashDialog, type SolidStashEntry } from "./component/stash-dialog"
import { demoErrorDetails, openErrorDetailsDialog } from "./component/error-details-dialog"
import { demoShellOutput, openShellOutputDialog } from "./component/shell-output-dialog"
import { demoMcpServers, openMcpDialog } from "./component/mcp-dialog"
import { demoSkills, openSkillDialog } from "./component/skill-dialog"
import { demoAgents, openAgentDialog } from "./component/agent-dialog"
import { demoVariants, openVariantDialog } from "./component/variant-dialog"
import {
  demoWorkspaces,
  openWorkspacesDialog,
  type SolidWorkspace,
} from "./component/workspaces-dialog"
import {
  demoOpenProjects,
  demoOpenWorktrees,
  groupWorktreesByProject,
  openOpenDialog,
} from "./component/open-dialog"
import { demoStatusSnapshot, openStatusDialog } from "./component/status-dialog"
import {
  demoUpdateAvailable,
  openUpdateDialog,
} from "./component/update-dialog"
import { openPairDialog } from "./component/pair-dialog"
import { openHighlightsDialog } from "./component/highlights-dialog"
import {
  demoImagePreview,
  openImagePreviewDialog,
} from "./component/image-preview-dialog"
import { openDialogConfirm } from "./ui/dialog-confirm"
import { openDialogHelp } from "./ui/dialog-help"
import { openDialogExportOptions } from "./ui/dialog-export-options"
import { openDialogExportResult } from "./ui/dialog-export-result"
import { ToastProvider, useToast } from "./ui/toast"
import { openCommandPalette } from "./component/command-palette"
import { openReviewPanel } from "./component/review-panel"
import {
  demoSessions,
  SessionListDialog,
  type SolidSessionEntry,
} from "./component/session-list-dialog"
import {
  demoPendingReviews,
  pendingStatusForReviews,
  reviewShortcut,
  settleReviews,
  type ReviewDecision,
  type SolidReviewItem,
} from "./reviews"
import { defaultThemeId } from "../themes"
import type { ActiveReview } from "../active-review"

export type SolidAppProps = {
  status?: string
  sessionTitle?: string
  directory?: string
  /** Seed messages for the conversation pane (fixture / tests / demo). */
  initialMessages?: ToolAwareMessage[]
  /**
   * Controlled transcript turns. When set (including `[]`), App syncs from this
   * prop instead of the demo fixture.
   */
  messages?: ToolAwareMessage[]
  /**
   * Parent owns send + history (live HTTP host). Skip local optimistic append;
   * keep `messages` in sync from the parent.
   */
  managed?: boolean
  /** Seed pending reviews for demos / tests (defaults to demo fixture). */
  initialReviews?: SolidReviewItem[]
  /** Seed session list for demos / tests (defaults to demo fixture). */
  initialSessions?: SolidSessionEntry[]
  streaming?: boolean
  streamingText?: string
  streamingCursor?: string
  notice?: string
  followTail?: boolean
  scrollRef?: (box: ScrollBoxRenderable | undefined) => void
  onSubmit?: (text: string) => void
  /** Optional hook when a Solid review decision is made (fixture settle still runs). */
  onReviewDecide?: (decision: ReviewDecision, targets: ActiveReview[]) => void
}

const demoFixture: ToolAwareMessage[] = [
  {
    role: "user",
    content: "Show the Solid transcript pane with Veasel mint chrome.",
  },
  {
    role: "assistant",
    content:
      "Conversation turns render through transcriptSegments on an OpenTUI scrollbox.\nSticky follow-tail keeps the live reply in view while streaming.\nPress Ctrl+P for commands · Ctrl+G toggles activity · Ctrl+R opens pending reviews.",
  },
  {
    role: "tool",
    content: "read: tui/src/solid/transcript.tsx",
    toolName: "read",
    toolStatus: "done",
  },
  {
    role: "tool",
    content: "grep: activityGroupHeader",
    toolName: "grep",
    toolStatus: "done",
  },
  {
    role: "assistant",
    content: "Consecutive tool calls collapse into a mint activity group with running/done/error status.",
  },
]

function AppShell(props: SolidAppProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const toast = useToast()
  const directory = () => props.directory ?? "~/veasel"
  const sessionTitle = () => {
    // Explicit prop wins (tests / host); otherwise follow the active list entry.
    if (props.sessionTitle) return props.sessionTitle
    const active = sessions().find((item) => item.id === activeSessionId())
    return active?.title ?? "Solid transcript"
  }
  const [messages, setMessages] = createSignal<ToolAwareMessage[]>(
    props.messages ?? props.initialMessages ?? (props.managed ? [] : demoFixture),
  )
  createEffect(() => {
    if (props.messages !== undefined) setMessages(props.messages)
  })
  const [reviews, setReviews] = createSignal<SolidReviewItem[]>(
    props.initialReviews ?? demoPendingReviews(),
  )
  const [sessions, setSessions] = createSignal<SolidSessionEntry[]>(
    props.initialSessions ?? demoSessions(),
  )
  const [activeSessionId, setActiveSessionId] = createSignal(
    (props.initialSessions ?? demoSessions())[0]?.id ?? "",
  )
  const [notice, setNotice] = createSignal(props.notice ?? "")
  const { themeId, setThemeId } = useSolidThemeState()
  const [activeModel, setActiveModel] = createSignal<SolidModelRef>(demoModels()[0]!)
  const [stashEntries, setStashEntries] = createSignal<SolidStashEntry[]>(demoStashEntries())
  const [activeAgent, setActiveAgent] = createSignal(demoAgents()[0]!.id)
  const [activeVariant, setActiveVariant] = createSignal<string | undefined>()
  const [workspaces, setWorkspaces] = createSignal(demoWorkspaces())
  const [activeWorkspaceId, setActiveWorkspaceId] = createSignal(demoWorkspaces()[0]!.id)
  const [composerFocused, setComposerFocused] = createSignal(true)
  const [activityToggleTick, setActivityToggleTick] = createSignal(0)
  const [verbosity, setVerbosity] = createSignal<TranscriptVerbosity>("default")
  const [thinkingToggleTick, setThinkingToggleTick] = createSignal(0)
  const [messageNavRequest, setMessageNavRequest] = createSignal<
    | { tick: number; direction: "next" | "prev"; userOnly?: boolean }
    | { tick: number; action: "last-user" }
    | undefined
  >(undefined)
  let messageNavTick = 0

  const status = createMemo(() => {
    const pending = pendingStatusForReviews(reviews())
    if (pending) return pending
    return props.status ?? "LOCAL · Solid shell"
  })

  const openReviews = () => {
    setComposerFocused(false)
    openReviewPanel(dialog, {
      reviews: reviews(),
      onClose: () => setComposerFocused(true),
      onDecide: (decision, targets) => {
        props.onReviewDecide?.(decision, targets)
        setReviews((prev) => settleReviews(prev, targets))
        const verb = decision === "approve" ? "Approved" : "Rejected"
        toast.success(
          `${verb} ${targets.length} review${targets.length === 1 ? "" : "s"} (Solid stub)`,
          "Reviews",
        )
        return { settled: targets, failed: [] }
      },
    })
  }

  const openSessions = () => {
    setComposerFocused(false)
    // Re-read signals inside the element factory: push/pop remounts the list
    // when rename stacks above it, so a frozen sessions snapshot would lose renames.
    dialog.replace(
      () => (
        <SessionListDialog
          sessions={sessions()}
          activeId={activeSessionId()}
          onSelect={(session) => {
            setActiveSessionId(session.id)
            toast.info(`Opened · ${session.title}`, "Session")
          }}
          onRename={(session, title) => {
            setSessions((prev) =>
              prev.map((item) => (item.id === session.id ? { ...item, title } : item)),
            )
            toast.success(`Renamed · ${title}`, "Session")
          }}
          onCreate={() => {
            const id = `sess-${Date.now().toString(36)}`
            const created: SolidSessionEntry = {
              id,
              title: "New session",
              directory: directory(),
            }
            setSessions((prev) => [created, ...prev])
            setActiveSessionId(id)
            toast.success("Created new session (Solid stub)", "Session")
          }}
        />
      ),
      { size: "large" },
    )
  }

  const commands = createMemo(() =>
    buildPaletteCommands({
      showHelp: (compact) => {
        openDialogHelp(dialog, { compact: compact ?? true })
      },
      runSlash: (command) => {
        setNotice(`Slash · ${command} (Solid stub — wire to session handler next)`)
      },
      cycleTheme: () => {
        const next = nextBuiltinThemeId(themeId())
        setThemeId(next)
        toast.info(`Theme · ${next} (cycle stub · /theme persists on legacy path)`, "Theme")
        return next
      },
      showSessions: () => {
        openSessions()
      },
      toggleActivity: () => {
        setActivityToggleTick((tick) => tick + 1)
        toast.info(`Toggled latest group (${activityToggleShortcut.label})`, "Activity")
      },
      previousUserMessage: () => {
        messageNavTick += 1
        setMessageNavRequest({ tick: messageNavTick, direction: "prev", userOnly: true })
      },
      nextUserMessage: () => {
        messageNavTick += 1
        setMessageNavRequest({ tick: messageNavTick, direction: "next", userOnly: true })
      },
      lastUserMessage: () => {
        messageNavTick += 1
        setMessageNavRequest({ tick: messageNavTick, action: "last-user" })
      },
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
      openReviews: () => {
        openReviews()
      },
      showToast: () => {
        toast.show({
          variant: "info",
          title: "Toast",
          message: "Solid mint notice · hover pauses · click dismisses",
          duration: 8_000,
        })
      },
      showConfirm: () => {
        openDialogConfirm(dialog, {
          title: "Confirm",
          message: "Apply this Solid shell action?",
          onConfirm: () => {
            toast.success("Confirmed (Solid DialogConfirm)", "Confirm")
          },
          onCancel: () => {
            toast.info("Cancelled", "Confirm")
          },
        })
      },
      showThemeList: () => {
        openDialogThemeList(dialog, {
          current: themeId(),
          onPreview: (id) => setThemeId(id),
          onSelect: (id) => {
            setThemeId(id)
            toast.info(`Theme · ${id} (Solid list · /theme persists on legacy path)`, "Theme")
          },
        })
      },
      showModelPicker: () => {
        setComposerFocused(false)
        openModelDialog(dialog, {
          models: demoModels(),
          favorites: demoFavoriteModels(),
          recents: demoRecentModels(),
          current: activeModel(),
          onSelect: (model) => {
            setActiveModel(model)
            toast.success(`Model · ${model.name}`, "Models")
          },
        })
      },
      showStash: () => {
        setComposerFocused(false)
        openStashDialog(dialog, {
          entries: stashEntries(),
          onSelect: (entry) => {
            setStashEntries((prev) => prev.filter((item) => item.id !== entry.id))
            setNotice(`Stash restored · ${entry.text.slice(0, 60)}`)
            toast.success("Stash restored into notice (composer wire next)", "Stash")
          },
        })
      },
      showErrorDetails: () => {
        setComposerFocused(false)
        openErrorDetailsDialog(dialog, {
          ...demoErrorDetails(),
          onCopy: () => toast.info("Error details copied (stub)", "Error"),
        })
      },
      showShellOutput: () => {
        setComposerFocused(false)
        openShellOutputDialog(dialog, demoShellOutput())
      },
      showMcp: () => {
        setComposerFocused(false)
        openMcpDialog(dialog, {
          servers: demoMcpServers(),
          onSelect: (server) => {
            toast.info(`MCP · ${server.name} · ${server.status}`, "MCP")
          },
        })
      },
      showPlugins: () => {
        setComposerFocused(false)
        openDialogAlert(dialog, {
          title: "Plugins",
          message:
            "Demo shell · LiveApp lists managed plugin links via /plugins. Use /plugin add <path> (headless) to link a local Agent Plugin package.",
          onConfirm: () => setComposerFocused(true),
        })
      },
      showSkills: () => {
        setComposerFocused(false)
        openSkillDialog(dialog, {
          skills: demoSkills(),
          onSelect: (skill) => {
            setNotice(`Skill · $${skill.key} (Solid stub — composer insert next)`)
            toast.success(`Selected · $${skill.key}`, "Skills")
          },
        })
      },
      showExport: () => {
        setComposerFocused(false)
        openDialogExportOptions(dialog, {
          defaultThinking: true,
          onConfirm: (options) => {
            if (options.action === "copy") {
              dialog.clear()
              toast.success(
                `Copied · ${options.format}${options.thinking ? " · thinking" : ""}${options.tools ? " · tools" : ""}`,
                "Export",
              )
              return
            }
            const ext = options.format === "json" ? "json" : "md"
            const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")
            openDialogExportResult(dialog, {
              path: `~/veasel-exports/veasel-session-${stamp}.${ext}`,
            })
          },
        })
      },
      showOpen: () => {
        setComposerFocused(false)
        openOpenDialog(dialog, {
          recentSessions: sessions(),
          projects: demoOpenProjects(),
          worktreesByProject: groupWorktreesByProject(demoOpenWorktrees()),
          onOpenSession: (session) => {
            setActiveSessionId(session.id)
            toast.info(`Opened · ${session.title}`, "Open")
          },
          onOpenWorktree: (worktree) => {
            setNotice(`Worktree · ${worktree.path} (fixture stub — LiveApp uses session HTTP)`)
            toast.success(`Opened worktree · ${worktree.name}`, "Open")
          },
        })
      },
      showStatus: () => {
        setComposerFocused(false)
        const model = activeModel()
        openStatusDialog(dialog, {
          ...demoStatusSnapshot(),
          sessionTitle: sessionTitle(),
          directory: directory(),
          model: model.name,
          provider: model.providerID,
          agent: activeAgent(),
          variant: activeVariant() ?? "default",
          mcpServers: demoMcpServers(),
        })
      },
      showAgent: () => {
        setComposerFocused(false)
        openAgentDialog(dialog, {
          agents: demoAgents(),
          current: activeAgent(),
          onSelect: (agent) => {
            setActiveAgent(agent.id)
            toast.success(`Agent · ${agent.id}`, "Agents")
          },
        })
      },
      showVariant: () => {
        setComposerFocused(false)
        openVariantDialog(dialog, {
          variants: demoVariants(),
          current: activeVariant() ?? "default",
          onSelect: (variant) => {
            setActiveVariant(variant)
            toast.info(`Variant · ${variant ?? "default"}`, "Models")
          },
        })
      },
      showWorkspaces: () => {
        setComposerFocused(false)
        openWorkspacesDialog(dialog, {
          workspaces: workspaces(),
          current: activeWorkspaceId(),
          onSelect: (workspace) => {
            setActiveWorkspaceId(workspace.id)
            toast.info(`Workspace · ${workspace.name}`, "Workspaces")
          },
          onCreateWorktree: (name) => {
            const created: SolidWorkspace = {
              id: `wt-${Date.now().toString(36)}`,
              name,
              path: `~/.ai-workspace/worktrees/${name}`,
              kind: "worktree",
            }
            setWorkspaces((prev) => [...prev, created])
            setActiveWorkspaceId(created.id)
            toast.success(`Worktree · ${name} (Solid stub)`, "Workspaces")
          },
        })
      },
      showUpdate: () => {
        setComposerFocused(false)
        openUpdateDialog(dialog, {
          state: demoUpdateAvailable(),
          onSkip: () => toast.info("Skipped update (stub)", "Update"),
          onInstall: () => toast.success("Install queued (stub)", "Update"),
        })
      },
      showPair: () => {
        setComposerFocused(false)
        openPairDialog(dialog)
      },
      showHighlights: () => {
        setComposerFocused(false)
        openHighlightsDialog(dialog)
      },
      showImagePreview: () => {
        setComposerFocused(false)
        openImagePreviewDialog(dialog, demoImagePreview())
      },
    }),
  )

  const onSubmit = (text: string) => {
    props.onSubmit?.(text)
    if (!props.managed) {
      setMessages((prev) => [...prev, { role: "user", content: text }])
    }
  }

  const openPalette = () => {
    setComposerFocused(false)
    openCommandPalette(dialog, commands())
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
      commands().find((command) => command.id === "veasel.open.dialog")?.run()
      return
    }
    if (key.ctrl && key.name === reviewShortcut.name && !key.meta) {
      key.preventDefault()
      openReviews()
    }
  })

  createEffect(() => {
    if (!dialog.open()) setComposerFocused(true)
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
        <text fg={colors.localStatus}>● {status()}</text>
      </box>

      <Show
        when={messages().length > 0 || props.streaming}
        fallback={
          <box width="100%" flexGrow={1} flexDirection="column">
            <HomeSplash
              theme={themes[themeId()] ?? themes.mint}
              directory={directory()}
            />
            <SolidComposer onSubmit={onSubmit} focused={composerFocused()} />
          </box>
        }
      >
        <box
          width="100%"
          height={2}
          flexShrink={0}
          flexDirection="row"
          alignItems="center"
          backgroundColor={colors.panelBg}
          border
          borderColor={colors.panelBorder}
          paddingLeft={1}
          paddingRight={1}
        >
          <text fg={colors.muted}>SESSION </text>
          <text fg={colors.body}>{sessionTitle()}</text>
          <text fg={colors.muted}>
            {" "}
            · {paletteShortcut.label} commands · {activityToggleShortcut.label} activity ·{" "}
            {reviewShortcut.label} reviews
          </text>
        </box>

        <SolidTranscript
          messages={messages}
          session={{ title: sessionTitle(), directory: directory() }}
          notice={notice() || props.notice}
          streaming={props.streaming}
          streamingText={props.streamingText}
          streamingCursor={props.streamingCursor}
          followTail={props.followTail}
          scrollRef={props.scrollRef}
          enableActivityKeys={!dialog.open()}
          activityToggleTick={activityToggleTick()}
          thinkingToggleTick={thinkingToggleTick()}
          messageNavRequest={messageNavRequest}
          verbosity={verbosity}
          onMessageNavigated={(info) => {
            toast.info(`Jumped to ${info.role} message`, "Transcript")
          }}
          cols={80}
        />

        <SolidComposer onSubmit={onSubmit} focused={composerFocused()} />
      </Show>
    </box>
  )
}

// Veasel-branded Solid shell: header + session chrome + transcript + composer
// + toast host / dialog host / command palette / review panel.
// Live HTTP session loop mounts via LiveApp (default `bun run start`).
export function App(props: SolidAppProps = {}) {
  return (
    <SolidThemeProvider initialTheme={defaultThemeId}>
      <ToastProvider>
        <DialogProvider>
          <AppShell {...props} />
        </DialogProvider>
      </ToastProvider>
    </SolidThemeProvider>
  )
}

/** Build padded fixture turns for scroll / follow-tail tests. */
export function fixtureTurns(count: number, pad = "padding "): ToolAwareMessage[] {
  const turns: ToolAwareMessage[] = []
  for (let index = 0; index < count; index++) {
    const role = index % 2 === 0 ? "user" : "assistant"
    turns.push({
      role,
      content: `Turn ${index + 1}: ${pad.repeat(6)}${role === "user" ? "ask" : "reply"}`,
    })
  }
  return turns
}
