/** @jsxImportSource @opentui/solid */
import { createSignal } from "solid-js"
import type { ScrollBoxRenderable } from "@opentui/core"
import { SolidComposer } from "./composer"
import { SolidTranscript, type TranscriptMessage } from "./transcript"
import { solidMint } from "./theme"

export type SolidAppProps = {
  status?: string
  sessionTitle?: string
  directory?: string
  /** Seed messages for the conversation pane (fixture / tests / demo). */
  initialMessages?: TranscriptMessage[]
  streaming?: boolean
  streamingText?: string
  streamingCursor?: string
  notice?: string
  followTail?: boolean
  scrollRef?: (box: ScrollBoxRenderable | undefined) => void
  onSubmit?: (text: string) => void
}

const demoFixture: TranscriptMessage[] = [
  {
    role: "user",
    content: "Show the Solid transcript pane with Veasel mint chrome.",
  },
  {
    role: "assistant",
    content:
      "Conversation turns render through transcriptSegments on an OpenTUI scrollbox.\nSticky follow-tail keeps the live reply in view while streaming.",
  },
]

// Veasel-branded Solid shell: header + session chrome + transcript + composer.
// HTTP session wiring stays optional; fixtures prove the conversation pane.
export function App(props: SolidAppProps = {}) {
  const status = () => props.status ?? "LOCAL · Solid shell"
  const sessionTitle = () => props.sessionTitle ?? "Solid transcript"
  const directory = () => props.directory ?? "~/veasel"
  const [messages, setMessages] = createSignal<TranscriptMessage[]>(
    props.initialMessages ?? demoFixture,
  )

  const onSubmit = (text: string) => {
    props.onSubmit?.(text)
    setMessages((prev) => [...prev, { role: "user", content: text }])
  }

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
      </box>

      <SolidTranscript
        messages={messages}
        session={{ title: sessionTitle(), directory: directory() }}
        notice={props.notice}
        streaming={props.streaming}
        streamingText={props.streamingText}
        streamingCursor={props.streamingCursor}
        followTail={props.followTail}
        scrollRef={props.scrollRef}
        cols={80}
      />

      <SolidComposer onSubmit={onSubmit} focused={true} />
    </box>
  )
}

/** Build padded fixture turns for scroll / follow-tail tests. */
export function fixtureTurns(count: number, pad = "padding "): TranscriptMessage[] {
  const turns: TranscriptMessage[] = []
  for (let index = 0; index < count; index++) {
    const role = index % 2 === 0 ? "user" : "assistant"
    turns.push({
      role,
      content: `Turn ${index + 1}: ${pad.repeat(6)}${role === "user" ? "ask" : "reply"}`,
    })
  }
  return turns
}
