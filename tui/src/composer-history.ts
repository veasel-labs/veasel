// Shell-style ↑/↓ recall for the session composer. Offset 0 is the live draft;
// higher offsets walk toward older submitted lines.

export const composerHistoryLimit = 50

export type ComposerHistory = {
  entries: string[]
  offset: number
  draft: string
}

export function emptyComposerHistory(): ComposerHistory {
  return { entries: [], offset: 0, draft: "" }
}

export function rememberComposerEntry(history: ComposerHistory, raw: string): ComposerHistory {
  const entry = raw.trim()
  if (!entry) return history
  const last = history.entries[history.entries.length - 1]
  const entries = last === entry ? [...history.entries] : [...history.entries, entry]
  while (entries.length > composerHistoryLimit) entries.shift()
  return { entries, offset: 0, draft: "" }
}

// Ctrl+U (readline kill-line) drops the draft and exits history recall so the
// next ↑ starts from the newest entry again.
export function clearComposerLine(history: ComposerHistory): ComposerHistory {
  return { ...history, offset: 0, draft: "" }
}

export function stepComposerHistory(
  history: ComposerHistory,
  direction: "older" | "newer",
  currentValue: string,
): { history: ComposerHistory; value: string } | undefined {
  if (history.entries.length === 0) return undefined
  let offset = history.offset
  let draft = history.draft
  if (offset === 0) {
    if (direction === "newer") return undefined
    if (currentValue.trim().length > 0) return undefined
    draft = currentValue
    offset = 1
  } else if (direction === "older") {
    if (offset >= history.entries.length) return undefined
    offset += 1
  } else {
    offset -= 1
  }
  if (offset === 0) {
    return { history: { ...history, offset: 0, draft }, value: draft }
  }
  const value = history.entries[history.entries.length - offset]!
  return { history: { ...history, offset, draft }, value }
}
