import { describe, expect, test } from "bun:test"
import {
  addComposerAttachment,
  asciiImagePreview,
  attachmentChipLabel,
  attachmentKindForPath,
  createComposerAttachment,
  formatMessageWithAttachments,
  normalizeAttachmentPath,
  removeComposerAttachment,
  resolveAttachmentPath,
} from "./composer-attachments"

describe("composer attachments", () => {
  test("detects image vs file by extension", () => {
    expect(attachmentKindForPath("/tmp/a.PNG")).toBe("image")
    expect(attachmentKindForPath("/tmp/notes.md")).toBe("file")
  })

  test("normalizes path-like pastes and rejects URLs", () => {
    expect(normalizeAttachmentPath("  '/tmp/shot.png'  ")).toBe("/tmp/shot.png")
    expect(normalizeAttachmentPath("file:///tmp/shot.png")).toBe("/tmp/shot.png")
    expect(normalizeAttachmentPath("https://example.com/a.png")).toBeUndefined()
    expect(normalizeAttachmentPath("hello world")).toBeUndefined()
  })

  test("resolveAttachmentPath checks existence", () => {
    expect(
      resolveAttachmentPath("/tmp/missing.png", {
        exists: () => false,
      }),
    ).toBeUndefined()
    expect(
      resolveAttachmentPath("~/shot.png", {
        home: "/home/dev",
        exists: (path) => path === "/home/dev/shot.png",
      }),
    ).toBe("/home/dev/shot.png")
  })

  test("formats submit text with @path mentions", () => {
    const attachment = createComposerAttachment("/tmp/a.png", {
      stat: () => ({ size: 2048 }),
      now: 1,
    })
    expect(formatMessageWithAttachments("look", [attachment])).toBe("look\n\n@/tmp/a.png")
    expect(formatMessageWithAttachments("  ", [attachment])).toBe("@/tmp/a.png")
    expect(attachmentChipLabel(attachment)).toContain("img")
    expect(attachmentChipLabel(attachment)).toContain("2KB")
    expect(asciiImagePreview(attachment)).toContain("VEASEL · image")
  })

  test("add is path-unique and remove by id", () => {
    const a = createComposerAttachment("/tmp/a.png", { stat: () => ({ size: 1 }), now: 1 })
    const b = createComposerAttachment("/tmp/b.md", { stat: () => ({ size: 1 }), now: 2 })
    const once = addComposerAttachment([], a)
    expect(addComposerAttachment(once, a)).toHaveLength(1)
    expect(removeComposerAttachment(addComposerAttachment(once, b), a.id).map((x) => x.path)).toEqual([
      "/tmp/b.md",
    ])
  })
})
