/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { DialogProvider, useDialog } from "./dialog"
import { openDialogPrompt } from "./dialog-prompt"

test("prompt stays open when confirmation rejects an empty value", async () => {
  const submitted: string[] = []
  function Content() {
    const dialog = useDialog()
    onMount(() => openDialogPrompt(dialog, {
      title: "Model ID",
      onConfirm: (value) => {
        if (!value.trim()) return false
        submitted.push(value)
      },
    }))
    return <text>Background</text>
  }

  const setup = await testRender(() => <DialogProvider><Content /></DialogProvider>, {
    width: 80,
    height: 24,
    kittyKeyboard: true,
  })
  try {
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Model ID")
    expect(submitted).toEqual([])

    await setup.mockInput.typeText("kimi-k3")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("Model ID")
    expect(submitted).toEqual(["kimi-k3"])
  } finally {
    setup.renderer.destroy()
  }
})
