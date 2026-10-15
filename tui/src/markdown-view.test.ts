import { describe, expect, test } from "bun:test"
import {
  createMarkdownSyntaxStyle,
  markdownSyntaxStyles,
  shouldStreamMarkdownSurface,
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
    const syntax = createMarkdownSyntaxStyle(themes.mint)
    expect(syntax.getRegisteredNames()).toContain("markup.heading")
    expect(syntax.getRegisteredNames()).toContain("markup.raw")
    syntax.destroy()
  })

  test("uses MarkdownRenderable only while following the live stream", () => {
    expect(shouldStreamMarkdownSurface({
      streaming: true,
      followBottom: true,
    })).toBe(true)
    expect(shouldStreamMarkdownSurface({
      streaming: true,
      followBottom: false,
    })).toBe(false)
    expect(shouldStreamMarkdownSurface({
      streaming: false,
      followBottom: true,
    })).toBe(false)
    expect(shouldStreamMarkdownSurface({
      streaming: true,
      followBottom: true,
      noticeOpen: true,
    })).toBe(false)
    expect(shouldStreamMarkdownSurface({
      streaming: true,
      followBottom: true,
      reviewSplitOpen: true,
    })).toBe(false)
  })
})
