/** @jsxImportSource @opentui/solid */
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { solidMint } from "../theme"

export type DialogExportResultProps = {
  path: string
  onClose?: () => void
}

export function DialogExportResult(props: DialogExportResultProps) {
  const dialog = useDialog()

  const close = () => {
    props.onClose?.()
    dialog.clear()
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      close()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="Session exported" hint="Enter · Esc" />}
      footer={
        <box flexDirection="row" justifyContent="flex-end">
          <box
            paddingLeft={2}
            paddingRight={2}
            backgroundColor={solidMint.inputFocusBg}
            onMouseUp={close}
          >
            <text fg={solidMint.brand}>Close</text>
          </box>
        </box>
      }
    >
      <text fg={solidMint.body}>{props.path}</text>
      <text fg={solidMint.muted}>Enter or Esc to dismiss</text>
    </DialogLayout>
  )
}

export function openDialogExportResult(
  dialog: ReturnType<typeof useDialog>,
  props: DialogExportResultProps,
) {
  dialog.replace(() => <DialogExportResult path={props.path} onClose={props.onClose} />, {
    size: "medium",
    onClose: props.onClose,
  })
}
