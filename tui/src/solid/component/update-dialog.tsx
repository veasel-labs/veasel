/** @jsxImportSource @opentui/solid */
import { For, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { solidMint } from "../theme"

export type UpdateDialogState =
  | { type: "current"; version: string }
  | { type: "available"; version: string; notes: string[] }
  | { type: "checking" }

export type UpdateDialogProps = {
  state: UpdateDialogState
  onSkip?: () => void
  onInstall?: () => void
}

/** Changelog stub for Solid update dialog / tests. */
export function demoUpdateNotes(): string[] {
  return [
    "Solid dialog parity wave (Open, Status, Agent, Variant, Workspaces)",
    "Mint chrome preserved · no OpenCode branding",
    "Wire to release channel when Veasel ships auto-update",
  ]
}

export function demoUpdateAvailable(): UpdateDialogState {
  return {
    type: "available",
    version: "0.2.0-preview",
    notes: demoUpdateNotes(),
  }
}

type UpdateChoice = "skip" | "install"

export function UpdateDialog(props: UpdateDialogProps) {
  const dialog = useDialog()
  const [active, setActive] = createSignal<UpdateChoice>("install")

  const finish = (choice: UpdateChoice) => {
    if (choice === "install") props.onInstall?.()
    else props.onSkip?.()
    dialog.clear()
  }

  useKeyboard((key: KeyEvent) => {
    const state = props.state
    if (state.type === "checking") return
    if (key.name === "left" || key.name === "right" || key.name === "tab") {
      key.preventDefault()
      setActive((current) => (current === "install" ? "skip" : "install"))
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      if (state.type === "current") finish("skip")
      else finish(active())
    }
  })

  const title = () => {
    switch (props.state.type) {
      case "checking":
        return "Checking for updates"
      case "available":
        return "Update available"
      default:
        return "Veasel is up to date"
    }
  }

  return (
    <DialogLayout
      header={<DialogHeader title={title()} hint="←/→ · Enter · Esc" />}
      footer={
        props.state.type === "available" ? (
          <box flexDirection="row" justifyContent="flex-end" gap={1}>
            {(["skip", "install"] as const).map((key) => {
              const selected = () => active() === key
              const label = key === "skip" ? "Skip" : "Install (stub)"
              return (
                <box
                  paddingLeft={2}
                  paddingRight={2}
                  backgroundColor={selected() ? solidMint.inputFocusBg : undefined}
                  onMouseUp={() => finish(key)}
                >
                  <text fg={selected() ? solidMint.brand : solidMint.muted}>{label}</text>
                </box>
              )
            })}
          </box>
        ) : (
          <text fg={solidMint.muted}>Release channel stub · no live download in TUI yet</text>
        )
      }
    >
      {props.state.type === "checking" ? (
        <text fg={solidMint.muted}>Contacting release metadata…</text>
      ) : props.state.type === "current" ? (
        <text fg={solidMint.body}>Running {props.state.version}</text>
      ) : (
        <box flexDirection="column" gap={1}>
          <text fg={solidMint.body}>Veasel {props.state.version}</text>
          <For each={props.state.notes}>
            {(line) => (
              <text fg={solidMint.muted} wrapMode="word">
                • {line}
              </text>
            )}
          </For>
        </box>
      )}
    </DialogLayout>
  )
}

export function openUpdateDialog(
  dialog: ReturnType<typeof useDialog>,
  props: UpdateDialogProps,
) {
  dialog.replace(() => <UpdateDialog {...props} />)
}
