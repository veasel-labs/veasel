/** @jsxImportSource @opentui/solid */
import { afterEach, expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { DialogProvider, useDialog } from "../ui/dialog"
import { openSubagentDelegateDialog } from "./subagent-delegate-dialog"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) setup.renderer.destroy()
})

test("delegate model picker shows provider-scoped catalog retry and retains healthy models", async () => {
  const retried: Array<{ providerId: string; roleId: string }> = []
  let submitted: { provider?: string; model?: string } | undefined

  function Fixture() {
    const dialog = useDialog()
    const open = (initialRole?: string) => openSubagentDelegateDialog(dialog, {
      roles: [{ id: "explorer", description: "Read-only investigation" }],
      models: [{ providerID: "openai", modelID: "gpt-test", name: "GPT Test", providerName: "OpenAI" }],
      catalogFailures: [{ providerId: "anthropic", providerName: "Anthropic", detail: "HTTP 503: catalog unavailable" }],
      initialRole,
      initialTask: "Keep the existing task",
      onRetryProviderCatalog: (providerId: string, roleId: string) => {
        retried.push({ providerId, roleId })
        open(roleId)
      },
      onSubmit: (input) => { submitted = input.target },
    })
    onMount(() => open())
    return <text>Delegate catalog test</text>
  }

  const setup = await testRender(
    () => <DialogProvider><Fixture /></DialogProvider>,
    { width: 32, height: 12, kittyKeyboard: true },
  )
  setups.push(setup)
  await setup.waitFor(() => setup.captureCharFrame().includes("explorer"))
  setup.mockInput.pressEnter()
  await setup.renderOnce()
  expect(setup.captureCharFrame()).toContain("Retry anthropic · 503")
  expect(setup.captureCharFrame()).toContain("GPT Test")

  setup.mockInput.pressEnter()
  await setup.renderOnce()
  expect(retried).toEqual([{ providerId: "anthropic", roleId: "explorer" }])
  expect(submitted).toBeUndefined()

  setup.mockInput.pressArrow("down")
  setup.mockInput.pressArrow("down")
  setup.mockInput.pressEnter()
  await setup.renderOnce()
  expect(setup.captureCharFrame()).toContain("Model: openai/gpt-test")
  expect(setup.captureCharFrame()).toContain("Keep the existing task")
})
