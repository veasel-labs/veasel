/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { SolidTranscript } from "./transcript"

for (const width of [32, 56, 100]) {
  test(`conversation preserves long message text at ${width} columns`, async () => {
    const setup = await testRender(() => (
      <SolidTranscript messages={[
        { role: "user", content: "Please review the current implementation carefully and explain each important change. USER-END" },
        { role: "assistant", content: "I will examine the implementation, follow the execution path, and explain any correctness concerns. ANSWER-END" },
      ]} cols={80} />
    ), { width, height: 36 })
    try {
      await setup.renderOnce()
      const frame = setup.captureCharFrame()
      expect(frame).toContain("● you")
      expect(frame).toContain("◆ assistant")
      expect(frame).toContain("USER-END")
      expect(frame).toContain("ANSWER-END")
      expect(frame).toContain("│")
      expect(frame.split("\n").map((line) => line.trimEnd()).join("\n").trimEnd()).toMatchSnapshot()
    } finally { setup.renderer.destroy() }
  })
}
