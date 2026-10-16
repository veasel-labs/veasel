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
import { openDialogPrompt } from "./ui/dialog-prompt"
import { buildLivePaletteCommands, nextBuiltinThemeId, paletteShortcut } from "./commands"
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
  const [activeTurnId, setActiveTurnId] = createSignal<string | undefined>()
  let turnController: AbortController | undefined
  const handledCompletions = new Set<string>()

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

  const [attachments, setAttachments] = createSignal<ComposerAttachment[]>([])

  const stageAttachmentPath = (raw: string) => {
    const resolved = resolveAttachmentPath(raw)
    if (!resolved) {
      toast.info("Path not found · enter an absolute or ~/ path", "Attach")
      return
    }
    const next = createComposerAttachment(resolved)
    setAttachments((current) => {
      const merged = addComposerAttachment(current, next)
      if (merged.length === current.length) toast.info("Already attached", "Attach")
      else toast.success(`Attached · ${next.name}`, "Attach")
      return merged
    })
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

  const inSession = createMemo(() => Boolean(activeSessionId()))
  const sessionTitle = createMemo(() => {
    const id = activeSessionId()
    return sessions().find((item) => item.id === id)?.title ?? "Session"
  })

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
          toast.info(`Selected · ${provider.name} (connect wire next)`, "MODEL SETTINGS")
          setStatus(formatHomeSessionStatus(selectedIndex(), sessions().length))
          setComposerFocused(true)
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

  const openPalette = () => {
    setComposerFocused(false)
    openCommandPalette(
      dialog,
      buildLivePaletteCommands({
        showHelp: () => openDialogHelp(dialog, { compact: true }),
        openSettings: () => {
          void openSettings()
        },
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
        attachFile: () => openAttachPrompt(),
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
    if (!inSession()) {
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
          />
        }
      >
        <box
          width="100%"
          height={2}
          flexShrink={0}
          flexDirection="row"
          alignItems="center"
          backgroundColor={solidMint.panelBg}
          border
          borderColor={solidMint.panelBorder}
          paddingLeft={1}
          paddingRight={1}
        >
          <text fg={solidMint.muted}>SESSION </text>
          <text fg={solidMint.body}>{sessionTitle()}</text>
        </box>
        <SolidTranscript
          messages={messages}
          session={{ title: sessionTitle(), directory: directory() }}
          streaming={streaming()}
          streamingText={streamingText()}
          followTail={true}
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
          workspaceRoot={directory()}
        />
        <box width="100%" height={1} flexShrink={0} paddingLeft={1}>
          <text fg={solidMint.muted}>
            {liveFooterHint} · Ctrl+S stash · attach via palette · theme {themeId()}
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
