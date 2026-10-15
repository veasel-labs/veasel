import { SyntaxStyle, type StyleDefinitionInput } from "@opentui/core"
import { diffSyntaxStyles } from "./diff-view"
import type { Theme } from "./themes"

// OpenTUI MarkdownRenderable markup.* tokens mapped onto Veasel theme colors.
// Fenced code highlighting reuses the DiffRenderable SyntaxStyle groups so
// `/theme` keeps prose and code fences consistent.
export function markdownSyntaxStyles(theme: Theme): Record<string, StyleDefinitionInput> {
  return {
    ...diffSyntaxStyles(theme),
    default: { fg: theme.assistantText },
    "markup.heading": { fg: theme.brand, bold: true },
    "markup.heading.1": { fg: theme.brand, bold: true },
    "markup.heading.2": { fg: theme.headerTitle, bold: true },
    "markup.heading.3": { fg: theme.headerTitle, bold: true },
    "markup.heading.4": { fg: theme.diffMeta, bold: true },
    "markup.heading.5": { fg: theme.diffMeta },
    "markup.heading.6": { fg: theme.meta },
    "markup.bold": { fg: theme.assistantText, bold: true },
    "markup.strong": { fg: theme.assistantText, bold: true },
    "markup.italic": { fg: theme.assistantText, italic: true },
    "markup.list": { fg: theme.diffMeta },
    "markup.quote": { fg: theme.meta, italic: true },
    "markup.raw": { fg: theme.diffAdd },
    "markup.raw.block": { fg: theme.diffAdd },
    "markup.raw.inline": { fg: theme.diffAdd },
    "markup.link": { fg: theme.diffMeta, underline: true },
    "markup.link.label": { fg: theme.diffMeta, underline: true },
    "markup.link.url": { fg: theme.meta, underline: true },
  }
}

export function createMarkdownSyntaxStyle(theme: Theme): SyntaxStyle {
  return SyntaxStyle.fromStyles(markdownSyntaxStyles(theme))
}

// Follow-mode live replies can use MarkdownRenderable streaming; once the
// operator scrolls the TextChunk transcript window, keep the stream inline so
// PgUp/Home still reveal earlier delta lines inside the same surface.
export function shouldStreamMarkdownSurface(input: {
  streaming: boolean
  followBottom: boolean
  noticeOpen?: boolean
  reviewSplitOpen?: boolean
}): boolean {
  return Boolean(input.streaming && input.followBottom && !input.noticeOpen && !input.reviewSplitOpen)
}
