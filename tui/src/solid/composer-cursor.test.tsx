/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { SolidComposer } from "./composer"

for (const entry of [
  { token: "@alpha", suggestion: "alpha.v", completion: "@alpha.v" },
  { token: "$kit/re", suggestion: "$kit/review", completion: "$kit/review" },
]) {
test(`cursor-only movement enters and leaves ${entry.token} completion without changing the draft`, async () => {
  const draft = `look ${entry.token} end`
  const setup = await testRender(() => <SolidComposer
    focused={true}
    restoreToken={{ id: "draft", text: draft }}
    workspaceRoot="/workspace"
    listPaths={() => ["alpha.v", "beta.v"]}
    skills={[{ key: "kit/review", description: "Review this workspace" }]}
  />, { width: 90, height: 22 })
  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).not.toContain(entry.suggestion)
    for (let n = 0; n < 4; n++) setup.mockInput.pressArrow("left")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain(entry.suggestion)
    expect(setup.renderer.currentFocusedEditor?.plainText).toBe(draft)
    for (let n = 0; n < entry.token.length; n++) setup.mockInput.pressArrow("left")
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.cursorOffset).toBe(5)
    expect(setup.captureCharFrame()).not.toContain(entry.suggestion)
    setup.mockInput.pressArrow("right")
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain(entry.suggestion)
    setup.mockInput.pressTab()
    await setup.renderOnce()
    expect(setup.renderer.currentFocusedEditor?.plainText).toContain(entry.completion)
    expect(setup.renderer.currentFocusedEditor?.plainText).toEndWith(" end")
  } finally { setup.renderer.destroy() }
})

}
