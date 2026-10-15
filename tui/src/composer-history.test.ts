import { expect, test, describe } from "bun:test"
import {
  clearComposerLine,
  emptyComposerHistory,
  rememberComposerEntry,
  stepComposerHistory,
} from "./composer-history"

describe("composer history", () => {
  test("remembers unique prompts and walks older/newer from an empty draft", () => {
    let history = emptyComposerHistory()
    history = rememberComposerEntry(history, "  one  ")
    history = rememberComposerEntry(history, "one")
    history = rememberComposerEntry(history, "two")
    expect(history.entries).toEqual(["one", "two"])

    expect(stepComposerHistory(history, "newer", "")).toBeUndefined()
    expect(stepComposerHistory(history, "older", "still typing")).toBeUndefined()

    const older = stepComposerHistory(history, "older", "")!
    expect(older.value).toBe("two")
    const oldest = stepComposerHistory(older.history, "older", older.value)!
    expect(oldest.value).toBe("one")
    expect(stepComposerHistory(oldest.history, "older", oldest.value)).toBeUndefined()

    const back = stepComposerHistory(oldest.history, "newer", oldest.value)!
    expect(back.value).toBe("two")
    const draft = stepComposerHistory(back.history, "newer", back.value)!
    expect(draft.value).toBe("")
    expect(draft.history.offset).toBe(0)

    const recalled = stepComposerHistory(history, "older", "")!
    expect(recalled.history.offset).toBe(1)
    const cleared = clearComposerLine(recalled.history)
    expect(cleared.offset).toBe(0)
    expect(cleared.draft).toBe("")
    expect(cleared.entries).toEqual(["one", "two"])
  })
})
