/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { DialogProvider, useDialog } from "./ui/dialog"
import { openDialogPrompt } from "./ui/dialog-prompt"
import { deleteSecret, replaceSecretSelection, secretInputLimit } from "./ui/secret-editor"

for (const kittyKeyboard of [false, true]) {
  test(`credential input masks typing/paste and submits edited value (${kittyKeyboard ? "kitty" : "legacy"})`, async () => {
    const submitted: string[] = []
    function Harness() {
      const dialog = useDialog()
      onMount(() => openDialogPrompt(dialog, { title: "API key", secret: true, onConfirm: (value) => submitted.push(value) }))
      return <text>Workspace</text>
    }
    const setup = await testRender(() => <DialogProvider><Harness /></DialogProvider>, { width: 80, height: 26, kittyKeyboard })
    try {
      await setup.renderOnce()
      await setup.mockInput.typeText("sk-Dummy_123")
      await setup.renderOnce()
      expect(setup.captureCharFrame()).not.toContain("sk-Dummy")
      expect(setup.captureCharFrame()).toContain("•••")
      expect(setup.renderer.currentFocusedEditor).toBeNull()
      setup.mockInput.pressArrow("left")
      setup.mockInput.pressBackspace()
      await setup.mockInput.typeText("X")
      setup.mockInput.pressKey("END")
      await setup.mockInput.pasteBracketedText("-paste-FAKE")
      await setup.renderOnce()
      expect(setup.captureCharFrame()).not.toContain("paste-FAKE")
      setup.mockInput.pressEnter()
      await setup.renderOnce()
      expect(submitted).toEqual(["sk-Dummy_1X3-paste-FAKE"])
    } finally { setup.renderer.destroy() }
  })
}

test("credential selection replacement and Unicode deletion preserve character boundaries", () => {
  expect(deleteSecret({ value: "A😀Z", cursor: 2, anchor: 2 }, true)).toEqual({ value: "AZ", cursor: 1, anchor: 1 })
  expect(replaceSecretSelection({ value: "old-key", cursor: 7, anchor: 0 }, "new-key\n")).toEqual({ value: "new-key", cursor: 7, anchor: 7 })
  expect(() => replaceSecretSelection({ value: "", cursor: 0, anchor: 0 }, "x".repeat(secretInputLimit + 1))).toThrow("input was not changed")
})

test("credential Ctrl+A replacement and Ctrl+U clearing never reveal the text", async () => {
  let submitted: string | undefined
  function Harness() {
    const dialog = useDialog()
    onMount(() => openDialogPrompt(dialog, { title: "Credential", secret: true, value: "existing-dummy", onConfirm: (value) => { submitted = value } }))
    return <text>Workspace</text>
  }
  const setup = await testRender(() => <DialogProvider><Harness /></DialogProvider>, { width: 40, height: 20, kittyKeyboard: true })
  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("existing-dummy")
    setup.mockInput.pressKey("a", { ctrl: true })
    await setup.mockInput.pasteBracketedText("replacement-dummy")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain("replacement-dummy")
    setup.mockInput.pressKey("u", { ctrl: true })
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(submitted).toBe("")
  } finally { setup.renderer.destroy() }
})
