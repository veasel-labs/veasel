/**
 * Collapsible ```thinking fences in transcript assistant content.
 * Engineering pattern from OpenCode reasoning disclosure; Veasel-owned copy.
 */

export type ThinkingPart =
  | { type: "text"; text: string }
  | { type: "thinking"; text: string; id: string }

export const thinkingToggleShortcut = {
  name: "h",
  ctrl: true,
  label: "Ctrl+H",
} as const

const THINKING_FENCE = /```thinking\r?\n([\s\S]*?)```/gi

/** Split content into ordered text / thinking parts (empty text parts dropped). */
export function splitThinkingParts(content: string, messageKey = "msg"): ThinkingPart[] {
  const parts: ThinkingPart[] = []
  let last = 0
  let match: RegExpExecArray | null
  let thinkingIndex = 0
  const re = new RegExp(THINKING_FENCE.source, THINKING_FENCE.flags)
  while ((match = re.exec(content)) !== null) {
    const before = content.slice(last, match.index)
    if (before.trim()) parts.push({ type: "text", text: before })
    const body = (match[1] ?? "").trim()
    parts.push({
      type: "thinking",
      text: body,
      id: `${messageKey}-thinking-${thinkingIndex++}`,
    })
    last = match.index + match[0].length
  }
  const after = content.slice(last)
  if (after.trim() || parts.length === 0) {
    if (after.length > 0 || parts.length === 0) parts.push({ type: "text", text: after })
  }
  return parts
}

export function contentHasThinking(content: string): boolean {
  return /```thinking/i.test(content)
}

export function thinkingHeader(expanded: boolean, preview: string): string {
  const disclosure = expanded ? "▾" : "▸"
  const snippet = preview.replace(/\s+/g, " ").trim()
  if (expanded) return `${disclosure} thinking`
  if (!snippet) return `${disclosure} thinking`
  const short = snippet.length > 48 ? `${snippet.slice(0, 47)}…` : snippet
  return `${disclosure} thinking  ·  ${short}`
}

export function toggleThinkingExpanded(
  expanded: Readonly<Record<string, boolean>>,
  id: string,
  next?: boolean,
): Record<string, boolean> {
  const current = Boolean(expanded[id])
  const value = next ?? !current
  return { ...expanded, [id]: value }
}

/** Default: collapsed unless explicitly expanded. */
export function isThinkingExpanded(
  expanded: Readonly<Record<string, boolean>>,
  id: string,
): boolean {
  return Boolean(expanded[id])
}

/** Latest thinking part id in a flat message list (for Ctrl+H). */
export function latestThinkingId(
  messages: readonly { role: string; content: string }[],
): string | undefined {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index]!
    if (message.role !== "assistant") continue
    const parts = splitThinkingParts(message.content, `m${index}`)
    for (let p = parts.length - 1; p >= 0; p--) {
      const part = parts[p]!
      if (part.type === "thinking") return part.id
    }
  }
  return undefined
}
