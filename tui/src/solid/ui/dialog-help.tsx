/** @jsxImportSource @opentui/solid */
import { createMemo } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { solidMint } from "../theme"
import { paletteHelpText, paletteShortcut } from "../commands"

export type DialogHelpProps = {
  /** Compact quick-help vs full /help advanced guide. */
  compact?: boolean
  onClose?: () => void
}

export function DialogHelp(props: DialogHelpProps) {
  const dialog = useDialog()
  const body = createMemo(() => paletteHelpText(props.compact ?? true))

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
      header={<DialogHeader title="Help" hint="Enter · Esc" />}
      footer={
        <box flexDirection="row" justifyContent="flex-end">
          <box
            paddingLeft={2}
            paddingRight={2}
            backgroundColor={solidMint.inputFocusBg}
            onMouseUp={close}
          >
            <text fg={solidMint.brand}>ok</text>
          </box>
        </box>
      }
    >
      <box width="100%" flexDirection="column" gap={1}>
        <text fg={solidMint.muted}>
          Press {paletteShortcut.label} for commands in any context.
        </text>
        <text fg={solidMint.body}>{body()}</text>
      </box>
    </DialogLayout>
  )
}

export function openDialogHelp(
  dialog: ReturnType<typeof useDialog>,
  props: DialogHelpProps = {},
) {
  dialog.replace(() => <DialogHelp {...props} />, { size: props.compact === false ? "large" : "medium" })
}
