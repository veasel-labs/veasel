/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { App } from "./app"
import { ToastProvider, useToast } from "./ui/toast"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Solid toast overlay", () => {
  test("show renders mint toast chrome with title and message", async () => {
    function Fixture() {
      const toast = useToast()
      onMount(() => {
        toast.show({
          variant: "success",
          title: "Saved",
          message: "Model profile stored locally",
          duration: 60_000,
        })
      })
      return (
        <box width="100%" height="100%">
          <text>fixture</text>
        </box>
      )
    }

    const setup = await testRender(
      () => (
        <ToastProvider>
          <Fixture />
        </ToastProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Saved")
    expect(frame).toContain("Model profile stored locally")
    expect(frame).toContain("dismiss")
  })

  test("queued toasts report pending count", async () => {
    function Fixture() {
      const toast = useToast()
      onMount(() => {
        toast.show({ variant: "info", message: "First notice", duration: 60_000 })
        toast.pause()
        toast.show({ variant: "warning", message: "Second notice", duration: 60_000 })
        toast.show({ variant: "error", message: "Third notice", duration: 60_000 })
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <ToastProvider>
          <Fixture />
        </ToastProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("First notice")
    expect(frame).toContain("+2 more")
  })

  test("palette toast demo surfaces a notice from App", async () => {
    const setup = await testRender(
      () => <App initialMessages={[]} initialReviews={[]} />,
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("demo toast")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Show demo toast")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Toast")
    expect(frame).toMatch(/Solid|mint|notice/i)
  })
})
