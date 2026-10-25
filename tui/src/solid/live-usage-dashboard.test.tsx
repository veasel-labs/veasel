/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp /usage browses durable provider/model data and preserves reported-field flags", async () => {
  const controller = new AbortController()
  let usageRequests = 0
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([
      { id: "session-1", title: "Usage project", directory: "/project" },
    ])
    if (path === "/v1/sessions/session-1/messages") return Response.json([])
    if (path === "/v1/usage") {
      usageRequests++
      return Response.json({
        sessions: 2,
        completed_turns: 4,
        reported_turns: 3,
        input_tokens: 3500,
        output_tokens: 600,
        usage_reported: true,
        cache_read_tokens: 1200,
        cache_creation_tokens: 100,
        cache_reported: true,
        reasoning_tokens: 42,
        reasoning_reported: true,
        cost: "$0.12",
        models: [{
          provider: "anthropic",
          model: "claude-test",
          completed_turns: 4,
          reported_turns: 3,
          input_tokens: 3500,
          output_tokens: 600,
          cache_read_tokens: 1200,
          cache_creation_tokens: 100,
          cache_reported: true,
          cache_reported_turns: 2,
          reasoning_tokens: 42,
          reasoning_reported: true,
          reasoning_reported_turns: 2,
          cost: "$0.12",
        }],
      })
    }
    return Response.json({})
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  async function until(text: string) {
    for (let attempt = 0; attempt < 100; attempt++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return setup.captureCharFrame()
      await Bun.sleep(5)
    }
    throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
  }
  try {
    await until("Usage project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("/usage")
    setup.mockInput.pressEnter()
    await until("Usage by model")
    let frame = await until("anthropic / claude-test")
    expect(frame).toContain("3.5k in")
    expect(frame).toContain("est $0.12")
    expect(usageRequests).toBe(1)

    setup.mockInput.pressEnter()
    frame = await until("Usage details")
    const details = frame.replace(/\s+/g, " ")
    expect(details).toContain("Provider-reported tokens: 3.5k input · 600 output")
    expect(details).toContain("Cache: 1.2k read · 100 written · reported on 2")
    expect(details).toContain("turns")
    expect(details).toContain("Reasoning: 42 tokens · reported on 2 turns")
    expect(details).toContain("Estimated cost for reported usage")
    expect(details).toContain("schedule): $0.12")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
