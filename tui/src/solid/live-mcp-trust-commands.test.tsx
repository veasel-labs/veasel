/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp routes MCP trust and revoke commands to the session API", async () => {
  const controller = new AbortController()
  const calls: Array<{ path: string; body?: unknown }> = []
  let trusted = false
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (url.pathname === "/v1/sessions/a/messages") return Response.json([])
    if (url.pathname === "/v1/sessions/a/mcp-servers") {
      const body = request.method === "POST" ? await request.json() : undefined
      if (body) {
        calls.push({ path: url.pathname, body })
        trusted = body.trusted
      }
      return Response.json(trusted
        ? [{ plugin_name: "configured", server_name: "echo-tools" }]
        : [])
    }
    if (url.pathname === "/v1/mcp-servers") {
      return Response.json({ servers: [
        { name: "echo-tools", enabled: true, transport: "stdio", scope: "user" },
        { name: "disabled-tools", enabled: false, transport: "stdio", scope: "user" },
      ] })
    }
    return Response.json({})
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  async function until(text: string) {
    for (let n = 0; n < 100; n++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return
      await Bun.sleep(5)
    }
    throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
  }
  async function submit(text: string, confirmation: string) {
    await setup.mockInput.typeText(text)
    setup.mockInput.pressEnter()
    await until(confirmation)
  }
  try {
    await until("Real project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText("/mcp trust ")
    await until("configured/echo-tools")
    expect(setup.captureCharFrame()).toContain("available")
    expect(setup.captureCharFrame()).not.toContain("disabled-tools")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe("/mcp trust configured/echo-tools")
    setup.mockInput.pressEnter()
    await until("Trusted configured/echo-tools")
    await submit("/mcp", "MCP servers")
    await until("Trusted")
    const inventory = setup.captureCharFrame()
    expect(inventory).toContain("configured/echo-tools")
    expect(inventory).not.toContain("Connected")
    setup.mockInput.pressEscape()
    await setup.renderOnce()
    await setup.mockInput.typeText("/mcp untrust ")
    await until("stdio · trusted")
    expect(setup.captureCharFrame()).toContain("trusted")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe("/mcp untrust configured/echo-tools")
    setup.mockInput.pressEnter()
    await until("Revoked trust for configured/echo-tools")
    expect(calls).toEqual([
      {
        path: "/v1/sessions/a/mcp-servers",
        body: { plugin_name: "configured", server_name: "echo-tools", trusted: true },
      },
      {
        path: "/v1/sessions/a/mcp-servers",
        body: { plugin_name: "configured", server_name: "echo-tools", trusted: false },
      },
    ])
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
