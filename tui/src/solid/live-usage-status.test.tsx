/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("Home status shows durable global usage without an active session", async () => {
  const controller = new AbortController()
  let usageRequests = 0
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([])
    if (path === "/v1/usage") {
      usageRequests++
      return Response.json({
        sessions: 3,
        completed_turns: 8,
        reported_turns: 7,
        input_tokens: 1200,
        output_tokens: 340,
        usage_reported: true,
        cost: "0.42",
      })
    }
    return Response.json({})
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/project" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  async function until(text: string) {
    for (let i = 0; i < 100; i++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return
      await Bun.sleep(5)
    }
    throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
  }
  try {
    await setup.renderOnce()
    setup.mockInput.pressKey("p", { ctrl: true })
    await until("Commands")
    await setup.mockInput.typeText("status")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await until("Usage · all sessions (3): 1200 in · 340 out · cost 0.42")
    expect(usageRequests).toBe(1)
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
