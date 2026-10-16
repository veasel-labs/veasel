/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"

export type SolidStashEntry = {
  id: string
  text: string
  /** Epoch ms when stashed. */
  timestamp: number
}

export type StashDialogProps = {
  entries: SolidStashEntry[]
  onSelect: (entry: SolidStashEntry) => void
  onDelete?: (entry: SolidStashEntry) => void
}

function relativeTime(timestamp: number): string {
  const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000))
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

function preview(text: string, max = 48): string {
  const first = text.split("\n")[0]?.trim() ?? ""
  if (first.length <= max) return first || "(empty)"
  return `${first.slice(0, max - 1)}…`
}

/** Demo stash for Solid shell / tests. */
export function demoStashEntries(): SolidStashEntry[] {
  const now = Date.now()
  return [
    {
      id: "stash-1",
      text: "Explain the Solid dialog host stack and Esc pop semantics.",
      timestamp: now - 90_000,
    },
    {
      id: "stash-2",
      text: "Wire model favorites to the HTTP settings cockpit.",
      timestamp: now - 3_600_000,
    },
  ]
}

export function openStashDialog(
  dialog: ReturnType<typeof useDialog>,
  props: StashDialogProps,
) {
  // Most recent first (OpenCode order).
  const ordered = [...props.entries].sort((a, b) => b.timestamp - a.timestamp)
  openDialogSelect(dialog, {
    title: "Stash",
    placeholder: "Filter stash…",
    options: ordered.map((entry) => {
      const lines = entry.text.split("\n").length
      return {
        title: preview(entry.text),
        value: entry.id,
        description: relativeTime(entry.timestamp),
        footer: lines > 1 ? `~${lines} lines` : undefined,
        searchText: entry.text,
      }
    }),
    onSelect: (option) => {
      const entry = ordered.find((item) => item.id === option.value)
      if (entry) props.onSelect(entry)
    },
    footer: "Enter restores into the composer · Esc cancels",
  })
}
