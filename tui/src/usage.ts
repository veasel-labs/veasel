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

export function formatReportedCacheUsage(cacheReadTokens: number, cacheCreationTokens: number): string {
  return `${formatTokenCount(cacheReadTokens)} cache read · ${formatTokenCount(cacheCreationTokens)} cache write`
}

export type ReportedUsageFields = {
  usage_reported?: boolean
  input_tokens?: number
  output_tokens?: number
  cache_reported?: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
}

export function statusWithUsage(
  provider: string,
  model: string,
  usage?: ReportedUsageFields,
): string {
  const base = `● ${provider}  ·  ${model}`
  if (!usage?.usage_reported) return base
  const input = usage.input_tokens ?? 0
  const output = usage.output_tokens ?? 0
  let line = `${base}  ·  ${formatReportedUsage(input, output)}`
  if (usage.cache_reported) {
    line += `  ·  ${formatReportedCacheUsage(usage.cache_read_tokens ?? 0, usage.cache_creation_tokens ?? 0)}`
  }
  return line
}

export type SessionUsageSummary = {
  session_id: string
  completed_turns: number
  reported_turns: number
  input_tokens: number
  output_tokens: number
  usage_reported: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
  cache_reported?: boolean
  cost: string
}

export function formatSessionUsageSummary(summary: SessionUsageSummary): string {
  const lines = [
    "SESSION TOKEN USAGE",
    `Completed turns: ${summary.completed_turns}`,
    `Turns with provider-reported tokens: ${summary.reported_turns}`,
  ]
  if (summary.usage_reported) {
    lines.push(`Tokens: ${formatReportedUsage(summary.input_tokens, summary.output_tokens)}`)
  } else {
    lines.push("Tokens: unavailable (no provider reported usage yet)")
  }
  if (summary.cache_reported) {
    lines.push(
      `Prompt cache (provider-reported): ${formatReportedCacheUsage(summary.cache_read_tokens ?? 0, summary.cache_creation_tokens ?? 0)}`,
    )
  } else {
    lines.push("Prompt cache: unavailable (provider omitted cache fields)")
  }
  lines.push(`Cost: ${summary.cost === "unavailable" ? "unavailable (no price schedule)" : summary.cost}`)
  return lines.join("\n")
}
