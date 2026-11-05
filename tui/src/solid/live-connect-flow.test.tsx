/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { VeaselApiClient } from "../api-client"
import { LiveApp } from "./live-app"

const PROVIDER = {
  id: "anthropic",
  name: "Anthropic",
  description: "Claude models",
  protocol: "anthropic",
  base_url: "https://api.anthropic.com/v1",
  environment_key: "ANTHROPIC_API_KEY",
  requires_api_key: true,
}

function serveConnect(sessions: unknown[]) {
  const discoveryBodies: unknown[] = []
  const saveBodies: unknown[] = []
  let saved = false
  const view = () => ({
    active_provider: saved ? "anthropic" : "openai-compatible",
    profiles: saved
      ? { anthropic: { model: "claude-fixture", base_url: PROVIDER.base_url, api_key_saved: true, max_output_tokens: 0 } }
      : {},
    providers: [PROVIDER],
    configured_providers: saved ? ["anthropic"] : [],
    model_ready: saved,
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/v1/events") return new Response(new ReadableStream({ start(stream) {
      stream.enqueue(new TextEncoder().encode(": connected\n\n"))
    } }), { headers: { "content-type": "text/event-stream" } })
    if (path === "/v1/sessions") return Response.json(sessions)
    if (path.endsWith("/messages")) return Response.json([])
    if (path === "/v1/config/model" && request.method === "GET") return Response.json(view())
    if (path === "/v1/config/models" && request.method === "POST") {
      discoveryBodies.push(await request.json())
      return Response.json({
        provider: "anthropic",
        models: [{ id: "claude-fixture", name: "Claude Fixture" }],
      })
    }
    if (path === "/v1/config/model" && request.method === "POST") {
      saveBodies.push(await request.json())
      saved = true
      return Response.json(view())
    }
    return Response.json({})
  } })
  return { server, discoveryBodies, saveBodies }
}

async function walkConnectDialog(
  setup: Awaited<ReturnType<typeof testRender>>,
  until: (text: string) => Promise<void>,
) {
  await until("CONNECT")
  await until("Anthropic")
  setup.mockInput.pressEnter()
  await until("API key")
  await setup.mockInput.typeText("sk-fixture-connect-key")
  setup.mockInput.pressEnter()
  await until("Select model")
  await until("Claude Fixture")
  setup.mockInput.pressEnter()
  await until("Connected · anthropic/claude-fixture")
}

function expectConnectSaved(discoveryBodies: unknown[], saveBodies: unknown[]) {
  expect(discoveryBodies).toEqual([
    { provider: "anthropic", base_url: PROVIDER.base_url, api_key: "sk-fixture-connect-key" },
  ])
  expect(saveBodies).toHaveLength(1)
  expect(saveBodies[0]).toMatchObject({
    provider: "anthropic",
    model: "claude-fixture",
    base_url: PROVIDER.base_url,
    api_key: "sk-fixture-connect-key",
  })
}

async function renderLiveApp(server: { url: URL }, controller: AbortController) {
  const setup = await testRender(
    () => <LiveApp api={new VeaselApiClient(server.url.origin, controller.signal)} directory="/project" />,
    { width: 120, height: 40, kittyKeyboard: true },
  )
  const until = async (text: string) => {
    for (let i = 0; i < 120; i++) {
      await setup.renderOnce()
      if (setup.captureCharFrame().includes(text)) return
      await Bun.sleep(5)
    }
    throw new Error(`Missing ${text}\n${setup.captureCharFrame()}`)
  }
  return { setup, until }
}

test("/connect from a session walks provider pick, key entry, discovery, model pick, and saves", async () => {
  const controller = new AbortController()
  const { server, discoveryBodies, saveBodies } = serveConnect([
    { id: "a", title: "Real project", directory: "/project" },
  ])
  const { setup, until } = await renderLiveApp(server, controller)
  try {
    await until("Real project")
    setup.mockInput.pressEnter()
    await until("Message Veasel")
    await setup.mockInput.typeText("/connect")
    setup.mockInput.pressEnter()
    await walkConnectDialog(setup, until)
    expectConnectSaved(discoveryBodies, saveBodies)
    // The pasted key must stay masked in the rendered frame.
    expect(setup.captureCharFrame()).not.toContain("sk-fixture-connect-key")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})

test("/connect from a clean-profile home (no sessions) completes the same flow", async () => {
  const controller = new AbortController()
  const { server, discoveryBodies, saveBodies } = serveConnect([])
  const { setup, until } = await renderLiveApp(server, controller)
  try {
    // First-run home: no sessions, splash steers to /connect.
    await until("/connect to choose a model")
    await setup.mockInput.typeText("/connect")
    setup.mockInput.pressEnter()
    await walkConnectDialog(setup, until)
    expectConnectSaved(discoveryBodies, saveBodies)
    expect(setup.captureCharFrame()).not.toContain("sk-fixture-connect-key")
  } finally {
    setup.renderer.destroy()
    controller.abort()
    server.stop(true)
  }
})
