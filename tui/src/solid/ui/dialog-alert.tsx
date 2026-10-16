/** @jsxImportSource @opentui/solid */
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { solidMint } from "../theme"

export type DialogAlertProps = {
  title: string
  message: string
  confirmLabel?: string
  onConfirm?: () => void
}

export function DialogAlert(props: DialogAlertProps) {
  const dialog = useDialog()
  const label = () => props.confirmLabel ?? "ok"

  const confirm = () => {
    props.onConfirm?.()
    dialog.clear()
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      confirm()
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
            onMouseUp={confirm}
          >
            <text fg={solidMint.brand}>{label()}</text>
          </box>
        </box>
      }
    >
      <text fg={solidMint.muted}>{props.message}</text>
    </DialogLayout>
  )
}

export function openDialogAlert(
  dialog: ReturnType<typeof useDialog>,
  props: DialogAlertProps,
) {
  dialog.replace(() => <DialogAlert {...props} />)
}
