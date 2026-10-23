import { mkdirSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { formatReportedCacheUsage, formatTokenCount } from "../usage"

export type ExportMessage = {
  role: string
  content: string
}

export type SessionExportOptions = {
  format: "markdown" | "json"
  /** Include tool / tool_result roles when true. */
  tools: boolean
  /** Include assistant content that looks like thinking blocks (```thinking). */
  thinking: boolean
  sanitize: boolean
}

export type SessionExportMeta = {
  title: string
  directory: string
  sessionId?: string
  exportedAt?: string
}

function stripThinking(content: string): string {
  return content.replace(/```thinking[\s\S]*?```/gi, "").trim()
}

function sanitizeText(text: string): string {
  return text
    .replace(/\bsk-[A-Za-z0-9_-]{8,}\b/g, "[redacted-key]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}\b/gi, "Bearer [redacted]")
}

function includeMessage(message: ExportMessage, options: SessionExportOptions): boolean {
  if (message.role === "tool" || message.role === "tool_result") return options.tools
  return true
}

function transformContent(content: string, options: SessionExportOptions): string {
  let next = content
  if (!options.thinking) next = stripThinking(next)
  if (options.sanitize) next = sanitizeText(next)
  return next
}

export function formatSessionExport(
  messages: readonly ExportMessage[],
  meta: SessionExportMeta,
  options: SessionExportOptions,
): string {
  const filtered = messages
    .filter((message) => includeMessage(message, options))
    .map((message) => ({
      role: message.role,
      content: transformContent(message.content, options),
    }))
    .filter((message) => message.content.length > 0)

  if (options.format === "json") {
    return `${JSON.stringify(
      {
        title: meta.title,
        directory: meta.directory,
        sessionId: meta.sessionId,
        exportedAt: meta.exportedAt ?? new Date().toISOString(),
        messages: filtered,
      },
      null,
      2,
    )}\n`
  }

  const lines = [
    `# ${meta.title}`,
    "",
    `Directory: \`${meta.directory}\``,
    meta.sessionId ? `Session: \`${meta.sessionId}\`` : undefined,
    `Exported: ${meta.exportedAt ?? new Date().toISOString()}`,
    "",
    "---",
    "",
  ].filter((line): line is string => line !== undefined)

  for (const message of filtered) {
    const heading =
      message.role === "user"
        ? "User"
        : message.role === "assistant"
          ? "Assistant"
          : message.role
    lines.push(`## ${heading}`, "", message.content, "")
  }
  return `${lines.join("\n").trimEnd()}\n`
}

export function sessionExportPath(
  format: "markdown" | "json",
  now = new Date(),
  home = homedir(),
): string {
  const stamp = now.toISOString().slice(0, 19).replace(/[:T]/g, "-")
  const ext = format === "json" ? "json" : "md"
  return join(home, "veasel-exports", `veasel-session-${stamp}.${ext}`)
}

export function writeSessionExport(path: string, body: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, body, { encoding: "utf8", mode: 0o600 })
}

export function formatGlobalUsageLine(summary: {
  sessions: number
  completed_turns?: number
  reported_turns?: number
  input_tokens: number
  output_tokens: number
  usage_reported: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
  cache_reported?: boolean
  reasoning_tokens?: number
  reasoning_reported?: boolean
  cost?: string
}): string | undefined {
  if (!summary.usage_reported) return undefined
  const parts = [
    `all sessions (${summary.sessions})`,
  ]
  if (typeof summary.completed_turns === "number") {
    const reported = typeof summary.reported_turns === "number"
      ? ` · ${summary.reported_turns} metered`
      : ""
    parts.push(`${summary.completed_turns} turns${reported}`)
  }
  parts.push(`${formatTokenCount(summary.input_tokens)} in`, `${formatTokenCount(summary.output_tokens)} out`)
  if (summary.cache_reported) {
    parts.push(formatReportedCacheUsage(summary.cache_read_tokens ?? 0, summary.cache_creation_tokens ?? 0))
  }
  if (summary.reasoning_reported) {
    parts.push(`${formatTokenCount(summary.reasoning_tokens ?? 0)} reasoning`)
  }
  if (summary.cost) {
    parts.push(summary.cost === "unavailable" ? "cost unavailable" : `cost ${summary.cost}`)
  }
  return parts.join(" · ")
}

export function formatUsageLine(summary: {
  input_tokens: number
  output_tokens: number
  usage_reported: boolean
  cache_read_tokens?: number
  cache_reported?: boolean
  cost?: string
}): string | undefined {
  if (!summary.usage_reported) return undefined
  const parts = [
    `${summary.input_tokens} in`,
    `${summary.output_tokens} out`,
  ]
  if (summary.cache_reported && typeof summary.cache_read_tokens === "number") {
    parts.push(`${summary.cache_read_tokens} cache read`)
  }
  if (summary.cost && summary.cost !== "unavailable") parts.push(`cost ${summary.cost}`)
  return parts.join(" · ")
}
