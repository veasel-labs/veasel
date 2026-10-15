// MCP OAuth authorize/complete/refresh summaries for the TUI. Never surfaces
// code verifiers, access tokens, or refresh tokens — only public authorize URLs
// and credential header names. Loopback --listen stays headless.

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

export function formatMcpOauthAuthorizeNotice(
  view: McpOauthAuthorizeView,
  options: { copiedAuthorizeUrl?: boolean } = {},
): string {
  const method = view.code_challenge_method || "S256"
  const copyCue = options.copiedAuthorizeUrl
    ? "Authorize URL copied to the clipboard (OSC 52)."
    : "Clipboard copy of the authorize URL was unavailable in this terminal."
  return [
    "MCP OAUTH AUTHORIZE",
    `Credential: ${view.credential}`,
    `PKCE: ${method} (challenge secret stays on the server)`,
    `State: ${view.state}`,
    `Redirect: ${view.redirect_uri}`,
    "",
    "Browser: open this URL to authorize (loopback redirect returns to Veasel):",
    view.authorize_url,
    copyCue,
    "",
    "Listen: for Veasel to own the loopback listener, use headless",
    `veasel mcp oauth authorize ${view.credential} … --listen`,
    "(the TUI does not bind a port).",
    "",
    "After the loopback redirect, finish with:",
    `/mcp oauth complete ${view.credential} <callback_url>`,
    `or /mcp oauth complete ${view.credential} ${view.state} <code>`,
    `Later: /mcp oauth refresh ${view.credential} when a refresh token was stored.`,
  ].join("\n")
}

export function formatMcpOauthCompleteNotice(view: McpOauthCredentialView): string {
  const headers = view.header_names.length > 0 ? view.header_names.join(", ") : "(none)"
  return [
    "MCP OAUTH COMPLETE",
    `Credential ${view.name} now has headers: ${headers}.`,
    "Token values are never shown. Reference this credential from a streamable-http MCP server.",
    `Refresh later with /mcp oauth refresh ${view.name} when the provider issued a refresh token.`,
  ].join("\n")
}

export function formatMcpOauthRefreshNotice(view: McpOauthCredentialView): string {
  const headers = view.header_names.length > 0 ? view.header_names.join(", ") : "(none)"
  return [
    "MCP OAUTH REFRESH",
    `Credential ${view.name} refreshed. Headers: ${headers}.`,
    "Token values are never shown. Stored refresh metadata rotates when the provider returns a new refresh token.",
  ].join("\n")
}
