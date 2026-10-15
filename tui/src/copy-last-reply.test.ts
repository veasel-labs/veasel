import { expect, test, describe } from "bun:test"
import {
  copyLastReplyNotice,
  lastAssistantReply,
  osc52CopySequence,
  writeClipboardOsc52,
} from "./copy-last-reply"

describe("copy last reply", () => {
  test("prefers streaming text then the latest assistant turn", () => {
    expect(lastAssistantReply([])).toBeUndefined()
    expect(lastAssistantReply([{ role: "user", content: "hi" }])).toBeUndefined()
    expect(
      lastAssistantReply([
        { role: "user", content: "hi" },
        { role: "assistant", content: "first" },
        { role: "user", content: "again" },
        { role: "assistant", content: "second" },
      ]),
    ).toBe("second")
    expect(
      lastAssistantReply([{ role: "assistant", content: "done" }], "partial…"),
    ).toBe("partial…")
  })

  test("encodes OSC 52 and reports copy outcomes", () => {
    const sequence = osc52CopySequence("hello")
    expect(sequence.startsWith("\x1b]52;c;")).toBe(true)
    expect(sequence.endsWith("\x07")).toBe(true)
    expect(Buffer.from(sequence.slice(7, -1), "base64").toString("utf8")).toBe("hello")

    const chunks: string[] = []
    expect(writeClipboardOsc52("yank", (chunk) => {
      chunks.push(String(chunk))
      return true
    })).toBe(true)
    expect(chunks.join("")).toBe(osc52CopySequence("yank"))

    expect(copyLastReplyNotice("copied")).toContain("Copied last reply")
    expect(copyLastReplyNotice("empty")).toContain("No assistant reply")
    expect(copyLastReplyNotice("failed")).toContain("clipboard unavailable")
  })
})
