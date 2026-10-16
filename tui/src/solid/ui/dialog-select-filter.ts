/** Pure filter / grouping helpers for DialogSelect (unit-tested without OpenTUI). */

export type DialogSelectOption<T = string> = {
  title: string
  value: T
  description?: string
  category?: string
  /** Extra fuzzy haystack (keywords, ids). */
  searchText?: string
  disabled?: boolean
  footer?: string
}

/** Case-insensitive subsequence score; higher is better. -1 = no match. */
export function fuzzyScore(haystack: string, needle: string): number {
  const text = haystack.toLowerCase()
  const query = needle.toLowerCase().trim()
  if (!query) return 0
  if (text === query) return 1_000
  if (text.startsWith(query)) return 800 - Math.min(text.length, 200)
  if (text.includes(query)) return 500 - Math.min(text.indexOf(query), 200)

  let score = 0
  let from = 0
  for (const char of query) {
    const at = text.indexOf(char, from)
    if (at < 0) return -1
    score += at === from ? 3 : 1
    from = at + 1
  }
  return score
}

export function filterSelectOptions<T>(
  options: readonly DialogSelectOption<T>[],
  query: string,
): DialogSelectOption<T>[] {
  const enabled = options.filter((option) => option.disabled !== true)
  const trimmed = query.trim()
  if (!trimmed) return [...enabled]

  const tokens = trimmed.toLowerCase().split(/\s+/).filter(Boolean)
  const ranked = enabled
    .map((option) => {
      const fields = [option.title, option.category ?? "", option.searchText ?? "", option.description ?? ""]
      let total = 0
      for (const token of tokens) {
        let best = -1
        for (const field of fields) {
          best = Math.max(best, fuzzyScore(field, token))
        }
        if (best < 0) return undefined
        // Title matches weigh more (OpenCode-style priority).
        total += best + fuzzyScore(option.title, token)
      }
      return { option, total }
    })
    .filter((entry): entry is { option: DialogSelectOption<T>; total: number } => entry !== undefined)
    .sort((a, b) => b.total - a.total)

  return ranked.map((entry) => entry.option)
}

/** Group filtered options by category; empty category sorts first. */
export function groupSelectOptions<T>(
  options: readonly DialogSelectOption<T>[],
  flat = false,
): Array<[string, DialogSelectOption<T>[]]> {
  if (flat || options.length === 0) {
    return options.length ? [["", [...options]]] : []
  }
  const map = new Map<string, DialogSelectOption<T>[]>()
  for (const option of options) {
    const key = option.category ?? ""
    const bucket = map.get(key)
    if (bucket) bucket.push(option)
    else map.set(key, [option])
  }
  return [...map.entries()]
}

export function moveSelectIndex(current: number, count: number, delta: number): number {
  if (count <= 0) return 0
  const next = current + delta
  if (next < 0) return count - 1
  if (next >= count) return 0
  return next
}
