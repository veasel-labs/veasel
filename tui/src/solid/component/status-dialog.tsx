/** @jsxImportSource @opentui/solid */
import { For, Show, createMemo } from "solid-js"
import { useKeyboard, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { dialogGeometry, wrappedLineCount } from "../ui/dialog-layout"
import { useSolidTheme } from "../theme"
import type { Theme } from "../../themes"
import type { SolidMcpServer } from "./mcp-dialog"

export type StatusDialogSnapshot = {
  sessionTitle: string
  directory: string
  provider?: string
  model?: string
  agent?: string
  variant?: string
  usageLine?: string
  connection?: string
  mcpServers: SolidMcpServer[]
}

/**
 * Like the provider dialog, this dialog's fixed chrome (three optional
 * detail lines, each followed by a gap row) already exceeds the content
 * height at 24 rows, so treat 24 rows as compact too: gaps and the MCP
 * section margin collapse and the list gets the space.
 */
export function statusDialogCompact(columns: number, rows: number): boolean {
  return dialogGeometry(columns, rows, 72).compact || rows <= 24
}

/**
 * MCP rows that fit the dialog at this terminal size. Fixed chrome is
 * charged against the shared dialog content height: DialogLayout header
 * and footer with their gaps and bottom padding (5), the session and
 * directory lines (2), each optional detail line present (connection,
 * model, usage), and the MCP header (1). Outside compact heights each
 * detail line also carries a gap row, as do the fixed sections, plus
 * the MCP section margin. One extra row is reserved for the "+N more"
 * summary whenever the list is truncated, so hidden servers are
 * acknowledged instead of silently dropped. At tiny heights the fixed
 * chrome alone fills the box, so zero rows is a valid result — the
 * "MCP (N)" header plus summary still state the true total.
 */
export function statusMcpVisibleCount(
  columns: number,
  rows: number,
  total: number,
  detailLines: number,
  wrappedExtra = 0,
): number {
  const { contentHeight } = dialogGeometry(columns, rows, 72)
  const compact = statusDialogCompact(columns, rows)
  // Wrap-continuation lines (wrappedExtra) cost one row each with no
  // accompanying gap, unlike detail entries outside compact heights.
  const chrome = (compact ? 8 + detailLines : 11 + 2 * detailLines) + wrappedExtra
  const budget = contentHeight - chrome
  const withSummaryRow = total > budget ? budget - 1 : budget
  return Math.max(0, Math.min(total, withSummaryRow))
}

function mcpStatusColor(status: SolidMcpServer["status"], colors: Theme): string {
  switch (status) {
    case "connected":
      return colors.statusOk
    case "failed":
      return colors.statusError
    case "needs_auth":
      return colors.statusWarn
    default:
      return colors.muted
  }
}

function mcpStatusLabel(server: SolidMcpServer): string {
  switch (server.status) {
    case "connected":
      return "Connected"
    case "trusted":
      return "Trusted · review each call"
    case "failed":
      return server.error ?? "Failed"
    case "needs_auth":
      return server.error ? `Needs auth · ${server.error}` : "Needs authentication"
    case "pending":
      return "Connecting…"
    default:
      return "Disabled"
  }
}

export function demoStatusSnapshot(): StatusDialogSnapshot {
  return {
    sessionTitle: "Solid transcript",
    directory: "~/veasel",
    provider: "anthropic",
    model: "claude-sonnet-4",
    agent: "build",
    variant: "default",
    usageLine: "12.4k in · 1.8k out · 42% cache reads",
    connection: "LOCAL · loopback",
    mcpServers: [
      { name: "filesystem", transport: "stdio", status: "connected" },
      { name: "echo-tools", transport: "stdio", status: "failed", error: "spawn ENOENT" },
    ],
  }
}

export function StatusDialog(props: StatusDialogSnapshot) {
  const colors = useSolidTheme()
  const dialog = useDialog()
  const dimensions = useTerminalDimensions()
  // At tiny heights (contentHeight <= 10, e.g. 32x12) the fixed lines
  // alone exceed the box and squash into each other. Drop the two
  // least essential detail lines and the footer there; session,
  // directory, model, and the MCP header/summary still fit.
  const tiny = () =>
    dialogGeometry(dimensions().width, dimensions().height, 72).contentHeight <= 10
  const showConnection = () => !!props.connection && !tiny()
  const showUsage = () => !!props.usageLine && !tiny()
  // Model and usage lines word-wrap at narrow widths (the usage tail
  // carries the cost, so truncating it loses information). Charge
  // their wrap-continuation lines — plus a wrapped footer's — against
  // the MCP budget instead of assuming one line each. At tiny heights
  // the model line truncates to one line instead (see render below).
  const modelLine = () =>
    props.provider && props.model
      ? `Model · ${props.provider}/${props.model}` +
        (props.agent ? ` · agent ${props.agent}` : "") +
        (props.variant ? ` · variant ${props.variant}` : "")
      : undefined
  const detailLines = () =>
    (showConnection() ? 1 : 0) + (modelLine() ? 1 : 0) + (showUsage() ? 1 : 0)
  const wrappedExtra = () => {
    if (tiny()) return 0
    const geometry = dialogGeometry(dimensions().width, dimensions().height, 72)
    const contentWidth = Math.max(1, geometry.width - 2 - geometry.paddingX * 2)
    const model = modelLine()
    return (
      (model ? wrappedLineCount(model, contentWidth) - 1 : 0) +
      (showUsage() ? wrappedLineCount(`Usage · ${props.usageLine}`, contentWidth) - 1 : 0) +
      (wrappedLineCount("Usage reflects provider-reported totals · Enter closes", contentWidth) - 1)
    )
  }
  const visibleServers = createMemo(() =>
    props.mcpServers.slice(
      0,
      statusMcpVisibleCount(
        dimensions().width,
        dimensions().height,
        props.mcpServers.length,
        detailLines(),
        wrappedExtra(),
      ),
    ),
  )
  const hiddenCount = () => props.mcpServers.length - visibleServers().length
  const compact = () => statusDialogCompact(dimensions().width, dimensions().height)

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="Status" hint="Enter · Esc" />}
      footer={
        tiny() ? undefined : (
          <text fg={colors.muted} flexShrink={0}>
            Usage reflects provider-reported totals · Enter closes
          </text>
        )
      }
    >
      <box flexDirection="column" gap={compact() ? 0 : 1}>
        <text fg={colors.body} wrapMode="none" flexShrink={0}>
          <span style={{ fg: colors.muted }}>Session </span>
          {props.sessionTitle}
        </text>
        <text fg={colors.muted} wrapMode="none" flexShrink={0}>
          Directory · {props.directory}
        </text>
        <Show when={showConnection() ? props.connection : undefined}>
          {(line) => (
            <text fg={colors.localStatus} wrapMode="none" flexShrink={0}>
              {line()}
            </text>
          )}
        </Show>
        <Show when={props.provider && props.model}>
          <text fg={colors.body} wrapMode={tiny() ? "none" : "word"} flexShrink={0}>
            Model · {props.provider}/{props.model}
            <Show when={props.agent}>
              {(agent) => (
                <span style={{ fg: colors.muted }}>
                  {" "}
                  · agent {agent()}
                </span>
              )}
            </Show>
            <Show when={props.variant}>
              {(variant) => (
                <span style={{ fg: colors.muted }}>
                  {" "}
                  · variant {variant()}
                </span>
              )}
            </Show>
          </text>
        </Show>
        <Show when={showUsage() ? props.usageLine : undefined}>
          {(line) => (
            <text fg={colors.muted} flexShrink={0}>
              Usage · {line()}
            </text>
          )}
        </Show>
        <box marginTop={compact() ? 0 : 1} flexDirection="column" gap={0}>
          <text fg={colors.headerTitle} flexShrink={0}>
            MCP ({props.mcpServers.length})
          </text>
          <Show
            when={props.mcpServers.length > 0}
            fallback={<text fg={colors.muted}>No MCP servers configured</text>}
          >
            <For each={visibleServers()}>
              {(server) => (
                <box flexDirection="row" gap={1} flexShrink={0}>
                  <text flexShrink={0} fg={mcpStatusColor(server.status, colors)}>
                    •
                  </text>
                  <text fg={colors.body} wrapMode="none">
                    <strong>{server.name}</strong>{" "}
                    <span style={{ fg: colors.muted }}>{mcpStatusLabel(server)}</span>
                  </text>
                </box>
              )}
            </For>
            <Show when={hiddenCount() > 0}>
              <text fg={colors.muted} wrapMode="none" flexShrink={0}>
                +{hiddenCount()} more · open MCP dialog for full list
              </text>
            </Show>
          </Show>
        </box>
      </box>
    </DialogLayout>
  )
}

export function openStatusDialog(
  dialog: ReturnType<typeof useDialog>,
  snapshot: StatusDialogSnapshot,
) {
  dialog.replace(() => <StatusDialog {...snapshot} />, { size: "large" })
}
