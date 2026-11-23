import type { ApiPluginCatalogEntry, ApiSessionPluginMcpServer } from "../api-client"
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
  plugins: readonly ApiPluginCatalogEntry[] = [],
): SolidMcpServer[] {
  const trustedByKey = new Map(trusted.map((item) => [`${item.plugin_name}/${item.server_name}`, item]))
  const rows: SolidMcpServer[] = []
  for (const server of configured?.servers ?? []) {
    const key = `configured/${server.name}`
    const trustedHit = trustedByKey.get(key)
    rows.push({
      name: key,
      transport: server.transport,
      scope: server.scope ?? "user",
      status: !server.enabled ? "disabled" : trustedHit ? "trusted" : "available",
      workspaceWriteAccess: trustedHit?.workspace_write_access ?? false,
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
    const pluginServer = plugins
      .find((plugin) => plugin.name === item.plugin_name)
      ?.mcp_servers?.find((server) => server.name === item.server_name)
    rows.push({
      name: key,
      transport: pluginServer?.transport ?? "plugin",
      scope: "session",
      status: "trusted",
      workspaceWriteAccess: item.workspace_write_access ?? false,
    })
  }
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}
