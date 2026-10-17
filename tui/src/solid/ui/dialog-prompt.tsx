/** @jsxImportSource @opentui/solid */
import { Show, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { SecretInput } from "./secret-input"
import { solidMint } from "../theme"

export type DialogPromptProps = {
  title: string
  description?: string
  placeholder?: string
  value?: string
  confirmLabel?: string
  secret?: boolean
  onConfirm?: (value: string) => void
  onCancel?: () => void
}

export function DialogPrompt(props: DialogPromptProps) {
  const dialog = useDialog()
  const [draft, setDraft] = createSignal(props.value ?? "")
  let input: InputRenderable | undefined

  const submit = () => {
    props.onConfirm?.(draft())
    dialog.clear()
  }

  const cancel = () => {
    props.onCancel?.()
    dialog.clear()
  }

  onMount(() => {
    queueMicrotask(() => input?.focus())
  })

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      submit()
      return
    }
    if (key.name === "escape") {
      // Host also pops on Esc; still invoke onCancel when provided.
      key.preventDefault()
      cancel()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title={props.title} hint="Enter · Esc" />}
      footer={
        <box flexDirection="row" justifyContent="flex-end">
          <box
            paddingLeft={2}
            paddingRight={2}
            backgroundColor={solidMint.inputFocusBg}
            onMouseUp={submit}
          >
            <text fg={solidMint.brand}>{props.confirmLabel ?? "submit"}</text>
          </box>
        </box>
      }
    >
      <box width="100%" flexDirection="column" gap={1}>
        <Show when={props.description}>
          <text fg={solidMint.muted}>{props.description}</text>
        </Show>
        <Show when={!props.secret} fallback={<SecretInput value={draft()} placeholder={props.placeholder} onInput={setDraft} />}>
        <input
          ref={(next: InputRenderable) => {
            input = next
          }}
          width="100%"
          focused={true}
          value={draft()}
          placeholder={props.placeholder ?? "Enter text"}
          placeholderColor={solidMint.muted}
          textColor={solidMint.inputText}
          focusedTextColor={solidMint.inputText}
          backgroundColor={solidMint.inputBg}
          focusedBackgroundColor={solidMint.inputFocusBg}
          cursorColor={solidMint.cursor}
          onInput={(value: string) => setDraft(value)}
        />
        </Show>
      </box>
    </DialogLayout>
  )
}

export function openDialogPrompt(
  dialog: ReturnType<typeof useDialog>,
  props: DialogPromptProps,
) {
  dialog.replace(() => <DialogPrompt {...props} />)
}
