import { describe, expect, test } from "bun:test"
import {
  loadSessionDrafts,
  parseSessionDrafts,
  saveSessionDrafts,
  sessionDraftsPath,
  sessionDraftLimit,
  upsertSessionDraft,
  type SessionDraft,
} from "./session-drafts"

function fakeIo() {
  const files = new Map<string, string>()
  return {
    files,
    io: {
      env: { XDG_STATE_HOME: "/tmp/veasel-drafts-test" },
      home: "/unused",
      readFile: (path: string) => {
        const data = files.get(path)
        if (data === undefined) throw new Error("missing")
        return data
      },
      writeFile: (path: string, data: string) => {
        files.set(path, data)
      },
    },
  }
}

describe("session draft persistence", () => {
  test("uses XDG_STATE_HOME when set", () => {
    expect(sessionDraftsPath({ XDG_STATE_HOME: "/tmp/veasel-state" }, "/unused")).toBe(
      "/tmp/veasel-state/veasel/session-drafts.json",
    )
  })

  test("draft typed in one process is restored in the next", () => {
    const { io } = fakeIo()
    let drafts = loadSessionDrafts(io)
    drafts = upsertSessionDraft(drafts, "session-a", {
      text: "half-written reply",
      attachments: [{ id: "a1", path: "/tmp/note.txt", name: "note.txt", kind: "file" }],
    }, 1_000)
    saveSessionDrafts(drafts, io)
    const restored = loadSessionDrafts(io)
    expect(restored.get("session-a")?.text).toBe("half-written reply")
    expect(restored.get("session-a")?.attachments).toEqual([
      { id: "a1", path: "/tmp/note.txt", name: "note.txt", kind: "file" },
    ])
  })

  test("empty draft removes the entry and corrupt data loads as empty", () => {
    const { files, io } = fakeIo()
    let drafts = upsertSessionDraft(new Map(), "s1", { text: "x", attachments: [] }, 1)
    drafts = upsertSessionDraft(drafts, "s1", { text: "", attachments: [] }, 2)
    expect(drafts.size).toBe(0)
    files.set(sessionDraftsPath(io.env, io.home), "{not json")
    expect(loadSessionDrafts(io).size).toBe(0)
    expect(parseSessionDrafts(JSON.stringify({ s2: { text: 42 } })).size).toBe(0)
  })

  test("keeps only the most recently updated sessions", () => {
    let drafts = new Map<string, SessionDraft>()
    for (let i = 0; i < sessionDraftLimit + 2; i += 1) {
      drafts = upsertSessionDraft(drafts, `s${i}`, { text: `draft ${i}`, attachments: [] }, i)
    }
    expect(drafts.size).toBe(sessionDraftLimit)
    expect(drafts.has("s0")).toBe(false)
    expect(drafts.get(`s${sessionDraftLimit + 1}`)?.text).toBe(`draft ${sessionDraftLimit + 1}`)
  })
})
