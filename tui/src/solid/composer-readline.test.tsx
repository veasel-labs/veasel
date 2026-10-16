/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { SolidComposer } from "./composer"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const size = { width: 80, height: 16 } as const

describe("SolidComposer readline", () => {
  test("↑ recalls the last submitted prompt when the draft is empty", async () => {
    const submitted: string[] = []
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer
            focused={true}
            onSubmit={(text) => {
              submitted.push(text)
            }}
          />
        </box>
      ),
      size,
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("recall me later")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(submitted).toEqual(["recall me later"])

    // Empty draft after submit — ↑ should restore history.
    setup.mockInput.pressArrow("up")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("recall me later")
  })

  test("↑ does not steal autocomplete navigation while the menu is open", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer focused={true} />
        </box>
      ),
      size,
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("/")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("commands")

    setup.mockInput.pressArrow("down")
    await setup.renderOnce()
    // Still showing the slash menu (not history recall).
    expect(setup.captureCharFrame()).toContain("commands")
  })
})
