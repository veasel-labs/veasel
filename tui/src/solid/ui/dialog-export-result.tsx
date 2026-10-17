/** @jsxImportSource @opentui/solid */
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { useSolidTheme } from "../theme"

export type DialogExportResultProps = {
  path: string
  onClose?: () => void
}

export function DialogExportResult(props: DialogExportResultProps) {
  const colors = useSolidTheme()
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
            backgroundColor={colors.inputFocusBg}
            onMouseUp={close}
          >
            <text fg={colors.brand}>Close</text>
          </box>
        </box>
      }
    >
      <text fg={colors.body}>{props.path}</text>
      <text fg={colors.muted}>Enter or Esc to dismiss</text>
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
