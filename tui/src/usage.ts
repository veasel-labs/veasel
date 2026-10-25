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

/**
 * Provider-reported cache-read share of (input + cache read + cache write).
 * Not a dollar savings claim — only a fraction of reported counters.
 */
export function formatReportedCacheHitRatio(
  inputTokens: number,
  cacheReadTokens: number,
  cacheCreationTokens: number,
): string | undefined {
  const input = Number.isFinite(inputTokens) && inputTokens > 0 ? inputTokens : 0
  const read = Number.isFinite(cacheReadTokens) && cacheReadTokens > 0 ? cacheReadTokens : 0
  const write = Number.isFinite(cacheCreationTokens) && cacheCreationTokens > 0 ? cacheCreationTokens : 0
  const denominator = input + read + write
  if (denominator <= 0 || read <= 0) return undefined
  const pct = Math.round((1000 * read) / denominator) / 10
  return `${pct}% of reported prompt tokens were cache reads`
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
  allowance_usd?: number
  allowance_reported?: boolean
  cost: string
}

export type GlobalUsageSummary = {
  sessions: number
  completed_turns: number
  reported_turns: number
  input_tokens: number
  output_tokens: number
  usage_reported: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
  cache_reported?: boolean
  allowance_usd?: number
  allowance_reported?: boolean
  cost: string
}

export function formatGlobalUsageSummary(summary: GlobalUsageSummary): string {
  const lines = [
    "ALL SESSIONS TOKEN USAGE",
    "Only provider-reported counters appear here. Veasel never estimates tokens or invents savings.",
    `Sessions: ${summary.sessions}`,
    `Completed turns: ${summary.completed_turns}`,
    `Turns with provider-reported tokens: ${summary.reported_turns}`,
  ]
  if (summary.usage_reported) {
    const total = summary.input_tokens + summary.output_tokens
    lines.push(`Tokens: ${formatReportedUsage(summary.input_tokens, summary.output_tokens)}`)
    lines.push(`Total (in+out): ${formatTokenCount(total)}`)
  } else {
    lines.push("Tokens: unavailable (no provider reported usage yet)")
  }
  if (summary.cache_reported) {
    lines.push(
      `Prompt cache (provider-reported): ${formatReportedCacheUsage(summary.cache_read_tokens ?? 0, summary.cache_creation_tokens ?? 0)}`,
    )
    lines.push("Cache lines are raw counters — not a dollar savings claim.")
  } else {
    lines.push("Prompt cache: unavailable (provider omitted cache fields)")
  }
  lines.push(
    `Cost: ${
      summary.cost === "unavailable"
        ? "unavailable (no matching pinned schedule rates)"
        : summary.cost
    }`,
  )
  if (summary.allowance_reported) {
    lines.push(`OpenCode Go allowance used: ${formatReportedUsd(summary.allowance_usd ?? 0)}`)
  }
  return lines.join("\n")
}

export function formatSessionUsageSummary(summary: SessionUsageSummary): string {
  const lines = [
    "SESSION TOKEN USAGE",
    "Only provider-reported counters appear here. Veasel never estimates tokens or invents savings.",
    `Completed turns: ${summary.completed_turns}`,
    `Turns with provider-reported tokens: ${summary.reported_turns}`,
  ]
  if (summary.usage_reported) {
    const total = summary.input_tokens + summary.output_tokens
    lines.push(`Tokens: ${formatReportedUsage(summary.input_tokens, summary.output_tokens)}`)
    lines.push(`Total (in+out): ${formatTokenCount(total)}`)
    if (summary.reported_turns > 0) {
      const avgIn = Math.round(summary.input_tokens / summary.reported_turns)
      const avgOut = Math.round(summary.output_tokens / summary.reported_turns)
      lines.push(`Avg per reported turn: ${formatReportedUsage(avgIn, avgOut)}`)
    }
  } else {
    lines.push("Tokens: unavailable (no provider reported usage yet)")
  }
  if (summary.cache_reported) {
    lines.push(
      `Prompt cache (provider-reported): ${formatReportedCacheUsage(summary.cache_read_tokens ?? 0, summary.cache_creation_tokens ?? 0)}`,
    )
    const ratio = formatReportedCacheHitRatio(
      summary.input_tokens,
      summary.cache_read_tokens ?? 0,
      summary.cache_creation_tokens ?? 0,
    )
    if (ratio) {
      lines.push(`Cache-read share: ${ratio} (not USD saved).`)
    }
    lines.push("Cache lines are raw counters — not a dollar savings claim.")
  } else {
    lines.push("Prompt cache: unavailable (provider omitted cache fields)")
  }
  lines.push(
    `Cost: ${
      summary.cost === "unavailable"
        ? "unavailable (no matching pinned schedule rates)"
        : summary.cost
    }`,
  )
  if (summary.allowance_reported) {
    lines.push(`OpenCode Go allowance used: ${formatReportedUsd(summary.allowance_usd ?? 0)}`)
  }
  return lines.join("\n")
}

export function formatReportedUsd(amount: number): string {
  if (!Number.isFinite(amount) || amount < 0) return "unavailable"
  return `$${amount.toFixed(6).replace(/0+$/, "").replace(/\.$/, ".00")}`
}
