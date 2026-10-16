/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo } from "solid-js"
import { solidMint } from "../theme"
import {
  truncateTabTitle,
  visibleSessionTabs,
  type SessionTab,
} from "../session-tabs"

export type SessionTabsProps = {
  tabs: SessionTab[]
  activeId?: string
  maxVisible?: number
  onSelect: (id: string) => void
  onCloseActive?: () => void
  onNew?: () => void
}

/** Compact mint session tab rail — switch without leaving the session chrome. */
export function SessionTabs(props: SessionTabsProps) {
  const windowed = createMemo(() =>
    visibleSessionTabs(props.tabs, props.activeId, props.maxVisible ?? 6),
  )

  return (
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
      gap={1}
    >
      <text fg={solidMint.muted}>TABS </text>
      <Show when={windowed().overflowLeft > 0}>
        <text fg={solidMint.muted}>‹{windowed().overflowLeft}</text>
      </Show>
      <For each={windowed().tabs}>
        {(tab) => {
          const active = () => tab.id === props.activeId
          return (
            <box onMouseUp={() => props.onSelect(tab.id)}>
              <text wrapMode="none">
                <Show
                  when={active()}
                  fallback={
                    <span style={{ fg: solidMint.muted }}>{truncateTabTitle(tab.title)}</span>
                  }
                >
                  <span style={{ fg: solidMint.brand }}>
                    <strong>{truncateTabTitle(tab.title)}</strong>
                  </span>
                </Show>
              </text>
            </box>
          )
        }}
      </For>
      <Show when={windowed().overflowRight > 0}>
        <text fg={solidMint.muted}>{windowed().overflowRight}›</text>
      </Show>
      <Show when={props.onNew}>
        <box onMouseUp={() => props.onNew?.()}>
          <text fg={solidMint.muted}>+</text>
        </box>
      </Show>
      <Show when={props.onCloseActive && props.activeId}>
        <box onMouseUp={() => props.onCloseActive?.()}>
          <text fg={solidMint.muted}>✕</text>
        </box>
      </Show>
    </box>
  )
}
