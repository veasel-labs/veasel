/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, createSignal, onMount, type JSX } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import { DialogHeader, useDialog } from "./dialog"
import { solidMint } from "../theme"
import {
  filterSelectOptions,
  groupSelectOptions,
  moveSelectIndex,
  type DialogSelectOption,
} from "./dialog-select-filter"

export type { DialogSelectOption }

export type DialogSelectProps<T = string> = {
  title: string
  options: DialogSelectOption<T>[]
  placeholder?: string
  footer?: JSX.Element | string
  /** Flatten categories while filtering (OpenCode default when query non-empty). */
  flatOnFilter?: boolean
  /** Currently selected value (shows ● marker). */
  current?: T
  maxVisible?: number
  onSelect?: (option: DialogSelectOption<T>) => void
  /** Fires when the highlight moves (theme live-preview). */
  onMove?: (option: DialogSelectOption<T>) => void
  onCancel?: () => void
  /**
   * When false, leave the dialog stack alone after onSelect (caller may
   * `replace`/`push` a follow-up dialog). Default true.
   */
  dismissOnSelect?: boolean
}

const visibleDefault = 10

export function DialogSelect<T>(props: DialogSelectProps<T>) {
  const dialog = useDialog()
  const [query, setQuery] = createSignal("")
  const [selected, setSelected] = createSignal(0)
  let filterInput: InputRenderable | undefined

  const filtered = createMemo(() => filterSelectOptions(props.options, query()))
  const flatMode = createMemo(
    () => (props.flatOnFilter !== false && query().trim().length > 0) || false,
  )
  const grouped = createMemo(() => groupSelectOptions(filtered(), flatMode()))
  const flat = createMemo(() => grouped().flatMap(([, options]) => options))
  const visible = () => Math.max(1, props.maxVisible ?? visibleDefault)

  const windowedGroups = createMemo(() => {
    const items = flat()
    if (items.length === 0) return [] as Array<[string, DialogSelectOption<T>[]]>
    const index = Math.min(Math.max(0, selected()), items.length - 1)
    const size = visible()
    const start = Math.max(0, Math.min(index - Math.floor(size / 2), items.length - size))
    const end = start + size
    const slice = items.slice(start, end)
    return groupSelectOptions(slice, flatMode())
  })

  const move = (delta: number) => {
    const count = flat().length
    if (count === 0) return
    setSelected((current) => {
      const next = moveSelectIndex(current, count, delta)
      const option = flat()[next]
      if (option) queueMicrotask(() => props.onMove?.(option))
      return next
    })
  }

  const submit = () => {
    const option = flat()[selected()]
    if (!option) return
    props.onSelect?.(option)
    if (props.dismissOnSelect !== false) dialog.clear()
  }

  onMount(() => {
    const current = props.current
    if (current !== undefined) {
      const index = flat().findIndex((option) => option.value === current)
      if (index >= 0) setSelected(index)
    }
    queueMicrotask(() => filterInput?.focus())
  })

  useKeyboard((key: KeyEvent) => {
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
      submit()
      return
    }
    if (key.name === "escape" && props.onCancel) {
      key.preventDefault()
      props.onCancel()
      dialog.clear()
    }
  })

  return (
    <box width="100%" flexDirection="column" gap={1}>
      <DialogHeader title={props.title} hint="↑/↓ · Enter · Esc" />
      <input
        ref={(next: InputRenderable) => {
          filterInput = next
        }}
        width="100%"
        focused={true}
        placeholder={props.placeholder ?? "Search…"}
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
        when={flat().length > 0}
        fallback={
          <text fg={solidMint.muted}>
            {query().trim() ? "No results found" : "No items available"}
          </text>
        }
      >
        <box width="100%" flexDirection="column">
          <For each={windowedGroups()}>
            {([category, options]) => (
              <>
                <Show when={category}>
                  <text fg={solidMint.brand}>
                    <strong>{category}</strong>
                  </text>
                </Show>
                <For each={options}>
                  {(option) => {
                    const index = () => flat().indexOf(option)
                    const active = () => index() === selected()
                    const isCurrent = () =>
                      props.current !== undefined && option.value === props.current
                    return (
                      <box
                        width="100%"
                        flexDirection="row"
                        backgroundColor={active() ? solidMint.inputFocusBg : solidMint.panelBg}
                        paddingLeft={1}
                        paddingRight={1}
                        onMouseUp={() => {
                          props.onSelect?.(option)
                          if (props.dismissOnSelect !== false) dialog.clear()
                        }}
                      >
                        <text fg={active() ? solidMint.brand : solidMint.body}>
                          {isCurrent() ? "● " : active() ? "▸ " : "  "}
                          {option.title}
                        </text>
                        <Show when={option.description || option.footer || (flatMode() && option.category)}>
                          <text fg={solidMint.muted}>
                            {"  "}
                            {flatMode()
                              ? (option.footer ?? option.category ?? option.description ?? "")
                              : (option.footer ?? option.description ?? "")}
                          </text>
                        </Show>
                      </box>
                    )
                  }}
                </For>
              </>
            )}
          </For>
        </box>
        <text fg={solidMint.muted}>
          {flat().length} match{flat().length === 1 ? "" : "es"} · ↑/↓ · Enter
        </text>
      </Show>
      <Show when={props.footer}>
        <text fg={solidMint.muted}>{props.footer}</text>
      </Show>
    </box>
  )
}

export function openDialogSelect<T>(
  dialog: ReturnType<typeof useDialog>,
  props: DialogSelectProps<T> & { size?: "medium" | "large" },
) {
  const { size, ...selectProps } = props
  dialog.replace(() => <DialogSelect {...selectProps} />, { size })
}
