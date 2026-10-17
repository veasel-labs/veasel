/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { SolidTranscript } from "./transcript"
import { assistantLabel, userLabel } from "../transcript"

test("assistant messages render markdown structure without raw markup", async () => {
  const setup = await testRender(
    () => (
      <SolidTranscript
        messages={[
          { role: "user", content: "show **raw** please" },
          {
            role: "assistant",
            content: "# Plan\n\nUse **bold steps** first.\n\n- item one\n- item two\n\n```ts\nconst answer = 42\n```",
          },
        ]}
        followTail={true}
      />
    ),
    { width: 80, height: 40 },
  )
  try {
    await setup.renderOnce()
    // Markdown blocks parse incrementally; wait until the list has rendered.
    await setup.waitFor(() => setup.captureCharFrame().includes("bold steps"))
    // Code fences highlight through tree-sitter asynchronously.
    for (let attempt = 0; attempt < 40 && !setup.captureCharFrame().includes("const answer = 42"); attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 50))
      await setup.renderOnce()
    }
    const frame = setup.captureCharFrame()
    expect(frame).toContain(userLabel)
    expect(frame).toContain("show **raw** please")
    expect(frame).toContain(assistantLabel)
    expect(frame).toContain("Plan")
    expect(frame).toContain("bold steps")
    expect(frame).toContain("item one")
    expect(frame).toContain("const answer = 42")
    expect(frame).not.toContain("# Plan")
    expect(frame).not.toContain("**bold steps**")
    expect(frame).not.toContain("```")
  } finally {
    setup.renderer.destroy()
  }
})

test("streaming assistant text renders as markdown while it grows", async () => {
  const setup = await testRender(
    () => (
      <SolidTranscript
        messages={[{ role: "user", content: "go" }]}
        streaming={true}
        streamingText={"Working **now**\n\n- step one"}
        followTail={true}
      />
    ),
    { width: 80, height: 40 },
  )
  try {
    await setup.renderOnce()
    await setup.waitFor(() => setup.captureCharFrame().includes("step one"))
    const frame = setup.captureCharFrame()
    expect(frame).toContain("Working")
    expect(frame).toContain("step one")
    expect(frame).not.toContain("**now**")
  } finally {
    setup.renderer.destroy()
  }
})
