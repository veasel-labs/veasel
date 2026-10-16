/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { App } from "./app"
import { DialogProvider, useDialog } from "./ui/dialog"
import { DialogAlert } from "./ui/dialog-alert"
import { DialogConfirm } from "./ui/dialog-confirm"
import { DialogHelp } from "./ui/dialog-help"
import { DialogPrompt } from "./ui/dialog-prompt"
import { DialogSelect } from "./ui/dialog-select"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const demoSize = { width: 80, height: 30, kittyKeyboard: true } as const

describe("Solid dialog primitives", () => {
  test("DialogAlert renders title/message and Enter confirms", async () => {
    const ran: string[] = []
    function Fixture() {
      const dialog = useDialog()
      onMount(() => {
        dialog.replace(() => (
          <DialogAlert
            title="Alert"
            message="Something needs attention"
            onConfirm={() => ran.push("ok")}
          />
        ))
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Alert")
    expect(frame).toContain("Something needs attention")
    expect(frame).toContain("ok")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(ran).toEqual(["ok"])
    expect(setup.captureCharFrame()).not.toContain("Something needs attention")
  })

  test("DialogConfirm Enter confirms the focused action", async () => {
    const ran: string[] = []
    function Fixture() {
      const dialog = useDialog()
      onMount(() => {
        dialog.replace(() => (
          <DialogConfirm
            title="Confirm"
            message="Proceed with action?"
            onConfirm={() => ran.push("confirm")}
            onCancel={() => ran.push("cancel")}
          />
        ))
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("Proceed with action?")
    expect(setup.captureCharFrame()).toContain("Confirm")
    expect(setup.captureCharFrame()).toContain("Cancel")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(ran).toEqual(["confirm"])
  })

  test("DialogConfirm left arrow then Enter cancels", async () => {
    const ran: string[] = []
    function Fixture() {
      const dialog = useDialog()
      onMount(() => {
        dialog.replace(() => (
          <DialogConfirm
            title="Confirm"
            message="Discard changes?"
            onConfirm={() => ran.push("confirm")}
            onCancel={() => ran.push("cancel")}
          />
        ))
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    setup.mockInput.pressArrow("left")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(ran).toEqual(["cancel"])
  })

  test("DialogPrompt submits typed value", async () => {
    const values: string[] = []
    function Fixture() {
      const dialog = useDialog()
      onMount(() => {
        dialog.replace(() => (
          <DialogPrompt
            title="Rename"
            placeholder="Session name"
            value="draft"
            onConfirm={(value) => values.push(value)}
          />
        ))
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    expect(setup.captureCharFrame()).toContain("Rename")
    await setup.mockInput.typeText("-session")
    await setup.renderOnce()
    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(values).toEqual(["draft-session"])
  })

  test("DialogHelp shows quick help body", async () => {
    function Fixture() {
      const dialog = useDialog()
      onMount(() => {
        dialog.replace(() => <DialogHelp compact />)
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("Help")
    expect(frame).toContain("VEASEL CODE / QUICK HELP")
    expect(frame).toContain("Ctrl+P")
  })

  test("DialogSelect filters categories and selects with Enter", async () => {
    const picked: string[] = []
    function Fixture() {
      const dialog = useDialog()
      onMount(() => {
        dialog.replace(() => (
          <DialogSelect
            title="Themes"
            options={[
              { title: "Mint", value: "mint", category: "Builtin" },
              { title: "Ember", value: "ember", category: "Builtin" },
              { title: "Night", value: "night", category: "Custom" },
            ]}
            onSelect={(option) => picked.push(option.value)}
          />
        ))
      })
      return <box width="100%" height="100%" />
    }

    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      demoSize,
    )
    setups.push(setup)
    await setup.renderOnce()
    await setup.renderOnce()

    let frame = setup.captureCharFrame()
    expect(frame).toContain("Themes")
    expect(frame).toContain("Builtin")
    expect(frame).toContain("Mint")
    expect(frame).toContain("Custom")

    await setup.mockInput.typeText("emb")
    await setup.renderOnce()
    frame = setup.captureCharFrame()
    expect(frame).toContain("Ember")
    expect(frame).not.toContain("Night")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    expect(picked).toEqual(["ember"])
  })
})

describe("Solid App dialog smoke", () => {
  test("palette confirm demo confirms via App shell", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("confirm dialog")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Show confirm dialog")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    let frame = setup.captureCharFrame()
    expect(frame).toContain("Confirm")
    expect(frame).toContain("Apply this Solid shell action?")
    expect(frame).not.toContain("Filter commands")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    frame = setup.captureCharFrame()
    expect(frame).toContain("Confirmed")
    expect(frame).not.toContain("Apply this Solid shell action?")
  })

  test("palette theme list opens DialogSelect of builtins", async () => {
    const setup = await testRender(() => <App initialMessages={[]} initialReviews={[]} />, demoSize)
    setups.push(setup)
    await setup.renderOnce()

    setup.mockInput.pressKey("p", { ctrl: true })
    await setup.renderOnce()
    await setup.mockInput.typeText("theme list")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Theme list")

    setup.mockInput.pressEnter()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Themes")
    expect(frame).toContain("Builtin")
    expect(frame).toContain("mint")
    expect(frame).not.toContain("Filter commands")
  })
})
