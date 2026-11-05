/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

function serveModelSettings(modelReady: boolean, onSettingsRequest: () => void) {
  return Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json([])
    if (path === "/v1/config/model") {
      onSettingsRequest()
      return Response.json({
        active_provider: "openai-compatible",
        profiles: {},
        providers: [],
        configured_providers: [],
        model_ready: modelReady,
      })
    }
    return Response.json({})
  } })
}

test("startup warns up front when the backend reports no usable model", async () => {
  const controller = new AbortController()
  let settingsRequests = 0
  const server = serveModelSettings(false, () => { settingsRequests++ })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/project" />,
    { width: 120, height: 40, kittyKeyboard: true },
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
    await until("Model setup")
    const frame = setup.captureCharFrame()
    expect(frame).toContain("No model is configured yet")
    expect(frame).toContain("/connect")
    expect(settingsRequests).toBeGreaterThan(0)
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})

test("startup stays quiet when the backend reports a usable model", async () => {
  const controller = new AbortController()
  let settingsRequests = 0
  const server = serveModelSettings(true, () => { settingsRequests++ })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/project" />,
    { width: 120, height: 40, kittyKeyboard: true },
  )
  try {
    // Give the startup settings probe ample opportunity to (not) warn.
    for (let i = 0; i < 40 && settingsRequests === 0; i++) {
      await setup.renderOnce()
      await Bun.sleep(5)
    }
    for (let i = 0; i < 10; i++) {
      await setup.renderOnce()
      await Bun.sleep(5)
    }
    expect(settingsRequests).toBeGreaterThan(0)
    expect(setup.captureCharFrame()).not.toContain("Model setup")
    expect(setup.captureCharFrame()).not.toContain("No model is configured yet")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
