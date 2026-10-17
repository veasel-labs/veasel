/** @jsxImportSource @opentui/solid */
import { afterEach, describe, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { createSignal } from "solid-js"
import { SolidTranscript } from "./transcript"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) {
    setup.renderer.destroy()
  }
})

const size = { width: 72, height: 18 } as const

describe("SolidTranscript scroll-follow cues", () => {
  test("reports offsetFromBottom and shows the End-follows cue while streaming", async () => {
    const reports: number[] = []
    const longBody = Array.from({ length: 40 }, (_, index) => `line ${index + 1}`).join("\n")
    const [streaming] = createSignal(true)
    const setup = await testRender(
      () => (
        <box width="100%" height="100%" flexDirection="column">
          <SolidTranscript
            messages={[{ role: "assistant", content: longBody }]}
            streaming={streaming()}
            streamingText="delta"
            followTail={true}
            cols={60}
            onScrollViewport={({ offsetFromBottom }) => {
              reports.push(offsetFromBottom)
            }}
          />
        </box>
      ),
      size,
    )
    setups.push(setup)
    await setup.renderOnce()
    await Bun.sleep(250)
    await setup.renderOnce()

    setup.mockInput.pressKey("HOME")
    await Bun.sleep(50)
    await setup.renderOnce()
    await Bun.sleep(250)
    await setup.renderOnce()

    const frame = setup.captureCharFrame()
    expect(frame).toContain("streaming below")
    expect(frame).toContain("End follows")
    expect(reports.some((offset) => offset > 0)).toBe(true)

    setup.mockInput.pressKey("END")
    await Bun.sleep(50)
    await setup.renderOnce()
    await Bun.sleep(250)
    await setup.renderOnce()
    expect(reports.at(-1)).toBe(0)
  })
})
