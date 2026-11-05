/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { DialogProvider } from "../ui/dialog"
import { dialogGeometry } from "../ui/dialog-layout"
import { SessionListDialog, type SolidSessionEntry } from "./session-list-dialog"
import { StatusDialog, type StatusDialogSnapshot } from "./status-dialog"
import { HighlightsDialog } from "./highlights-dialog"
import { ProviderSettingsDialog } from "./provider-settings-dialog"
import type { ModelProvider } from "../../model-providers"
import { liveReleaseHighlights } from "../release-highlights"
import type { SolidMcpServer } from "./mcp-dialog"

// The 100x24 smoke-geometry regressions charge rows against the shared
// dialog geometry, but at 40x16 / 32x12 the same dialogs still overdrew:
// session rows are always two lines yet were charged one line in
// compact mode, status detail lines wrapped/squashed into each other,
// and highlights forced one entry even when it alone exceeded the box.
// The provider status line wrapped at 32 columns and pushed its
// "Showing" line onto the bottom border. These render through the real
// large-dialog geometry at tiny sizes.

const providers: ModelProvider[] = Array.from({ length: 210 }, (_, i) => ({
  id: `p${i}`,
  name: i === 0 ? "Anthropic" : `Provider ${i}`,
  description: "models",
  protocol: i === 0 ? "anthropic" : "openai-compatible",
  base_url: "https://example.test",
  environment_key: "X_API_KEY",
  requires_api_key: true,
}))

const sessions: SolidSessionEntry[] = Array.from({ length: 25 }, (_, i) => ({
  id: `sess-${i}`,
  title: `Session ${i}`,
  directory: `~/work/project-${i}`,
}))

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

function Backdrop(props: { w: number; h: number; children?: unknown }) {
  const g = dialogGeometry(props.w, props.h, 72)
  return (
    <DialogProvider>
      <box width={props.w} height={props.h} alignItems="center" justifyContent="center">
        <box
          width={g.width}
          maxHeight={g.height}
          flexDirection="column"
          border
          paddingTop={g.paddingY}
          paddingBottom={g.paddingY}
          paddingLeft={g.paddingX}
          paddingRight={g.paddingX}
        >
          {props.children as never}
        </box>
      </box>
    </DialogProvider>
  )
}

for (const [w, h] of [[40, 16], [32, 12]] as const) {
  test(`session list fits ${w}x${h} without overdrawn rows`, async () => {
    const setup = await testRender(
      () => (<Backdrop w={w} h={h}><SessionListDialog sessions={sessions} /></Backdrop>),
      { width: w, height: h, kittyKeyboard: true },
    )
    try {
      await setup.waitFor(() => setup.captureCharFrame().includes("Sessions"))
      const lines = setup.captureCharFrame().split("\n")
      const footerIndex = lines.findIndex((line) => line.includes("25 sessions"))
      const borderIndex = lines.findIndex((line) => line.includes("└"))
      expect(footerIndex).toBeGreaterThan(-1)
      expect(borderIndex).toBeGreaterThan(footerIndex)
      // Footer is not fused with a session row ("25 sessions4· …").
      expect(lines[footerIndex]).toContain("25 sessions ·")
      // Nothing paints over the bottom border row.
      expect(lines[borderIndex]).not.toContain("~/work")
      expect(lines[borderIndex]).not.toContain("Session")
      for (const line of lines) {
        const titles = line.match(/Session \d+/g) ?? []
        expect(titles.length).toBeLessThanOrEqual(1)
        // Title and its directory never share a line.
        expect(line.includes("Session") && line.includes("~/work/project-")).toBe(false)
      }
    } finally { setup.renderer.destroy() }
  }, 30000)

  test(`status dialog fits ${w}x${h} without fused lines`, async () => {
    const setup = await testRender(
      () => (<Backdrop w={w} h={h}><StatusDialog {...snapshot} /></Backdrop>),
      { width: w, height: h, kittyKeyboard: true },
    )
    try {
      await setup.waitFor(() => setup.captureCharFrame().includes("Status"))
      const frame = setup.captureCharFrame()
      const lines = frame.split("\n")
      expect(frame).toContain("MCP (20)")
      expect(frame).toContain("Directory · ~/work")
      for (const line of lines) {
        // Fixed one-line fields never paint over each other.
        expect(line.includes("LOCAL") && line.includes("Directory")).toBe(false)
        expect(line.includes("Directory") && line.includes("Session Probe")).toBe(false)
        // The usage detail line never fuses with the footer's "reflects".
        expect(line.includes("Usage ·") && line.includes("reflects")).toBe(false)
      }
      const borderIndex = lines.findIndex((line) => line.includes("└"))
      expect(borderIndex).toBeGreaterThan(-1)
      expect(lines[borderIndex]).not.toContain("more")
      expect(lines[borderIndex]).not.toContain("Usage")
    } finally { setup.renderer.destroy() }
  }, 30000)

  test(`highlights dialog fits ${w}x${h} without fused lines`, async () => {
    const setup = await testRender(
      () => (<Backdrop w={w} h={h}><HighlightsDialog entries={liveReleaseHighlights()} /></Backdrop>),
      { width: w, height: h, kittyKeyboard: true },
    )
    try {
      await setup.waitFor(() => setup.captureCharFrame().includes("What's new"))
      const lines = setup.captureCharFrame().split("\n")
      const borderIndex = lines.findIndex((line) => line.includes("└"))
      expect(borderIndex).toBeGreaterThan(-1)
      // Summary and entry text never paint over the bottom border.
      expect(lines[borderIndex]).not.toContain("more")
      expect(lines[borderIndex]).not.toContain("enlarge")
      for (const line of lines) {
        // Footer never fuses with entry body text.
        expect(line.includes("Tip") && line.includes("variants")).toBe(false)
        expect(line.includes("Tip") && line.includes("switches")).toBe(false)
      }
    } finally { setup.renderer.destroy() }
  }, 30000)
}

for (const [w, h] of [[40, 16], [32, 12]] as const) {
  test(`provider dialog at ${w}x${h} keeps Showing and count off the border`, async () => {
    const setup = await testRender(
      () => (<Backdrop w={w} h={h}><ProviderSettingsDialog providers={providers} /></Backdrop>),
      { width: w, height: h, kittyKeyboard: true },
    )
    try {
      await setup.waitFor(() => setup.captureCharFrame().includes("MODEL SETTINGS"))
      const frame = setup.captureCharFrame()
      const lines = frame.split("\n")
      const borderIndex = lines.findIndex((line) => line.includes("└"))
      expect(borderIndex).toBeGreaterThan(-1)
      expect(lines[borderIndex]).not.toContain("Showing")
      expect(frame).toContain("Showing")
      expect(frame).toContain("All 210/210")
    } finally { setup.renderer.destroy() }
  }, 30000)
}
