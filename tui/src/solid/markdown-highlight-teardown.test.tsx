/** @jsxImportSource @opentui/solid */
import { expect, spyOn, test } from "bun:test"
import { createSignal } from "solid-js"
import { SyntaxStyle } from "@opentui/core"
import { testRender } from "@opentui/solid"
import { SolidThemeProvider } from "./theme"
import { SolidTranscript, type ToolAwareMessage } from "./transcript"
import { renderMarkdownFrame } from "./markdown-test-helpers"

const CODE_MESSAGE = "```ts\nconst answer: number = 42\n```"

function isDestroyed(style: SyntaxStyle): boolean {
  try {
    style.getStyleCount()
    return false
  } catch (error) {
    return /destroyed/i.test(String(error))
  }
}

function captureSyntaxStyles() {
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
  return {
    created,
    destroyedWarnings: () =>
      warnings.filter((line) =>
        /Code highlighting failed|syntaxStyle\.getStyle|NativeSyntaxStyle is destroyed/i.test(line),
      ),
    restore() {
      warnSpy.mockRestore()
      errorSpy.mockRestore()
      fromStylesSpy.mockRestore()
    },
  }
}

test("fenced code renders with distinct syntax span colors", async () => {
  // #554 acceptance: highlighting must be visible, not silently plain.
  const setup = await testRender(
    () => (
      <SolidThemeProvider initialTheme="mint">
        <SolidTranscript
          messages={[{ role: "assistant", content: CODE_MESSAGE }]}
          followTail={true}
        />
      </SolidThemeProvider>
    ),
    { width: 80, height: 30 },
  )
  try {
    await renderMarkdownFrame(setup)
    await setup.waitFor(() => setup.captureCharFrame().includes("const answer"))
    const frame = setup.captureSpans()
    const codeLine = frame.lines.find((line) =>
      line.spans.some((span) => span.text.includes("const")),
    )
    expect(codeLine).toBeDefined()
    const distinctFg = new Set(
      codeLine!.spans
        .filter((span) => span.text.trim().length > 0)
        .map((span) => span.fg.toInts().join(",")),
    )
    // Keyword, identifier, type, and number must not collapse to one color.
    expect(distinctFg.size).toBeGreaterThanOrEqual(2)
  } finally {
    setup.renderer.destroy()
  }
})

test("renderer teardown during pending highlight destroys styles without warnings", async () => {
  const spy = captureSyntaxStyles()
  let setup: Awaited<ReturnType<typeof testRender>> | undefined
  try {
    setup = await testRender(
      () => (
        <SolidThemeProvider initialTheme="mint">
          <SolidTranscript
            messages={[{ role: "assistant", content: CODE_MESSAGE }]}
            followTail={true}
          />
        </SolidThemeProvider>
      ),
      { width: 80, height: 30 },
    )
    // One frame only: teardown lands while the async Tree-sitter highlight
    // may still be in flight, which is exactly the dialog-close / quit path.
    await setup.renderOnce()
    expect(spy.created.length).toBeGreaterThanOrEqual(1)
    setup.renderer.destroy()
    setup = undefined
    await Bun.sleep(20)
    for (const style of spy.created) {
      expect(isDestroyed(style)).toBe(true)
    }
    expect(spy.destroyedWarnings()).toEqual([])
  } finally {
    setup?.renderer.destroy()
    spy.restore()
  }
})

test("switching transcript content during pending highlight settles on the new content", async () => {
  const spy = captureSyntaxStyles()
  let setMessages!: (messages: ToolAwareMessage[]) => void
  function Content() {
    const [messages, set] = createSignal<ToolAwareMessage[]>([
      { role: "assistant", content: CODE_MESSAGE },
    ])
    setMessages = set
    return <SolidTranscript messages={messages} followTail={true} />
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
    await setup.renderOnce()
    // Session switch before the first highlight settles.
    setMessages([{ role: "assistant", content: "Plain reply after switch" }])
    await renderMarkdownFrame(setup)
    await setup.waitFor(() => setup!.captureCharFrame().includes("Plain reply after switch"))
    expect(setup.captureCharFrame()).not.toContain("const answer")
    expect(spy.destroyedWarnings()).toEqual([])
    // The switched-away message's styles must not outlive it.
    await Bun.sleep(20)
    await renderMarkdownFrame(setup)
    expect(spy.destroyedWarnings()).toEqual([])
  } finally {
    setup?.renderer.destroy()
    spy.restore()
  }
})
