import { describe, expect, test } from "bun:test"
import { assistantLabel, noticeSegments, transcriptPlainText, transcriptSegments, userLabel } from "./transcript"

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

  test("marks in-flight turns with a status", () => {
    const text = transcriptPlainText(transcriptSegments({
      messages: [],
      pendingUserMessage: "add a test",
      streamingText: "Reading",
      streaming: true,
    }))
    expect(text).toBe("● YOU  ·  sending\nadd a test\n\n◆ VEASEL  ·  streaming…\nReading")
  })

  test("labels an interrupted response as partial", () => {
    const segments = transcriptSegments({ messages: [], streamingText: "half", streaming: false })
    expect(segments).toContainEqual({ text: "  ·  partial response", tone: "status" })
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
    expect(segments).toContainEqual({ text: "-old\n", tone: "diffRemove" })
    expect(segments).toContainEqual({ text: "+new\n", tone: "diffAdd" })
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

  test("treats any non-assistant role as the user", () => {
    const segments = transcriptSegments({ messages: [{ role: "system", content: "x" }] })
    expect(segments[0]).toEqual({ text: userLabel, tone: "userLabel" })
  })
})
