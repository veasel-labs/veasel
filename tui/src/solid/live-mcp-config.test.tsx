/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

test("LiveApp adds, toggles, and confirms removal of configured MCP servers", async () => {
  const controller = new AbortController()
  const calls: Array<{ method: string; url: string; body?: Record<string, unknown> }> = []
  let configured: Array<{ name: string; scope: string; enabled: boolean; transport: string; command?: string }> = []
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (url.pathname === "/v1/sessions") return Response.json([{ id: "a", title: "Real project", directory: "/project/alpha" }])
    if (url.pathname.endsWith("/messages")) return Response.json([])
    if (url.pathname === "/v1/mcp-servers" && request.method === "GET") return Response.json({ servers: configured })
    if (url.pathname === "/v1/mcp-servers" && request.method === "POST") {
      const body = await request.json() as Record<string, unknown>
      calls.push({ method: request.method, url: request.url, body })
      configured = [{ name: "demo", scope: "project", enabled: true, transport: "stdio", command: "node" }]
      return Response.json({ name: "demo", transport: "stdio", scope: "project" })
    }
    if (url.pathname === "/v1/mcp-servers/demo" && request.method === "PATCH") {
      const body = await request.json() as Record<string, unknown>
      calls.push({ method: request.method, url: request.url, body })
      return Response.json({ name: "demo", enabled: body.enabled })
    }
    if (url.pathname === "/v1/mcp-servers/demo" && request.method === "DELETE") {
      calls.push({ method: request.method, url: request.url })
      return new Response(null, { status: 204 })
    }
    return Response.json({ servers: [] })
  } })
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/launch" />,
    { width: 100, height: 35, kittyKeyboard: true },
  )
  const until = (text: string) => setup.waitForFrame((frame) => frame.includes(text))
  try {
    await until("Real project")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    await setup.mockInput.typeText('/mcp add project stdio demo node "server package.js"')
    setup.mockInput.pressEnter()
    await until("Added configured/demo")
    expect(calls[0]?.body).toEqual({
      name: "demo", transport: "stdio", command: "node", args: ["server package.js"],
      scope: "project", directory: "/project/alpha", enabled: true,
    })

    await setup.mockInput.typeText('/mcp add project stdio demo bun "new server.js"')
    setup.mockInput.pressEnter()
    await until("Replace configured MCP server?")
    expect(calls).toHaveLength(1)
    setup.mockInput.pressEscape()
    await setup.renderOnce()
    expect(calls).toHaveLength(1)

    await setup.mockInput.typeText('/mcp add project stdio demo bun "new server.js"')
    setup.mockInput.pressEnter()
    await until("Replace configured MCP server?")
    setup.mockInput.pressEnter()
    await until("Added configured/demo")
    expect(calls).toHaveLength(2)
    expect(calls[1]?.body).toMatchObject({ command: "bun", args: ["new server.js"] })

    await setup.mockInput.typeText("/mcp disable project ")
    await until("project · enabled · stdio")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe("/mcp disable project demo")
    setup.mockInput.pressEnter()
    await until("Disabled project-scope MCP server · demo")
    expect(calls[2]?.method).toBe("PATCH")
    expect(calls[2]?.body).toEqual({ enabled: false })

    await setup.mockInput.typeText("/mcp remove project demo")
    setup.mockInput.pressEnter()
    await until("Remove configured MCP server?")
    expect(calls).toHaveLength(3)
    setup.mockInput.pressEscape()
    await setup.renderOnce()
    expect(calls).toHaveLength(3)

    await setup.mockInput.typeText("/mcp remove project demo")
    setup.mockInput.pressEnter()
    await until("Remove configured MCP server?")
    setup.mockInput.pressEnter()
    await until("Removed project-scope MCP server · demo")
    expect(calls[3]?.method).toBe("DELETE")
    expect(calls[3]?.url).toContain("scope=project&directory=%2Fproject%2Falpha")
  } finally {
    await setup.dispose()
    controller.abort()
    server.stop(true)
  }
})
