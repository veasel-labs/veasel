// MCP OAuth authorize/complete summaries for the TUI. Never surfaces code
// verifiers or access tokens — only public authorize URLs and header names.

export type McpOauthAuthorizeView = {
  credential: string
  state: string
  authorize_url: string
  redirect_uri: string
  code_challenge_method?: string
}

export type McpOauthCredentialView = {
  name: string
  header_names: string[]
}

export function formatMcpOauthAuthorizeNotice(view: McpOauthAuthorizeView): string {
  const method = view.code_challenge_method || "S256"
  return [
    "MCP OAUTH AUTHORIZE",
    `Credential: ${view.credential}`,
    `PKCE: ${method} (challenge secret stays on the server)`,
    `State: ${view.state}`,
    `Redirect: ${view.redirect_uri}`,
    "",
    "Open this URL in a browser:",
    view.authorize_url,
    "",
    `After the loopback redirect, finish with:`,
    `/mcp oauth complete ${view.credential} <callback_url>`,
    `or /mcp oauth complete ${view.credential} ${view.state} <code>`,
  ].join("\n")
}

export function formatMcpOauthCompleteNotice(view: McpOauthCredentialView): string {
  const headers = view.header_names.length > 0 ? view.header_names.join(", ") : "(none)"
  return [
    "MCP OAUTH COMPLETE",
    `Credential ${view.name} now has headers: ${headers}.`,
    "Token values are never shown. Reference this credential from a streamable-http MCP server.",
  ].join("\n")
}
