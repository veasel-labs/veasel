import { describe, expect, test } from "bun:test"
import {
  draftStashLimit,
  draftStashPath,
  loadDraftStash,
  parseDraftStash,
  pushDraftStash,
  removeDraftStash,
  saveDraftStash,
  serializeDraftStash,
} from "./draft-stash"

describe("draft stash persistence", () => {
  test("uses XDG_STATE_HOME when set", () => {
    expect(draftStashPath({ XDG_STATE_HOME: "/tmp/veasel-state" }, "/unused")).toBe(
      "/tmp/veasel-state/veasel/prompt-stash.jsonl",
    )
  })

  test("parses JSONL and skips corrupt lines", () => {
    const text = [
      JSON.stringify({ id: "a", text: "hello", timestamp: 1 }),
      "not-json",
      JSON.stringify({ id: "b", text: "world", timestamp: 2 }),
      "",
    ].join("\n")
    expect(parseDraftStash(text).map((entry) => entry.id)).toEqual(["a", "b"])
  })

  test("push trims to limit and round-trips through save/load", () => {
    const files = new Map<string, string>()
    const io = {
      env: { XDG_STATE_HOME: "/tmp/veasel-stash-test" },
      home: "/unused",
      readFile: (path: string) => {
        const data = files.get(path)
        if (data === undefined) throw new Error("missing")
        return data
      },
      writeFile: (path: string, data: string) => {
        files.set(path, data)
      },
    }
    let entries = loadDraftStash(io)
    expect(entries).toEqual([])
    for (let i = 0; i < draftStashLimit + 3; i += 1) {
      entries = pushDraftStash(entries, `draft ${i}`, 1_000 + i)
    }
    expect(entries).toHaveLength(draftStashLimit)
    expect(entries[0]?.text).toBe("draft 3")
    saveDraftStash(entries, io)
    const path = draftStashPath(io.env, io.home)
    expect(files.get(path)).toBe(serializeDraftStash(entries))
    expect(loadDraftStash(io).map((entry) => entry.text)).toEqual(entries.map((entry) => entry.text))
    const trimmed = removeDraftStash(entries, entries[0]!.id)
    expect(trimmed).toHaveLength(draftStashLimit - 1)
  })

  test("ignores blank drafts", () => {
    expect(pushDraftStash([], "   \n")).toEqual([])
  })
})
