import { CodeRenderable, type BaseRenderable } from "@opentui/core"

type TestRenderer = {
  renderer: { root: BaseRenderable }
  renderOnce: () => Promise<void>
}

function markdownCodeBlocks(root: BaseRenderable): CodeRenderable[] {
  const blocks: CodeRenderable[] = []
  const pending = [root]
  while (pending.length > 0) {
    const node = pending.pop()!
    if (node instanceof CodeRenderable && node.filetype === "markdown") blocks.push(node)
    pending.push(...node.getChildren())
  }
  return blocks
}

/** Wait for OpenTUI's asynchronous Markdown syntax pass before capturing a frame. */
export async function renderMarkdownFrame(setup: TestRenderer): Promise<void> {
  await setup.renderOnce()
  for (let pass = 0; pass < 8; pass++) {
    const blocks = markdownCodeBlocks(setup.renderer.root)
    if (blocks.length === 0) break
    await Promise.all(blocks.map((block) => block.highlightingDone))
    await setup.renderOnce()
    if (blocks.every((block) => !block.isHighlighting)) return
  }
}
