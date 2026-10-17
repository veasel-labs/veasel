/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { onMount } from "solid-js"
import { RGBA } from "@opentui/core"
import { testRender } from "@opentui/solid"
import { themes, type BuiltinThemeId } from "../themes"
import { SolidThemeProvider, useSolidThemeState } from "./theme"
import { SolidTranscript } from "./transcript"
import { SolidComposer } from "./composer"
import { DialogProvider, useDialog } from "./ui/dialog"
import { openDialogAlert } from "./ui/dialog-alert"

test("theme changes recolor mounted transcript, composer, and dialog without remounting", async () => {
  let setTheme!: (id: BuiltinThemeId) => void
  let showDialog!: () => void
  function Content() {
    const state = useSolidThemeState()
    const dialog = useDialog()
    onMount(() => {
      setTheme = state.setThemeId
      showDialog = () => openDialogAlert(dialog, { title: "Theme check", message: "Dialog sample" })
    })
    return (
      <box width="100%" height="100%" flexDirection="column">
        <SolidTranscript messages={[{ role: "user", content: "Distinct user content" }]} />
        <SolidComposer focused={true} />
      </box>
    )
  }
  const setup = await testRender(() => (
    <SolidThemeProvider initialTheme="mint">
      <DialogProvider><Content /></DialogProvider>
    </SolidThemeProvider>
  ), { width: 100, height: 35, kittyKeyboard: true })
  const textColor = (text: string) => {
    const span = setup.captureSpans().lines.flatMap((line) => line.spans)
      .find((span) => span.text.includes(text))
    expect(span).toBeDefined()
    return span!.fg
  }
  try {
    await setup.renderOnce()
    await setup.mockInput.typeText("Preserved draft")
    await setup.renderOnce()
    expect(textColor("Distinct user content").equals(RGBA.fromHex(themes.mint.userText))).toBe(true)
    setTheme("ember")
    await setup.renderOnce()
    expect(textColor("Distinct user content").equals(RGBA.fromHex(themes.ember.userText))).toBe(true)
    expect(textColor("Preserved draft").equals(RGBA.fromHex(themes.ember.inputText))).toBe(true)
    showDialog()
    await setup.renderOnce()
    expect(textColor("Dialog sample").equals(RGBA.fromHex(themes.ember.muted))).toBe(true)
    setTheme("mint")
    await setup.renderOnce()
    expect(textColor("Dialog sample").equals(RGBA.fromHex(themes.mint.muted))).toBe(true)
    setup.mockInput.pressEscape()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Preserved draft")
  } finally {
    setup.renderer.destroy()
  }
})

test("theme providers do not leak selection across application roots", async () => {
  let first!: ReturnType<typeof useSolidThemeState>
  let second!: ReturnType<typeof useSolidThemeState>
  function Probe(props: { receive: (state: ReturnType<typeof useSolidThemeState>) => void }) {
    props.receive(useSolidThemeState())
    return <text>Theme probe</text>
  }
  const setup = await testRender(() => (
    <box>
      <SolidThemeProvider initialTheme="mint"><Probe receive={(state) => { first = state }} /></SolidThemeProvider>
      <SolidThemeProvider initialTheme="ember"><Probe receive={(state) => { second = state }} /></SolidThemeProvider>
    </box>
  ), { width: 80, height: 24 })
  try {
    await setup.renderOnce()
    first.setThemeId("ember")
    second.setThemeId("mint")
    expect(first.colors.shellBg).toBe(themes.ember.shellBg)
    expect(second.colors.shellBg).toBe(themes.mint.shellBg)
  } finally {
    setup.renderer.destroy()
  }
})
