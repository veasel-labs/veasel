/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"
import { renderMarkdownFrame } from "./markdown-test-helpers"

// #552 size matrix for the session view. Regression: the session tab rail
// used height={2} with a border (zero content rows), so tab titles painted
// onto the bottom border, and header texts wrapped over the header borders
// at narrow widths — stray "TA"/"BS"/"CODE" fragments on border rows.
const SIZES: Array<[number, number]> = [
  [32, 12], [40, 16], [80, 24], [80, 30], [100, 35], [120, 40],
]

function serveSession() {
  return Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([
      { id: "a", title: "Fix flaky parser in src/main.v", directory: "/project" },
    ])
    if (path === "/v1/sessions/a/messages") return Response.json([
      { role: "user", content: "Fix the flaky parser test" },
      { role: "assistant", content: "I found the race in the lexer and patched the token buffer handling." },
    ])
    if (path === "/v1/sessions/a/operations") return Response.json([])
    if (path === "/v1/config/model") return Response.json({
      active_provider: "openai-compatible",
      profiles: { "openai-compatible": { model: "smoke-model", base_url: "", api_key_saved: true, max_output_tokens: 0 } },
      providers: [], configured_providers: ["openai-compatible"], model_ready: true,
    })
    return Response.json({})
  } })
}

for (const [width, height] of SIZES) {
  test(`session chrome stays inside its borders at ${width}x${height}`, async () => {
    const controller = new AbortController()
    const server = serveSession()
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
      await until("Fix flaky")
      setup.mockInput.pressEnter()
      await until("Message Veasel")
      await renderMarkdownFrame(setup)
      await until("I found the race")

      const lines = setup.captureCharFrame().split("\n")
      // Header (3 rows) + tab rail (3 rows): border rows must contain only
      // border glyphs — no wrapped wordmark/status/tab-label fragments.
      for (const line of lines.slice(0, 6)) {
        const trimmed = line.trimEnd()
        if (trimmed.startsWith("┌") || trimmed.startsWith("└")) {
          expect(trimmed).toMatch(/^[┌└][─ ]*[┐┘]$/)
        }
      }
      // The active tab title sits on a content row, never on a border row.
      const tabLine = lines.find((line) => line.includes("Fix flaky parser"))
      expect(tabLine).toBeDefined()
      expect(tabLine!.startsWith("└")).toBe(false)
      expect(tabLine!.startsWith("┌")).toBe(false)
    } finally {
      setup.renderer.destroy()
      controller.abort()
      server.stop(true)
    }
  })
}
