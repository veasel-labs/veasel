/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { DialogProvider } from "../ui/dialog"
import { HighlightsDialog } from "./highlights-dialog"
import { liveReleaseHighlights } from "../release-highlights"

// The shipping "What's new" entries overflow the large dialog at
// 100x24: four entries at title + 2 wrapped body lines + margin need
// 16 lines but the entries region has ~11, so titles overdrew body
// text ("Ctrl+Rgloadseedits,rshell..."). Visible entries must be
// charged by wrapped height against the shared dialog geometry and
// the remainder summarized.

test("highlights dialog fits 100x24 with the shipping entries", async () => {
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
            <HighlightsDialog entries={liveReleaseHighlights()} />
          </box>
        </box>
      </DialogProvider>
    ),
    { width: 100, height: 24, kittyKeyboard: true },
  )
  try {
    await setup.waitFor(() => setup.captureCharFrame().includes("What's new"))
    const frame = setup.captureCharFrame()
    const lines = frame.split("\n")
    // First entry renders fully: title on its own line, body wrap intact.
    const titleIndex = lines.findIndex((line) =>
      line.includes("Provider connect without the classic wizard"),
    )
    expect(titleIndex).toBeGreaterThan(-1)
    expect(lines[titleIndex]).not.toContain("Press s")
    expect(lines[titleIndex + 1]).toContain("Press s")
    // Second entry title is never fused with its body.
    for (const line of lines) {
      expect(line.includes("Pending reviews") && line.includes("Ctrl+R loads")).toBe(false)
    }
    // Entries that cannot fit are summarized, not silently dropped.
    expect(frame).toMatch(/\+\d+ more/)
    // Footer stays above the bottom border.
    const footerIndex = lines.findIndex((line) => line.includes("Tip LiveApp highlights"))
    const borderIndex = lines.findIndex((line) => line.includes("└"))
    expect(footerIndex).toBeGreaterThan(-1)
    expect(borderIndex).toBeGreaterThan(footerIndex)
  } finally {
    setup.renderer.destroy()
  }
}, 30000)
