// Formats provider-reported token counts for the status bar. Only call this
// when the server set usage_reported; never invent estimates.
export function formatTokenCount(tokens: number): string {
  if (!Number.isFinite(tokens) || tokens < 0) return "0"
  if (tokens >= 1_000_000) {
    const millions = tokens / 1_000_000
    return `${millions >= 10 ? Math.round(millions) : millions.toFixed(1)}M`
  }
  if (tokens >= 10_000) return `${Math.round(tokens / 1000)}k`
  if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`
  return String(Math.round(tokens))
}

export function formatReportedUsage(inputTokens: number, outputTokens: number): string {
  return `${formatTokenCount(inputTokens)} in · ${formatTokenCount(outputTokens)} out`
}

export function statusWithUsage(
  provider: string,
  model: string,
  usage?: { usage_reported?: boolean; input_tokens?: number; output_tokens?: number },
): string {
  const base = `● ${provider}  ·  ${model}`
  if (!usage?.usage_reported) return base
  const input = usage.input_tokens ?? 0
  const output = usage.output_tokens ?? 0
  return `${base}  ·  ${formatReportedUsage(input, output)}`
}
