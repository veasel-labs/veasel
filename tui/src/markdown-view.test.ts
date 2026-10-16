import { describe, expect, test } from "bun:test"
import { ResourceContext } from "@opentui/core"
import {
  createMarkdownSyntaxStyle,
  latestAssistantMarkdown,
  markdownSyntaxStyles,
  shouldStreamMarkdownSurface,
  shouldUseMarkdownSurface,
} from "./markdown-view"
import { themes } from "./themes"

describe("markdown stream surface", () => {
  test("maps theme tones onto Markdown markup.* tokens", () => {
    const styles = markdownSyntaxStyles(themes.mint)
    expect(styles.default?.fg).toBe(themes.mint.assistantText)
    expect(styles["markup.heading"]?.fg).toBe(themes.mint.brand)
    expect(styles["markup.list"]?.fg).toBe(themes.mint.diffMeta)
    expect(styles["markup.raw.inline"]?.fg).toBe(themes.mint.diffAdd)
    expect(styles["markup.link"]?.fg).toBe(themes.mint.diffMeta)
    expect(styles.keyword?.fg).toBe(themes.mint.brand)
    const owner = new ResourceContext({ objectCapacity: 64, renderCellsMax: 256 })
    const syntax = createMarkdownSyntaxStyle(themes.mint, owner)
    expect(syntax.getRegisteredNames()).toContain("markup.heading")
    expect(syntax.getRegisteredNames()).toContain("markup.raw")
    syntax.destroy()
    owner.destroy()
  })

  test("uses MarkdownRenderable while following live or completed assistant bodies", () => {
    expect(shouldUseMarkdownSurface({
      followBottom: true,
      hasAssistantMarkdown: true,
    })).toBe(true)
    expect(shouldUseMarkdownSurface({
      followBottom: false,
      hasAssistantMarkdown: true,
    })).toBe(false)
    expect(shouldUseMarkdownSurface({
      followBottom: true,
      hasAssistantMarkdown: false,
    })).toBe(false)
    expect(shouldUseMarkdownSurface({
      followBottom: true,
      hasAssistantMarkdown: true,
      noticeOpen: true,
    })).toBe(false)
    expect(shouldUseMarkdownSurface({
      followBottom: true,
      hasAssistantMarkdown: true,
      reviewSplitOpen: true,
    })).toBe(false)
  })

  test("keeps stream-only helper gated on an in-flight turn", () => {
    expect(shouldStreamMarkdownSurface({
      streaming: true,
      followBottom: true,
    })).toBe(true)
    expect(shouldStreamMarkdownSurface({
      streaming: false,
      followBottom: true,
    })).toBe(false)
  })

  test("prefers the live stream over a prior completed assistant turn", () => {
    expect(latestAssistantMarkdown({
      messages: [
        { role: "user", content: "hi" },
        { role: "assistant", content: "# Done" },
      ],
      streaming: true,
      streamingText: "## Live",
      streamingCursor: "█",
    })).toEqual({ content: "## Live█", streaming: true })
  })

  test("finalizes the latest completed assistant when idle", () => {
    expect(latestAssistantMarkdown({
      messages: [
        { role: "user", content: "hi" },
        { role: "assistant", content: "first" },
        { role: "user", content: "again" },
        { role: "assistant", content: "# Shipped\n\nok" },
      ],
    })).toEqual({ content: "# Shipped\n\nok", streaming: false })
  })

  test("returns null when there is no assistant body to render", () => {
    expect(latestAssistantMarkdown({
      messages: [{ role: "user", content: "only me" }],
    })).toBeNull()
    expect(latestAssistantMarkdown({
      messages: [],
      streaming: true,
      streamingText: "",
      streamingCursor: "█",
    })).toEqual({ content: "█", streaming: true })
  })
})
