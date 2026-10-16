import { describe, expect, test } from "bun:test"
import {
  filterSessionDiffRows,
  sessionDiffFileRows,
  sessionDiffStatusLabel,
  summarizeUnifiedDiff,
} from "./session-diff"

describe("session diff helpers", () => {
  test("builds sorted file rows from workspace edits", () => {
    const rows = sessionDiffFileRows([
      { id: "b", path: "src/z.v", status: "pending" },
      { id: "a", path: "README.md", status: "applied" },
    ])
    expect(rows.map((row) => row.path)).toEqual(["README.md", "src/z.v"])
    expect(rows[0]?.name).toBe("README.md")
    expect(sessionDiffStatusLabel("pending")).toBe("PENDING")
  })

  test("filters by status, path, or id", () => {
    const rows = sessionDiffFileRows([
      { id: "111", path: "src/main.v", status: "pending" },
      { id: "222", path: "docs/a.md", status: "rejected" },
    ])
    expect(filterSessionDiffRows(rows, "pending").map((row) => row.id)).toEqual(["111"])
    expect(filterSessionDiffRows(rows, "docs").map((row) => row.id)).toEqual(["222"])
  })

  test("summarizes unified diff +/- lines", () => {
    const diff = [
      "--- a/x",
      "+++ b/x",
      "@@ -1,2 +1,3 @@",
      " context",
      "-old",
      "+new",
      "+extra",
    ].join("\n")
    expect(summarizeUnifiedDiff(diff)).toEqual({ added: 2, removed: 1 })
  })
})
