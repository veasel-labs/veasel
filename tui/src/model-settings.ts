export const defaultOutputTokenBudget = 4_096
export const minimumOutputTokenBudget = 16
export const maximumOutputTokenBudget = 131_072

export function parseOutputTokenBudget(value: string): number | undefined {
  const normalized = value.trim()
  if (!/^\d+$/.test(normalized)) return undefined
  const budget = Number(normalized)
  if (!Number.isSafeInteger(budget) || budget > maximumOutputTokenBudget) return undefined
  if (budget !== 0 && budget < minimumOutputTokenBudget) return undefined
  return budget
}

export function initialOutputTokenBudget(provider: string, saved?: number): number {
  if (saved !== undefined) return saved
  return provider === "meta" ? 0 : defaultOutputTokenBudget
}
