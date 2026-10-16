/**
 * Transcript verbosity cycle — quiet / default / everything.
 * Engineering pattern from OpenCode mini/verbosity.ts; Veasel-owned labels
 * and filtering (no opencode.* keys).
 *
 * Veasel mapping (preserves current LiveApp default of showing activity groups):
 * - quiet: hide tools, strip thinking
 * - default: show tools (collapsed groups), keep thinking
 * - everything: show tools with groups expanded, keep thinking
 */

import type { ToolAwareMessage } from "./activity-group"

export type TranscriptVerbosity = "quiet" | "default" | "everything"

export const transcriptVerbosityLevels = ["quiet", "default", "everything"] as const

const labels: Record<TranscriptVerbosity, string> = {
  quiet: "Quiet",
  default: "Default",
  everything: "Everything",
}

export function transcriptVerbosityLabel(level: TranscriptVerbosity): string {
  return labels[level]
}

export function cycleTranscriptVerbosity(
  current: TranscriptVerbosity,
  direction: 1 | -1 = 1,
): TranscriptVerbosity {
  const index = transcriptVerbosityLevels.indexOf(current)
  const at = index < 0 ? 0 : index
  const next = at + direction
  if (next < 0) return transcriptVerbosityLevels[0]!
  if (next >= transcriptVerbosityLevels.length) {
    return transcriptVerbosityLevels[transcriptVerbosityLevels.length - 1]!
  }
  return transcriptVerbosityLevels[next]!
}

/** Strip fenced ```thinking blocks from assistant content. */
export function stripThinkingBlocks(content: string): string {
  return content.replace(/```thinking[\s\S]*?```/gi, "").trim()
}

function isToolRole(role: string): boolean {
  return role === "tool" || role === "tool_result"
}

/** Whether activity groups should start forced-open for this level. */
export function verbosityExpandsActivity(level: TranscriptVerbosity): boolean {
  return level === "everything"
}

/**
 * Project messages for the current verbosity.
 * Indices are display-local (message-nav should use the filtered list).
 */
export function applyTranscriptVerbosity(
  messages: readonly ToolAwareMessage[],
  level: TranscriptVerbosity,
): ToolAwareMessage[] {
  const hideTools = level === "quiet"
  const hideThinking = level === "quiet"
  const out: ToolAwareMessage[] = []
  for (const message of messages) {
    if (hideTools && isToolRole(message.role)) continue
    if (hideThinking && (message.role === "assistant" || message.role === "user")) {
      const content = stripThinkingBlocks(message.content)
      if (!content && message.role === "assistant") continue
      out.push(content === message.content ? message : { ...message, content })
      continue
    }
    out.push(message)
  }
  return out
}
