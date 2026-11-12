import { expect, test } from "bun:test"
import { loadDelegateCatalogs } from "./subagent-model-catalog"

test("a provider catalog failure stays scoped while healthy provider models remain available", async () => {
  const providers = [
    { id: "anthropic", name: "Anthropic" },
    { id: "openai", name: "OpenAI" },
  ] as Parameters<typeof loadDelegateCatalogs<{ id: string }>>[0]
  const catalogs = await loadDelegateCatalogs(providers, new Set(["anthropic", "openai"]), async (providerId) => {
    if (providerId === "anthropic") throw new Error("HTTP 503: catalog unavailable")
    return [{ id: "gpt-test" }]
  })

  expect(catalogs).toEqual([
    { provider: providers[0], models: [], error: "HTTP 503: catalog unavailable" },
    { provider: providers[1], models: [{ id: "gpt-test" }] },
  ])
})

test("catalog failure details redact credentials and terminal control characters", async () => {
  const providers = [{ id: "provider-x", name: "Provider X" }] as Parameters<typeof loadDelegateCatalogs>[0]
  const [catalog] = await loadDelegateCatalogs(providers, new Set(["provider-x"]), async () => {
    throw new Error("HTTP 401: Authorization: Bearer secret-value\napi-key: hidden")
  })
  expect(catalog?.error).toBe("HTTP 401: Authorization: Bearer [redacted] api-key: [redacted]")
})
