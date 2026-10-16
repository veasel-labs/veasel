import { describe, expect, test } from "bun:test"
import {
  formatSessionExport,
  formatUsageLine,
  sessionExportPath,
} from "./session-export"

describe("session export", () => {
  test("formats markdown with roles", () => {
    const body = formatSessionExport(
      [
        { role: "user", content: "hello" },
        { role: "assistant", content: "hi there" },
        { role: "tool", content: "secret tool" },
      ],
      { title: "Demo", directory: "/tmp/demo", sessionId: "s1", exportedAt: "2026-10-16T00:00:00.000Z" },
      { format: "markdown", tools: false, thinking: true, sanitize: false },
    )
    expect(body).toContain("# Demo")
    expect(body).toContain("## User")
    expect(body).toContain("hello")
    expect(body).not.toContain("secret tool")
  })

  test("json includes tools when requested and sanitizes keys", () => {
    const body = formatSessionExport(
      [
        { role: "user", content: "use sk-abcdefghijklmnop" },
        { role: "tool", content: "ran" },
      ],
      { title: "Demo", directory: "/tmp", exportedAt: "2026-10-16T00:00:00.000Z" },
      { format: "json", tools: true, thinking: true, sanitize: true },
    )
    const parsed = JSON.parse(body) as { messages: Array<{ role: string; content: string }> }
    expect(parsed.messages).toHaveLength(2)
    expect(parsed.messages[0]?.content).toContain("[redacted-key]")
  })

  test("export path uses veasel-exports", () => {
    expect(sessionExportPath("markdown", new Date("2026-10-16T12:34:56Z"), "/home/u")).toBe(
      "/home/u/veasel-exports/veasel-session-2026-10-16-12-34-56.md",
    )
  })

  test("formats usage line when reported", () => {
    expect(
      formatUsageLine({
        input_tokens: 10,
        output_tokens: 4,
        usage_reported: true,
        cache_read_tokens: 2,
        cache_reported: true,
        cost: "0.01",
      }),
    ).toBe("10 in · 4 out · 2 cache read · cost 0.01")
    expect(formatUsageLine({ input_tokens: 1, output_tokens: 1, usage_reported: false })).toBeUndefined()
  })
})
