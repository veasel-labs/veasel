/** @jsxImportSource @opentui/solid */
import { Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { filetypeFromReviewPath, diffRenderableTheme } from "../../diff-view"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"
import { useSolidTheme } from "../theme"
import {
  sessionDiffFileRows,
  sessionDiffStatusLabel,
  summarizeUnifiedDiff,
  type WorkspaceEditProposal,
  type WorkspaceEditSummary,
} from "../session-diff"

export type SessionDiffDialogProps = {
  edits: WorkspaceEditSummary[]
  loadDiff: (editId: string) => Promise<WorkspaceEditProposal>
  onError?: (message: string) => void
}

function SessionDiffView(props: { proposal: WorkspaceEditProposal }) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const dimensions = useTerminalDimensions()
  const stats = createMemo(() => summarizeUnifiedDiff(props.proposal.diff))
  const diffTheme = () => diffRenderableTheme(colors)

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="Session diff" hint="Enter · Esc" />}
      footer={
        <text fg={colors.muted}>
          {sessionDiffStatusLabel(props.proposal.status)} · +{stats().added} −{stats().removed} · OpenTUI
          split
        </text>
      }
    >
      <text fg={colors.body}>
        <strong>{props.proposal.path}</strong>
      </text>
      <Show
        when={props.proposal.diff.trim().length > 0}
        fallback={<text fg={colors.muted}>Empty diff</text>}
      >
        <diff
          width="100%"
          height={Math.max(10, Math.min(22, dimensions().height - 12))}
          diff={props.proposal.diff}
          view="split"
          filetype={filetypeFromReviewPath(props.proposal.path)}
          fg={diffTheme().fg}
          addedSignColor={diffTheme().addedSignColor}
          removedSignColor={diffTheme().removedSignColor}
          lineNumberFg={diffTheme().lineNumberFg}
          addedBg={diffTheme().addedBg}
          removedBg={diffTheme().removedBg}
          contextBg={diffTheme().contextBg}
          addedContentBg={diffTheme().addedContentBg}
          removedContentBg={diffTheme().removedContentBg}
          contextContentBg={diffTheme().contextContentBg}
          selectionBg={diffTheme().selectionBg}
          selectionFg={diffTheme().selectionFg}
          showLineNumbers={diffTheme().showLineNumbers}
          syncScroll={diffTheme().syncScroll}
          wrapMode={diffTheme().wrapMode}
        />
      </Show>
    </DialogLayout>
  )
}

function SessionDiffLoader(props: {
  editId: string
  path: string
  loadDiff: (editId: string) => Promise<WorkspaceEditProposal>
  onError?: (message: string) => void
}) {
  const colors = useSolidTheme()
  const [proposal, setProposal] = createSignal<WorkspaceEditProposal | undefined>()
  const [failed, setFailed] = createSignal<string | undefined>()

  onMount(() => {
    void props
      .loadDiff(props.editId)
      .then((next) => setProposal(next))
      .catch((error) => {
        const message = error instanceof Error ? error.message : "failed to load diff"
        setFailed(message)
        props.onError?.(message)
      })
  })

  return (
    <Show
      when={proposal()}
      fallback={
        <Show
          when={failed()}
          fallback={
            <DialogLayout header={<DialogHeader title="Session diff" hint="Esc" />}>
              <text fg={colors.muted}>Loading · {props.path}</text>
            </DialogLayout>
          }
        >
          {(message) => (
            <DialogLayout header={<DialogHeader title="Session diff" hint="Esc" />}>
              <text fg={colors.statusError}>{message()}</text>
            </DialogLayout>
          )}
        </Show>
      }
    >
      {(loaded) => <SessionDiffView proposal={loaded()} />}
    </Show>
  )
}

/** File picker → split DiffRenderable for a workspace edit proposal. */
export function openSessionDiffDialog(
  dialog: ReturnType<typeof useDialog>,
  props: SessionDiffDialogProps,
) {
  const rows = sessionDiffFileRows(props.edits)
  if (rows.length === 0) {
    props.onError?.("No workspace edit proposals in this session")
    return
  }

  openDialogSelect(dialog, {
    title: "Session diffs",
    placeholder: "Filter path / status / id…",
    options: rows.map((row) => ({
      title: row.path,
      value: row.id,
      description: `${sessionDiffStatusLabel(row.status)} · ${row.name}`,
      searchText: row.searchText,
    })),
    onSelect: (option) => {
      const row = rows.find((item) => item.id === option.value)
      if (!row) return
      dialog.replace(
        () => (
          <SessionDiffLoader
            editId={row.id}
            path={row.path}
            loadDiff={props.loadDiff}
            onError={props.onError}
          />
        ),
        { size: "large" },
      )
    },
    footer: `${rows.length} file${rows.length === 1 ? "" : "s"} · Enter opens split diff`,
  })
}
