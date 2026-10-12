export type ModelProvider = {
  id: string
  name: string
  description: string
  protocol: "openai-compatible" | "anthropic" | "gemini"
  base_url: string
  environment_key: string
  requires_api_key: boolean
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
