// Named MCP HTTP credentials: header names only — secret values never appear.

export type McpCredentialView = {
  name: string
  header_names: string[]
}

export type McpCredentialCatalog = {
  path?: string
  credentials: McpCredentialView[]
}

export function formatMcpCredentialLine(credential: McpCredentialView): string {
  const headers = credential.header_names.length > 0
    ? credential.header_names.join(", ")
    : "(no headers)"
  return `• ${credential.name}  ·  headers: ${headers}`
}

export function formatMcpCredentialCatalog(catalog: McpCredentialCatalog): string {
  const lines = ["MCP HTTP CREDENTIALS"]
  if (catalog.path) lines.push(`Store: ${catalog.path}`)
  lines.push("Secret values are never shown. Streamable HTTP servers may reference a credential by name.")
  lines.push("")
  if (catalog.credentials.length === 0) {
    lines.push("No named credentials yet. Create one with /mcp credential set <name> <Header>=<value>…")
    lines.push("Or complete OAuth into a name with /mcp oauth authorize … then /mcp oauth complete …")
    lines.push("Refresh a stored OAuth credential with /mcp oauth refresh <name> (no secrets shown).")
  } else {
    for (const credential of catalog.credentials) {
      lines.push(formatMcpCredentialLine(credential))
    }
    lines.push("")
    lines.push("Remove with /mcp credential remove <name>. Servers that still reference a removed name fail at connect until updated.")
    lines.push("OAuth: /mcp oauth refresh <name> when refresh metadata exists (header names only).")
  }
  return lines.join("\n")
}

export function parseMcpCredentialHeaders(raw: string): { headers: Record<string, string>; error?: string } {
  const headers: Record<string, string> = {}
  const parts = raw.trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return { headers, error: "Provide at least one Header=value pair." }
  for (const part of parts) {
    const eq = part.indexOf("=")
    if (eq <= 0) return { headers: {}, error: `Expected Header=value, got “${part}”.` }
    const name = part.slice(0, eq).trim()
    const value = part.slice(eq + 1)
    if (!name) return { headers: {}, error: `Empty header name in “${part}”.` }
    if (Object.prototype.hasOwnProperty.call(headers, name)) {
      return { headers: {}, error: `Duplicate header “${name}”.` }
    }
    headers[name] = value
  }
  return { headers }
}
