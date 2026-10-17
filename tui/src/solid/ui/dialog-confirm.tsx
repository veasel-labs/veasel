/** @jsxImportSource @opentui/solid */
import { For, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { useSolidTheme } from "../theme"

export type DialogConfirmProps = {
  title: string
  message: string
  onConfirm?: () => void
  onCancel?: () => void
  label?: {
    confirm?: string
    cancel?: string
  }
}

type ConfirmChoice = "cancel" | "confirm"

function titlecase(value: string): string {
  if (!value) return value
  return value.charAt(0).toUpperCase() + value.slice(1)
}

export function DialogConfirm(props: DialogConfirmProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const [active, setActive] = createSignal<ConfirmChoice>("confirm")

  const finish = (choice: ConfirmChoice) => {
    if (choice === "confirm") props.onConfirm?.()
    else props.onCancel?.()
    dialog.clear()
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "left" || key.name === "right" || key.name === "tab") {
      key.preventDefault()
      setActive((current) => (current === "confirm" ? "cancel" : "confirm"))
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      finish(active())
    }
  })

  const choices = ["cancel", "confirm"] as const

  return (
    <DialogLayout
      header={<DialogHeader title={props.title} hint="←/→ · Enter · Esc" />}
      footer={
        <box flexDirection="row" justifyContent="flex-end" gap={1}>
          <For each={choices}>
            {(key) => {
              const selected = () => active() === key
              const caption = () =>
                titlecase(props.label?.[key] ?? key)
              return (
                <box
                  paddingLeft={2}
                  paddingRight={2}
                  backgroundColor={selected() ? colors.inputFocusBg : undefined}
                  onMouseUp={() => finish(key)}
                >
                  <text fg={selected() ? colors.brand : colors.muted}>
                    {caption()}
                  </text>
                </box>
              )
            }}
          </For>
        </box>
      }
    >
      <text fg={colors.muted}>{props.message}</text>
    </DialogLayout>
  )
}

export function openDialogConfirm(
  dialog: ReturnType<typeof useDialog>,
  props: DialogConfirmProps,
) {
  dialog.replace(() => <DialogConfirm {...props} />)
}
