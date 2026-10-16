/** @jsxImportSource @opentui/solid */
import { createMemo } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent, ScrollBoxRenderable } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { solidMint } from "../theme"

export type ShellOutputDialogProps = {
  command: string
  output: string
  status?: string
  exitCode?: number
  onClose?: () => void
}

export function ShellOutputDialog(props: ShellOutputDialogProps) {
  const dialog = useDialog()
  let scroll: ScrollBoxRenderable | undefined

  const statusLine = createMemo(() => {
    if (props.status) return props.status
    if (props.exitCode === undefined) return "Exited"
    return `Exited · code ${props.exitCode}`
  })

  const close = () => {
    props.onClose?.()
    dialog.clear()
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      close()
      return
    }
    if (key.name === "up") {
      key.preventDefault()
      scroll?.scrollBy(-1)
      return
    }
    if (key.name === "down") {
      key.preventDefault()
      scroll?.scrollBy(1)
      return
    }
    if (key.name === "pageup") {
      key.preventDefault()
      scroll?.scrollBy(-10)
      return
    }
    if (key.name === "pagedown") {
      key.preventDefault()
      scroll?.scrollBy(10)
      return
    }
    if (key.name === "home") {
      key.preventDefault()
      scroll?.scrollTo(0)
      return
    }
    if (key.name === "end") {
      key.preventDefault()
      scroll?.scrollTo(Number.MAX_SAFE_INTEGER)
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="Shell output" hint="↑/↓ · Enter · Esc" />}
      footer={<text fg={solidMint.muted}>{statusLine()} · Enter closes</text>}
    >
      <box width="100%" flexDirection="column" gap={1}>
        <text fg={solidMint.brand}>$ {props.command}</text>
        <scrollbox
          ref={(next: ScrollBoxRenderable) => {
            scroll = next
          }}
          width="100%"
          height={14}
          stickyScroll={true}
          stickyStart="bottom"
        >
          <text fg={solidMint.body}>{props.output}</text>
        </scrollbox>
      </box>
    </DialogLayout>
  )
}

export function openShellOutputDialog(
  dialog: ReturnType<typeof useDialog>,
  props: ShellOutputDialogProps,
) {
  dialog.replace(() => <ShellOutputDialog {...props} />, { size: "large" })
}

/** Demo shell capture for palette / tests. */
export function demoShellOutput(): ShellOutputDialogProps {
  return {
    command: "bun test tui/src/solid --bail",
    status: "Exited · code 0",
    exitCode: 0,
    output: [
      "bun test v1.4.3",
      "",
      "src/solid/dialog-select-filter.test.ts:",
      "(pass) DialogSelect filter helpers > fuzzyScore prefers exact and prefix matches",
      "(pass) DialogSelect filter helpers > filterSelectOptions skips disabled and ranks title hits",
      "",
      " 2 pass",
      " 0 fail",
    ].join("\n"),
  }
}
