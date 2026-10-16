import { SyntaxStyle, type NativeResourceOwner, type StyleDefinitionInput } from "@opentui/core"
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

export function createMarkdownSyntaxStyle(theme: Theme, owner: NativeResourceOwner): SyntaxStyle {
  return SyntaxStyle.fromStyles(markdownSyntaxStyles(theme), owner)
}

// Stick-to-bottom can own the latest assistant body via MarkdownRenderable
// (live stream + completed history). Scrolled TextChunk windows keep markdown
// tones so Home/PgUp still page earlier lines inside one surface.
export function shouldUseMarkdownSurface(input: {
  followBottom: boolean
  noticeOpen?: boolean
  reviewSplitOpen?: boolean
  hasAssistantMarkdown?: boolean
}): boolean {
  const hasBody = input.hasAssistantMarkdown !== false
  return Boolean(input.followBottom && hasBody && !input.noticeOpen && !input.reviewSplitOpen)
}

/** @deprecated Prefer shouldUseMarkdownSurface; kept for stream-only call sites. */
export function shouldStreamMarkdownSurface(input: {
  streaming: boolean
  followBottom: boolean
  noticeOpen?: boolean
  reviewSplitOpen?: boolean
}): boolean {
  return shouldUseMarkdownSurface({
    followBottom: input.followBottom,
    noticeOpen: input.noticeOpen,
    reviewSplitOpen: input.reviewSplitOpen,
    hasAssistantMarkdown: input.streaming,
  })
}

export type LatestAssistantMarkdown = {
  content: string
  streaming: boolean
}

// Latest assistant body for the follow-mode Markdown panel. Live streams win
// over the last completed turn so deltas keep updating one renderable.
export function latestAssistantMarkdown(input: {
  messages: Array<{ role: string; content: string }>
  streaming?: boolean
  streamingText?: string
  streamingCursor?: string
}): LatestAssistantMarkdown | null {
  if (input.streaming || (input.streamingText !== undefined && input.streamingText.length > 0)) {
    const body = input.streamingText ?? ""
    const cursor = input.streaming ? (input.streamingCursor ?? "") : ""
    return {
      content: `${body}${cursor}`,
      streaming: Boolean(input.streaming),
    }
  }
  for (let index = input.messages.length - 1; index >= 0; index--) {
    const message = input.messages[index]!
    if (message.role === "assistant" && message.content.trim().length > 0) {
      return { content: message.content, streaming: false }
    }
  }
  return null
}
