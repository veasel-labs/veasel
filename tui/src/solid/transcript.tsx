/** @jsxImportSource @opentui/solid */
import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, type Accessor } from "solid-js"
import type { KeyEvent, Renderable, ScrollBoxRenderable } from "@opentui/core"
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
import { scrollOffsetFromBottom, transcriptBelowCue, transcriptSegmentLines } from "../transcript-scroll"
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
import {
  blockMountWeight,
  blocksAfter,
  blocksBefore,
  mountCueAbove,
  transcriptBackfillChunk,
  transcriptTailBudget,
  windowBlocks,
} from "./mount-budget"
import { solidMint, solidToneBold, solidToneFg } from "./theme"
import {
  findAdjacentMessageTarget,
  findLastUserMessageTarget,
  findMessageBoundaryByScroll,
  listMessageNavTargets,
  messageNavShortcut,
  type TranscriptNavDirection,
} from "./transcript-nav"
import {
  applyTranscriptVerbosity,
  verbosityExpandsActivity,
  type TranscriptVerbosity,
} from "./transcript-verbosity"
import {
  contentHasThinking,
  isThinkingExpanded,
  latestThinkingId,
  splitThinkingParts,
  thinkingHeader,
  thinkingToggleShortcut,
  toggleThinkingExpanded,
} from "./thinking-blocks"

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
  /**
   * Palette / parent-driven message jump. Each increment with a direction
   * runs the same navigation path as Alt+[ / Alt+] / Alt+End.
   */
  messageNavRequest?: Accessor<
    | { tick: number; direction: TranscriptNavDirection; userOnly?: boolean }
    | { tick: number; action: "last-user" }
    | undefined
  >
  /** Fired after a successful jump (status / toast). */
  onMessageNavigated?: (info: { index: number; role: string }) => void
  /** Transcript verbosity (quiet / default / everything). */
  verbosity?: TranscriptVerbosity | Accessor<TranscriptVerbosity>
  /**
   * Incrementing tick from the parent (palette / tests) toggles the latest
   * thinking block the same way Ctrl+H does.
   */
  thinkingToggleTick?: number | Accessor<number>
  /** Rendered-entry budget for the initial sticky-tail window. */
  mountBudget?: number
  /** Extra weight to mount when the viewport approaches the top. */
  backfillChunk?: number
  /** Fired when the operator pages away from / back to the sticky bottom. */
  onScrollViewport?: (info: { offsetFromBottom: number }) => void
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

function ThinkingBlockView(props: {
  id: string
  text: string
  expanded: boolean
  onToggle: () => void
}) {
  return (
    <box flexDirection="column" width="100%" marginTop={0} marginBottom={0}>
      <box flexDirection="row" width="100%" onMouseUp={() => props.onToggle()}>
        <text wrapMode="none">
          <span style={{ fg: solidMint.muted }}>
            <strong>{thinkingHeader(props.expanded, props.text)}</strong>
          </span>
        </text>
      </box>
      <text wrapMode="none">
        <span style={{ fg: solidMint.muted }}>
          {"  "}
          {thinkingToggleShortcut.label} toggle
        </span>
      </text>
      <Show when={props.expanded}>
        <text wrapMode="word">
          <span style={{ fg: solidMint.muted }}>
            {"  "}
            {props.text}
          </span>
        </text>
      </Show>
    </box>
  )
}

function bodySegmentsWithoutLabel(message: ToolAwareMessage, cols?: number): TranscriptSegment[] {
  const segments = transcriptSegments({
    messages: [{ role: message.role, content: message.content }],
    cols,
  })
  // First segment is the spoken role label; keep indented body only.
  return segments.slice(1)
}

function MessageBlockView(props: {
  messages: ToolAwareMessage[]
  startIndex: number
  cols?: number
  thinkingExpanded: Record<string, boolean>
  onToggleThinking: (id: string) => void
}) {
  const message = () => props.messages[0]
  const hasThinking = createMemo(() => {
    const msg = message()
    return Boolean(msg && contentHasThinking(msg.content))
  })
  const parts = createMemo(() => {
    const msg = message()
    if (!msg) return []
    return splitThinkingParts(msg.content, `m${props.startIndex}`)
  })

  return (
    <Show
      when={hasThinking() ? message() : undefined}
      fallback={
        <SegmentLines
          segments={transcriptSegments({
            messages: props.messages,
            cols: props.cols,
          })}
        />
      }
    >
      {(msg) => (
        <box flexDirection="column" width="100%">
          <SegmentLines
            segments={transcriptSegments({
              messages: [{ role: msg().role, content: "" }],
              cols: props.cols,
            })}
          />
          <For each={parts()}>
            {(part) => (
              <Show
                when={part.type === "thinking"}
                fallback={
                  <Show when={part.type === "text" && part.text.trim()}>
                    <SegmentLines
                      segments={bodySegmentsWithoutLabel(
                        {
                          role: msg().role,
                          content: part.type === "text" ? part.text.replace(/^\n+/, "") : "",
                        },
                        props.cols,
                      )}
                    />
                  </Show>
                }
              >
                <ThinkingBlockView
                  id={part.type === "thinking" ? part.id : ""}
                  text={part.type === "thinking" ? part.text : ""}
                  expanded={
                    part.type === "thinking"
                      ? isThinkingExpanded(props.thinkingExpanded, part.id)
                      : false
                  }
                  onToggle={() => {
                    if (part.type === "thinking") props.onToggleThinking(part.id)
                  }}
                />
              </Show>
            )}
          </For>
        </box>
      )}
    </Show>
  )
}

// Session transcript on OpenTUI scrollbox. Tone tags and role copy come from
// transcript.ts; consecutive tool roles collapse into mint activity groups.
// Long sessions mount a sticky-tail budget first, then backfill near the top.
export function SolidTranscript(props: SolidTranscriptProps) {
  const followTail = () => props.followTail !== false
  const keysEnabled = () => props.enableActivityKeys !== false
  const tailBudget = () => props.mountBudget ?? transcriptTailBudget
  const backfill = () => props.backfillChunk ?? transcriptBackfillChunk
  const [expanded, setExpanded] = createSignal<Record<string, boolean>>({})
  const [thinkingExpanded, setThinkingExpanded] = createSignal<Record<string, boolean>>({})
  const [hiddenStart, setHiddenStart] = createSignal<number | undefined>(undefined)
  const [visibleEnd, setVisibleEnd] = createSignal<number | undefined>(undefined)
  const [navIndex, setNavIndex] = createSignal<number | undefined>(undefined)
  const [offsetFromBottom, setOffsetFromBottom] = createSignal(0)
  /** Operator left the sticky bottom (Home/PgUp/jump); End re-engages follow. */
  const [followDetached, setFollowDetached] = createSignal(false)
  let scrollBox: ScrollBoxRenderable | undefined
  let revealingOlder = false
  let lastReportedOffset = -1
  const anchors = new Map<number, Pick<Renderable, "y" | "height" | "isDestroyed">>()
  const stickyFollow = () => followTail() && !followDetached()

  const sampleViewport = () => {
    if (!scrollBox || scrollBox.isDestroyed) return
    const viewportHeight = scrollBox.viewport?.height ?? scrollBox.height
    const geometric = scrollOffsetFromBottom({
      scrollTop: scrollBox.scrollTop,
      scrollHeight: scrollBox.scrollHeight,
      viewportHeight,
    })
    // While detached, keep a non-zero report so status/cues stay honest even if
    // sticky geometry has not finished catching up after Home/PgUp.
    const next = followDetached() ? Math.max(geometric, 1) : geometric
    setOffsetFromBottom(geometric)
    if (next !== lastReportedOffset) {
      lastReportedOffset = next
      props.onScrollViewport?.({ offsetFromBottom: next })
    }
  }

  const resolved = createMemo(() => resolveMessages(props.messages))
  const verbosity = (): TranscriptVerbosity => {
    const value = props.verbosity
    if (typeof value === "function") return value()
    return value ?? "default"
  }
  const displayMessages = createMemo(() => applyTranscriptVerbosity(resolved(), verbosity()))
  const blocks = createMemo(() => projectTranscriptBlocks(displayMessages()))

  const registerAnchor = (index: number, node: Pick<Renderable, "y" | "height" | "isDestroyed">) => {
    anchors.set(index, node)
  }

  const anchorPositions = () =>
    [...anchors.entries()]
      .filter(([, node]) => !node.isDestroyed && node.height > 0)
      .map(([index, node]) => ({ index, y: node.y }))
      .sort((a, b) => a.y - b.y)

  const ensureMessageMounted = (messageIndex: number) => {
    const all = blocks()
    const blockIndex = all.findIndex(
      (block) => block.type === "messages" && block.startIndex === messageIndex,
    )
    if (blockIndex < 0) return
    const start = mountStart()
    const end = mountEnd()
    if (blockIndex < start) setHiddenStart(blockIndex)
    if (blockIndex >= end) setVisibleEnd(blockIndex + 1)
  }

  const jumpToMessageIndex = (messageIndex: number) => {
    ensureMessageMounted(messageIndex)
    setNavIndex(messageIndex)
    setFollowDetached(true)
    const role = displayMessages()[messageIndex]?.role ?? "user"
    queueMicrotask(() => {
      if (!scrollBox || scrollBox.isDestroyed) return
      scrollBox.stickyScroll = false
      const node = anchors.get(messageIndex)
      if (node && !node.isDestroyed && node.height > 0) {
        const top = Math.max(0, scrollBox.scrollTop + node.y - (scrollBox.viewport?.y ?? 0))
        scrollBox.scrollTo(top)
      }
      sampleViewport()
      props.onMessageNavigated?.({ index: messageIndex, role })
    })
    return true
  }

  const navigateMessages = (direction: TranscriptNavDirection, userOnly = true) => {
    const targets = listMessageNavTargets(displayMessages(), { userOnly })
    if (targets.length === 0) return false
    const positions = anchorPositions().filter((child) =>
      targets.some((target) => target.index === child.index),
    )
    if (positions.length > 0 && scrollBox && !scrollBox.isDestroyed) {
      const boundary = findMessageBoundaryByScroll({
        direction,
        children: positions,
        scrollTop: scrollBox.scrollTop,
        currentIndex: navIndex(),
      })
      if (boundary) return jumpToMessageIndex(boundary.index)
    }
    const next = findAdjacentMessageTarget({
      targets,
      currentIndex: navIndex(),
      direction,
    })
    if (!next) return false
    return jumpToMessageIndex(next.index)
  }

  const jumpLastUser = () => {
    const target = findLastUserMessageTarget(displayMessages())
    if (!target) return false
    return jumpToMessageIndex(target.index)
  }

  const groupIsExpanded = (groupId: string, items: ToolCallItem[]) => {
    if (verbosityExpandsActivity(verbosity())) return true
    return isGroupExpanded(expanded(), groupId, items)
  }

  const weights = createMemo(() =>
    blocks().map((block) =>
      blockMountWeight(block, (groupId) =>
        block.type === "activity" ? groupIsExpanded(groupId, block.items) : false,
      ),
    ),
  )

  const mountStart = createMemo(() => {
    const all = blocks().length
    const fallback = blocksBefore(weights(), all, tailBudget())
    return Math.min(hiddenStart() ?? fallback, fallback)
  })

  const mountEnd = createMemo(() => {
    const all = blocks().length
    const start = mountStart()
    const end = visibleEnd() ?? all
    return Math.max(start, Math.min(end, all))
  })

  const mounted = createMemo(() => windowBlocks(blocks(), mountStart(), mountEnd()))

  // Follow appends while sticky-tail is active: keep the hidden span at the budgeted start.
  // Any explicit mount window (including Home → start at 0) is preserved until End.
  createEffect(
    on(
      () => [blocks().length, weights().join(","), followTail(), followDetached()] as const,
      () => {
        if (!stickyFollow()) return
        if (hiddenStart() !== undefined) return
        setHiddenStart(undefined)
        setVisibleEnd(undefined)
      },
    ),
  )

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
    const empty = displayMessages().length === 0 && resolved().length === 0
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

  // Reset message cursor when verbosity changes so geometry matches the new list.
  createEffect(
    on(
      () => verbosity(),
      () => {
        setNavIndex(undefined)
      },
    ),
  )

  const toggleGroup = (groupId: string) => {
    setExpanded((prev) => toggleGroupExpanded(prev, groupId))
  }

  const toggleLatest = () => {
    const id = latestActivityGroupId(blocks())
    if (!id) return false
    toggleGroup(id)
    return true
  }

  const toggleThinking = (id: string) => {
    setThinkingExpanded((prev) => toggleThinkingExpanded(prev, id))
  }

  const toggleLatestThinking = () => {
    const id = latestThinkingId(resolved())
    if (!id) return false
    toggleThinking(id)
    return true
  }

  const revealOlder = () => {
    const current = mountStart()
    if (revealingOlder || current <= 0 || !scrollBox || scrollBox.isDestroyed) return false
    if (scrollBox.scrollTop > Math.max(1, scrollBox.height)) return false
    revealingOlder = true
    const before = scrollBox.scrollHeight
    const wasSticky = scrollBox.stickyScroll
    scrollBox.stickyScroll = false
    setHiddenStart(blocksBefore(weights(), current, backfill()))
    queueMicrotask(() => {
      if (scrollBox && !scrollBox.isDestroyed) {
        const delta = scrollBox.scrollHeight - before
        if (delta !== 0) scrollBox.scrollBy(delta)
        scrollBox.stickyScroll = wasSticky && stickyFollow()
      }
      revealingOlder = false
    })
    return true
  }

  const revealNewer = () => {
    const current = mountEnd()
    const all = blocks().length
    if (current >= all || !scrollBox || scrollBox.isDestroyed) return false
    const next = blocksAfter(weights(), current, backfill())
    setVisibleEnd(next >= all ? undefined : next)
    return true
  }

  useKeyboard((key: KeyEvent) => {
    if (!keysEnabled()) return
    if (key.ctrl && key.name === activityToggleShortcut.name && !key.meta) {
      if (!toggleLatest()) return
      key.preventDefault()
      return
    }
    if (key.ctrl && key.name === thinkingToggleShortcut.name && !key.meta) {
      if (!toggleLatestThinking()) return
      key.preventDefault()
      return
    }
    if (key.meta && key.name === messageNavShortcut.previousUser.name && !key.ctrl) {
      if (navigateMessages("prev", true)) key.preventDefault()
      return
    }
    if (key.meta && key.name === messageNavShortcut.nextUser.name && !key.ctrl) {
      if (navigateMessages("next", true)) key.preventDefault()
      return
    }
    if (key.meta && key.name === messageNavShortcut.lastUser.name && !key.ctrl) {
      if (jumpLastUser()) key.preventDefault()
      return
    }
    if (key.name === "pageup" || key.name === "ppage") {
      setFollowDetached(true)
      if (scrollBox && !scrollBox.isDestroyed) scrollBox.stickyScroll = false
      if (revealOlder()) key.preventDefault()
      else key.preventDefault()
      queueMicrotask(sampleViewport)
      return
    }
    if (key.name === "pagedown" || key.name === "npage") {
      if (revealNewer()) key.preventDefault()
      queueMicrotask(sampleViewport)
      return
    }
    if (key.name === "home") {
      setFollowDetached(true)
      setHiddenStart(0)
      key.preventDefault()
      if (scrollBox && !scrollBox.isDestroyed) {
        scrollBox.stickyScroll = false
        scrollBox.scrollTo(0)
      }
      queueMicrotask(sampleViewport)
      return
    }
    if (key.name === "end" && !key.meta) {
      setNavIndex(undefined)
      setHiddenStart(undefined)
      setVisibleEnd(undefined)
      setFollowDetached(false)
      if (scrollBox && !scrollBox.isDestroyed) {
        scrollBox.stickyScroll = followTail()
        const maxTop = Math.max(
          0,
          scrollBox.scrollHeight - (scrollBox.viewport?.height ?? scrollBox.height),
        )
        scrollBox.scrollTo(maxTop)
      }
      queueMicrotask(sampleViewport)
    }
  })

  // Sample while streaming / after content growth so mouse-wheel scroll still updates cues.
  createEffect(() => {
    void props.streaming
    void props.streamingText
    void blocks().length
    const id = setInterval(sampleViewport, 200)
    onCleanup(() => clearInterval(id))
    queueMicrotask(sampleViewport)
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

  createEffect(
    on(
      () =>
        typeof props.thinkingToggleTick === "function"
          ? props.thinkingToggleTick()
          : (props.thinkingToggleTick ?? 0),
      (tick, prev) => {
        if (prev === undefined || tick === prev || tick <= 0) return
        toggleLatestThinking()
      },
    ),
  )

  createEffect(
    on(
      () => props.messageNavRequest?.(),
      (request, prev) => {
        if (!request || request.tick <= 0) return
        if (prev && prev.tick === request.tick) return
        if ("action" in request && request.action === "last-user") {
          jumpLastUser()
          return
        }
        if ("direction" in request) {
          navigateMessages(request.direction, request.userOnly !== false)
        }
      },
    ),
  )

  return (
    <box width="100%" flexGrow={1} flexDirection="column" backgroundColor={solidMint.shellBg}>
      <Show when={mounted().window.truncatedAbove}>
        <box width="100%" height={1} flexShrink={0} paddingLeft={1}>
          <text wrapMode="none">
            <span style={{ fg: solidMint.muted }}>
              {mountCueAbove(mounted().window.hiddenAbove)}
            </span>
          </text>
        </box>
      </Show>
      <scrollbox
        ref={(box: ScrollBoxRenderable) => {
          scrollBox = box
          props.scrollRef?.(box)
        }}
        width="100%"
        flexGrow={1}
        backgroundColor={solidMint.shellBg}
        stickyScroll={stickyFollow()}
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
          <For each={mounted().visible}>
            {(block) => (
              <Show
                when={block.type === "activity"}
                fallback={
                  <box
                    width="100%"
                    flexDirection="column"
                    ref={(node: Renderable) => {
                      const messageBlock = block as Extract<TranscriptBlock, { type: "messages" }>
                      registerAnchor(messageBlock.startIndex, node)
                    }}
                  >
                    <MessageBlockView
                      messages={(block as Extract<TranscriptBlock, { type: "messages" }>).messages}
                      startIndex={(block as Extract<TranscriptBlock, { type: "messages" }>).startIndex}
                      cols={props.cols}
                      thinkingExpanded={thinkingExpanded()}
                      onToggleThinking={toggleThinking}
                    />
                  </box>
                }
              >
                <ActivityGroupView
                  block={block as Extract<TranscriptBlock, { type: "activity" }>}
                  expanded={groupIsExpanded(
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
      <Show when={followDetached() || offsetFromBottom() > 0}>
        <box width="100%" height={1} flexShrink={0} paddingLeft={1}>
          <text wrapMode="none">
            <span style={{ fg: solidMint.statusWarn }}>
              {transcriptBelowCue({
                truncatedBelow: true,
                streaming: Boolean(props.streaming),
              }).trimStart()}
            </span>
          </text>
        </box>
      </Show>
    </box>
  )
}

export { userLabel, assistantLabel, activityToggleShortcut, messageNavShortcut, thinkingToggleShortcut }
export type { TranscriptMessage, TranscriptTone, ToolAwareMessage, ToolCallItem }
