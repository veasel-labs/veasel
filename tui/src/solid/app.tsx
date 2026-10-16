/** @jsxImportSource @opentui/solid */
import { For, createSignal } from "solid-js"
import { SolidComposer } from "./composer"
import { solidMint } from "./theme"

export type SolidAppProps = {
  status?: string
  sessionTitle?: string
}

// Veasel-branded Solid shell stub. Session/transcript wiring comes in later
// migration slices; this PR proves layout + reactive composer only.
export function App(props: SolidAppProps = {}) {
  const status = () => props.status ?? "LOCAL · Solid shell"
  const sessionTitle = () => props.sessionTitle ?? "No session"
  const [lines, setLines] = createSignal<string[]>([
    "Transcript stub — Solid migration P0.",
    "Legacy OpenTUI main.ts remains the default entry until cutover.",
  ])

  const onSubmit = (text: string) => {
    setLines((prev) => [...prev, `you › ${text}`])
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

      <scrollbox
        width="100%"
        flexGrow={1}
        backgroundColor={solidMint.shellBg}
        stickyScroll={true}
        stickyStart="bottom"
      >
        <box
          width="100%"
          flexDirection="column"
          paddingLeft={1}
          paddingRight={1}
          paddingTop={1}
          gap={0}
        >
          <For each={lines()}>
            {(line) => (
              <text fg={solidMint.body} wrapMode="word">
                {line}
              </text>
            )}
          </For>
        </box>
      </scrollbox>

      <SolidComposer onSubmit={onSubmit} focused={true} />
    </box>
  )
}
