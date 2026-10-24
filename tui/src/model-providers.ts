export type ModelProvider = {
  id: string
  name: string
  description: string
  protocol: "openai-compatible" | "openai-responses" | "anthropic" | "gemini"
  base_url: string
  environment_key: string
  documentation_url?: string
  requires_api_key: boolean
}

export type ModelCatalogEntry = {
  id: string
  name: string
  /** Pinned USD per million input tokens when the model is on Veasel's schedule. */
  input_per_mtok?: number
  /** Pinned USD per million output tokens when the model is on Veasel's schedule. */
  output_per_mtok?: number
  cost_unit?: string
  /** Curated context window in tokens when the model is on Veasel's schedule. */
  context_tokens?: number
}

/** Provider-specific setup note shown before a user starts entering credentials. */
export function providerConnectionGuidance(provider: ModelProvider): string | undefined {
  if (provider.id !== "opencode-go") return undefined
  return "Use a fresh OpenCode Console API key (OPENCODE_API_KEY). Veasel cannot reuse the OpenCode CLI login; replace expired keys in Console."
}

/** Compact context-window badge for the model picker. Empty when unknown. */
export function formatModelCatalogContextBadge(model: ModelCatalogEntry): string {
  const tokens = model.context_tokens
  if (typeof tokens !== "number" || !Number.isFinite(tokens) || tokens <= 0) return ""
  const label = tokens >= 1_000_000
    ? `${Number.isInteger(tokens / 1_000_000) ? tokens / 1_000_000 : (tokens / 1_000_000).toFixed(2).replace(/0$/, "")}M`
    : tokens >= 1_000
      ? `${Math.round(tokens / 1_000)}k`
      : String(Math.round(tokens))
  return `${label} ctx (pinned)`
}

/** Compact schedule badge for the model picker. Empty when rates are absent. */
export function formatModelCatalogCostBadge(model: ModelCatalogEntry): string {
  if (
    typeof model.input_per_mtok !== "number"
    || typeof model.output_per_mtok !== "number"
    || !Number.isFinite(model.input_per_mtok)
    || !Number.isFinite(model.output_per_mtok)
    || model.input_per_mtok < 0
    || model.output_per_mtok < 0
  ) {
    return ""
  }
  const unit = model.cost_unit === "usd_per_million_tokens" || !model.cost_unit
    ? "$/MTok"
    : model.cost_unit
  const formatRate = (value: number) => {
    if (value >= 100) return String(Math.round(value))
    if (value >= 10) return value.toFixed(1).replace(/\.0$/, "")
    return String(value)
  }
  return `${formatRate(model.input_per_mtok)}/${formatRate(model.output_per_mtok)} ${unit} in/out (pinned)`
}
export type ProviderEndpoints = Record<string, { base_url: string }>
export type ProviderPickerScope = "all" | "configured" | "local" | "specialized" | "compatible"
type SearchField = { values: string[]; weight: number }

export const providerPickerScopes: ProviderPickerScope[] = ["all", "configured", "local", "specialized", "compatible"]

export function providerPickerScopeLabel(scope: ProviderPickerScope) {
  switch (scope) {
    case "all": return "All"
    case "configured": return "Configured"
    case "local": return "Local"
    case "specialized": return "Specialized APIs"
    case "compatible": return "OpenAI-compatible"
  }
}

export function moveProviderPickerScope(scope: ProviderPickerScope, direction: 1 | -1): ProviderPickerScope {
  const index = providerPickerScopes.indexOf(scope)
  return providerPickerScopes[(index + direction + providerPickerScopes.length) % providerPickerScopes.length]
}

function isLoopbackEndpoint(value: string) {
  try {
    const hostname = new URL(value).hostname.toLocaleLowerCase()
    return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]" || hostname === "::1"
  } catch {
    return false
  }
}

// Provider model IDs and display names are remote input. Keep terminal control
// characters and bidirectional overrides out of OpenTUI labels, while retaining
// the original model ID as the option value sent to the server.
export function safeModelCatalogText(value: string) {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").slice(0, 200)
}

export function filterModelProviders(
  providers: ModelProvider[],
  query: string,
  scope: ProviderPickerScope = "all",
  configuredProviders: Set<string> = new Set(),
  profiles: ProviderEndpoints = {},
) {
  const needle = normalizeQuery(query)
  const matches = providers.flatMap((provider, index) => {
    const inScope = scope === "all"
      || (scope === "configured" && configuredProviders.has(provider.id))
      || (scope === "local" && isLoopbackEndpoint(profiles[provider.id]?.base_url || provider.base_url))
      || (scope === "specialized" && provider.protocol !== "openai-compatible")
      || (scope === "compatible" && provider.protocol === "openai-compatible")
    if (!inScope) return []
    if (!needle) return [{ provider, index, score: 0 }]
    const score = searchScore(needle, [
      { values: [provider.id, provider.name], weight: 120 },
      { values: [provider.description, provider.protocol], weight: 40 },
      { values: [provider.environment_key], weight: 0 },
    ])
    return score === undefined ? [] : [{ provider, index, score }]
  })
  if (needle) {
    matches.sort((left, right) => right.score - left.score || left.index - right.index)
  }
  return matches.map(({ provider }) => provider)
}

function normalizeQuery(query: string) {
  return tokenize([query.trim()])
}

function tokenize(values: string[]) {
  const tokens = values.flatMap((value) => value.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [])
  return [...new Set(tokens)]
}

function searchScore(query: string[], fields: SearchField[]): number | undefined {
  let bestFieldScore: number | undefined
  for (const field of fields) {
    // Keep each search group's terms together: "model api key" must match the
    // credential-variable field, not unrelated words from a provider summary.
    const candidates = tokenize(field.values)
    let total = field.weight
    let matchedAll = true
    for (const queryToken of query) {
      let bestTokenScore: number | undefined
      for (const candidate of candidates) {
        const score = tokenMatchScore(queryToken, candidate)
        if (score !== undefined) bestTokenScore = Math.max(bestTokenScore ?? 0, score)
      }
      if (bestTokenScore === undefined) {
        matchedAll = false
        break
      }
      total += bestTokenScore
    }
    if (matchedAll) bestFieldScore = Math.max(bestFieldScore ?? 0, total)
  }
  return bestFieldScore
}

function tokenMatchScore(query: string, candidate: string): number | undefined {
  if (candidate === query) return 1_000
  const position = candidate.indexOf(query)
  if (position === 0) return 800 - (candidate.length - query.length)
  if (position > 0) return 700 - position * 4 - (candidate.length - query.length)

  // Short fragments are common across unrelated provider names. Require exact
  // prefix/substring matches for them and allow one typo per four characters
  // for longer queries, including transposed characters.
  if (query.length < 4) return undefined
  const maximumDistance = query.length < 8 ? 1 : Math.floor(query.length / 4)
  if (Math.abs(query.length - candidate.length) > maximumDistance) return undefined
  const distance = optimalStringAlignmentDistance(query, candidate)
  if (distance > maximumDistance) return undefined
  return 500 - distance * 32 - Math.abs(candidate.length - query.length) * 2
}

function optimalStringAlignmentDistance(left: string, right: string) {
  const rows = left.length + 1
  const columns = right.length + 1
  const distance = Array.from({ length: rows }, () => Array<number>(columns).fill(0))
  for (let row = 0; row < rows; row++) distance[row][0] = row
  for (let column = 0; column < columns; column++) distance[0][column] = column

  for (let row = 1; row < rows; row++) {
    for (let column = 1; column < columns; column++) {
      const substitution = left[row - 1] === right[column - 1] ? 0 : 1
      distance[row][column] = Math.min(
        distance[row - 1][column] + 1,
        distance[row][column - 1] + 1,
        distance[row - 1][column - 1] + substitution,
      )
      if (row > 1 && column > 1 && left[row - 1] === right[column - 2] && left[row - 2] === right[column - 1]) {
        distance[row][column] = Math.min(distance[row][column], distance[row - 2][column - 2] + substitution)
      }
    }
  }
  return distance[left.length][right.length]
}

export function prioritizeModelProviders(
  providers: ModelProvider[],
  activeProvider: string,
  configuredProviders: Set<string>,
) {
  return [...providers].sort((left, right) => {
    const priority = (provider: ModelProvider) =>
      provider.id === activeProvider ? 0 : configuredProviders.has(provider.id) ? 1 : 2
    return priority(left) - priority(right)
  })
}

export function filterModelCatalog(models: ModelCatalogEntry[], query: string) {
  const needle = normalizeQuery(query)
  if (!needle.length) return models
  return models.flatMap((model, index) => {
    const score = searchScore(needle, [{ values: [model.id, model.name], weight: 0 }])
    return score === undefined ? [] : [{ model, index, score }]
  }).sort((left, right) => right.score - left.score || left.index - right.index).map(({ model }) => model)
}
