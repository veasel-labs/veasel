/** @jsxImportSource @opentui/solid */
import { afterEach, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { SolidTranscript } from "./transcript"
import { SolidComposer } from "./composer"
const setups: Array<Awaited<ReturnType<typeof testRender>>> = []
afterEach(() => { for (const setup of setups.splice(0)) setup.renderer.destroy() })
async function mount(composer: boolean) {
  let scroll: ScrollBoxRenderable | undefined
  const setup = await testRender(() => (
    <box width="100%" height="100%" flexDirection="column">
      <SolidTranscript messages={[{ role: "assistant", content: Array.from({ length: 80 }, (_, i) => `line ${i}`).join("\n") }]} scrollRef={(value) => { scroll = value }} cols={60} />
      {composer && <SolidComposer focused={true} />}
    </box>
  ), { width: 72, height: 24 })
  setups.push(setup)
  await setup.renderOnce()
  return { ...setup, scroll: () => scroll! }
}
test("editor Home/End and autocomplete paging do not move the transcript", async () => {
  const setup = await mount(true)
  await setup.mockInput.typeText("a draft")
  await setup.renderOnce()
  const before = setup.scroll().scrollTop
  setup.mockInput.pressKey("HOME")
  await setup.renderOnce()
  expect(setup.scroll().scrollTop).toBe(before)
  expect(setup.renderer.currentFocusedEditor?.cursorOffset).toBe(0)
  setup.mockInput.pressKey("END")
  await setup.renderOnce()
  expect(setup.renderer.currentFocusedEditor?.cursorOffset).toBe(7)
  expect(setup.scroll().scrollTop).toBe(before)
  setup.renderer.currentFocusedEditor?.setText("/")
  await setup.renderOnce()
  const menuTop = setup.scroll().scrollTop
  setup.mockInput.pressKey("\x1b[5~")
  await setup.renderOnce()
  expect(setup.scroll().scrollTop).toBe(menuTop)
})
test("Page Up and Page Down move an unfocused transcript", async () => {
  const setup = await mount(false)
  const bottom = setup.scroll().scrollTop
  expect(bottom).toBeGreaterThan(0)
  setup.mockInput.pressKey("\x1b[5~")
  await setup.renderOnce()
  const above = setup.scroll().scrollTop
  expect(above).toBeLessThan(bottom)
  setup.mockInput.pressKey("\x1b[6~")
  await setup.renderOnce()
  expect(setup.scroll().scrollTop).toBeGreaterThan(above)
})
test("Ctrl+Home/End navigate without moving the editor cursor", async () => {
  const setup = await mount(true)
  await setup.mockInput.typeText("keep my cursor")
  await setup.renderOnce()
  const cursor = setup.renderer.currentFocusedEditor?.cursorOffset
  setup.mockInput.pressKey("HOME", { ctrl: true })
  await setup.renderOnce()
  expect(setup.scroll().scrollTop).toBe(0)
  expect(setup.renderer.currentFocusedEditor?.cursorOffset).toBe(cursor)
  setup.mockInput.pressKey("END", { ctrl: true })
  await setup.renderOnce()
  expect(setup.scroll().scrollTop).toBeGreaterThan(0)
  expect(setup.renderer.currentFocusedEditor?.cursorOffset).toBe(cursor)
})
