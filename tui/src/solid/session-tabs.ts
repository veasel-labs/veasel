export type SessionTab = {
  id: string
  title: string
}

export function truncateTabTitle(title: string, max = 18): string {
  const trimmed = title.trim() || "Session"
  if (trimmed.length <= max) return trimmed
  const head = trimmed.slice(0, Math.max(1, max - 1)).trimEnd()
  return `${head || trimmed.slice(0, 1)}…`
}

export function moveSessionTabIndex(index: number, delta: number, length: number): number {
  if (length <= 0) return 0
  const next = index + delta
  if (next < 0) return length - 1
  if (next >= length) return 0
  return next
}

export type VisibleSessionTabs = {
  tabs: SessionTab[]
  /** Absolute indices into the full tab list for `tabs`. */
  startIndex: number
  overflowLeft: number
  overflowRight: number
}

/** Keep the active tab in a capped visible window (OpenCode overflow idea, simpler). */
export function visibleSessionTabs(
  tabs: readonly SessionTab[],
  activeId: string | undefined,
  maxVisible = 6,
): VisibleSessionTabs {
  if (tabs.length === 0) {
    return { tabs: [], startIndex: 0, overflowLeft: 0, overflowRight: 0 }
  }
  const cap = Math.max(1, maxVisible)
  if (tabs.length <= cap) {
    return { tabs: [...tabs], startIndex: 0, overflowLeft: 0, overflowRight: 0 }
  }
  const activeIndex = Math.max(
    0,
    tabs.findIndex((tab) => tab.id === activeId),
  )
  let start = Math.max(0, activeIndex - Math.floor(cap / 2))
  if (start + cap > tabs.length) start = tabs.length - cap
  return {
    tabs: tabs.slice(start, start + cap),
    startIndex: start,
    overflowLeft: start,
    overflowRight: Math.max(0, tabs.length - (start + cap)),
  }
}

export function sessionTabsFromEntries(
  entries: readonly { id: string; title: string }[],
): SessionTab[] {
  return entries.map((entry) => ({
    id: entry.id,
    title: entry.title.trim() || "Session",
  }))
}
