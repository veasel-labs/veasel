import { describe, expect, test } from "bun:test"
import { assistantLabel, transcriptPlainText, transcriptSegments, userLabel } from "./transcript"

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

  test("renders notices and can hide messages behind the help guide", () => {
    const segments = transcriptSegments({ notice: "VEASEL CODE / QUICK HELP", messages: [{ role: "user", content: "hi" }], showMessages: false })
    expect(transcriptPlainText(segments)).toBe("VEASEL CODE / QUICK HELP\n\n")
  })

  test("treats any non-assistant role as the user", () => {
    const segments = transcriptSegments({ messages: [{ role: "system", content: "x" }] })
    expect(segments[0]).toEqual({ text: userLabel, tone: "userLabel" })
  })
})
