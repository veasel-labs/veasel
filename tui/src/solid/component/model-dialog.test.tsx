/** @jsxImportSource @opentui/solid */
import { afterEach, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { DialogProvider, useDialog } from "../ui/dialog"
import { openModelDialog } from "./model-dialog"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) setup.renderer.destroy()
})

test("empty provider catalog still offers manual model entry", async () => {
  let manualEntries = 0

  function Fixture() {
    const dialog = useDialog()
    onMount(() =>
      openModelDialog(dialog, {
        models: [],
        onSelect: () => {},
        onManual: () => manualEntries++,
      }),
    )
    return <box width="100%" height="100%" />
  }

  const setup = await testRender(
    () => (
      <DialogProvider>
        <Fixture />
      </DialogProvider>
    ),
    { width: 120, height: 36, kittyKeyboard: true },
  )
  setups.push(setup)
  await setup.renderOnce()
  await setup.renderOnce()

  expect(setup.captureCharFrame()).toContain("Use a model ID manually")
  setup.mockInput.pressEnter()
  await setup.renderOnce()
  expect(manualEntries).toBe(1)
})
