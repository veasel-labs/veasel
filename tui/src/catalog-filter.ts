// Token filter for /skills, /mcp, and /plugins inventory lists.
// Every token must hit the haystack so "stdio trusted" narrows both ways.

export function catalogFilterTokens(filter: string): string[] {
  return filter
    .toLowerCase()
    .split(/[^a-z0-9._/-]+/)
    .filter((token) => token.length > 0)
}

export function matchesCatalogFilter(haystack: string, filter: string): boolean {
  const tokens = catalogFilterTokens(filter)
  if (tokens.length === 0) return true
  const text = haystack.toLowerCase()
  return tokens.every((token) => {
    if (text.includes(token)) return true
    const words = text.split(/[^a-z0-9._/-]+/).filter(Boolean)
    return words.some((word) => word === token || word.startsWith(token))
  })
}

export function formatCatalogFilterHeader(
  kind: string,
  matched: number,
  total: number,
  filter: string,
): string {
  const trimmed = filter.trim()
  if (!trimmed) return total === 0 ? kind : `${kind}  ·  ${total}`
  return `${kind}  ·  ${matched}/${total} match “${trimmed}”`
}

export function formatCatalogFilterEmpty(kind: string, filter: string): string {
  const trimmed = filter.trim() || "…"
  return `No ${kind} matched “${trimmed}”. Try a broader filter, or clear it.`
}

// Reserved /mcp verbs so free-text filters do not steal manage commands.
export function isMcpManageRest(rest: string): boolean {
  return /^(add|remove|enable|disable|trust|untrust|calls|call)\b/i.test(rest.trim())
}
