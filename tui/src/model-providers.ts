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

// Provider model IDs and display names are remote input. Keep terminal control
// characters and bidirectional overrides out of OpenTUI labels, while retaining
// the original model ID as the option value sent to the server.
export function safeModelCatalogText(value: string) {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").slice(0, 200)
}

export function filterModelProviders(providers: ModelProvider[], query: string) {
  const needle = query.trim().toLocaleLowerCase()
  if (!needle) return providers
  return providers.filter((provider) => [
    provider.name,
    provider.id,
    provider.description,
    provider.environment_key,
    provider.protocol,
  ].join(" ").toLocaleLowerCase().includes(needle))
}

export function filterModelCatalog(models: ModelCatalogEntry[], query: string) {
  const needle = query.trim().toLocaleLowerCase()
  if (!needle) return models
  return models.filter((model) => `${model.id} ${model.name}`.toLocaleLowerCase().includes(needle))
}
