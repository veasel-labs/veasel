import { describe, expect, test } from "bun:test"
import { formatBoundedReviewLines, formatMcpReview, mcpReviewLineBudget, mcpStdioSandboxWarning } from "./mcp-review"

function longArguments(): string {
  const fields = Array.from({ length: 30 }, (_, index) => `  "field_${String(index + 1).padStart(2, "0")}": "value ${index + 1}"`)
  fields.push('  "tail": "MCP-TAIL"')
  return `{\n${fields.join(",\n")}\n}`
}

describe("formatMcpReview", () => {
  test("puts the approval decision ahead of the arguments", () => {
    const text = formatMcpReview({
      plugin: "review-tools",
      server: "local",
      tool: "effect",
      operationId: "op-1",
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      pending: true,
      argumentsText: '{\n  "path": "src/main.v"\n}',
      maxLines: 20,
    })
    expect(text.indexOf("has not reached its MCP server")).toBeLessThan(text.indexOf('"path"'))
    expect(text).toContain("Type /mcp call approve cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    expect(text).not.toContain("Showing ")
  })

  test("hides the tail of an argument list taller than the terminal", () => {
    expect(mcpReviewLineBudget(40)).toBe(20)
    const text = formatMcpReview({
      plugin: "review-tools",
      server: "local",
      tool: "effect",
      operationId: "op-1",
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      pending: true,
      argumentsText: longArguments(),
      maxLines: mcpReviewLineBudget(40),
    })
    expect(text).toContain("Showing 20 of ")
    expect(text).not.toContain("MCP-TAIL")
    expect(text.indexOf("has not reached its MCP server")).toBeLessThan(text.indexOf("Showing 20 of "))
  })

  test("escapes a control character without joining every line into one", () => {
    const text = formatBoundedReviewLines("keep\nline\u0007two", 10)
    expect(text).toBe("keep\nline\\u0007two")
  })

  test("shows stdio sandbox preview and default-off honesty ahead of arguments", () => {
    const text = formatMcpReview({
      plugin: "review-tools",
      server: "local",
      tool: "effect",
      operationId: "op-1",
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      pending: true,
      argumentsText: '{\n  "path": "src/main.v"\n}',
      maxLines: 20,
      stdioSandbox: { mode: "off", will_wrap: false, backend: "none" },
    })
    expect(text).toContain("Stdio sandbox: mode off · will not wrap")
    expect(text).toContain("unsandboxed OS-user privileges")
    expect(text.indexOf("Stdio sandbox:")).toBeLessThan(text.indexOf('"path"'))
    expect(mcpStdioSandboxWarning({ mode: "auto", will_wrap: true, backend: "bubblewrap" })).toContain("Bubblewrap")
  })
})
