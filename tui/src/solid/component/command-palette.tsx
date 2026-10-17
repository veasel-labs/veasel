/** @jsxImportSource @opentui/solid */
import { dialogGeometry, dialogResultCount } from "../ui/dialog-layout"
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard, useTerminalDimensions } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import {
  filterPaletteCommands,
  paletteShortcut,
  type PaletteCommand,
} from "../commands"
import { DialogHeader, useDialog } from "../ui/dialog"
import { useSolidTheme } from "../theme"

export type CommandPaletteProps = {
  commands: PaletteCommand[]
  /** Max visible rows in the result list. */
  maxVisible?: number
}

const visibleDefault = 8

export function CommandPalette(props: CommandPaletteProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const dimensions = useTerminalDimensions()
  const compact = () => dialogGeometry(dimensions().width, dimensions().height).compact
  const [query, setQuery] = createSignal("")
  const [selected, setSelected] = createSignal(0)
  let filterInput: InputRenderable | undefined

  const filtered = createMemo(() => filterPaletteCommands(props.commands, query()))
  const visible = () => dialogResultCount(dimensions().width, dimensions().height, props.maxVisible ?? visibleDefault)

  const windowed = createMemo(() => {
    const items = filtered()
    if (items.length === 0) return [] as PaletteCommand[]
    const index = Math.min(Math.max(0, selected()), items.length - 1)
    const size = visible()
    const start = Math.max(0, Math.min(index - Math.floor(size / 2), items.length - size))
    return items.slice(start, start + size)
  })

  const move = (delta: number) => {
    const items = filtered()
    if (items.length === 0) return
    setSelected((current) => {
      const next = current + delta
      if (next < 0) return items.length - 1
      if (next >= items.length) return 0
      return next
    })
  }

  const runSelected = () => {
    const items = filtered()
    const command = items[selected()]
    if (!command) return
    dialog.clear()
    command.run()
  }

  onMount(() => {
    queueMicrotask(() => filterInput?.focus())
  })

  useKeyboard((key: KeyEvent) => {
    // Arrows only — j/k must type into the filter input.
    if (key.name === "up") {
      key.preventDefault()
      move(-1)
      return
    }
    if (key.name === "down") {
      key.preventDefault()
      move(1)
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      runSelected()
      return
    }
    // Keep Ctrl+P as a toggle while the palette is open.
    if (key.ctrl && key.name === paletteShortcut.name) {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <box width="100%" flexDirection="column" gap={1}>
      <DialogHeader title="Commands" hint={`${paletteShortcut.label} · Esc`} />
      <input
        ref={(next: InputRenderable) => {
          filterInput = next
        }}
        width="100%"
        focused={true}
        placeholder="Filter commands…"
        placeholderColor={colors.muted}
        textColor={colors.inputText}
        focusedTextColor={colors.inputText}
        backgroundColor={colors.inputBg}
        focusedBackgroundColor={colors.inputFocusBg}
        cursorColor={colors.cursor}
        onInput={(value: string) => {
          setQuery(value)
          setSelected(0)
        }}
      />
      <Show
        when={filtered().length > 0}
        fallback={<text fg={colors.muted}>No matching commands</text>}
      >
        <box width="100%" flexDirection="column">
          <For each={windowed()}>
            {(command) => {
              const items = filtered()
              const index = () => items.indexOf(command)
              const active = () => index() === selected()
              return (
                <box
                  width="100%"
                  flexDirection="row"
                  backgroundColor={active() ? colors.inputFocusBg : colors.panelBg}
                  paddingLeft={1}
                  paddingRight={1}
                  onMouseUp={() => {
                    dialog.clear()
                    command.run()
                  }}
                >
                  <text fg={active() ? colors.brand : colors.body} flexGrow={1} flexShrink={1} wrapMode="none">
                    {active() ? "▸ " : "  "}
                    {command.title}
                  </text>
                  <Show when={!compact()}>
                    <text fg={colors.muted} wrapMode="none">
                      {"  "}
                      {command.group}
                      {command.shortcut ? ` · ${command.shortcut}` : ""}
                    </text>
                  </Show>
                </box>
              )
            }}
          </For>
        </box>
        <text fg={colors.muted}>
          {filtered().length} match{filtered().length === 1 ? "" : "es"} · ↑/↓ · Enter
        </text>
      </Show>
    </box>
  )
}

/** Open the command palette on the dialog stack. */
export function openCommandPalette(dialog: ReturnType<typeof useDialog>, commands: PaletteCommand[]) {
  dialog.replace(() => <CommandPalette commands={commands} />)
}
