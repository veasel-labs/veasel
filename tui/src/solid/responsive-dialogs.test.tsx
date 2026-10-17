/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { onMount } from "solid-js"
import { testRender } from "@opentui/solid"
import { DialogProvider, useDialog } from "./ui/dialog"
import { openDialogSelect } from "./ui/dialog-select"
import { openCommandPalette } from "./component/command-palette"
import { dialogGeometry, dialogResultCount } from "./ui/dialog-layout"

for (const [width, height] of [[32, 12], [40, 16], [80, 24], [120, 40]]) {
  test(`model selector fits ${width}x${height} and keeps selection visible`, async () => {
    let selected = ""
    function Content() {
      const dialog = useDialog()
      onMount(() => openDialogSelect(dialog, {
        title: "Models",
        options: Array.from({ length: 30 }, (_, n) => ({
          title: `Model ${String(n).padStart(2, "0")}`, value: String(n),
          category: `Provider ${n}`, description: "Long explanatory model description",
        })),
        onSelect: (option) => { selected = option.value },
      }))
      return <text>Background</text>
    }
    const setup = await testRender(() => <DialogProvider><Content /></DialogProvider>,
      { width, height, kittyKeyboard: true })
    try {
      await setup.renderOnce()
      expect(setup.captureCharFrame()).toContain("Models")
      expect(setup.captureCharFrame()).toContain("30 matches")
      for (let n = 0; n < 22; n++) setup.mockInput.pressArrow("down")
      await setup.renderOnce()
      expect(setup.captureCharFrame()).toContain("Model 22")
      expect(setup.captureCharFrame()).toContain("30 matches")
      setup.resize(32, 12)
      await setup.renderOnce()
      expect(setup.captureCharFrame()).toContain("Model 22")
      expect(setup.captureCharFrame()).toContain("30 matches")
      setup.mockInput.pressEnter()
      await setup.renderOnce()
      expect(selected).toBe("22")
      expect(setup.captureCharFrame()).not.toContain("30 matches")
    } finally { setup.renderer.destroy() }
  })
}

for (const input of ["keyboard", "mouse"]) {
test(`small command palette remains searchable and executable with ${input}`, async () => {
  let called = false
  function Content() {
    const dialog = useDialog()
    onMount(() => openCommandPalette(dialog, [{
      id: "test", title: "Open model settings", group: "setup",
      description: "Configure providers", shortcut: "F2", run: () => { called = true },
    }]))
    return <text>Background</text>
  }
  const setup = await testRender(() => <DialogProvider><Content /></DialogProvider>,
    { width: 32, height: 12, kittyKeyboard: true })
  try {
    await setup.renderOnce()
    await setup.mockInput.typeText("model")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Open model settings")
    expect(setup.captureCharFrame()).toContain("1 match")
    if (input === "keyboard") {
      setup.mockInput.pressEnter()
    } else {
      const lines = setup.captureCharFrame().split("\n")
      const y = lines.findIndex((line) => line.includes("Open model settings"))
      const x = lines[y]!.indexOf("Open model settings")
      await setup.mockMouse.click(x, y)
    }
    await setup.renderOnce()
    expect(called).toBe(true)
  } finally { setup.renderer.destroy() }
})

}

test("dialog dimensions never exceed the terminal", () => {
  for (const columns of [1, 12, 32, 40, 80, 120]) {
    for (const rows of [1, 8, 12, 16, 24, 40]) {
      const geometry = dialogGeometry(columns, rows, 72)
      expect(geometry.width).toBeLessThanOrEqual(columns)
      expect(geometry.height).toBeLessThanOrEqual(rows)
      expect(dialogResultCount(columns, rows, 10, true)).toBeGreaterThanOrEqual(1)
    }
  }
})
