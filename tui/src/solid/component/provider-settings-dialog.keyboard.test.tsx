/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import type { ModelProvider } from "../../model-providers"
import { DialogProvider } from "../ui/dialog"
import { ProviderSettingsDialog } from "./provider-settings-dialog"

const providers: ModelProvider[] = [
  { id: "gemini", name: "Gemini", description: "Google models", protocol: "gemini", base_url: "https://example.test", environment_key: "GEMINI_API_KEY", requires_api_key: true },
  { id: "jina", name: "Jina", description: "Jina models", protocol: "openai-compatible", base_url: "https://example.test", environment_key: "JINA_API_KEY", requires_api_key: true },
  { id: "kimi", name: "Kimi", description: "Moonshot models", protocol: "openai-compatible", base_url: "https://example.test", environment_key: "KIMI_API_KEY", requires_api_key: true },
  { id: "302-ai", name: "302 AI", description: "302 provider", protocol: "openai-compatible", base_url: "https://example.test", environment_key: "302_API_KEY", requires_api_key: true },
]

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) setup.renderer.destroy()
})

describe("provider picker typing", () => {
  for (const [query, expected] of [
    ["gemini", "Gemini"],
    ["jina", "Jina"],
    ["kimi", "Kimi"],
    ["302", "302 AI"],
  ] as const) {
    test(`search accepts ${query} as the first input`, async () => {
      const setup = await testRender(
        () => <DialogProvider><ProviderSettingsDialog providers={providers} /></DialogProvider>,
        { width: 80, height: 40, kittyKeyboard: true },
      )
      setups.push(setup)
      await setup.renderOnce()
      await setup.mockInput.typeText(query)
      await setup.renderOnce()
      const frame = setup.captureCharFrame()
      expect(frame).toContain(expected)
      expect(frame).toContain("1/4")
    })
  }
})
