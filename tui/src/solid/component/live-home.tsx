/** @jsxImportSource @opentui/solid */
import { For, Show } from "solid-js"
import type { MouseEvent } from "@opentui/core"
import { homeFooterHint } from "../../footer-hints"
import { solidMint } from "../theme"
import { HomeSplash } from "./home-splash"
import type { SolidSessionEntry } from "./session-list-dialog"
import type { Theme } from "../../themes"
import {
  HOME_SIDEBAR_DEFAULT,
  clampHomeSidebarWidth,
} from "../ui/pane-layout"
import { createPaneResize } from "../ui/pane-resize"
import { PaneResizeHandle } from "../ui/pane-resize-handle"

export type LiveHomeProps = {
  sessions: SolidSessionEntry[]
  selectedIndex: number
  directory: string
  theme: Theme
  filter?: string
  /** Preferred SESSIONS column width (persisted by LiveApp). */
  sidebarWidth?: number
  terminalColumns?: number
  onSidebarWidthChange?: (width: number) => void
}

/** Classic-compatible home: SESSIONS sidebar + splash + q quit footer. */
export function LiveHome(props: LiveHomeProps) {
  const filter = () => props.filter?.trim() ?? ""
  const cols = () => props.terminalColumns ?? process.stdout.columns ?? 80
  const preferred = () =>
    clampHomeSidebarWidth(props.sidebarWidth ?? HOME_SIDEBAR_DEFAULT, cols())

  const resize = createPaneResize({
    value: preferred,
    defaultValue: () => clampHomeSidebarWidth(HOME_SIDEBAR_DEFAULT, cols()),
    clamp: (size) => clampHomeSidebarWidth(size, cols()),
    fromMouse: (event: MouseEvent) => event.x,
    contains: (event: MouseEvent, size: number) =>
      event.x >= size - 1 && event.x <= size + 1,
    onCommit: (size) => props.onSidebarWidthChange?.(size),
  })

  const visible = () => {
    const needle = filter().toLowerCase()
    if (!needle) return props.sessions
    return props.sessions.filter(
      (session) =>
        session.title.toLowerCase().includes(needle)
        || session.directory.toLowerCase().includes(needle),
    )
  }

  return (
    <box width="100%" flexGrow={1} flexDirection="column" gap={0}>
      <box width="100%" flexGrow={1} flexDirection="row" gap={0}>
        <box
          width={resize.size()}
          flexShrink={0}
          flexDirection="column"
          padding={1}
          gap={1}
          backgroundColor={solidMint.panelBg}
          border
          borderColor={solidMint.panelBorder}
        >
          <text fg={solidMint.sidebarLabel}>
            SESSIONS
            <Show when={props.sessions.length > 0}>
              {"  "}
              {props.sessions.length}
            </Show>
          </text>
          <Show
            when={visible().length > 0}
            fallback={<text fg={solidMint.muted}>No sessions yet · press n</text>}
          >
            <For each={visible()}>
              {(session, index) => {
                const active = () => index() === props.selectedIndex
                return (
                  <text fg={active() ? solidMint.brand : solidMint.sidebarFg}>
                    {active() ? "▸ " : "  "}
                    {session.title}
                  </text>
                )
              }}
            </For>
          </Show>
          <text fg={solidMint.muted}>VEASEL CODE{"\n"}your local workspace</text>
        </box>

        <PaneResizeHandle resize={resize} />

        <box
          flexGrow={1}
          flexDirection="column"
          backgroundColor={solidMint.panelBg}
          border
          borderColor={solidMint.panelBorder}
        >
          <HomeSplash theme={props.theme} directory={props.directory} />
        </box>
      </box>

      <box
        width="100%"
        height={1}
        flexShrink={0}
        paddingLeft={1}
        paddingRight={1}
        backgroundColor={solidMint.shellBg}
      >
        <text fg={solidMint.muted}>
          {homeFooterHint} · drag │ · Alt+←/→ resize sidebar
        </text>
      </box>
    </box>
  )
}
