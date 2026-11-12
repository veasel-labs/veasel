/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { VeaselApiClient, type ApiSubagentRun } from "../../api-client"
import { openSubagentRunsDialog } from "./subagent-runs-dialog"
import { DialogProvider, useDialog } from "../ui/dialog"

const fixture: ApiSubagentRun = {
  id: "run-1",
  request_id: "request-1",
  parent_session_id: "parent-1",
  parent_operation_id: "operation-1",
  child_session_id: "child-1",
  agent_id: "explorer",
  target_provider: "",
  target_model: "",
  provider: "provider-a",
  model: "model-a",
  depth: 1,
  status: "running",
  result: "",
  error: "",
  cancel_requested: false,
  outcome_claimed: false,
  workspace_ready: true,
  workspace_started: true,
  workspace_base_commit: "base-commit",
  usage_reported: false,
}

type TestSetup = Awaited<ReturnType<typeof testRender>>

async function waitForScreen(setup: TestSetup, predicate: (frame: string) => boolean, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs
  let frame = setup.captureCharFrame()
  while (!predicate(frame) && Date.now() < deadline) {
    await Bun.sleep(25)
    await setup.renderOnce()
    frame = setup.captureCharFrame()
  }
  if (!predicate(frame)) throw new Error(`Timed out waiting for terminal state:\n${frame}`)
  return frame
}

function Harness(props: { api: VeaselApiClient }) {
  const dialog = useDialog()
  onMount(() => openSubagentRunsDialog(dialog, { api: props.api, sessionId: "parent-1" }))
  return <text>Agent dialog test</text>
}

test("agent details refresh and Enter returns through the stack at 32x12", async () => {
  let current = fixture
  let completedListRequests = 0
  const completion = setTimeout(() => {
    current = {
      ...fixture,
      status: "completed",
      result: "Verified child result after refresh.",
      outcome_claimed: true,
      input_tokens: 23,
      output_tokens: 9,
      usage_reported: true,
      reported_cost_usd: 0.0042,
      cost_reported: true,
    }
  }, 600)
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      if (path.endsWith("/subagents")) {
        if (current.status === "completed") completedListRequests += 1
        return Response.json([current])
      }
      if (path.endsWith("/subagents/run-1")) return Response.json(current)
      return new Response("not found", { status: 404 })
    },
  })
  const setup = await testRender(
    () => <DialogProvider><Harness api={new VeaselApiClient(server.url.origin)} /></DialogProvider>,
    { width: 32, height: 12, kittyKeyboard: true },
  )
  try {
    await waitForScreen(setup, (frame) => frame.includes("RUNNING · explorer"))
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Inspect result")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Status: running")
    setup.mockInput.pressKey("END")
    await setup.renderOnce()
    const unavailableFrame = setup.captureCharFrame()
    expect(unavailableFrame).toContain("Provider-reported cost:")
    expect(unavailableFrame).toContain("unavailable")
    setup.mockInput.pressKey("HOME")
    await setup.renderOnce()
    await Bun.sleep(1_600)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Status: completed")

    setup.mockInput.pressKey("END")
    await setup.renderOnce()
    const costFrame = setup.captureCharFrame()
    expect(costFrame).toContain("Provider-reported usage: 23")
    expect(costFrame).toContain("Provider-reported cost: $0.")
    expect(costFrame).toContain("004200 USD")
    expect(costFrame).toContain("Cost estimates: not shown")
    setup.mockInput.pressKey("HOME")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Status: completed")
    const lines = setup.captureCharFrame().split("\n")
    const bottomBorder = lines.findIndex((line) => line.includes("└"))
    expect(bottomBorder).toBeGreaterThan(-1)
    expect(lines[bottomBorder]).not.toContain("Verified child result")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Inspect result")
    setup.mockInput.pressEscape()
    await setup.renderOnce()
    await waitForScreen(setup, (frame) => frame.includes("COMPLETED · explorer"))
    expect(completedListRequests).toBeGreaterThan(0)
  } finally {
    clearTimeout(completion)
    setup.renderer.destroy()
    server.stop(true)
  }
}, 10_000)
