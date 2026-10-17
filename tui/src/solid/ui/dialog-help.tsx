/** @jsxImportSource @opentui/solid */
import { createMemo } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "./dialog"
import { useSolidTheme } from "../theme"
import { paletteHelpText, paletteShortcut } from "../commands"

export type DialogHelpProps = {
  /** Compact quick-help vs full /help advanced guide. */
  compact?: boolean
  onClose?: () => void
}

export function DialogHelp(props: DialogHelpProps) {
  const colors = useSolidTheme()
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
            backgroundColor={colors.inputFocusBg}
            onMouseUp={close}
          >
            <text fg={colors.brand}>ok</text>
          </box>
        </box>
      }
    >
      <box width="100%" flexDirection="column" gap={1}>
        <text fg={colors.muted}>
          Press {paletteShortcut.label} for commands in any context.
        </text>
        <text fg={colors.body}>{body()}</text>
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
