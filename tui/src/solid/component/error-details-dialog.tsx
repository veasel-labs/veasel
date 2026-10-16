/** @jsxImportSource @opentui/solid */
import { createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent, ScrollBoxRenderable } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { solidMint } from "../theme"

export type ErrorDetailsDialogProps = {
  title?: string
  source?: string
  error: string
  context?: string
  onCopy?: (text: string) => void
  onClose?: () => void
}

export function formatErrorDetailsText(props: ErrorDetailsDialogProps): string {
  const parts = [
    props.title ?? "Error",
    props.source ? `Source: ${props.source}` : "",
    props.context ? `Context: ${props.context}` : "",
    "",
    props.error,
  ]
  return parts.filter((line, index) => line.length > 0 || index === 3).join("\n")
}

export function ErrorDetailsDialog(props: ErrorDetailsDialogProps) {
  const dialog = useDialog()
  const [copied, setCopied] = createSignal(false)
  let scroll: ScrollBoxRenderable | undefined

  const close = () => {
    props.onClose?.()
    dialog.clear()
  }

  const copy = () => {
    const text = formatErrorDetailsText(props)
    props.onCopy?.(text)
    setCopied(true)
  }

  useKeyboard((key: KeyEvent) => {
    if (key.name === "c" && !key.ctrl && !key.meta) {
      key.preventDefault()
      copy()
      return
    }
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
      scroll?.scrollBy(-8)
      return
    }
    if (key.name === "pagedown") {
      key.preventDefault()
      scroll?.scrollBy(8)
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title={props.title ?? "Error details"} hint="c copy · Enter · Esc" />}
      footer={
        <text fg={solidMint.muted}>
          {copied() ? "Copied · " : ""}
          c copies details · Enter / Esc closes
        </text>
      }
    >
      <scrollbox
        ref={(next: ScrollBoxRenderable) => {
          scroll = next
        }}
        width="100%"
        height={12}
        stickyScroll={false}
      >
        <box width="100%" flexDirection="column" gap={1}>
          {props.source ? <text fg={solidMint.muted}>Source · {props.source}</text> : null}
          {props.context ? <text fg={solidMint.muted}>Context · {props.context}</text> : null}
          <text fg={solidMint.statusError}>{props.error}</text>
        </box>
      </scrollbox>
    </DialogLayout>
  )
}

export function openErrorDetailsDialog(
  dialog: ReturnType<typeof useDialog>,
  props: ErrorDetailsDialogProps,
) {
  dialog.replace(() => <ErrorDetailsDialog {...props} />, { size: "large" })
}

/** Demo error for palette / tests. */
export function demoErrorDetails(): ErrorDetailsDialogProps {
  return {
    title: "Provider error",
    source: "anthropic",
    context: "POST /v1/messages",
    error:
      "rate_limit_error: This organization has exceeded its rate limit. Retry after 12s.\nRequest id: req_demo_solid_001",
  }
}
