/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo } from "solid-js"
import { useTerminalDimensions } from "@opentui/solid"
import { useSolidTheme } from "../theme"
import {
  formatSessionTabLabel,
  sessionTabsLayout,
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
  const dimensions = useTerminalDimensions()
  const windowed = createMemo(() =>
    sessionTabsLayout(props.tabs, props.activeId, dimensions().width, {
      maxVisible: props.maxVisible,
      showNew: Boolean(props.onNew),
      showClose: Boolean(props.onCloseActive && props.activeId),
    }),
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
      <Show when={windowed().showLabel}>
        <text fg={colors.muted}>TABS </text>
      </Show>
      <Show when={windowed().overflowLeft > 0}>
        <text fg={colors.muted}>‹{windowed().overflowLeft}</text>
      </Show>
      <For each={windowed().tabs}>
        {(tab) => {
          const active = () => tab.id === props.activeId
          return (
            <box width={windowed().titleWidth} flexShrink={0} onMouseUp={() => props.onSelect(tab.id)}>
              <text width={windowed().titleWidth} wrapMode="none">
                <Show
                  when={active()}
                  fallback={
                    <span style={{ fg: tab.unread ? colors.brand : colors.muted }}>
                      {formatSessionTabLabel(tab, windowed().titleWidth)}
                    </span>
                  }
                >
                  <span style={{ fg: colors.brand }}>
                    <strong>{formatSessionTabLabel(tab, windowed().titleWidth)}</strong>
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
      <Show when={windowed().showNew}>
        <box onMouseUp={() => props.onNew?.()}>
          <text fg={colors.muted}>+</text>
        </box>
      </Show>
      <Show when={windowed().showClose && props.activeId}>
        <box onMouseUp={() => props.onCloseActive?.()}>
          <text fg={colors.muted}>✕</text>
        </box>
      </Show>
    </box>
  )
}
