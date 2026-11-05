/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

const PROVIDERS = [
  { id: "anthropic", name: "Anthropic", description: "Claude models via the Anthropic Messages API", protocol: "anthropic", base_url: "https://api.anthropic.com/v1", environment_key: "ANTHROPIC_API_KEY", documentation_url: "https://docs.anthropic.com", requires_api_key: true },
  { id: "openai-compatible", name: "OpenAI-compatible gateway with a very long display name", description: "Any OpenAI-compatible chat completions endpoint, self-hosted or hosted", protocol: "openai-compatible", base_url: "https://example.invalid/v1", environment_key: "", requires_api_key: true },
  { id: "ollama", name: "Ollama local", description: "Local models, no key", protocol: "openai-compatible", base_url: "http://127.0.0.1:11434/v1", environment_key: "", requires_api_key: false },
]

// #552: at small heights the provider list used a fixed page of 12 rows, so
// the dialog content overflowed and list rows painted onto the bottom
// border while the focused row could be off-screen entirely.
for (const [width, height] of [[32, 12], [40, 16]] as Array<[number, number]>) {
  test(`connect dialog keeps its list inside the border at ${width}x${height}`, async () => {
    const controller = new AbortController()
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
      const path = new URL(request.url).pathname
      if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
        stream.enqueue(new TextEncoder().encode(": connected\n\n"))
      } }), { headers: { "content-type": "text/event-stream" } })
      if (path === "/v1/sessions") return Response.json([])
      if (path === "/v1/config/model") return Response.json({
        active_provider: "openai-compatible", profiles: {}, providers: PROVIDERS,
        configured_providers: [], model_ready: false,
      })
      return Response.json({})
    } })
    const setup = await testRender(
      () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/project" />,
      { width, height, kittyKeyboard: true },
    )
    async function until(text: string) {
      for (let i = 0; i < 120; i++) {
        await setup.renderOnce()
        if (setup.captureCharFrame().includes(text)) return
        await Bun.sleep(5)
      }
      throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
    }
    try {
      await until("VEASEL")
      await setup.mockInput.typeText("/connect")
      setup.mockInput.pressEnter()
      await until("CONNECT")

      const lines = setup.captureCharFrame().split("\n")
      for (const line of lines) {
        const trimmed = line.trimEnd()
        if (trimmed.startsWith("┌") || trimmed.startsWith("└")) {
          expect(trimmed).toMatch(/^[┌└][─ ]*[┐┘]$/)
        }
      }
      // The focused provider row is visible on a content row.
      const focused = lines.find((line) => line.includes("▸"))
      expect(focused).toBeDefined()
      expect(focused!.startsWith("└")).toBe(false)
      // No provider row rides the bottom border.
      const bottomBorder = [...lines].reverse().find((line) => line.trimEnd().startsWith("└"))
      expect(bottomBorder).toBeDefined()
      expect(bottomBorder!).not.toContain("Ollama")
      expect(bottomBorder!).not.toContain("Anthropic")
    } finally {
      setup.renderer.destroy()
      controller.abort()
      server.stop(true)
    }
  })
}
