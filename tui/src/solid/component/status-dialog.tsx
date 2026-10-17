/** @jsxImportSource @opentui/solid */
import { For, Show } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
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

  useKeyboard((key: KeyEvent) => {
    if (key.name === "return" || key.name === "kpenter") {
      key.preventDefault()
      dialog.clear()
    }
  })

  return (
    <DialogLayout
      header={<DialogHeader title="Status" hint="Enter · Esc" />}
      footer={<text fg={colors.muted}>Rich status · wire to /usage and live MCP list</text>}
    >
      <box flexDirection="column" gap={1}>
        <text fg={colors.body}>
          <span style={{ fg: colors.muted }}>Session </span>
          {props.sessionTitle}
        </text>
        <text fg={colors.muted}>Directory · {props.directory}</text>
        <Show when={props.connection}>
          {(line) => <text fg={colors.localStatus}>{line()}</text>}
        </Show>
        <Show when={props.provider && props.model}>
          <text fg={colors.body}>
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
        <Show when={props.usageLine}>
          {(line) => <text fg={colors.muted}>Usage · {line()}</text>}
        </Show>
        <box marginTop={1} flexDirection="column" gap={0}>
          <text fg={colors.headerTitle}>
            MCP ({props.mcpServers.length})
          </text>
          <Show
            when={props.mcpServers.length > 0}
            fallback={<text fg={colors.muted}>No MCP servers configured</text>}
          >
            <For each={props.mcpServers}>
              {(server) => (
                <box flexDirection="row" gap={1}>
                  <text flexShrink={0} fg={mcpStatusColor(server.status, colors)}>
                    •
                  </text>
                  <text fg={colors.body} wrapMode="word">
                    <strong>{server.name}</strong>{" "}
                    <span style={{ fg: colors.muted }}>{mcpStatusLabel(server)}</span>
                  </text>
                </box>
              )}
            </For>
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
