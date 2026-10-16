import { formatBusyStatus, formatErrorStatus, formatOkStatus, statusGlyph } from "../status-a11y"
import type { TranscriptMessage } from "../transcript"

/** Discoverable binding: Ctrl+G toggles the latest activity group (Ctrl+P stays palette). */
export const activityToggleShortcut = {
  name: "g",
  ctrl: true,
  label: "Ctrl+G",
} as const

export type ToolCallStatus = "running" | "done" | "error"

export type ToolCallItem = {
  id: string
  name: string
  detail: string
  status: ToolCallStatus
  messageIndex: number
}

export type TranscriptBlock =
  | {
      type: "messages"
      id: string
      messages: TranscriptMessage[]
      startIndex: number
    }
  | {
      type: "activity"
      id: string
      items: ToolCallItem[]
    }

export type ActivitySummary = {
  status: ToolCallStatus
  /** Compact header label with spoken status (works without color). */
  label: string
  /** Short status word used in chrome: running / done / error. */
  statusWord: string
  count: number
  runningCount: number
  errorCount: number
}

/** Optional structured tool fields on a transcript message (Solid grouping). */
export type ToolAwareMessage = TranscriptMessage & {
  toolName?: string
  toolStatus?: ToolCallStatus
  toolId?: string
}

function isToolRole(role: string): boolean {
  return role === "tool" || role === "tool_result"
}

/** Parse a tool name from free-form content when structured metadata is absent. */
export function parseToolName(content: string, explicit?: string): string {
  const trimmedExplicit = explicit?.trim()
  if (trimmedExplicit) return trimmedExplicit
  const line = content.trim().split("\n")[0] ?? ""
  const named = /^([a-zA-Z][\w.-]{0,63})\s*[:=]\s*(.+)$/.exec(line)
  if (named) return named[1]!.toLowerCase()
  const first = line.split(/\s+/)[0] ?? ""
  if (/^[a-zA-Z][\w.-]{0,63}$/.test(first)) return first.toLowerCase()
  return "tool"
}

export function parseToolDetail(content: string, name: string): string {
  const trimmed = content.trim()
  if (!trimmed) return name
  const line = trimmed.split("\n")[0] ?? trimmed
  const named = new RegExp(`^${escapeRegExp(name)}\\s*[:=]\\s*(.+)$`, "i").exec(line)
  if (named) return named[1]!.trim() || name
  return line
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

export function inferToolStatus(message: ToolAwareMessage): ToolCallStatus {
  if (message.toolStatus === "running" || message.toolStatus === "done" || message.toolStatus === "error") {
    return message.toolStatus
  }
  const text = message.content.toLowerCase()
  if (/\b(error|failed|failure)\b/.test(text)) return "error"
  if (/\b(running|in[- ]progress|pending|…|\.\.\.)\b/.test(text)) return "running"
  return "done"
}

export function toolCallFromMessage(message: ToolAwareMessage, messageIndex: number): ToolCallItem {
  const name = parseToolName(message.content, message.toolName)
  return {
    id: message.toolId?.trim() || `tool-${messageIndex}`,
    name,
    detail: parseToolDetail(message.content, name),
    status: inferToolStatus(message),
    messageIndex,
  }
}

/** Aggregate status: error wins, then running, else done. */
export function activityGroupStatus(items: readonly ToolCallItem[]): ToolCallStatus {
  if (items.some((item) => item.status === "error")) return "error"
  if (items.some((item) => item.status === "running")) return "running"
  return "done"
}

export function summarizeActivityGroup(items: readonly ToolCallItem[]): ActivitySummary {
  const count = items.length
  const runningCount = items.filter((item) => item.status === "running").length
  const errorCount = items.filter((item) => item.status === "error").length
  const status = activityGroupStatus(items)
  const noun = count === 1 ? "tool" : "tools"
  const statusWord = status === "running" ? "running" : status === "error" ? "error" : "done"

  if (status === "running") {
    const current = items.find((item) => item.status === "running")
    const busy = current
      ? `Running ${current.name}…`
      : `${count} ${noun}`
    return {
      status,
      statusWord,
      count,
      runningCount,
      errorCount,
      label: formatBusyStatus(busy),
    }
  }
  if (status === "error") {
    const failed = errorCount === 1 ? "1 failed" : `${errorCount} failed`
    return {
      status,
      statusWord,
      count,
      runningCount,
      errorCount,
      label: formatErrorStatus(`${failed} · ${count} ${noun}`),
    }
  }
  return {
    status,
    statusWord,
    count,
    runningCount,
    errorCount,
    label: formatOkStatus(`${count} ${noun}`),
  }
}

/** Header line for a collapsible activity group (spoken roles, no color required). */
export function activityGroupHeader(items: readonly ToolCallItem[], expanded: boolean): string {
  const summary = summarizeActivityGroup(items)
  const disclosure = expanded ? "▾" : "▸"
  return `${disclosure} activity  ·  ${summary.label}`
}

/** Per-item line when a group is expanded. */
export function activityItemLine(item: ToolCallItem): string {
  const level = item.status === "error" ? "error" : item.status === "running" ? "busy" : "ok"
  const glyph = statusGlyph(level)
  const word = item.status === "running" ? "running" : item.status === "error" ? "error" : "done"
  return `  ${glyph} ${item.name}  ·  ${word}  ·  ${item.detail}`
}

/**
 * Project transcript messages into render blocks: consecutive tool roles become
 * one activity group; each non-tool message is its own block so mount-budget
 * can window long sessions by rendered entry (OpenCode-style).
 */
export function projectTranscriptBlocks(messages: readonly ToolAwareMessage[]): TranscriptBlock[] {
  const blocks: TranscriptBlock[] = []
  let index = 0
  while (index < messages.length) {
    const message = messages[index]!
    if (isToolRole(message.role)) {
      const items: ToolCallItem[] = []
      const start = index
      while (index < messages.length && isToolRole(messages[index]!.role)) {
        items.push(toolCallFromMessage(messages[index]!, index))
        index++
      }
      blocks.push({
        type: "activity",
        id: `activity-${start}-${items[items.length - 1]!.messageIndex}`,
        items,
      })
      continue
    }
    blocks.push({
      type: "messages",
      id: `messages-${index}`,
      messages: [message],
      startIndex: index,
    })
    index += 1
  }
  return blocks
}

/** Pure toggle helper for expanded-group maps. */
export function toggleGroupExpanded(
  expanded: Readonly<Record<string, boolean>>,
  groupId: string,
  next?: boolean,
): Record<string, boolean> {
  const current = Boolean(expanded[groupId])
  const value = next ?? !current
  return { ...expanded, [groupId]: value }
}

/** Default disclosure: running groups open; completed/error groups start collapsed. */
export function defaultGroupExpanded(items: readonly ToolCallItem[]): boolean {
  return activityGroupStatus(items) === "running"
}

export function isGroupExpanded(
  expanded: Readonly<Record<string, boolean>>,
  groupId: string,
  items: readonly ToolCallItem[],
): boolean {
  if (Object.prototype.hasOwnProperty.call(expanded, groupId)) {
    return Boolean(expanded[groupId])
  }
  return defaultGroupExpanded(items)
}

/** Latest activity group id (for Ctrl+G), or undefined when none. */
export function latestActivityGroupId(blocks: readonly TranscriptBlock[]): string | undefined {
  for (let index = blocks.length - 1; index >= 0; index--) {
    const block = blocks[index]!
    if (block.type === "activity") return block.id
  }
  return undefined
}
