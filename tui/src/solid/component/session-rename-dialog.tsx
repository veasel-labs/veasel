/** @jsxImportSource @opentui/solid */
import { createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import { DialogHeader, useDialog } from "../ui/dialog"
import { useSolidTheme } from "../theme"
import type { SolidSessionEntry } from "./session-list-dialog"

export type SessionRenameDialogProps = {
  session: SolidSessionEntry
  onConfirm: (title: string) => void
}

export function SessionRenameDialog(props: SessionRenameDialogProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const [title, setTitle] = createSignal(props.session.title)
  let titleInput: InputRenderable | undefined

  const confirm = () => {
    const next = title().trim()
    if (!next) return
    props.onConfirm(next)
    dialog.pop()
  }

  onMount(() => {
    queueMicrotask(() => titleInput?.focus())
  })

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      confirm()
    }
    // Esc is handled by DialogProvider.pop (returns to the session list).
  })

  return (
    <box width="100%" flexDirection="column" gap={1}>
      <DialogHeader title="Rename session" hint="Enter · Esc" />
      <text fg={colors.muted}>{props.session.directory}</text>
      <input
        ref={(next: InputRenderable) => {
          titleInput = next
        }}
        width="100%"
        focused={true}
        value={title()}
        placeholder="Session title"
        placeholderColor={colors.muted}
        textColor={colors.inputText}
        focusedTextColor={colors.inputText}
        backgroundColor={colors.inputBg}
        focusedBackgroundColor={colors.inputFocusBg}
        cursorColor={colors.cursor}
        onInput={(value: string) => setTitle(value)}
      />
      <text fg={colors.muted}>Enter saves · Esc returns to the list</text>
    </box>
  )
}

/** Stack rename above the session list. */
export function openSessionRenameDialog(
  dialog: ReturnType<typeof useDialog>,
  props: SessionRenameDialogProps,
) {
  dialog.push(() => <SessionRenameDialog session={props.session} onConfirm={props.onConfirm} />, {
    size: "medium",
  })
}
