import { describe, expect, test } from "bun:test"
import { filterModelCatalog, filterModelProviders, formatModelCatalogCostBadge, formatModelCatalogContextBadge, moveProviderPickerScope, prioritizeModelProviders, providerConnectionGuidance, providerPickerScopeLabel, providerPickerScopes, safeModelCatalogText, type ModelCatalogEntry, type ModelProvider } from "./model-providers"

const providers: ModelProvider[] = [
  { id: "meta", name: "Meta Model API", description: "Muse Wonder and Muse Spark · OpenAI Responses API", protocol: "openai-responses", base_url: "https://api.meta.ai/v1", environment_key: "MODEL_API_KEY", documentation_url: "https://dev.meta.ai/docs/coding-agents", requires_api_key: true },
  { id: "anthropic", name: "Anthropic", description: "Claude models", protocol: "anthropic", base_url: "https://api.anthropic.com/v1", environment_key: "ANTHROPIC_API_KEY", requires_api_key: true },
  { id: "deepseek", name: "DeepSeek", description: "OpenAI-compatible Chat Completions", protocol: "openai-compatible", base_url: "https://api.deepseek.com/v1", environment_key: "DEEPSEEK_API_KEY", requires_api_key: true },
  { id: "ollama", name: "Ollama", description: "Local models", protocol: "openai-compatible", base_url: "http://127.0.0.1:11434/v1", environment_key: "", requires_api_key: false },
]

describe("model provider picker", () => {
  test("explains OpenCode Go credential requirements without adding noise for other providers", () => {
    const go: ModelProvider = {
      id: "opencode-go",
      name: "OpenCode Go",
      description: "OpenCode Go",
      protocol: "openai-compatible",
      base_url: "https://opencode.ai/inference/go/openai/v1",
      environment_key: "OPENCODE_API_KEY",
      documentation_url: "https://opencode.ai/v2/docs/console/go/",
      requires_api_key: true,
    }
    expect(providerConnectionGuidance(go)).toContain("fresh OpenCode Console API key")
    expect(providerConnectionGuidance(go)).toContain("cannot reuse the OpenCode CLI login")
    expect(providerConnectionGuidance(providers[0])).toBeUndefined()
  })

  test("shows all options when the query is empty", () => {
    expect(filterModelProviders(providers, " ")).toEqual(providers)
  })

  test("matches provider names and IDs without case sensitivity", () => {
    expect(filterModelProviders(providers, "DEEP").map(({ id }) => id)).toEqual(["deepseek"])
  })

  test("tolerates short typos and ranks exact names ahead of fuzzy matches", () => {
    expect(filterModelProviders(providers, "anthorpic").map(({ id }) => id)).toEqual(["anthropic"])
    expect(filterModelProviders(providers, "muse wonder").map(({ id }) => id)).toEqual(["meta"])
    expect(filterModelProviders(providers, "deepseak").map(({ id }) => id)).toEqual(["deepseek"])
    const closeMatch: ModelProvider = {
      ...providers[0],
      id: "museai",
      name: "MuseAI",
      description: "Compatible model API",
    }
    expect(filterModelProviders([closeMatch, providers[0]], "muse").map(({ id }) => id)).toEqual(["meta", "museai"])
  })

  test("rejects oversized fragments without computing edit distance", () => {
    expect(filterModelProviders(providers, "x".repeat(4_096))).toEqual([])
  })

  test("matches protocol, environment variable, and description", () => {
    expect(filterModelProviders(providers, "muse").map(({ id }) => id)).toEqual(["meta"])
    expect(filterModelProviders(providers, "MODEL_API_KEY").map(({ id }) => id)).toEqual(["meta"])
    expect(filterModelProviders(providers, "anthropic_api_key").map(({ id }) => id)).toEqual(["anthropic"])
    expect(filterModelProviders(providers, "local models").map(({ id }) => id)).toEqual(["ollama"])
    expect(filterModelProviders(providers, "chat completions").map(({ id }) => id)).toEqual(["deepseek"])
  })

  test("puts the active and configured providers before the rest without mutating the catalog", () => {
    const ordered = prioritizeModelProviders(providers, "deepseek", new Set(["meta"]))
    expect(ordered.map(({ id }) => id)).toEqual(["deepseek", "meta", "anthropic", "ollama"])
    expect(providers.map(({ id }) => id)).toEqual(["meta", "anthropic", "deepseek", "ollama"])
  })

  test("groups compatible, specialized, local, and connected providers without losing search", () => {
    expect(filterModelProviders(providers, "", "specialized").map(({ id }) => id)).toEqual(["meta", "anthropic"])
    expect(filterModelProviders(providers, "", "compatible").map(({ id }) => id)).toEqual(["deepseek", "ollama"])
    expect(filterModelProviders(providers, "", "local").map(({ id }) => id)).toEqual(["ollama"])
    expect(filterModelProviders(providers, "", "local", new Set(), { deepseek: { base_url: "http://localhost:8000/v1" } }).map(({ id }) => id)).toEqual(["deepseek", "ollama"])
    expect(filterModelProviders(providers, "deep", "compatible").map(({ id }) => id)).toEqual(["deepseek"])
    expect(filterModelProviders(providers, "", "configured", new Set(["meta", "ollama"])).map(({ id }) => id)).toEqual(["meta", "ollama"])
  })

  test("exposes stable labels and keyboard cycling order for provider groups", () => {
    expect(providerPickerScopes).toEqual(["all", "configured", "local", "specialized", "compatible"])
    expect(providerPickerScopeLabel("configured")).toBe("Configured")
    expect(providerPickerScopeLabel("specialized")).toBe("Specialized APIs")
    expect(moveProviderPickerScope("all", 1)).toBe("configured")
    expect(moveProviderPickerScope("compatible", 1)).toBe("all")
    expect(moveProviderPickerScope("all", -1)).toBe("compatible")
  })
})

describe("provider model picker", () => {
  const models: ModelCatalogEntry[] = [
    { id: "muse-wonder-1.0", name: "muse-wonder-1.0" },
    { id: "muse-spark-1.3", name: "muse-spark-1.3" },
    { id: "claude-sonnet-4", name: "Claude Sonnet 4" },
    { id: "gpt-5-codex", name: "GPT-5 Codex" },
  ]

  test("filters by model ID and display name", () => {
    expect(filterModelCatalog(models, "WONDER").map(({ id }) => id)).toEqual(["muse-wonder-1.0"])
    expect(filterModelCatalog(models, "CODEX").map(({ id }) => id)).toEqual(["gpt-5-codex"])
    expect(filterModelCatalog(models, "sonnet").map(({ id }) => id)).toEqual(["claude-sonnet-4"])
  })

  test("matches transposed characters and ranks exact model prefixes first", () => {
    const candidates = [
      ...models,
      { id: "muse-wonder-1-preview", name: "Muse Wonder Preview" },
      { id: "musa-wonder-1-preview", name: "Musa Wonder Preview" },
      { id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5" },
    ]
    expect(filterModelCatalog(candidates, "muse wonder").map(({ id }) => id)).toEqual([
      "muse-wonder-1.0",
      "muse-wonder-1-preview",
      "musa-wonder-1-preview",
    ])
    expect(filterModelCatalog(candidates, "claud sonnet").map(({ id }) => id)).toEqual([
      "claude-sonnet-4",
      "claude-sonnet-4-5",
    ])
    expect(filterModelCatalog(candidates, "muse-wodner").map(({ id }) => id)).toEqual([
      "muse-wonder-1.0",
      "muse-wonder-1-preview",
      "musa-wonder-1-preview",
    ])
  })

  test("keeps all models for an empty query", () => {
    expect(filterModelCatalog(models, " ")).toEqual(models)
  })

  test("removes terminal control and bidirectional formatting characters from labels", () => {
    expect(safeModelCatalogText("safe\u001b[2J\u202Ename\u009b")).toBe("safe[2Jname")
  })

  test("formats pinned schedule rates as a model picker badge", () => {
    expect(formatModelCatalogCostBadge({ id: "x", name: "x" })).toBe("")
    expect(formatModelCatalogCostBadge({
      id: "claude-haiku-4-5",
      name: "Haiku",
      input_per_mtok: 1,
      output_per_mtok: 5,
      cost_unit: "usd_per_million_tokens",
    })).toBe("1/5 $/MTok in/out (pinned)")
  })

  test("formats curated context windows as a model picker badge", () => {
    expect(formatModelCatalogContextBadge({ id: "x", name: "x" })).toBe("")
    expect(formatModelCatalogContextBadge({ id: "x", name: "x", context_tokens: 0 })).toBe("")
    expect(formatModelCatalogContextBadge({ id: "x", name: "x", context_tokens: 200_000 })).toBe("200k ctx (pinned)")
    expect(formatModelCatalogContextBadge({ id: "x", name: "x", context_tokens: 1_000_000 })).toBe("1M ctx (pinned)")
    expect(formatModelCatalogContextBadge({ id: "x", name: "x", context_tokens: 1_048_576 })).toBe("1.05M ctx (pinned)")
  })
})
