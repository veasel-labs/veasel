import {
  formatSandboxPreviewLine,
  sandboxCapabilityFromPreview,
  type ReviewSandboxPreview,
} from "./shell-review"

export function mcpReviewLineBudget(terminalRows: number): number {
  return Math.max(6, terminalRows - 20)
}

export function mcpStdioSandboxWarning(preview: ReviewSandboxPreview | undefined): string {
  const capability = sandboxCapabilityFromPreview(preview)
  if (capability === "bubblewrap") {
    return "Trusted stdio MCP will wrap in Linux Bubblewrap when this call uses stdio (read-only host, writable PLUGIN_ROOT/PLUGIN_DATA, network shared). Streamable HTTP ignores this wrap. Review every effect before approval."
  }
  if (capability === "seatbelt") {
    return "Trusted stdio MCP will wrap in macOS Seatbelt when this call uses stdio (writable PLUGIN_ROOT/PLUGIN_DATA, network shared). Streamable HTTP ignores this wrap. Review every effect before approval."
  }
  if (capability === "windows") {
    return "Trusted stdio MCP will wrap in Windows AppContainer + Job when this call uses stdio (writable PLUGIN_ROOT/PLUGIN_DATA, network shared). Streamable HTTP ignores this wrap. Review every effect before approval."
  }
  if (preview?.mode === "require") {
    return "This stdio MCP server will not start because the required OS sandbox is unavailable. Set VEASEL_MCP_STDIO_SANDBOX=off only if you intentionally accept unsandboxed OS-user privileges. Streamable HTTP is unaffected."
  }
  if (preview?.mode === "auto") {
    return "This explicit auto policy falls back to unsandboxed OS-user privileges when no platform sandbox is available. Set VEASEL_MCP_STDIO_SANDBOX=require to fail closed. Streamable HTTP ignores this wrap. Review every effect before approval."
  }
  return "Trusted stdio MCP is running unsandboxed because VEASEL_MCP_STDIO_SANDBOX=off was explicitly set; it inherits OS-user privileges. Streamable HTTP ignores this wrap. Review every effect before approval."
}

function escapeReviewLine(line: string): string {
  return line.replace(
    /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/gu,
    (character) => `\\u${(character.codePointAt(0) ?? 0).toString(16).padStart(4, "0")}`,
  )
}

export function formatBoundedReviewLines(text: string, maxLines: number): string {
  const lines = text.replace(/\r\n/g, "\n").replace(/\n$/, "").split("\n").map(escapeReviewLine)
  if (lines.length === 0 || (lines.length === 1 && lines[0] === "")) return ""
  const limit = Math.max(1, maxLines)
  if (lines.length <= limit) return lines.join("\n")
  const shown = lines.slice(0, limit)
  return `Showing ${shown.length} of ${lines.length} lines.\n${shown.join("\n")}`
}

// The decision stays above the arguments so a long JSON payload cannot hide it.
export function formatMcpReview(input: {
  plugin: string
  server: string
  tool: string
  operationId: string
  id: string
  pending: boolean
  argumentsText: string
  maxLines: number
  stdioSandbox?: ReviewSandboxPreview
}): string {
  const parts = [
    `${input.plugin}/${input.server} · ${input.tool}`,
    `Operation: ${input.operationId}`,
  ]
  const previewLine = formatSandboxPreviewLine(input.stdioSandbox, "Stdio sandbox")
  if (previewLine) parts.push(previewLine)
  parts.push(mcpStdioSandboxWarning(input.stdioSandbox))
  if (input.pending) {
    parts.push(`This call has not reached its MCP server. Type /mcp call approve ${input.id} or /mcp call reject ${input.id}.`)
  }
  parts.push("Arguments (terminal control and direction characters are escaped):")
  const body = formatBoundedReviewLines(input.argumentsText, input.maxLines)
  if (body) parts.push(body)
  return parts.join("\n")
}
