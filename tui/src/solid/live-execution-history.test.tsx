/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp browses durable session executions and inspects a failed run", async () => {
  const controller = new AbortController()
  const requested: string[] = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname
    requested.push(path)
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([
      { id: "a", title: "Real project", directory: "/project/alpha" },
    ])
    if (path === "/v1/sessions/a/messages") return Response.json([])
    if (path === "/v1/sessions/a/operations") return Response.json([
      {
        id: "run-1", session_id: "a", status: "completed", provider: "openai", model: "gpt-test",
        error: "", usage_reported: true, input_tokens: 20, output_tokens: 8,
        created_at: "2026-10-21 10:00:00", updated_at: "2026-10-21 10:00:02",
      },
      {
        id: "run-2", session_id: "a", status: "failed", provider: "anthropic", model: "claude-test",
        error: "provider timed out", usage_reported: false,
        created_at: "2026-10-21 11:00:00", updated_at: "2026-10-21 11:00:30",
      },
    ])
    return Response.json({})
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />,
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
    await until("Real project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("/runs")
    setup.mockInput.pressEnter()
    await until("Executions · 2")
    expect(requested).toContain("/v1/sessions/a/operations")
    expect(setup.captureCharFrame()).toContain("FAILED · anthropic/claude-test")
    setup.mockInput.pressEnter()
    await until("Execution details")
    expect(setup.captureCharFrame()).toContain("Error: provider timed out")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
