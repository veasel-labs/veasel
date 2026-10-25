import stringWidth from "string-width"

export type SessionTab = {
  id: string
  title: string
  /** Background activity while another session is focused (OpenCode unread idea). */
  unread?: boolean
}

/** Spoken unread glyph — works without color (reduced-motion / a11y). */
export const sessionTabUnreadMarker = "●"

export function truncateTabTitle(title: string, max = 18): string {
  const trimmed = title.trim() || "Session"
  if (stringWidth(trimmed) <= max) return trimmed
  const ellipsis = "…"
  const ellipsisWidth = stringWidth(ellipsis)
  if (max <= ellipsisWidth) return ellipsis
  const budget = max - ellipsisWidth
  let head = ""
  for (const character of trimmed) {
    if (stringWidth(head + character) > budget) break
    head += character
  }
  return head ? `${head.trimEnd()}${ellipsis}` : ellipsis
}

/** Tab label with optional unread marker; reserve marker width inside the truncate budget. */
export function formatSessionTabLabel(tab: SessionTab, max = 18): string {
  if (!tab.unread) return truncateTabTitle(tab.title, max)
  const prefix = `${sessionTabUnreadMarker} `
  const prefixWidth = stringWidth(prefix)
  if (max <= prefixWidth) return sessionTabUnreadMarker
  const budget = max - prefixWidth
  return `${prefix}${truncateTabTitle(tab.title, budget)}`
}

/** Mark a session unread unless it is the focused tab. */
export function markSessionUnread(
  unread: Readonly<Record<string, true>>,
  sessionId: string,
  activeId: string | undefined,
): Record<string, true> {
  if (!sessionId || sessionId === activeId) return { ...unread }
  return { ...unread, [sessionId]: true }
}

export function clearSessionUnread(
  unread: Readonly<Record<string, true>>,
  sessionId: string,
): Record<string, true> {
  if (!Object.prototype.hasOwnProperty.call(unread, sessionId)) return { ...unread }
  const next = { ...unread }
  delete next[sessionId]
  return next
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

export type SessionTabsLayout = VisibleSessionTabs & {
  showLabel: boolean
  showNew: boolean
  showClose: boolean
  titleWidth: number
}

const maxSessionTabLabelWidth = 18
const minSessionTabLabelWidth = 4

/** Fit the session rail to the terminal while keeping the active tab visible. */
export function sessionTabsLayout(
  tabs: readonly SessionTab[],
  activeId: string | undefined,
  terminalWidth: number,
  options: { maxVisible?: number; showNew?: boolean; showClose?: boolean } = {},
): SessionTabsLayout {
  const columns = Math.max(1, Math.floor(terminalWidth))
  const showLabel = columns >= 44
  const headerWidth = showLabel ? 5 : 0
  const preferred = Math.max(1, Math.min(6, options.maxVisible ?? 6, tabs.length || 1))
  const activeIndex = Math.max(0, tabs.findIndex((tab) => tab.id === activeId))

  const fit = (showNew: boolean, showClose: boolean): SessionTabsLayout | undefined => {
    const actionCount = Number(showNew) + Number(showClose)
    for (let count = preferred; count >= 1; count--) {
      const visible = visibleSessionTabsAt(tabs, activeIndex, count)
      const beforeWidth = visible.overflowLeft > 0 ? String(visible.overflowLeft).length + 1 : 0
      const afterWidth = visible.overflowRight > 0 ? String(visible.overflowRight).length + 1 : 0
      const elementCount =
        Number(showLabel) + Number(beforeWidth > 0) + count + Number(afterWidth > 0) + actionCount
      const gaps = Math.max(0, elementCount - 1)
      const fixedWidth = 4 + headerWidth + beforeWidth + afterWidth + actionCount + gaps
      const titleWidth = Math.min(maxSessionTabLabelWidth, Math.floor((columns - fixedWidth) / count))
      if (titleWidth < minSessionTabLabelWidth) continue
      return { ...visible, showLabel, showNew, showClose, titleWidth }
    }
  }

  const withActions = fit(Boolean(options.showNew), Boolean(options.showClose))
  if (withActions) return withActions

  const withoutActions = fit(false, false)
  if (withoutActions) return withoutActions

  // Even a one-cell terminal retains one active tab; labels and actions yield first.
  const visible = visibleSessionTabsAt(tabs, activeIndex, 1)
  return { ...visible, showLabel: false, showNew: false, showClose: false, titleWidth: 1 }
}

function visibleSessionTabsAt(
  tabs: readonly SessionTab[],
  activeIndex: number,
  maxVisible: number,
): VisibleSessionTabs {
  if (tabs.length === 0) {
    return { tabs: [], startIndex: 0, overflowLeft: 0, overflowRight: 0 }
  }
  const cap = Math.max(1, maxVisible)
  if (tabs.length <= cap) {
    return { tabs: [...tabs], startIndex: 0, overflowLeft: 0, overflowRight: 0 }
  }
  let start = Math.max(0, activeIndex - Math.floor(cap / 2))
  if (start + cap > tabs.length) start = tabs.length - cap
  return {
    tabs: tabs.slice(start, start + cap),
    startIndex: start,
    overflowLeft: start,
    overflowRight: Math.max(0, tabs.length - (start + cap)),
  }
}

/** Keep the active tab in a capped visible window (OpenCode overflow idea, simpler). */
export function visibleSessionTabs(
  tabs: readonly SessionTab[],
  activeId: string | undefined,
  maxVisible = 6,
): VisibleSessionTabs {
  const cap = Math.max(1, maxVisible)
  if (tabs.length <= cap) return visibleSessionTabsAt(tabs, 0, cap)
  const activeIndex = Math.max(0, tabs.findIndex((tab) => tab.id === activeId))
  return visibleSessionTabsAt(tabs, activeIndex, cap)
}

export function sessionTabsFromEntries(
  entries: readonly { id: string; title: string }[],
  unread: Readonly<Record<string, true>> = {},
): SessionTab[] {
  return entries.map((entry) => ({
    id: entry.id,
    title: entry.title.trim() || "Session",
    unread: Boolean(unread[entry.id]),
  }))
}
