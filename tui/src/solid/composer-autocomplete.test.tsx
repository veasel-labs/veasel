/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { SolidComposer } from "./composer"
import { demoComposerSkills } from "./composer-autocomplete"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const size = { width: 80, height: 20 } as const

/** Lone ESC is ambiguous until the stdin parser timeout (~20ms) flushes. */
async function pressEscapeSettled(setup: Awaited<ReturnType<typeof testRender>>) {
  setup.mockInput.pressEscape()
  await Bun.sleep(30)
  await setup.renderOnce()
}

describe("SolidComposer autocomplete", () => {
  test("shows slash command suggestions for /", async () => {
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

    await setup.mockInput.typeText("/he")
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("commands")
    expect(frame).toContain("/help")
    expect(frame).toContain("Tab")
  })

  test("Tab accepts a slash suggestion without submitting", async () => {
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

    await setup.mockInput.typeText("/he")
    await setup.renderOnce()
    setup.mockInput.pressTab()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("/help")
    expect(submitted).toEqual([])
  })

  test("Enter sends when the autocomplete menu is closed", async () => {
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

    await setup.mockInput.typeText("hello solid")
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(submitted).toEqual(["hello solid"])
  })

  test("shows @ path suggestions from a fixture lister", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer
            focused={true}
            workspaceRoot="/tmp/ws"
            listPaths={() => ["src/main.ts", "src/composer.tsx"]}
          />
        </box>
      ),
      size,
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("@src/ma")
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("paths")
    expect(frame).toContain("@src/main.ts")
  })

  test("shows $ skill suggestions from the demo catalog", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer focused={true} skills={demoComposerSkills()} />
        </box>
      ),
      size,
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("$demo/code")
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("skills")
    expect(frame).toContain("$demo/code-review")
  })

  test("Esc dismisses the menu and keeps the draft", async () => {
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

    await setup.mockInput.typeText("/he")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("/help")

    await pressEscapeSettled(setup)

    const frame = setup.captureCharFrame()
    expect(frame).toContain("/he")
    expect(frame).not.toContain("▸ /help")
  })

  test("arrow keys move the selected suggestion", async () => {
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidComposer
            focused={true}
            listPaths={() => ["a.ts", "b.ts", "c.ts"]}
            workspaceRoot="/tmp/ws"
          />
        </box>
      ),
      size,
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("@")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("@a.ts")

    setup.mockInput.pressArrow("down")
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toMatch(/▸\s+@b\.ts/)
  })
})
