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

describe("SolidComposer autocomplete UI", () => {
  test("shows slash menu for /he", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer focused={true} />
        </box>
      ),
      { width: 80, height: 16 },
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.mockInput.typeText("/he")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("/help")
    expect(frame).toContain("commands")
  })

  test("shows path menu for @ with stub paths", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer
            focused={true}
            workspaceRoot="/tmp/ws"
            listPaths={() => ["src/main.ts", "README.md"]}
          />
        </box>
      ),
      { width: 80, height: 16 },
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.mockInput.typeText("@src")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("@src/main.ts")
    expect(frame).toContain("paths")
  })

  test("Tab inserts the selected slash completion", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer focused={true} />
        </box>
      ),
      { width: 80, height: 16 },
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.mockInput.typeText("/he")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("/help")
    setup.mockInput.pressTab()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("/help")
    expect(frame).toMatch(/│ \/help\s/)
  })
})
