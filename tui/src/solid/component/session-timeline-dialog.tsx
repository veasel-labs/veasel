/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"
import {
  buildSessionTimeline,
  type SessionTimelineEntry,
  type TimelineMessage,
} from "../session-timeline"

export type SessionTimelineDialogProps = {
  messages: TimelineMessage[]
  onRestore: (entry: SessionTimelineEntry) => void
}

/** User-turn timeline — Enter restores the prompt into Compose. */
export function openSessionTimelineDialog(
  dialog: ReturnType<typeof useDialog>,
  props: SessionTimelineDialogProps,
) {
  const entries = buildSessionTimeline(props.messages)
  if (entries.length === 0) {
    openDialogSelect(dialog, {
      title: "Timeline",
      options: [
        {
          title: "No user turns yet",
          value: "empty",
          description: "Send a message to populate the timeline",
        },
      ],
      onSelect: () => {},
      footer: "Esc closes",
    })
    return
  }

  openDialogSelect(dialog, {
    title: "Timeline",
    placeholder: "Filter user turns…",
    size: "large",
    options: entries.map((entry) => ({
      title: entry.title,
      value: entry.id,
      description: `Turn ${entry.turn}`,
      footer: `#${entry.messageIndex + 1}`,
      searchText: entry.content,
    })),
    onSelect: (option) => {
      const entry = entries.find((item) => item.id === option.value)
      if (entry) props.onRestore(entry)
    },
    footer: "Enter restores into Compose · newest user turns first",
  })
}
