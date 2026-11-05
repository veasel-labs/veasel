/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { DialogProvider } from "../ui/dialog"
import { SessionListDialog, type SolidSessionEntry } from "./session-list-dialog"

// Same geometry regression class as the provider dialog at 100x24
// (provider-settings-dialog.smoke-geometry.test.tsx): each session row
// is two lines (title + directory), so a fixed 10-row window needs 20
// lines plus header/input/footer inside the large dialog box (72x20 at
// 100x24, 16 lines of interior). The window must shrink to the
// terminal so the footer stays above the bottom border and no row
// overdraws another.

const sessions: SolidSessionEntry[] = Array.from({ length: 25 }, (_, i) => ({
  id: `sess-${i}`,
  title: `Session ${i}`,
  directory: `~/work/project-${i}`,
}))

test("session list fits 100x24 with many sessions", async () => {
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
            <SessionListDialog sessions={sessions} />
          </box>
        </box>
      </DialogProvider>
    ),
    { width: 100, height: 24, kittyKeyboard: true },
  )
  try {
    await setup.waitFor(() => setup.captureCharFrame().includes("Sessions"))
    const frame = setup.captureCharFrame()
    const lines = frame.split("\n")
    const footerIndex = lines.findIndex((line) => line.includes("25 sessions"))
    const borderIndex = lines.findIndex((line) => line.includes("└"))
    expect(footerIndex).toBeGreaterThan(-1)
    expect(borderIndex).toBeGreaterThan(footerIndex)
    // The selected row renders its full title on its own line and its
    // directory on the next line — not squashed into one overdrawn line
    // ("▸ Se~/work/project-0").
    const titleIndex = lines.findIndex((line) => line.includes("▸ Session 0"))
    expect(titleIndex).toBeGreaterThan(-1)
    expect(lines[titleIndex]).not.toContain("~/work/project-0")
    expect(lines[titleIndex + 1]).toContain("~/work/project-0")
    // No two session rows share a rendered line (overdraw signature).
    for (const line of lines) {
      const titles = line.match(/Session \d+/g) ?? []
      expect(titles.length).toBeLessThanOrEqual(1)
    }
  } finally {
    setup.renderer.destroy()
  }
}, 30000)
