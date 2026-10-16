/**
 * Map OpenCode-style model variants to Veasel `max_output_tokens`.
 * Bounds match provider.v (`min_configured_output_tokens` .. `max_configured_output_tokens`).
 */

export const VARIANT_OUTPUT_BUDGET = {
  fast: 1024,
  default: 4096,
  max: 32_768,
} as const

export type ModelVariantId = keyof typeof VARIANT_OUTPUT_BUDGET

export const modelVariantIds: ModelVariantId[] = ["default", "fast", "max"]

export function outputBudgetForVariant(variant: ModelVariantId | undefined): number {
  if (!variant || variant === "default") return VARIANT_OUTPUT_BUDGET.default
  return VARIANT_OUTPUT_BUDGET[variant]
}

/** Nearest named variant for a configured max_output_tokens (0 → default). */
export function variantForOutputBudget(tokens: number | undefined): ModelVariantId {
  if (tokens === undefined || tokens === 0) return "default"
  let best: ModelVariantId = "default"
  let bestDelta = Number.POSITIVE_INFINITY
  for (const id of modelVariantIds) {
    const delta = Math.abs(VARIANT_OUTPUT_BUDGET[id] - tokens)
    if (delta < bestDelta) {
      best = id
      bestDelta = delta
    }
  }
  return best
}

export function variantBudgetLabel(variant: ModelVariantId): string {
  const tokens = VARIANT_OUTPUT_BUDGET[variant]
  return `${variant} · max_output ${tokens}`
}
