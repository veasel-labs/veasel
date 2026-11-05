/** @jsxImportSource @opentui/solid */
import { expect, spyOn, test } from "bun:test"
import { onMount } from "solid-js"
import { SyntaxStyle } from "@opentui/core"
import { testRender } from "@opentui/solid"
import type { BuiltinThemeId } from "../themes"
import { SolidThemeProvider, useSolidThemeState } from "./theme"
import { SolidTranscript } from "./transcript"
import { renderMarkdownFrame } from "./markdown-test-helpers"

function isDestroyed(style: SyntaxStyle): boolean {
  try {
    style.getStyleCount()
    return false
  } catch (error) {
    return /destroyed/i.test(String(error))
  }
}

test("theme changes destroy superseded markdown syntax styles without a highlighter fallback", async () => {
  // Regression for #554: AssistantMarkdown recreated its native SyntaxStyle
  // on every theme change but only destroyed the latest one on unmount, so
  // each /theme switch leaked a native style per rendered assistant message.
  const warnings: string[] = []
  const capture = (...args: unknown[]) => {
    warnings.push(args.map(String).join(" "))
  }
  const warnSpy = spyOn(console, "warn").mockImplementation(capture)
  const errorSpy = spyOn(console, "error").mockImplementation(capture)
  const created: SyntaxStyle[] = []
  const originalFromStyles = SyntaxStyle.fromStyles.bind(SyntaxStyle)
  const fromStylesSpy = spyOn(SyntaxStyle, "fromStyles").mockImplementation((styles, owner) => {
    const style = originalFromStyles(styles, owner)
    created.push(style)
    return style
  })
  let setTheme!: (id: BuiltinThemeId) => void
  function Content() {
    const state = useSolidThemeState()
    onMount(() => {
      setTheme = state.setThemeId
    })
    return (
      <SolidTranscript
        messages={[{ role: "assistant", content: "```ts\nconst answer: number = 42\n```" }]}
        followTail={true}
      />
    )
  }
  let setup: Awaited<ReturnType<typeof testRender>> | undefined
  try {
    setup = await testRender(
      () => (
        <SolidThemeProvider initialTheme="mint">
          <Content />
        </SolidThemeProvider>
      ),
      { width: 80, height: 30 },
    )
    await renderMarkdownFrame(setup)
    await setup.waitFor(() => setup!.captureCharFrame().includes("const answer"))
    expect(created.length).toBeGreaterThanOrEqual(1)
    const firstGeneration = [...created]

    setTheme("ember")
    await setup.renderOnce()
    await renderMarkdownFrame(setup)
    await setup.waitFor(() => setup!.captureCharFrame().includes("const answer"))
    expect(created.length).toBeGreaterThan(firstGeneration.length)
    for (const style of firstGeneration) {
      expect(isDestroyed(style)).toBe(true)
    }
    const secondGeneration = created.slice(firstGeneration.length)
    expect(secondGeneration.some((style) => !isDestroyed(style))).toBe(true)

    setTheme("slate")
    await setup.renderOnce()
    await renderMarkdownFrame(setup)
    await setup.waitFor(() => setup!.captureCharFrame().includes("const answer"))
    for (const style of secondGeneration) {
      expect(isDestroyed(style)).toBe(true)
    }

    expect(
      warnings.filter((line) => /Code highlighting failed|syntaxStyle\.getStyle|NativeSyntaxStyle is destroyed/i.test(line)),
    ).toEqual([])
  } finally {
    setup?.renderer.destroy()
    warnSpy.mockRestore()
    errorSpy.mockRestore()
    fromStylesSpy.mockRestore()
  }
})
