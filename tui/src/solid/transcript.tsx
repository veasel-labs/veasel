/** @jsxImportSource @opentui/solid */
import { For, Show, createEffect, createMemo, createSignal, on, type Accessor } from "solid-js"
import type { KeyEvent, ScrollBoxRenderable } from "@opentui/core"
import { useKeyboard } from "@opentui/solid"
import type { ChatTurn } from "../chat-history"
import {
  assistantLabel,
  transcriptSegments,
  userLabel,
  type TranscriptInput,
  type TranscriptMessage,
  type TranscriptSegment,
  type TranscriptTone,
} from "../transcript"
import { transcriptSegmentLines } from "../transcript-scroll"
import {
  activityGroupHeader,
  activityItemLine,
  activityToggleShortcut,
  isGroupExpanded,
  latestActivityGroupId,
  projectTranscriptBlocks,
  summarizeActivityGroup,
  toggleGroupExpanded,
  type ToolAwareMessage,
  type ToolCallItem,
  type TranscriptBlock,
} from "./activity-group"
import { solidMint, solidToneBold, solidToneFg } from "./theme"

/** Map durable chat-history turns into transcript message shape. */
export function transcriptMessagesFromChatTurns(turns: ChatTurn[]): TranscriptMessage[] {
  return turns.map((turn) => ({ role: turn.role, content: turn.content }))
}

export type SolidTranscriptProps = {
  messages: ToolAwareMessage[] | Accessor<ToolAwareMessage[]>
  session?: TranscriptInput["session"]
  notice?: string
  pendingUserMessage?: string
  streaming?: boolean
  streamingText?: string
  streamingCursor?: string
  hasOlder?: boolean
  cols?: number
  /** Stick to latest lines while content grows (streaming follow-tail). */
  followTail?: boolean
  /** Optional ref to the OpenTUI scrollbox for tests / focus. */
  scrollRef?: (box: ScrollBoxRenderable | undefined) => void
  /** When false, skip Ctrl+G handling (e.g. while a dialog owns keys). */
  enableActivityKeys?: boolean
  /**
   * Incrementing tick from the parent (palette / tests) toggles the latest
   * activity group the same way Ctrl+G does.
   */
  activityToggleTick?: number | Accessor<number>
}

function resolveMessages(
  messages: ToolAwareMessage[] | Accessor<ToolAwareMessage[]>,
): ToolAwareMessage[] {
  return typeof messages === "function" ? messages() : messages
}

function SegmentSpan(props: { segment: TranscriptSegment }) {
  const fg = () => solidToneFg(props.segment.tone)
  const bold = () => solidToneBold(props.segment.tone)
  return (
    <Show
      when={bold()}
      fallback={<span style={{ fg: fg() }}>{props.segment.text}</span>}
    >
      <span style={{ fg: fg() }}>
        <strong>{props.segment.text}</strong>
      </span>
    </Show>
  )
}

function SegmentLines(props: { segments: TranscriptSegment[] }) {
  const lines = createMemo(() => transcriptSegmentLines(props.segments))
  return (
    <For each={lines()}>
      {(line) => (
        <text wrapMode="none">
          <For each={line}>{(segment) => <SegmentSpan segment={segment} />}</For>
        </text>
      )}
    </For>
  )
}

function statusFg(status: ToolCallItem["status"]): string {
  // Mint status tokens — same family as themes.ts statusOk / statusError / localStatus.
  if (status === "error") return solidMint.statusError
  if (status === "running") return solidMint.localStatus
  return solidMint.statusOk
}

function ActivityGroupView(props: {
  block: Extract<TranscriptBlock, { type: "activity" }>
  expanded: boolean
  onToggle: () => void
}) {
  const summary = createMemo(() => summarizeActivityGroup(props.block.items))
  return (
    <box flexDirection="column" width="100%" marginTop={1} marginBottom={1}>
      <box flexDirection="row" width="100%" onMouseUp={() => props.onToggle()}>
        <text wrapMode="none">
          <span style={{ fg: solidMint.brand }}>
            <strong>{activityGroupHeader(props.block.items, props.expanded)}</strong>
          </span>
        </text>
      </box>
      <text wrapMode="none">
        <span style={{ fg: statusFg(summary().status) }}>
          {"  "}status  ·  {summary().statusWord}
          {"  ·  "}
          {activityToggleShortcut.label} toggle
        </span>
      </text>
      <Show when={props.expanded}>
        <For each={props.block.items}>
          {(item) => (
            <text wrapMode="none">
              <span style={{ fg: statusFg(item.status) }}>{activityItemLine(item)}</span>
            </text>
          )}
        </For>
      </Show>
    </box>
  )
}

// Session transcript on OpenTUI scrollbox. Tone tags and role copy come from
// transcript.ts; consecutive tool roles collapse into mint activity groups.
export function SolidTranscript(props: SolidTranscriptProps) {
  const followTail = () => props.followTail !== false
  const keysEnabled = () => props.enableActivityKeys !== false
  const [expanded, setExpanded] = createSignal<Record<string, boolean>>({})

  const resolved = createMemo(() => resolveMessages(props.messages))
  const blocks = createMemo(() => projectTranscriptBlocks(resolved()))

  const chromeSegments = createMemo(() => {
    if (!props.session && !props.notice) return [] as TranscriptSegment[]
    return transcriptSegments({
      session: props.session,
      notice: props.notice,
      messages: [],
      showMessages: false,
      cols: props.cols,
    })
  })

  const trailSegments = createMemo(() => {
    const empty = resolved().length === 0
    const hasTrail = Boolean(
      props.pendingUserMessage || props.streaming || props.streamingText || props.hasOlder || empty,
    )
    if (!hasTrail) return [] as TranscriptSegment[]
    return transcriptSegments({
      messages: [],
      pendingUserMessage: props.pendingUserMessage,
      streaming: props.streaming,
      streamingText: props.streamingText,
      streamingCursor: props.streamingCursor,
      hasOlder: props.hasOlder,
      cols: props.cols,
    })
  })

  const toggleGroup = (groupId: string) => {
    setExpanded((prev) => toggleGroupExpanded(prev, groupId))
  }

  const toggleLatest = () => {
    const id = latestActivityGroupId(blocks())
    if (!id) return false
    toggleGroup(id)
    return true
  }

  useKeyboard((key: KeyEvent) => {
    if (!keysEnabled()) return
    if (!(key.ctrl && key.name === activityToggleShortcut.name && !key.meta)) return
    if (!toggleLatest()) return
    key.preventDefault()
  })

  createEffect(
    on(
      () =>
        typeof props.activityToggleTick === "function"
          ? props.activityToggleTick()
          : (props.activityToggleTick ?? 0),
      (tick, prev) => {
        if (prev === undefined || tick === prev || tick <= 0) return
        toggleLatest()
      },
    ),
  )

  return (
    <scrollbox
      ref={(box: ScrollBoxRenderable) => {
        props.scrollRef?.(box)
      }}
      width="100%"
      flexGrow={1}
      backgroundColor={solidMint.shellBg}
      stickyScroll={followTail()}
      stickyStart="bottom"
      scrollX={false}
      scrollY={true}
      viewportOptions={{
        backgroundColor: solidMint.shellBg,
      }}
      contentOptions={{
        backgroundColor: solidMint.shellBg,
      }}
    >
      <box
        width="100%"
        flexDirection="column"
        paddingLeft={1}
        paddingRight={1}
        paddingTop={1}
        paddingBottom={1}
        gap={0}
      >
        <Show when={chromeSegments().length > 0}>
          <SegmentLines segments={chromeSegments()} />
        </Show>
        <For each={blocks()}>
          {(block) => (
            <Show
              when={block.type === "activity"}
              fallback={
                <SegmentLines
                  segments={transcriptSegments({
                    messages: (block as Extract<TranscriptBlock, { type: "messages" }>).messages,
                    cols: props.cols,
                  })}
                />
              }
            >
              <ActivityGroupView
                block={block as Extract<TranscriptBlock, { type: "activity" }>}
                expanded={isGroupExpanded(
                  expanded(),
                  (block as Extract<TranscriptBlock, { type: "activity" }>).id,
                  (block as Extract<TranscriptBlock, { type: "activity" }>).items,
                )}
                onToggle={() =>
                  toggleGroup((block as Extract<TranscriptBlock, { type: "activity" }>).id)
                }
              />
            </Show>
          )}
        </For>
        <Show when={trailSegments().length > 0}>
          <SegmentLines segments={trailSegments()} />
        </Show>
      </box>
    </scrollbox>
  )
}

export { userLabel, assistantLabel, activityToggleShortcut }
export type { TranscriptMessage, TranscriptTone, ToolAwareMessage, ToolCallItem }
