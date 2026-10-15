import { describe, expect, test } from "bun:test"
import { formatBoundedBlock, formatShellReview, shellReviewLineBudget } from "./shell-review"

function longCommand(): string {
  const lines = Array.from({ length: 30 }, (_, index) => `echo step ${String(index + 1).padStart(2, "0")}`)
  lines.push("echo SHELL-TAIL")
  return lines.join("\n")
}

describe("formatShellReview", () => {
  test("puts the sandbox warning ahead of a command that does not fill the screen", () => {
    const text = formatShellReview({
      command: "echo hi",
      cwd: "/tmp/alpha",
      timeoutSeconds: 10,
      runner: "/bin/sh",
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      pending: true,
      output: "",
      maxLines: 20,
    })
    expect(text.indexOf("without a sandbox")).toBeGreaterThan(-1)
    expect(text.indexOf("without a sandbox")).toBeLessThan(text.indexOf("echo hi"))
    expect(text).toContain("Type /command approve bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    expect(text).not.toContain("Showing ")
  })

  test("hides the tail of a command taller than the terminal", () => {
    expect(shellReviewLineBudget(40)).toBe(20)
    const command = longCommand()
    const text = formatShellReview({
      command,
      cwd: ".",
      timeoutSeconds: 10,
      runner: "/bin/sh",
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      pending: true,
      output: "",
      maxLines: shellReviewLineBudget(40),
    })
    const block = formatBoundedBlock(command, 20)
    expect(block.totalLines).toBe(31)
    expect(block.shownLines).toBe(20)
    expect(text).toContain("Showing 20 of 31 lines.")
    expect(text).not.toContain("SHELL-TAIL")
    expect(text.indexOf("without a sandbox")).toBeLessThan(text.indexOf("Showing 20 of 31 lines."))
  })

  test("keeps captured output behind the same line budget", () => {
    const output = `${Array.from({ length: 12 }, (_, index) => `line ${index}`).join("\n")}\nTAIL`
    const text = formatBoundedBlock(output, 6)
    expect(text.text.startsWith("Showing 6 of 13 lines.")).toBe(true)
    expect(text.text).not.toContain("TAIL")
  })
})
