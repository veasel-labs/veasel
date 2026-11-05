/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo } from "solid-js"
import { useKeyboard, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { dialogGeometry, wrappedLineCount } from "../ui/dialog-layout"
import { useSolidTheme } from "../theme"

export type HighlightEntry = {
  title: string
  body: string
}

/**
 * Like the provider and status dialogs, the fixed chrome plus wrapped
 * entry bodies exceed the content height at 24 rows, so treat 24 rows
 * as compact too: the per-entry bottom margin collapses.
 */
export function highlightsDialogCompact(columns: number, rows: number): boolean {
  return dialogGeometry(columns, rows, 72).compact || rows <= 24
}

/** Lines `text` occupies when word-wrapped at `width` columns. */
export const highlightWrappedLines = wrappedLineCount

/**
 * Entries that fit the dialog at this terminal size, charged by wrapped
 * height (title + body + bottom margin) against the shared dialog
 * content height at the large dialog's content width, less DialogLayout
 * chrome (header, footer, two gaps, bottom padding = 5). One line is
 * reserved for the "+N more" summary whenever entries are truncated,
 * so hidden highlights are acknowledged instead of silently dropped.
 * When even the first entry exceeds the box (32x12), zero entries are
 * shown and the summary stands alone — forcing one entry painted it
 * over the footer and the bottom border.
 */
export function highlightsVisibleCount(
  entries: HighlightEntry[],
  columns: number,
  rows: number,
): number {
  const geometry = dialogGeometry(columns, rows, 72)
  const contentWidth = Math.max(1, geometry.width - 2 - geometry.paddingX * 2)
  const margin = highlightsDialogCompact(columns, rows) ? 0 : 1
  const costs = entries.map(
    (entry) =>
      highlightWrappedLines(entry.title, contentWidth) +
      highlightWrappedLines(entry.body, contentWidth) +
      margin,
  )
  const fit = (budget: number) => {
    let used = 0
    let count = 0
    for (const cost of costs) {
      if (used + cost > budget) break
      used += cost
      count += 1
    }
    return count
  }
  const budget = geometry.contentHeight - 5
  const all = fit(budget)
  if (all >= entries.length) return entries.length
  return fit(budget - 1)
}

export function demoHighlights(): HighlightEntry[] {
  return [
    {
      title: "Solid dialog host",
      body: "DialogSelect, Confirm, Prompt, and product dialogs share mint chrome.",
    },
    {
      title: "Open recent sessions & worktrees",
      body: "Ctrl+O opens sessions and live git worktrees (GET workspace/git/worktrees).",
    },
    {
      title: "Reviews stay first-class",
      body: "Multi-select file, shell, and MCP reviews with sandbox honesty.",
    },
  ]
}

export function HighlightsDialog(props: { entries: HighlightEntry[] }) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const dimensions = useTerminalDimensions()
  const compact = () => highlightsDialogCompact(dimensions().width, dimensions().height)
  const visibleEntries = createMemo(() =>
    props.entries.slice(
      0,
      highlightsVisibleCount(props.entries, dimensions().width, dimensions().height),
    ),
  )
  const hiddenCount = () => props.entries.length - visibleEntries().length

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="What's new" hint="Enter · Esc" />}
      footer={<text fg={colors.muted}>Tip LiveApp highlights · Enter closes</text>}
    >
      <For each={visibleEntries()}>
        {(entry) => (
          <box flexDirection="column" flexShrink={0} marginBottom={compact() ? 0 : 1}>
            <text fg={colors.headerTitle} flexShrink={0}>
              {entry.title}
            </text>
            <text fg={colors.muted} wrapMode="word" flexShrink={0}>
              {entry.body}
            </text>
          </box>
        )}
      </For>
      <Show when={hiddenCount() > 0}>
        <text fg={colors.muted} flexShrink={0}>
          +{hiddenCount()} more · enlarge the terminal to read
        </text>
      </Show>
    </DialogLayout>
  )
}

export function openHighlightsDialog(
  dialog: ReturnType<typeof useDialog>,
  entries: HighlightEntry[] = demoHighlights(),
) {
  dialog.replace(() => <HighlightsDialog entries={entries} />, { size: "large" })
}
