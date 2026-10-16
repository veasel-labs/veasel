/** @jsxImportSource @opentui/solid */
import { For } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { solidMint } from "../theme"

export type HighlightEntry = {
  title: string
  body: string
}

export function demoHighlights(): HighlightEntry[] {
  return [
    {
      title: "Solid dialog host",
      body: "DialogSelect, Confirm, Prompt, and product dialogs share mint chrome.",
    },
    {
      title: "Open recent sessions & worktrees",
      body: "Ctrl+O opens sessions and project worktrees (HTTP catalog wire next).",
    },
    {
      title: "Reviews stay first-class",
      body: "Multi-select file, shell, and MCP reviews with sandbox honesty.",
    },
  ]
}

export function HighlightsDialog(props: { entries: HighlightEntry[] }) {
  const dialog = useDialog()

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="What's new" hint="Enter · Esc" />}
      footer={<text fg={solidMint.muted}>Release highlights stub · wire to shipped notes</text>}
    >
      <For each={props.entries}>
        {(entry) => (
          <box flexDirection="column" marginBottom={1}>
            <text fg={solidMint.headerTitle}>{entry.title}</text>
            <text fg={solidMint.muted} wrapMode="word">
              {entry.body}
            </text>
          </box>
        )}
      </For>
    </DialogLayout>
  )
}

export function openHighlightsDialog(
  dialog: ReturnType<typeof useDialog>,
  entries: HighlightEntry[] = demoHighlights(),
) {
  dialog.replace(() => <HighlightsDialog entries={entries} />, { size: "large" })
}
