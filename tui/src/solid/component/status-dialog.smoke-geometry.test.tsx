/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { DialogProvider } from "../ui/dialog"
import { StatusDialog, type StatusDialogSnapshot } from "./status-dialog"
import type { SolidMcpServer } from "./mcp-dialog"

// Same geometry regression class as the provider and session dialogs:
// the MCP list was unbounded, so at 100x24 with 20 servers the rows
// overdrew each other ("•Cserver-2 Connected"), the "MCP (20)" header
// was squashed away, and hidden servers were not acknowledged. The
// visible rows must be charged against the shared dialog geometry and
// the remainder summarized.

const servers: SolidMcpServer[] = Array.from({ length: 20 }, (_, i) => ({
  name: `server-${i}`,
  transport: "stdio",
  status: "connected",
}))

const snapshot: StatusDialogSnapshot = {
  sessionTitle: "Probe session",
  directory: "~/work",
  provider: "anthropic",
  model: "claude-sonnet-4",
  agent: "build",
  variant: "default",
  usageLine: "12.4k in · 1.8k out",
  connection: "LOCAL · loopback",
  mcpServers: servers,
}

test("status dialog bounds the MCP list at 100x24", async () => {
  const setup = await testRender(
    () => (
      <DialogProvider>
        <box width={100} height={24} alignItems="center" justifyContent="center">
          <box
            width={72}
            maxHeight={20}
            flexDirection="column"
            border
            paddingTop={1}
            paddingBottom={1}
            paddingLeft={2}
            paddingRight={2}
          >
            <StatusDialog {...snapshot} />
          </box>
        </box>
      </DialogProvider>
    ),
    { width: 100, height: 24, kittyKeyboard: true },
  )
  try {
    await setup.waitFor(() => setup.captureCharFrame().includes("Status"))
    const frame = setup.captureCharFrame()
    const lines = frame.split("\n")
    // Header survives and states the true total.
    expect(frame).toContain("MCP (20)")
    // First server renders cleanly on its own line.
    const firstRow = lines.find((line) => line.includes("server-0"))
    expect(firstRow).toContain("server-0")
    expect(firstRow).toContain("Connected")
    expect(firstRow).not.toContain("server-1")
    // Hidden servers are acknowledged, not silently dropped.
    expect(frame).toMatch(/\+\d+ more/)
    // Footer stays above the bottom border.
    const footerIndex = lines.findIndex((line) => line.includes("Usage reflects"))
    const borderIndex = lines.findIndex((line) => line.includes("└"))
    expect(footerIndex).toBeGreaterThan(-1)
    expect(borderIndex).toBeGreaterThan(footerIndex)
    // No line carries two servers (overdraw signature).
    for (const line of lines) {
      const names = line.match(/server-\d+/g) ?? []
      expect(names.length).toBeLessThanOrEqual(1)
    }
  } finally {
    setup.renderer.destroy()
  }
}, 30000)
