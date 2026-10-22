import type { ApiSessionPluginMcpServer } from "../api-client"
import type { SolidMcpServer } from "./component/mcp-dialog"

export type ConfiguredMcpServerView = {
  name: string
  scope?: string
  enabled: boolean
  transport: string
  command?: string
  url_origin?: string
}

export type ConfiguredMcpCatalog = {
  servers: ConfiguredMcpServerView[]
}

/** Merge configured catalog + session-trusted plugin MCP into Solid dialog rows. */
export function solidMcpServersFromCatalog(
  configured: ConfiguredMcpCatalog | undefined,
  trusted: readonly ApiSessionPluginMcpServer[],
): SolidMcpServer[] {
  const trustedKeys = new Set(
    trusted.map((item) => `${item.plugin_name}/${item.server_name}`),
  )
  const rows: SolidMcpServer[] = []
  for (const server of configured?.servers ?? []) {
    const key = `configured/${server.name}`
    const trustedHit = trustedKeys.has(key)
    rows.push({
      name: key,
      transport: server.transport,
      scope: server.scope ?? "user",
      status: !server.enabled ? "disabled" : trustedHit ? "trusted" : "available",
      error: !server.enabled
        ? "Disabled in configured MCP settings"
        : trustedHit
          ? undefined
          : "Available · trust via /mcp trust",
    })
  }
  for (const item of trusted) {
    const key = `${item.plugin_name}/${item.server_name}`
    if (rows.some((row) => row.name === key)) continue
    rows.push({
      name: key,
      transport: "plugin",
      scope: "session",
      status: "trusted",
    })
  }
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}
