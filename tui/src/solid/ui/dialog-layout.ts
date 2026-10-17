/** Shared terminal-cell geometry for dialogs and their result lists. */
export function dialogGeometry(columns: number, rows: number, preferredWidth = 56) {
  const width = Math.max(1, Math.floor(columns))
  const height = Math.max(1, Math.floor(rows))
  const compact = height < 24 || width < 60
  const marginX = width < 44 ? 0 : 2
  const marginY = height < 20 ? 0 : 2
  const paddingX = width < 44 ? 1 : 2
  const paddingY = compact ? 0 : 1
  const outerHeight = Math.max(1, height - marginY * 2)
  return {
    width: Math.min(preferredWidth, Math.max(1, width - marginX * 2)),
    height: outerHeight,
    paddingX,
    paddingY,
    compact,
    contentHeight: Math.max(1, outerHeight - 2 - paddingY * 2),
  }
}

export function dialogResultCount(
  columns: number,
  rows: number,
  requested: number,
  grouped = false,
  footer = false,
) {
  const geometry = dialogGeometry(columns, rows)
  // Header, search, count, and inter-section gaps. Optional footer takes two rows.
  const available = Math.max(1, geometry.contentHeight - 7 - (footer ? 2 : 0))
  const rowCost = grouped && !geometry.compact ? 2 : 1
  return Math.max(1, Math.min(Math.max(1, requested), Math.floor(available / rowCost)))
}
