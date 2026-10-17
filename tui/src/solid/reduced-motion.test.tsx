/** @jsxImportSource @opentui/solid */
import { afterEach, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { SolidTranscript } from "./transcript"

const original = process.env.VEASEL_TUI_REDUCED_MOTION
afterEach(() => {
  if (original === undefined) delete process.env.VEASEL_TUI_REDUCED_MOTION
  else process.env.VEASEL_TUI_REDUCED_MOTION = original
})

test("reduced motion uses the static streaming cursor", async () => {
  process.env.VEASEL_TUI_REDUCED_MOTION = "1"
  const setup = await testRender(
    () => (
      <SolidTranscript
        messages={[{ role: "user", content: "go" }]}
        streaming={true}
        streamingText="partial reply"
        followTail={true}
      />
    ),
    { width: 80, height: 24 },
  )
  try {
    await setup.renderOnce()
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    expect(frame).toContain("partial reply·")
    expect(frame).not.toContain("█")
  } finally {
    setup.renderer.destroy()
  }
})

test("motion allowed keeps the block streaming cursor", async () => {
  process.env.VEASEL_TUI_REDUCED_MOTION = "0"
  const setup = await testRender(
    () => (
      <SolidTranscript
        messages={[{ role: "user", content: "go" }]}
        streaming={true}
        streamingText="partial reply"
        followTail={true}
      />
    ),
    { width: 80, height: 24 },
  )
  try {
    await setup.renderOnce()
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("partial reply█")
  } finally {
    setup.renderer.destroy()
  }
})
