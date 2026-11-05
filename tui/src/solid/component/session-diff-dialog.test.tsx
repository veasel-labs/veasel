/** @jsxImportSource @opentui/solid */
import { afterEach, expect, spyOn, test } from "bun:test"
import { CodeRenderable, RGBA, SyntaxStyle, type BaseRenderable } from "@opentui/core"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { themes } from "../../themes"
import { DialogProvider, useDialog } from "../ui/dialog"
import { openSessionDiffDialog } from "./session-diff-dialog"

const setups: Array<Awaited<ReturnType<typeof testRender>>> = []

afterEach(() => {
  for (const setup of setups.splice(0)) setup.renderer.destroy()
})

const DIFF = [
  "--- a/src/app.ts",
  "+++ b/src/app.ts",
  "@@ -1 +1 @@",
  "-const answer = 41",
  "+const answer = 42",
].join("\n")

test("session diff highlights filetype syntax with the themed diff style", async () => {
  // The review panel supplies createDiffSyntaxStyle to its <diff>; the
  // session-diff dialog omitted syntaxStyle entirely, so OpenTUI fell back
  // to an empty default style and rendered split diffs without any
  // filetype coloring.
  const created: SyntaxStyle[] = []
  const originalFromStyles = SyntaxStyle.fromStyles.bind(SyntaxStyle)
  const fromStylesSpy = spyOn(SyntaxStyle, "fromStyles").mockImplementation((styles, owner) => {
    const style = originalFromStyles(styles, owner)
    created.push(style)
    return style
  })
  try {
    function Fixture() {
      const dialog = useDialog()
      onMount(() =>
        openSessionDiffDialog(dialog, {
          edits: [{ id: "e1", path: "src/app.ts", status: "applied" }],
          loadDiff: async () => ({ id: "e1", path: "src/app.ts", status: "applied", diff: DIFF }),
        }),
      )
      return <box width="100%" height="100%" />
    }
    const setup = await testRender(
      () => (
        <DialogProvider>
          <Fixture />
        </DialogProvider>
      ),
      { width: 120, height: 40, kittyKeyboard: true },
    )
    setups.push(setup)
    await setup.waitFor(() => setup.captureCharFrame().includes("Session diffs"))
    setup.mockInput.pressEnter()
    await setup.waitFor(() => setup.captureCharFrame().includes("const answer = 42"))
    expect(created.length).toBeGreaterThanOrEqual(1)
    // Wait for the DiffRenderable's async Tree-sitter passes to settle.
    const codeBlocks: CodeRenderable[] = []
    const pending: BaseRenderable[] = [setup.renderer.root]
    while (pending.length > 0) {
      const node = pending.pop()!
      if (node instanceof CodeRenderable) codeBlocks.push(node)
      pending.push(...node.getChildren())
    }
    expect(codeBlocks.length).toBeGreaterThanOrEqual(1)
    await Promise.all(codeBlocks.map((block) => block.highlightingDone))
    await setup.renderOnce()
    // The keyword token must carry the themed keyword color, proving the
    // themed style reached the DiffRenderable's code blocks.
    const keyword = RGBA.fromHex(themes.mint.brand)
    await setup.waitFor(() =>
      setup
        .captureSpans()
        .lines.flatMap((line) => line.spans)
        .some((span) => span.text.includes("const") && span.fg.equals(keyword)),
    )
  } finally {
    fromStylesSpy.mockRestore()
  }
})
