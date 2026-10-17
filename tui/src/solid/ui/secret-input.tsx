/** @jsxImportSource @opentui/solid */
import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard, usePaste, useTerminalDimensions } from "@opentui/solid"
import type { BoxRenderable } from "@opentui/core"
import { useSolidTheme } from "../theme"
import { deleteSecret, moveSecretCursor, replaceSecretSelection, secretSelection, type SecretState } from "./secret-editor"

export function SecretInput(props: { value: string; placeholder?: string; onInput: (value: string) => void }) {
  const colors = useSolidTheme()
  const initialLength = Array.from(props.value).length
  const [state, setState] = createSignal<SecretState>({ value: props.value, cursor: initialLength, anchor: initialLength })
  const [error, setError] = createSignal<string>()
  const dimensions = useTerminalDimensions()
  let field: BoxRenderable | undefined
  onMount(() => queueMicrotask(() => { if (field && !field.isDestroyed) field.focus() }))
  onCleanup(() => setState({ value: "", cursor: 0, anchor: 0 }))
  createEffect(() => {
    const value = props.value
    if (value !== state().value) {
      const cursor = Array.from(value).length
      setState({ value, cursor, anchor: cursor })
    }
  })
  const update = (next: SecretState) => {
    props.onInput(next.value)
    setState(next)
    setError(undefined)
  }
  const insert = (text: string) => {
    try { update(replaceSecretSelection(state(), text)) }
    catch (failure) { setError(failure instanceof Error ? failure.message : "Could not insert credential") }
  }
  usePaste((event) => {
    if (!field?.focused) return
    event.preventDefault()
    event.stopPropagation()
    insert(new TextDecoder().decode(event.bytes))
  })
  useKeyboard((key) => {
    if (!field?.focused || key.eventType === "release") return
    if (["return", "kpenter", "escape", "tab"].includes(key.name)) return
    key.preventDefault()
    key.stopPropagation()
    const current = state()
    const length = Array.from(current.value).length
    if (key.ctrl && key.name === "a") { update({ ...current, anchor: 0, cursor: length }); return }
    if (key.ctrl && key.name === "u") { update({ value: "", cursor: 0, anchor: 0 }); return }
    if (key.ctrl && key.name === "k") { update(replaceSecretSelection({ ...current, anchor: length }, "")); return }
    if (key.name === "backspace") { update(deleteSecret(current, true)); return }
    if (key.name === "delete") { update(deleteSecret(current, false)); return }
    if (key.name === "home" || key.name === "end") {
      update(moveSecretCursor(current, key.name === "home" ? 0 : length, key.shift)); return
    }
    if (key.name === "left" || key.name === "right") {
      const [start, end] = secretSelection(current)
      const direction = key.name === "left" ? -1 : 1
      const target = !key.shift && start !== end ? (direction < 0 ? start : end) : current.cursor + direction
      update(moveSecretCursor(current, target, key.shift)); return
    }
    if (key.ctrl || key.meta || key.super) return
    const text = key.name === "space" ? " " : Array.from(key.sequence).length === 1
      ? key.sequence : Array.from(key.name).length === 1 ? (key.shift ? key.name.toUpperCase() : key.name) : ""
    if (text) insert(text)
  })
  const view = createMemo(() => {
    const value = state()
    const length = Array.from(value.value).length
    const width = Math.max(1, Math.min(40, dimensions().width - 14))
    const start = Math.max(0, value.cursor - width + 1)
    const end = Math.min(length, start + width)
    const [selectedStart, selectedEnd] = secretSelection(value)
    // Never put the original characters in JSX, native editor buffers, or clipboard hooks.
    return Array.from({ length: end - start + 1 }, (_, offset) => ({
      cursor: start + offset === value.cursor,
      bullet: start + offset < end,
      selected: start + offset >= selectedStart && start + offset < selectedEnd,
    }))
  })
  return <box flexDirection="column" width="100%">
    <box ref={(node: BoxRenderable) => { field = node }} focusable={true} height={1} width="100%"
      backgroundColor={colors.inputBg} onMouseDown={() => field?.focus()}>
      <text wrapMode="none">
        <For each={view()}>{(cell) => <>
          <Show when={cell.cursor}><span style={{ fg: colors.brand }}>▏</span></Show>
          <Show when={cell.bullet}><span style={{ fg: cell.selected ? colors.brand : colors.body }}>•</span></Show>
        </>}</For>
        <Show when={!state().value}><span style={{ fg: colors.muted }}>{props.placeholder ?? "Paste or type credential"}</span></Show>
      </text>
    </box>
    <text fg={colors.muted}>Hidden · Ctrl+A select all · Ctrl+U clear</text>
    <Show when={error()}>{(message) => <text fg={colors.statusWarn}>{message()}</text>}</Show>
  </box>
}
