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
import { themes, defaultThemeId, type BuiltinThemeId } from "../themes"
import { DialogProvider, useDialog } from "./ui/dialog"
import { ToastProvider, useToast } from "./ui/toast"
import { SolidComposer } from "./composer"
import { SolidTranscript, transcriptMessagesFromChatTurns, type ToolAwareMessage } from "./transcript"
import { LiveHome } from "./component/live-home"
import { openProviderSettingsDialog } from "./component/provider-settings-dialog"
import { solidMint } from "./theme"
import type { SolidSessionEntry } from "./component/session-list-dialog"

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
  const [themeId] = createSignal<BuiltinThemeId>(defaultThemeId)
  const [composerFocused, setComposerFocused] = createSignal(true)
  const [activeTurnId, setActiveTurnId] = createSignal<string | undefined>()
  let turnController: AbortController | undefined
  const handledCompletions = new Set<string>()

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

  useKeyboard((key: KeyEvent) => {
    if (dialog.open()) return
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
            void sendMessage(text)
          }}
          focused={composerFocused()}
        />
        <box width="100%" height={1} flexShrink={0} paddingLeft={1}>
          <text fg={solidMint.muted}>{homeFooterHint}</text>
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
