import { describe, expect, test } from "bun:test"
import { formatTuiHelp, formatTuiVersion, parseTuiCliAction } from "./cli"

describe("TUI CLI", () => {
  test("finds help and version flags independent of Bun's argv layout", () => {
    expect(parseTuiCliAction(["/path/veasel-tui", "--help"])).toBe("help")
    expect(parseTuiCliAction(["/usr/bin/bun", "src/main.ts", "-v"])).toBe("version")
    expect(parseTuiCliAction(["/path/veasel-tui", "workspace"])).toBe("run")
  })

  test("prints product-versioned help and version text", () => {
    expect(formatTuiHelp("0.24.1-next.0")).toContain("Usage: veasel-tui")
    expect(formatTuiVersion("0.24.1-next.0")).toBe("Veasel Code Terminal 0.24.1-next.0")
  })
})
