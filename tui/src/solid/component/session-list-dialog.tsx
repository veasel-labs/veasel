/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, KeyEvent } from "@opentui/core"
import {
  filterSessionList,
  formatSessionFilterHeader,
  moveSessionSelection,
  sessionDigitIndex,
  type SessionListEntry,
} from "../../session-list"
import { DialogHeader, useDialog } from "../ui/dialog"
import { useSolidTheme } from "../theme"
import { openSessionRenameDialog } from "./session-rename-dialog"

export type SolidSessionEntry = SessionListEntry & {
  id: string
}

export type SessionListDialogProps = {
  sessions: SolidSessionEntry[]
  /** Active session id for ▸ marker. */
  activeId?: string
  onSelect?: (session: SolidSessionEntry) => void
  onRename?: (session: SolidSessionEntry, title: string) => void
  onDelete?: (session: SolidSessionEntry) => void
  onCreate?: () => void
}

const visibleDefault = 10

/** Demo sessions for Solid shell / testRender. */
export function demoSessions(): SolidSessionEntry[] {
  return [
    { id: "sess-alpha", title: "Solid transcript", directory: "~/veasel" },
    { id: "sess-beta", title: "Review queue polish", directory: "~/veasel/tui" },
    { id: "sess-gamma", title: "MCP credentials", directory: "~/veasel" },
  ]
}

export function SessionListDialog(props: SessionListDialogProps) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const [sessions, setSessions] = createSignal<SolidSessionEntry[]>([...props.sessions])
  const [query, setQuery] = createSignal("")
  const [selected, setSelected] = createSignal(0)
  let filterInput: InputRenderable | undefined

  const filtered = createMemo(() => filterSessionList(sessions(), query()))
  const visible = () => visibleDefault

  const windowed = createMemo(() => {
    const items = filtered()
    if (items.length === 0) return [] as SolidSessionEntry[]
    const index = Math.min(Math.max(0, selected()), items.length - 1)
    const size = visible()
    const start = Math.max(0, Math.min(index - Math.floor(size / 2), items.length - size))
    return items.slice(start, start + size)
  })

  const filterHeader = createMemo(() =>
    formatSessionFilterHeader(filtered().length, sessions().length, query()),
  )

  const move = (action: Parameters<typeof moveSessionSelection>[2]) => {
    const items = filtered()
    if (items.length === 0) return
    setPendingDeleteId(undefined)
    setSelected((current) => moveSessionSelection(current, items.length, action, visible()))
  }

  const current = () => filtered()[Math.min(Math.max(0, selected()), Math.max(0, filtered().length - 1))]

  const selectCurrent = () => {
    const session = current()
    if (!session) return
    dialog.clear()
    props.onSelect?.(session)
  }

  const [pendingDeleteId, setPendingDeleteId] = createSignal<string | undefined>()

  const deleteCurrent = () => {
    const session = current()
    if (!session || !props.onDelete) return
    // Two-step confirm: first `d` arms, second `d` on the same row deletes.
    if (pendingDeleteId() !== session.id) {
      setPendingDeleteId(session.id)
      return
    }
    setPendingDeleteId(undefined)
    props.onDelete(session)
    setSessions((prev) => prev.filter((item) => item.id !== session.id))
    setSelected((currentSelected) => Math.max(0, Math.min(currentSelected, filtered().length - 2)))
  }

  const renameCurrent = () => {
    const session = current()
    if (!session) return
    openSessionRenameDialog(dialog, {
      session,
      onConfirm: (title) => {
        props.onRename?.(session, title)
        setSessions((prev) =>
          prev.map((item) => (item.id === session.id ? { ...item, title } : item)),
        )
      },
    })
  }

  onMount(() => {
    queueMicrotask(() => filterInput?.focus())
  })

  useKeyboard((key: KeyEvent) => {
    // Rename (and any pushed dialog) owns keys while stacked above this list.
    if (dialog.stack().length > 1) return
    if (key.name === "up") {
      key.preventDefault()
      move("up")
      return
    }
    if (key.name === "down") {
      key.preventDefault()
      move("down")
      return
    }
    if (key.name === "home") {
      key.preventDefault()
      move("home")
      return
    }
    if (key.name === "end") {
      key.preventDefault()
      move("end")
      return
    }
    if (key.name === "pageup") {
      key.preventDefault()
      move("pageup")
      return
    }
    if (key.name === "pagedown") {
      key.preventDefault()
      move("pagedown")
      return
    }
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      selectCurrent()
      return
    }
    // Ctrl chords avoid colliding with type-to-filter in the input.
    // Note: focused <input> may swallow Ctrl+E (readline end-of-line); prefer `r`
    // when the filter is empty, and keep Ctrl+E as a secondary chord.
    if (key.ctrl && !key.meta && key.name === "e") {
      key.preventDefault()
      renameCurrent()
      return
    }
    if (key.ctrl && !key.meta && key.name === "n") {
      key.preventDefault()
      dialog.clear()
      props.onCreate?.()
      return
    }
    if (key.ctrl && !key.meta && key.name === "l") {
      key.preventDefault()
      setQuery("")
      setSelected(0)
      return
    }
    // Bare keys only when the filter is empty so typing still filters.
    if (!key.ctrl && !key.meta && !key.shift && query().trim() === "") {
      if (key.name === "r") {
        key.preventDefault()
        renameCurrent()
        return
      }
      if (key.name === "d") {
        key.preventDefault()
        deleteCurrent()
        return
      }
      if (key.name === "n") {
        key.preventDefault()
        dialog.clear()
        props.onCreate?.()
        return
      }
      const jump = sessionDigitIndex(key.name, filtered().length)
      if (jump !== undefined) {
        key.preventDefault()
        setSelected(jump)
      }
    }
  })

  return (
    <box width="100%" flexDirection="column" gap={1}>
      <DialogHeader title="Sessions" hint="Enter · r rename · d delete · n new · Esc" />
      <Show when={pendingDeleteId()}>
        <text fg={colors.brand}>
          Press d again to permanently delete this session and its history.
        </text>
      </Show>
      <Show when={filterHeader()}>
        {(header) => <text fg={colors.muted}>{header()}</text>}
      </Show>
      <input
        ref={(next: InputRenderable) => {
          filterInput = next
        }}
        width="100%"
        focused={true}
        placeholder="Filter sessions…"
        placeholderColor={colors.muted}
        textColor={colors.inputText}
        focusedTextColor={colors.inputText}
        backgroundColor={colors.inputBg}
        focusedBackgroundColor={colors.inputFocusBg}
        cursorColor={colors.cursor}
        onInput={(value: string) => {
          setQuery(value)
          setPendingDeleteId(undefined)
          setSelected(0)
        }}
      />
      <Show
        when={filtered().length > 0}
        fallback={
          <text fg={colors.muted}>
            {query().trim()
              ? "No sessions match this filter."
              : "No sessions yet. Press n to start one."}
          </text>
        }
      >
        <box width="100%" flexDirection="column">
          <For each={windowed()}>
            {(session) => {
              const items = filtered()
              const index = () => items.indexOf(session)
              const active = () => index() === selected()
              const currentSession = () => props.activeId === session.id
              return (
                <box
                  width="100%"
                  flexDirection="column"
                  backgroundColor={active() ? colors.inputFocusBg : colors.panelBg}
                  paddingLeft={1}
                  paddingRight={1}
                >
                  <text fg={active() ? colors.brand : colors.body}>
                    {active() ? "▸ " : currentSession() ? "● " : "  "}
                    {session.title}
                    {pendingDeleteId() === session.id ? " · delete? press d again" : ""}
                  </text>
                  <text fg={colors.muted}>
                    {"    "}
                    {session.directory}
                  </text>
                </box>
              )
            }}
          </For>
        </box>
        <text fg={colors.muted}>
          {filtered().length} session{filtered().length === 1 ? "" : "s"} · ↑/↓ · 1-9 jump
        </text>
      </Show>
    </box>
  )
}

export function openSessionListDialog(
  dialog: ReturnType<typeof useDialog>,
  props: SessionListDialogProps,
) {
  dialog.replace(() => <SessionListDialog {...props} />, { size: "large" })
}
