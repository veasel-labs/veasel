import { describe, expect, test } from "bun:test"
import {
  assistantLabel,
  messageBodySegments,
  noticeSegments,
  streamingCursor,
  systemLabel,
  toolLabel,
  transcriptPlainText,
  transcriptSegments,
  userLabel,
} from "./transcript"

const session = { title: "fix tests", directory: "/work/app" }

describe("transcriptSegments", () => {
  test("labels each turn with its role and tones the body to match", () => {
    const segments = transcriptSegments({
      session,
      messages: [
        { role: "user", content: "Why does CI fail?" },
        { role: "assistant", content: "The Windows job times out." },
      ],
    })
    expect(segments).toContainEqual({ text: userLabel, tone: "userLabel" })
    expect(segments).toContainEqual({ text: "\nWhy does CI fail?", tone: "userText" })
    expect(segments).toContainEqual({ text: assistantLabel, tone: "assistantLabel" })
    expect(segments).toContainEqual({ text: "\nThe Windows job times out.", tone: "assistantText" })
    expect(transcriptPlainText(segments)).toBe(
      "fix tests\n/work/app\n\n● YOU\nWhy does CI fail?\n\n◆ VEASEL\nThe Windows job times out.",
    )
  })

  test("marks in-flight turns with a status and a streaming cursor", () => {
    const text = transcriptPlainText(transcriptSegments({
      messages: [],
      pendingUserMessage: "add a test",
      streamingText: "Reading",
      streaming: true,
    }))
    expect(text).toBe(`● YOU  ·  sending\nadd a test\n\n◆ VEASEL  ·  streaming…\nReading${streamingCursor}`)
  })

  test("shows a cursor while streaming before the first token arrives", () => {
    const text = transcriptPlainText(transcriptSegments({
      messages: [],
      streamingText: "",
      streaming: true,
    }))
    expect(text).toBe(`◆ VEASEL  ·  streaming…\n${streamingCursor}`)
  })

  test("labels an interrupted response as partial without a cursor", () => {
    const segments = transcriptSegments({ messages: [], streamingText: "half", streaming: false })
    expect(segments).toContainEqual({ text: "  ·  partial response", tone: "status" })
    expect(transcriptPlainText(segments)).toBe("◆ VEASEL  ·  partial response\nhalf")
  })

  test("shows the empty-state hint and the older-history hint", () => {
    expect(transcriptPlainText(transcriptSegments({ session, messages: [] }))).toContain(
      "Start with a question or describe a coding task.",
    )
    expect(transcriptPlainText(transcriptSegments({ messages: [{ role: "user", content: "hi" }], hasOlder: true }))).toEndWith(
      "/history older · load earlier messages",
    )
  })

  test("tones unified diff lines without dropping their markers", () => {
    const diff = "REVIEW\nsrc/main.v\n@@ -1 +1 @@\n context\n-old\n+new\n--- a/src/main.v\n+++ b/src/main.v"
    const segments = noticeSegments(diff)
    expect(transcriptPlainText(segments)).toBe(`${diff}\n\n`)
    expect(segments).toContainEqual({ text: "-", tone: "diffRemove" })
    expect(segments).toContainEqual({ text: "old", tone: "diffRemove" })
    expect(segments).toContainEqual({ text: "+", tone: "diffAdd" })
    expect(segments).toContainEqual({ text: "new", tone: "diffAdd" })
    expect(segments).toContainEqual({ text: "@@ -1 +1 @@\n", tone: "diffMeta" })
    expect(segments).toContainEqual({ text: "--- a/src/main.v\n", tone: "diffMeta" })
    expect(segments).toContainEqual({ text: "+++ b/src/main.v\n\n", tone: "diffMeta" })
    expect(noticeSegments("No workspace edit proposals.")).toEqual([
      { text: "No workspace edit proposals.\n\n", tone: "notice" },
    ])
  })

  test("renders notices and can hide messages behind the help guide", () => {
    const segments = transcriptSegments({ notice: "VEASEL CODE / QUICK HELP", messages: [{ role: "user", content: "hi" }], showMessages: false })
    expect(transcriptPlainText(segments)).toBe("VEASEL CODE / QUICK HELP\n\n")
  })

  test("tones fenced code distinctly from surrounding prose", () => {
    const content = "Before\n```ts\nconst n = 1\n```\nAfter"
    const body = messageBodySegments(content, "assistantText")
    expect(body).toEqual([
      { text: "Before\n", tone: "assistantText" },
      { text: "```ts\n", tone: "codeFence" },
      { text: "const n = 1\n", tone: "codeBody" },
      { text: "```\n", tone: "codeFence" },
      { text: "After", tone: "assistantText" },
    ])
    const text = transcriptPlainText(transcriptSegments({
      messages: [{ role: "assistant", content }],
    }))
    expect(text).toBe(`◆ VEASEL\n${content}`)
    expect(transcriptSegments({
      messages: [{ role: "assistant", content }],
    })).toContainEqual({ text: "```ts\n", tone: "codeFence" })
  })

  test("tones inline code and bold spans without dropping markers", () => {
    const content = "Use `fmt` and **save** the file."
    expect(messageBodySegments(content, "assistantText")).toEqual([
      { text: "Use ", tone: "assistantText" },
      { text: "`fmt`", tone: "inlineCode" },
      { text: " and ", tone: "assistantText" },
      { text: "**save**", tone: "strong" },
      { text: " the file.", tone: "assistantText" },
    ])
    expect(transcriptPlainText(transcriptSegments({
      messages: [{ role: "assistant", content }],
    }))).toBe(`◆ VEASEL\n${content}`)
  })

  test("tones list markers and markdown links in streamed prose", () => {
    const content = "- read [docs](https://example.com/docs)\n1. run `make`"
    expect(messageBodySegments(content, "assistantText")).toEqual([
      { text: "- ", tone: "listMarker" },
      { text: "read ", tone: "assistantText" },
      { text: "[docs](https://example.com/docs)\n", tone: "link" },
      { text: "1. ", tone: "listMarker" },
      { text: "run ", tone: "assistantText" },
      { text: "`make`", tone: "inlineCode" },
    ])
    expect(transcriptPlainText(messageBodySegments(content, "assistantText"))).toBe(content)
  })

  test("tones markdown headings without dropping hashes or inline spans", () => {
    const content = "## Fix `main.v`\nBody"
    expect(messageBodySegments(content, "assistantText")).toEqual([
      { text: "## ", tone: "heading" },
      { text: "Fix ", tone: "heading" },
      { text: "`main.v`\n", tone: "inlineCode" },
      { text: "Body", tone: "assistantText" },
    ])
    expect(transcriptPlainText(messageBodySegments(content, "assistantText"))).toBe(content)
  })

  test("keeps system and tool roles distinct from the operator", () => {
    const segments = transcriptSegments({
      messages: [
        { role: "system", content: "workspace tools available" },
        { role: "tool", content: "read src/main.v" },
      ],
    })
    expect(segments).toContainEqual({ text: systemLabel, tone: "systemLabel" })
    expect(segments).toContainEqual({ text: "\nworkspace tools available", tone: "systemText" })
    expect(segments).toContainEqual({ text: toolLabel, tone: "toolLabel" })
    expect(segments).toContainEqual({ text: "\nread src/main.v", tone: "toolText" })
    expect(transcriptPlainText(segments)).not.toContain(userLabel)
  })
})
