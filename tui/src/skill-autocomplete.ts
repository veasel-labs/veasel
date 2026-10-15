// $-mention Skill completion for the session composer. Suggestions use the
// discovered plugin/standalone catalog (`source/skill`) and insert a one-shot
// `$source/skill` token the same way `@` inserts workspace paths.

export const maxSkillSuggestions = 6

export type SkillMention = {
  start: number
  end: number
  query: string
}

export type SkillCatalogEntry = {
  key: string
  description: string
}

export type SkillSuggestion = {
  name: string
  description: string
  key: string
}

// Finds the $skill token that contains the cursor (or sits just before it).
// The $ must start a token so shell-like mid-word `$` is ignored.
export function skillMentionAt(value: string, cursor: number): SkillMention | undefined {
  const pos = Math.min(Math.max(0, cursor), value.length)
  let start = pos
  while (start > 0) {
    const ch = value[start - 1]!
    if (ch === "$") break
    if (/\s/.test(ch)) return undefined
    start -= 1
  }
  if (start <= 0 || value[start - 1] !== "$") return undefined
  const dollar = start - 1
  if (dollar > 0 && !/\s/.test(value[dollar - 1]!)) return undefined
  let end = pos
  while (end < value.length && !/\s/.test(value[end]!)) end += 1
  return {
    start: dollar,
    end,
    query: value.slice(dollar + 1, end),
  }
}

export function filterSkills(
  skills: SkillCatalogEntry[],
  query: string,
  limit = maxSkillSuggestions,
): SkillSuggestion[] {
  const needle = query.trim().toLowerCase()
  const unique = new Map<string, SkillCatalogEntry>()
  for (const skill of skills) {
    const key = skill.key.trim().replaceAll("\\", "/").replace(/^\.\//, "")
    if (!key || key.startsWith("/") || key.includes("\0") || !key.includes("/")) continue
    if (!unique.has(key)) unique.set(key, { key, description: skill.description })
  }
  const entries = [...unique.values()]
  if (!needle) {
    return entries.slice(0, limit).map((skill) => skillSuggestion(skill, "skill"))
  }
  const scored = entries.flatMap((skill, index) => {
    const score = skillMatchScore(needle, skill.key)
    return score === undefined ? [] : [{ skill, index, score }]
  })
  scored.sort((left, right) => right.score - left.score || left.index - right.index)
  return scored.slice(0, limit).map(({ skill, score }) => skillSuggestion(skill, skillScoreDescription(score)))
}

function skillSuggestion(skill: SkillCatalogEntry, description: string): SkillSuggestion {
  const detail = skill.description.trim()
  return {
    name: `$${skill.key}`,
    description: detail.length > 0 && description === "skill" ? detail : description,
    key: skill.key,
  }
}

function skillScoreDescription(score: number): string {
  if (score >= 1_100) return "name match"
  if (score >= 1_000) return "exact prefix"
  if (score >= 900) return "name match"
  if (score >= 800) return "path match"
  if (score >= 700) return "name match"
  if (score >= 500) return "close match"
  return "skill"
}

function skillMatchScore(needle: string, key: string): number | undefined {
  const lower = key.toLowerCase()
  const slash = lower.lastIndexOf("/")
  const source = slash >= 0 ? lower.slice(0, slash) : lower
  const name = slash >= 0 ? lower.slice(slash + 1) : lower
  if (lower === needle) return 1_200 - key.length
  // Exact skill-name equality outranks a source-key prefix (`review` must beat
  // `review-tools/audit` even though that key also starts with "review").
  if (name === needle) return 1_120 - Math.min(20, name.length)
  if (lower.startsWith(needle)) return 1_050 - Math.min(40, lower.length - needle.length)
  if (name.startsWith(needle)) return 940 - Math.min(30, name.length - needle.length)
  if (source.startsWith(needle)) return 900 - Math.min(30, source.length - needle.length)
  const keyAt = lower.indexOf(needle)
  if (keyAt >= 0) return 820 - keyAt * 4 - (lower.length - needle.length)
  const nameAt = name.indexOf(needle)
  if (nameAt >= 0) return 740 - nameAt * 4 - (name.length - needle.length)
  const sourceAt = source.indexOf(needle)
  if (sourceAt >= 0) return 720 - sourceAt * 4 - (source.length - needle.length)

  // Typo-tolerant skill / source match (same OSA budget as @ path ranking).
  // Skip when the query already includes `/` — prefix/substring ranking covers
  // `source/skill` shapes, and fuzzy on the source alone would false-hit siblings.
  if (needle.length < 4 || needle.includes("/")) return undefined
  const maximumDistance = needle.length < 8 ? 1 : Math.floor(needle.length / 4)
  let best: number | undefined
  for (const candidate of [name, source]) {
    if (Math.abs(needle.length - candidate.length) > maximumDistance) continue
    const distance = optimalStringAlignmentDistance(needle, candidate)
    if (distance > maximumDistance) continue
    const score = 560 - distance * 32 - Math.abs(candidate.length - needle.length) * 2
    best = Math.max(best ?? 0, score)
  }
  return best
}

function optimalStringAlignmentDistance(left: string, right: string) {
  const rows = left.length + 1
  const columns = right.length + 1
  const distance = Array.from({ length: rows }, () => Array<number>(columns).fill(0))
  for (let row = 0; row < rows; row++) distance[row]![0] = row
  for (let column = 0; column < columns; column++) distance[0]![column] = column

  for (let row = 1; row < rows; row++) {
    for (let column = 1; column < columns; column++) {
      const substitution = left[row - 1] === right[column - 1] ? 0 : 1
      distance[row]![column] = Math.min(
        distance[row - 1]![column]! + 1,
        distance[row]![column - 1]! + 1,
        distance[row - 1]![column - 1]! + substitution,
      )
      if (row > 1 && column > 1 && left[row - 1] === right[column - 2] && left[row - 2] === right[column - 1]) {
        distance[row]![column] = Math.min(distance[row]![column]!, distance[row - 2]![column - 2]! + substitution)
      }
    }
  }
  return distance[left.length]![right.length]!
}

export function suggestSkills(
  query: string,
  skills: SkillCatalogEntry[],
  limit = maxSkillSuggestions,
): SkillSuggestion[] {
  return filterSkills(skills, query, limit)
}

export function completeSkillMention(
  value: string,
  cursor: number,
  suggestion: SkillSuggestion,
): { value: string; cursor: number } | undefined {
  const mention = skillMentionAt(value, cursor)
  if (!mention) return undefined
  const insert = `$${suggestion.key}`
  const next = value.slice(0, mention.start) + insert + value.slice(mention.end)
  const nextCursor = mention.start + insert.length
  // Add a trailing space when the mention ends the draft so Enter can submit
  // the one-shot `$source/skill` token (trimmed) without reopening the menu.
  if (mention.end >= value.length) {
    return { value: `${next} `, cursor: nextCursor + 1 }
  }
  return { value: next, cursor: nextCursor }
}
