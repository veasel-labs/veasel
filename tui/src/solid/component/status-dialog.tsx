/** @jsxImportSource @opentui/solid */
import { For, Show } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { KeyEvent } from "@opentui/core"
import { DialogHeader, DialogLayout, useDialog } from "../ui/dialog"
import { solidMint } from "../theme"
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

function mcpStatusColor(status: SolidMcpServer["status"]): string {
  switch (status) {
    case "connected":
      return solidMint.statusOk
    case "failed":
      return solidMint.statusError
    case "needs_auth":
      return solidMint.statusWarn
    default:
      return solidMint.muted
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
      footer={<text fg={solidMint.muted}>Rich status · wire to /usage and live MCP list</text>}
    >
      <box flexDirection="column" gap={1}>
        <text fg={solidMint.body}>
          <span style={{ fg: solidMint.muted }}>Session </span>
          {props.sessionTitle}
        </text>
        <text fg={solidMint.muted}>Directory · {props.directory}</text>
        <Show when={props.connection}>
          {(line) => <text fg={solidMint.localStatus}>{line()}</text>}
        </Show>
        <Show when={props.provider && props.model}>
          <text fg={solidMint.body}>
            Model · {props.provider}/{props.model}
            <Show when={props.agent}>
              {(agent) => (
                <span style={{ fg: solidMint.muted }}>
                  {" "}
                  · agent {agent()}
                </span>
              )}
            </Show>
            <Show when={props.variant}>
              {(variant) => (
                <span style={{ fg: solidMint.muted }}>
                  {" "}
                  · variant {variant()}
                </span>
              )}
            </Show>
          </text>
        </Show>
        <Show when={props.usageLine}>
          {(line) => <text fg={solidMint.muted}>Usage · {line()}</text>}
        </Show>
        <box marginTop={1} flexDirection="column" gap={0}>
          <text fg={solidMint.headerTitle}>
            MCP ({props.mcpServers.length})
          </text>
          <Show
            when={props.mcpServers.length > 0}
            fallback={<text fg={solidMint.muted}>No MCP servers configured</text>}
          >
            <For each={props.mcpServers}>
              {(server) => (
                <box flexDirection="row" gap={1}>
                  <text flexShrink={0} fg={mcpStatusColor(server.status)}>
                    •
                  </text>
                  <text fg={solidMint.body} wrapMode="word">
                    <strong>{server.name}</strong>{" "}
                    <span style={{ fg: solidMint.muted }}>{mcpStatusLabel(server)}</span>
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
