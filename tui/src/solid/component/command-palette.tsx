/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import {
  filterPaletteCommands,
  paletteShortcut,
  type PaletteCommand,
} from "../commands"
import { DialogHeader, useDialog } from "../ui/dialog"
import { solidMint } from "../theme"

export type CommandPaletteProps = {
  commands: PaletteCommand[]
  /** Max visible rows in the result list. */
  maxVisible?: number
}

const visibleDefault = 8

export function CommandPalette(props: CommandPaletteProps) {
  const dialog = useDialog()
  const [query, setQuery] = createSignal("")
  const [selected, setSelected] = createSignal(0)
  let filterInput: InputRenderable | undefined

  const filtered = createMemo(() => filterPaletteCommands(props.commands, query()))
  const visible = () => Math.max(1, props.maxVisible ?? visibleDefault)

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
        placeholderColor={solidMint.muted}
        textColor={solidMint.inputText}
        focusedTextColor={solidMint.inputText}
        backgroundColor={solidMint.inputBg}
        focusedBackgroundColor={solidMint.inputFocusBg}
        cursorColor={solidMint.cursor}
        onInput={(value: string) => {
          setQuery(value)
          setSelected(0)
        }}
      />
      <Show
        when={filtered().length > 0}
        fallback={<text fg={solidMint.muted}>No matching commands</text>}
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
                  backgroundColor={active() ? solidMint.inputFocusBg : solidMint.panelBg}
                  paddingLeft={1}
                  paddingRight={1}
                >
                  <text fg={active() ? solidMint.brand : solidMint.body}>
                    {active() ? "▸ " : "  "}
                    {command.title}
                  </text>
                  <text fg={solidMint.muted}>
                    {"  "}
                    {command.group}
                    {command.shortcut ? ` · ${command.shortcut}` : ""}
                  </text>
                </box>
              )
            }}
          </For>
        </box>
        <text fg={solidMint.muted}>
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
