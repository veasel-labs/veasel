/** @jsxImportSource @opentui/solid */
import { createEffect, createMemo, createSignal } from "solid-js"
import type { KeyEvent, ScrollBoxRenderable } from "@opentui/core"
import { useKeyboard } from "@opentui/solid"
import { SolidComposer } from "./composer"
import { SolidTranscript, type ToolAwareMessage } from "./transcript"
import { activityToggleShortcut } from "./activity-group"
import { solidMint } from "./theme"
import {
  buildPaletteCommands,
  nextBuiltinThemeId,
  paletteHelpText,
  paletteShortcut,
} from "./commands"
import { DialogProvider, useDialog } from "./ui/dialog"
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
import type { BuiltinThemeId } from "../themes"
import { defaultThemeId } from "../themes"
import type { ActiveReview } from "../active-review"

export type SolidAppProps = {
  status?: string
  sessionTitle?: string
  directory?: string
  /** Seed messages for the conversation pane (fixture / tests / demo). */
  initialMessages?: ToolAwareMessage[]
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
    props.initialMessages ?? demoFixture,
  )
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
  const [themeId, setThemeId] = createSignal<BuiltinThemeId>(defaultThemeId)
  const [composerFocused, setComposerFocused] = createSignal(true)
  const [activityToggleTick, setActivityToggleTick] = createSignal(0)

  const status = createMemo(() => {
    const pending = pendingStatusForReviews(reviews())
    if (pending) return pending
    return props.status ?? "LOCAL · Solid shell"
  })

  const openReviews = () => {
    setComposerFocused(false)
    openReviewPanel(dialog, {
      reviews: reviews(),
      onDecide: (decision, targets) => {
        props.onReviewDecide?.(decision, targets)
        setReviews((prev) => settleReviews(prev, targets))
        const verb = decision === "approve" ? "Approved" : "Rejected"
        toast.success(
          `${verb} ${targets.length} review${targets.length === 1 ? "" : "s"} (Solid stub)`,
          "Reviews",
        )
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
        setNotice(paletteHelpText(compact ?? true))
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
    }),
  )

  const onSubmit = (text: string) => {
    props.onSubmit?.(text)
    setMessages((prev) => [...prev, { role: "user", content: text }])
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
          <span style={{ fg: solidMint.headerMeta }}> code</span>
        </text>
        <text fg={solidMint.localStatus}>{status()}</text>
      </box>

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
        <text fg={solidMint.muted}>
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
        cols={80}
      />

      <SolidComposer onSubmit={onSubmit} focused={composerFocused()} />
    </box>
  )
}

// Veasel-branded Solid shell: header + session chrome + transcript + composer
// + toast host / dialog host / command palette / review panel.
// HTTP session wiring stays optional.
export function App(props: SolidAppProps = {}) {
  return (
    <ToastProvider>
      <DialogProvider>
        <AppShell {...props} />
      </DialogProvider>
    </ToastProvider>
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
