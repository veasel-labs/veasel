import type { ModelProvider } from "../../model-providers"

export type DelegateCatalogResult<TModel> = {
  provider: ModelProvider
  models: TModel[]
  error?: string
}

/** Load each configured provider independently so a broken catalog cannot hide
 * models from healthy providers. Provider IDs stay attached to their errors. */
export async function loadDelegateCatalogs<TModel>(
  providers: ModelProvider[],
  configuredProviderIds: Set<string>,
  listModels: (providerId: string) => Promise<TModel[]>,
): Promise<DelegateCatalogResult<TModel>[]> {
  return await Promise.all(providers
    .filter((provider) => configuredProviderIds.has(provider.id))
    .map(async (provider) => {
      try {
        return { provider, models: await listModels(provider.id) }
      } catch (error) {
        const detail = error instanceof Error ? error.message : "Model catalog request failed"
        return { provider, models: [], error: safeCatalogFailure(detail) }
      }
    }))
}

function safeCatalogFailure(detail: string) {
  return detail
    .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    .replace(/((?:authorization\s*:\s*)?bearer\s+)[^\s,;]+/gi, "$1[redacted]")
    .replace(/((?:api[_-]?key|token|secret)\s*[:=]\s*)[^&\s,;]+/gi, "$1[redacted]")
    .slice(0, 160)
}
