/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, type Accessor } from "solid-js"
import type { ScrollBoxRenderable } from "@opentui/core"
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
import { solidMint, solidToneBold, solidToneFg } from "./theme"

/** Map durable chat-history turns into transcript message shape. */
export function transcriptMessagesFromChatTurns(turns: ChatTurn[]): TranscriptMessage[] {
  return turns.map((turn) => ({ role: turn.role, content: turn.content }))
}

export type SolidTranscriptProps = {
  messages: TranscriptMessage[] | Accessor<TranscriptMessage[]>
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
}

function resolveMessages(
  messages: TranscriptMessage[] | Accessor<TranscriptMessage[]>,
): TranscriptMessage[] {
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

// Session transcript on OpenTUI scrollbox. Tone tags and role copy come from
// transcript.ts; this component only mounts them — no forked business rules.
export function SolidTranscript(props: SolidTranscriptProps) {
  const followTail = () => props.followTail !== false

  const segments = createMemo(() =>
    transcriptSegments({
      session: props.session,
      notice: props.notice,
      messages: resolveMessages(props.messages),
      pendingUserMessage: props.pendingUserMessage,
      streaming: props.streaming,
      streamingText: props.streamingText,
      streamingCursor: props.streamingCursor,
      hasOlder: props.hasOlder,
      cols: props.cols,
    }),
  )

  const lines = createMemo(() => transcriptSegmentLines(segments()))

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
        <For each={lines()}>
          {(line) => (
            <text wrapMode="none">
              <For each={line}>{(segment) => <SegmentSpan segment={segment} />}</For>
            </text>
          )}
        </For>
      </box>
    </scrollbox>
  )
}

export { userLabel, assistantLabel }
export type { TranscriptMessage, TranscriptTone }
