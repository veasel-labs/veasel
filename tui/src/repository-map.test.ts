import { describe, expect, test } from "bun:test"
import { formatRepositoryMapSummary, truncateUtf8Preview, type WorkspaceRepositoryMap } from "./repository-map"

const sample: WorkspaceRepositoryMap = {
  text: "<veasel-repository-map untrusted=\"true\">\nsrc/main.v · fn boot\n</veasel-repository-map>",
  bytes: 96,
  estimated_token_bound: 24,
  budget_bytes: 12_288,
  file_count: 2,
  symbol_count: 1,
  files_scanned: 4,
  truncated: false,
  untrusted: true,
  ranked_paths: ["src/main.v", "README.md"],
}

describe("formatRepositoryMapSummary", () => {
  test("states measured bytes and ranked paths without inventing token savings", () => {
    const text = formatRepositoryMapSummary(sample)
    expect(text).toContain("WORKSPACE REPOSITORY MAP")
    expect(text).toContain("Untrusted extractive ranking")
    expect(text).toContain("Measured: 96 UTF-8 bytes (budget 12288; bytes/4 bound 24)")
    expect(text).toContain("Coverage: 2 ranked files · 1 symbols · 4 scanned")
    expect(text).toContain("  src/main.v")
    expect(text).toContain("Map preview:")
    expect(text).not.toContain("% savings")
  })

  test("includes an optional hint and truncated coverage", () => {
    const text = formatRepositoryMapSummary({ ...sample, truncated: true }, "fix boot")
    expect(text).toContain("Hint: fix boot")
    expect(text).toContain("· truncated")
  })

  test("handles an empty map honestly", () => {
    const text = formatRepositoryMapSummary({
      text: "",
      bytes: 0,
      estimated_token_bound: 0,
      budget_bytes: 12_288,
      file_count: 0,
      symbol_count: 0,
      files_scanned: 0,
      truncated: false,
      untrusted: true,
      ranked_paths: [],
    })
    expect(text).toContain("Ranked paths: (none)")
    expect(text).not.toContain("Map preview:")
  })
})

describe("truncateUtf8Preview", () => {
  test("keeps short text intact", () => {
    expect(truncateUtf8Preview("hello", 100)).toBe("hello")
  })

  test("cuts on a UTF-8 boundary and reports hidden bytes", () => {
    const text = "café" + "x".repeat(40)
    const out = truncateUtf8Preview(text, 8)
    expect(out).toContain("more UTF-8 bytes hidden")
    expect(out.startsWith("café")).toBe(true)
  })
})
