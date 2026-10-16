/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "./app"
import { SolidComposer } from "./composer"
import { userLabel } from "../transcript"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30 } as const

describe("Solid shell P0", () => {
  test("mounts Veasel identity chrome at demo size", async () => {
    const setup = await testRender(
      () => <App status="LOCAL · Solid shell" initialReviews={[]} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL")
    expect(frame).toContain("CODE")
    expect(frame).toContain("LOCAL")
    expect(frame).toContain("SESSION")
    expect(frame).toContain("Compose")
    expect(frame).toContain(userLabel)
    expect(frame.split("\n").length).toBeGreaterThanOrEqual(10)
  })

  test("composer accepts text and submits", async () => {
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
      { width: 80, height: 10 },
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("hello solid")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("hello solid")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(submitted).toEqual(["hello solid"])
  })

  test("app transcript records a submitted turn", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} sessionTitle="submit-demo" />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    await setup.mockInput.typeText("ship transcript")
    setup.mockInput.pressEnter()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("VEASEL")
    expect(frame).toContain(userLabel)
    expect(frame).toContain("ship transcript")
  })
})
