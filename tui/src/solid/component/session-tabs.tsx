/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo } from "solid-js"
import { useSolidTheme } from "../theme"
import {
  formatSessionTabLabel,
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
  const colors = useSolidTheme()
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
      backgroundColor={colors.panelBg}
      border
      borderColor={colors.panelBorder}
      paddingLeft={1}
      paddingRight={1}
      gap={1}
    >
      <text fg={colors.muted}>TABS </text>
      <Show when={windowed().overflowLeft > 0}>
        <text fg={colors.muted}>‹{windowed().overflowLeft}</text>
      </Show>
      <For each={windowed().tabs}>
        {(tab) => {
          const active = () => tab.id === props.activeId
          const label = () => formatSessionTabLabel(tab)
          return (
            <box onMouseUp={() => props.onSelect(tab.id)}>
              <text wrapMode="none">
                <Show
                  when={active()}
                  fallback={
                    <span style={{ fg: tab.unread ? colors.brand : colors.muted }}>
                      {label()}
                    </span>
                  }
                >
                  <span style={{ fg: colors.brand }}>
                    <strong>{label()}</strong>
                  </span>
                </Show>
              </text>
            </box>
          )
        }}
      </For>
      <Show when={windowed().overflowRight > 0}>
        <text fg={colors.muted}>{windowed().overflowRight}›</text>
      </Show>
      <Show when={props.onNew}>
        <box onMouseUp={() => props.onNew?.()}>
          <text fg={colors.muted}>+</text>
        </box>
      </Show>
      <Show when={props.onCloseActive && props.activeId}>
        <box onMouseUp={() => props.onCloseActive?.()}>
          <text fg={colors.muted}>✕</text>
        </box>
      </Show>
    </box>
  )
}
