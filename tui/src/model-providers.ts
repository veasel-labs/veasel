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

export type ModelCatalogEntry = { id: string; name: string }
export type ProviderEndpoints = Record<string, { base_url: string }>
export type ProviderPickerScope = "all" | "configured" | "local" | "specialized" | "compatible"

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
  const needle = query.trim().toLocaleLowerCase()
  return providers.filter((provider) => {
    const inScope = scope === "all"
      || (scope === "configured" && configuredProviders.has(provider.id))
      || (scope === "local" && isLoopbackEndpoint(profiles[provider.id]?.base_url || provider.base_url))
      || (scope === "specialized" && provider.protocol !== "openai-compatible")
      || (scope === "compatible" && provider.protocol === "openai-compatible")
    if (!inScope) return false
    if (!needle) return true
    return [
      provider.name,
      provider.id,
      provider.description,
      provider.environment_key,
      provider.protocol,
    ].join(" ").toLocaleLowerCase().includes(needle)
  })
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
  const needle = query.trim().toLocaleLowerCase()
  if (!needle) return models
  return models.filter((model) => `${model.id} ${model.name}`.toLocaleLowerCase().includes(needle))
}
