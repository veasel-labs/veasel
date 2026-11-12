/** @jsxImportSource @opentui/solid */
import { afterEach, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { VeaselApiClient } from "../../api-client"
import { DialogProvider, useDialog } from "../ui/dialog"
import type { SolidModelRef } from "./model-dialog"
import { openSubagentDelegateDialog } from "./subagent-delegate-dialog"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) setup.renderer.destroy()
})

test("delegation sends the selected cross-provider model independently of the role", async () => {
  let observed: { method: string; path: string; body: unknown } | undefined
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      observed = {
        method: request.method,
        path: new URL(request.url).pathname,
        body: await request.json(),
      }
      return Response.json({
        id: "run-1",
        request_id: "request-cross-provider",
        parent_session_id: "parent/id",
        parent_operation_id: "operation-1",
        child_session_id: "child-1",
        agent_id: "reviewer",
        target_provider: "anthropic",
        target_model: "claude-review-test",
        provider: "anthropic",
        model: "claude-review-test",
        depth: 1,
        status: "queued",
        result: "",
        error: "",
        cancel_requested: false,
        outcome_claimed: false,
        workspace_ready: false,
        workspace_started: false,
        workspace_base_commit: "",
      })
    },
  })

  const models: SolidModelRef[] = [
    { providerID: "openai", modelID: "gpt-implementation-test", name: "GPT implementation", providerName: "OpenAI" },
    { providerID: "anthropic", modelID: "claude-review-test", name: "Claude review", providerName: "Anthropic" },
  ]
  const api = new VeaselApiClient(server.url.origin)

  function Harness() {
    const dialog = useDialog()
    onMount(() => openSubagentDelegateDialog(dialog, {
      roles: [
        { id: "explorer", description: "Read-only repository investigation" },
        { id: "reviewer", description: "Read-only code and change review" },
      ],
      models,
      currentModel: { providerID: "google", modelID: "parent", name: "Parent model", providerName: "Google" },
      initialTask: "Review the auth boundary",
      onSubmit: (input) => {
        void api.createSubagent("parent/id", {
          request_id: "request-cross-provider",
          agent_id: input.agent_id,
          task: input.task,
          target: input.target,
          mode: "async",
        })
      },
    }))
    return <text>Delegate test harness</text>
  }

  const setup = await testRender(
    () => <DialogProvider><Harness /></DialogProvider>,
    { width: 120, height: 36, kittyKeyboard: true },
  )
  setups.push(setup)

  try {
    await setup.waitFor(() => setup.captureCharFrame().includes("Choose agent role"))
    setup.mockInput.pressArrow("down")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Choose model")
    expect(setup.captureCharFrame()).toContain("google/parent")

    // The options are inherit-parent, OpenAI, and Anthropic. Select Anthropic
    // while the parent conversation remains configured for Google.
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressArrow("down")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Role: reviewer")
    expect(setup.captureCharFrame()).toContain("Model: anthropic/claude-review-test")
    setup.mockInput.pressEnter()

    await setup.waitFor(() => observed !== undefined)
    expect(observed).toEqual({
      method: "POST",
      path: "/v1/sessions/parent%2Fid/subagents",
      body: {
        request_id: "request-cross-provider",
        agent_id: "reviewer",
        task: "Review the auth boundary",
        target: { provider: "anthropic", model: "claude-review-test" },
        mode: "async",
      },
    })
  } finally {
    setup.renderer.destroy()
    server.stop(true)
  }
})
