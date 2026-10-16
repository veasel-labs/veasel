/** @jsxImportSource @opentui/solid */
import type { useDialog } from "../ui/dialog"
import { openDialogSelect } from "../ui/dialog-select"
import { openErrorDetailsDialog } from "./error-details-dialog"

export type SolidMcpStatus = "connected" | "failed" | "needs_auth" | "disabled" | "pending"

export type SolidMcpServer = {
  name: string
  transport: string
  status: SolidMcpStatus
  scope?: string
  error?: string
}

export type McpDialogProps = {
  servers: SolidMcpServer[]
  onSelect?: (server: SolidMcpServer) => void
  onToggle?: (server: SolidMcpServer) => void
}

function statusLabel(status: SolidMcpStatus): string {
  switch (status) {
    case "connected":
      return "Connected"
    case "failed":
      return "Failed"
    case "needs_auth":
      return "Sign in required"
    case "pending":
      return "Connecting…"
    default:
      return "Disabled"
  }
}

function statusCategory(status: SolidMcpStatus): string {
  switch (status) {
    case "connected":
      return "Connected"
    case "failed":
    case "needs_auth":
      return "Attention"
    case "pending":
      return "Pending"
    default:
      return "Disabled"
  }
}

/** Demo MCP inventory for Solid shell / tests. */
export function demoMcpServers(): SolidMcpServer[] {
  return [
    {
      name: "filesystem",
      transport: "stdio",
      status: "connected",
      scope: "project",
    },
    {
      name: "github",
      transport: "http",
      status: "needs_auth",
      scope: "user",
      error: "OAuth token expired — reconnect via /mcp auth github",
    },
    {
      name: "echo-tools",
      transport: "stdio",
      status: "failed",
      scope: "user",
      error: "spawn ENOENT: echo-mcp binary missing",
    },
    {
      name: "browser",
      transport: "stdio",
      status: "disabled",
      scope: "user",
    },
  ]
}

export function openMcpDialog(
  dialog: ReturnType<typeof useDialog>,
  props: McpDialogProps,
) {
  openDialogSelect(dialog, {
    title: "MCP servers",
    placeholder: "Filter servers…",
    size: "large",
    // Keep stack so failed/auth rows can replace with error details.
    dismissOnSelect: false,
    options: props.servers.map((server) => ({
      title: server.name,
      value: server.name,
      category: statusCategory(server.status),
      description: statusLabel(server.status),
      footer: `${server.transport}${server.scope ? ` · ${server.scope}` : ""}`,
      searchText: `${server.name} ${server.transport} ${server.scope ?? ""} ${server.error ?? ""}`,
    })),
    onSelect: (option) => {
      const server = props.servers.find((item) => item.name === option.value)
      if (!server) {
        dialog.clear()
        return
      }
      if (server.error && (server.status === "failed" || server.status === "needs_auth")) {
        openErrorDetailsDialog(dialog, {
          title: `MCP · ${server.name}`,
          source: server.transport,
          context: statusLabel(server.status),
          error: server.error,
          onClose: () => {
            // Return to the list after Esc from details.
            openMcpDialog(dialog, props)
          },
        })
        return
      }
      dialog.clear()
      props.onSelect?.(server)
    },
    footer: "Enter opens · failed/auth show error details",
  })
}
