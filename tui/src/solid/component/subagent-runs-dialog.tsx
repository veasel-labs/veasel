/** @jsxImportSource @opentui/solid */
import { createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent, ScrollBoxRenderable } from "@opentui/core"
import type { VeaselApiClient } from "../../api-client"
import { subagentCanCancel, subagentCanIntegrate, subagentRunDetails, subagentRunOption, toSubagentRunView, type SubagentRunView } from "../subagent-runs"
import { openDialogAlert } from "../ui/dialog-alert"
import { DialogHeader, DialogLayout } from "../ui/dialog"
import { dialogGeometry } from "../ui/dialog-layout"
import { useSolidTheme } from "../theme"
import { DialogSelect, type DialogSelectOption } from "../ui/dialog-select"
import { useDialog, type DialogHost } from "../ui/dialog"

type SubagentRunsDialogProps = {
  api: VeaselApiClient
  sessionId: string
  onFollowUp?: (run: SubagentRunView) => void
  onIntegrate?: (run: SubagentRunView) => void
}

function SubagentRunActions(props: { run: SubagentRunView; api: VeaselApiClient; sessionId: string; onFollowUp?: (run: SubagentRunView) => void; onIntegrate?: (run: SubagentRunView) => void }) {
  const dialog = useDialog()
  const actions = createMemo((): DialogSelectOption<string>[] => [
    { title: "Inspect result and provenance", value: "inspect", description: "Show the durable child outcome, model, and workspace" },
    ...(subagentCanCancel(props.run)
      ? [{ title: "Request cancellation", value: "cancel", description: "Cancel only this child execution" }]
      : []),
    ...(subagentCanIntegrate(props.run) && props.onIntegrate
      ? [{ title: "Integrate changes", value: "integrate", description: "Create parent-workspace proposals for explicit review" }]
      : []),
    ...(props.onFollowUp
      ? [{ title: "Continue in child session", value: "follow-up", description: "Open this child session to send a follow-up" }]
      : []),
  ])
  return <DialogSelect
    title={`${props.run.agent_id} · ${props.run.status}`}
    options={actions()}
    footer="Actions are scoped to this child · Esc closes"
    dismissOnSelect={false}
    onSelect={(option) => {
      if (option.value === "inspect") {
        dialog.replace(() => <SubagentResultDialog run={props.run} />)
      } else if (option.value === "cancel") {
        void props.api.cancelSubagent(props.sessionId, props.run.id).then((updated) => {
          openDialogAlert(dialog, {
            title: "Cancellation recorded",
            message: `Run ${updated.id} is ${updated.status}${updated.cancel_requested ? " · cancellation requested" : ""}.`,
            confirmLabel: "close",
          })
        }).catch((error: unknown) => {
          openDialogAlert(dialog, {
            title: "Could not cancel agent",
            message: error instanceof Error ? error.message : "The cancellation request failed.",
            confirmLabel: "close",
          })
        })
      } else if (option.value === "follow-up") {
        dialog.clear()
        props.onFollowUp?.(props.run)
      } else if (option.value === "integrate") {
        props.onIntegrate?.(props.run)
      }
    }}
  />
}

function SubagentResultDialog(props: { run: SubagentRunView }) {
  const colors = useSolidTheme()
  const dimensions = useTerminalDimensions()
  const dialog = useDialog()
  let scroll: ScrollBoxRenderable | undefined
  useKeyboard((key: KeyEvent) => {
    if (key.name === "up") { key.preventDefault(); scroll?.scrollBy(-1) }
    else if (key.name === "down") { key.preventDefault(); scroll?.scrollBy(1) }
    else if (key.name === "pageup") { key.preventDefault(); scroll?.scrollBy(-8) }
    else if (key.name === "pagedown") { key.preventDefault(); scroll?.scrollBy(8) }
    else if (key.name === "home") { key.preventDefault(); scroll?.scrollTo(0) }
    else if (key.name === "end") { key.preventDefault(); scroll?.scrollTo(Number.MAX_SAFE_INTEGER) }
    else if (key.name === "return" || key.name === "kpenter") { key.preventDefault(); dialog.pop() }
  })
  return <DialogLayout
    header={<DialogHeader title={`Agent · ${props.run.status}`} hint="↑/↓ · PgUp/PgDn · Enter" />}
    footer={<text fg={colors.muted}>Run outcome and provider provenance · Enter returns</text>}
  >
    <scrollbox
      ref={(next: ScrollBoxRenderable) => { scroll = next }}
      width="100%"
      height={Math.max(2, dialogGeometry(dimensions().width, dimensions().height, 72).contentHeight - 5)}
      stickyScroll={false}
    >
      <text fg={colors.body}>{subagentRunDetails(props.run)}</text>
    </scrollbox>
  </DialogLayout>
}

function SubagentRunsDialog(props: SubagentRunsDialogProps) {
  const dialog = useDialog()
  const [runs, setRuns] = createSignal<SubagentRunView[]>([])
  const [loading, setLoading] = createSignal(true)
  const [error, setError] = createSignal<string>()
  let refreshTimer: ReturnType<typeof setTimeout> | undefined
  let disposed = false
  const load = async () => {
    setLoading(true)
    try {
      const next = (await props.api.listSubagents(props.sessionId)).map(toSubagentRunView)
      if (disposed) return
      setRuns(next)
      setError(undefined)
      if (next.some((run) => run.status === "queued" || run.status === "running")) {
        refreshTimer = setTimeout(() => void load(), 1500)
      }
    } catch (cause) {
      if (!disposed) {
        setError(cause instanceof Error ? cause.message : "Could not load delegated agents.")
        refreshTimer = setTimeout(() => void load(), 3000)
      }
    } finally {
      if (!disposed) setLoading(false)
    }
  }
  onMount(() => {
    void load()
  })
  onCleanup(() => {
    disposed = true
    if (refreshTimer) clearTimeout(refreshTimer)
  })
  const options = createMemo((): DialogSelectOption<string>[] => {
    if (runs().length > 0) return runs().map(subagentRunOption)
    return [{
      title: loading() ? "Loading agents…" : error() ? "Agents unavailable" : "No delegated agents yet",
      value: "__empty__",
      description: error() ?? "Delegated work from this conversation will appear here.",
      searchText: "",
    }]
  })
  return <DialogSelect
    title={`Agents · ${runs().length}`}
    options={options()}
    placeholder="Filter task, role, model, or status…"
    footer={error() ?? (loading() ? "Refreshing durable agent state…" : "Enter to inspect · select a child to view actions · Esc closes")}
    dismissOnSelect={false}
    onSelect={(option) => {
      const run = runs().find((item) => item.id === option.value)
      if (!run) return
      dialog.replace(() => <SubagentRunActions run={run} api={props.api} sessionId={props.sessionId} onFollowUp={props.onFollowUp} onIntegrate={props.onIntegrate} />)
    }}
  />
}

export function openSubagentRunsDialog(dialog: DialogHost, props: SubagentRunsDialogProps) {
  dialog.replace(() => <SubagentRunsDialog {...props} />, { size: "large" })
}
