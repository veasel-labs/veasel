export function mcpReviewLineBudget(terminalRows: number): number {
  return Math.max(6, terminalRows - 20)
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
}): string {
  const parts = [
    `${input.plugin}/${input.server} · ${input.tool}`,
    `Operation: ${input.operationId}`,
  ]
  if (input.pending) {
    parts.push(`This call has not reached its MCP server. Type /mcp call approve ${input.id} or /mcp call reject ${input.id}.`)
  }
  parts.push("Arguments (terminal control and direction characters are escaped):")
  const body = formatBoundedReviewLines(input.argumentsText, input.maxLines)
  if (body) parts.push(body)
  return parts.join("\n")
}
