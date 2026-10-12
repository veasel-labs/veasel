import { describe, expect, test } from "bun:test"
import { filterModelCatalog, filterModelProviders, safeModelCatalogText, type ModelCatalogEntry, type ModelProvider } from "./model-providers"

const providers: ModelProvider[] = [
  { id: "anthropic", name: "Anthropic", description: "Claude models", protocol: "anthropic", base_url: "https://api.anthropic.com/v1", environment_key: "ANTHROPIC_API_KEY", requires_api_key: true },
  { id: "deepseek", name: "DeepSeek", description: "OpenAI-compatible Chat Completions", protocol: "openai-compatible", base_url: "https://api.deepseek.com/v1", environment_key: "DEEPSEEK_API_KEY", requires_api_key: true },
  { id: "ollama", name: "Ollama", description: "Local models", protocol: "openai-compatible", base_url: "http://127.0.0.1:11434/v1", environment_key: "", requires_api_key: false },
]

describe("model provider picker", () => {
  test("shows all options when the query is empty", () => {
    expect(filterModelProviders(providers, " ")).toEqual(providers)
  })

  test("matches provider names and IDs without case sensitivity", () => {
    expect(filterModelProviders(providers, "DEEP").map(({ id }) => id)).toEqual(["deepseek"])
  })

  test("matches protocol, environment variable, and description", () => {
    expect(filterModelProviders(providers, "anthropic_api_key").map(({ id }) => id)).toEqual(["anthropic"])
    expect(filterModelProviders(providers, "local models").map(({ id }) => id)).toEqual(["ollama"])
    expect(filterModelProviders(providers, "chat completions").map(({ id }) => id)).toEqual(["deepseek"])
  })
})

describe("provider model picker", () => {
  const models: ModelCatalogEntry[] = [
    { id: "claude-sonnet-4", name: "Claude Sonnet 4" },
    { id: "gpt-5-codex", name: "GPT-5 Codex" },
  ]

  test("filters by model ID and display name", () => {
    expect(filterModelCatalog(models, "CODEX").map(({ id }) => id)).toEqual(["gpt-5-codex"])
    expect(filterModelCatalog(models, "sonnet").map(({ id }) => id)).toEqual(["claude-sonnet-4"])
  })

  test("keeps all models for an empty query", () => {
    expect(filterModelCatalog(models, " ")).toEqual(models)
  })

  test("removes terminal control and bidirectional formatting characters from labels", () => {
    expect(safeModelCatalogText("safe\u001b[2J\u202Ename\u009b")).toBe("safe[2Jname")
  })
})
