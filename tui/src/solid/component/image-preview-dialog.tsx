/** @jsxImportSource @opentui/solid */
import { Show } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { useSolidTheme } from "../theme"

export type ImagePreviewProps = {
  path: string
  alt?: string
  /** Optional ASCII preview for terminals without image protocols. */
  preview?: string
}

export function demoImagePreview(): ImagePreviewProps {
  return {
    path: "~/veasel/screenshots/solid-transcript.png",
    alt: "Solid transcript screenshot",
    preview: [
      "┌──────────────────────────────┐",
      "│ VEASEL code        LOCAL · … │",
      "│ SESSION Solid transcript     │",
      "│ mint activity groups …       │",
      "└──────────────────────────────┘",
    ].join("\n"),
  }
}

export function ImagePreviewDialog(props: ImagePreviewProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="Image preview" hint="Enter · Esc" />}
      footer={
        <text fg={colors.muted}>
          Kitty/iTerm image protocols not wired · ASCII fallback only
        </text>
      }
    >
      <text fg={colors.muted}>Path · {props.path}</text>
      <Show when={props.alt}>
        {(alt) => <text fg={colors.body}>{alt()}</text>}
      </Show>
      <text fg={colors.brand} wrapMode="word">
        {props.preview ?? "(no preview bytes)"}
      </text>
    </DialogLayout>
  )
}

export function openImagePreviewDialog(
  dialog: ReturnType<typeof useDialog>,
  props: ImagePreviewProps,
) {
  dialog.replace(() => <ImagePreviewDialog {...props} />, { size: "large" })
}
