/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import type { ModelProvider } from "../../model-providers"
import { DialogProvider } from "../ui/dialog"
import { ProviderSettingsDialog } from "./provider-settings-dialog"

// Regression for the packaged standalone-TUI smoke failure at 100x24
// (the PTY size scripts/standalone-tui-smoke.py drives): with the full
// 210-provider catalog, the dialog chrome overflowed the large dialog
// box (72x20 at this terminal size), rows overdrew each other
// ("Showingi1–2 ofp210"), and the smoke's "All 210/210" marker never
// appeared contiguously after Ctrl+L. This renders the dialog inside a
// box with the real DialogBackdrop geometry for 100x24 and repeats the
// smoke's filter/clear sequence.

const providers: ModelProvider[] = Array.from({ length: 210 }, (_, i) => ({
  id: `p${i}`,
  name: i === 0 ? "Anthropic" : `Provider ${i}`,
  description: "models",
  protocol: i === 0 ? "anthropic" : "openai-compatible",
  base_url: "https://example.test",
  environment_key: "X_API_KEY",
  requires_api_key: true,
}))

test("provider dialog fits 100x24 without overdrawn rows through filter and clear", async () => {
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
            <ProviderSettingsDialog providers={providers} />
          </box>
        </box>
      </DialogProvider>
    ),
    { width: 100, height: 24, kittyKeyboard: true },
  )
  try {
    await setup.waitFor(() => setup.captureCharFrame().includes("MODEL SETTINGS"))
    const initial = setup.captureCharFrame()
    expect(initial).toContain("All 210/210")
    expect(initial).toContain("Showing 1–8 of 210")
    const initialLines = initial.split("\n")
    const showingIndex = initialLines.findIndex((line) => line.includes("Showing 1–8 of 210"))
    const borderIndex = initialLines.findIndex((line) => line.includes("└"))
    expect(showingIndex).toBeGreaterThan(-1)
    expect(borderIndex).toBeGreaterThan(showingIndex)
    // No row overdraws another: a provider row and the Showing line
    // never share a rendered line.
    for (const line of initialLines) {
      expect(line.includes("Showing") && line.includes("Provider 1")).toBe(false)
    }

    await setup.mockInput.typeText("anthorpic")
    await setup.renderOnce()
    const filtered = setup.captureCharFrame()
    expect(filtered).toContain("1/210")
    expect(filtered).toContain("Anthropic")

    setup.mockInput.pressKey("l", { ctrl: true })
    await setup.renderOnce()
    const cleared = setup.captureCharFrame()
    expect(cleared).toContain("All 210/210")
    expect(cleared).toContain("Showing 1–8 of 210")
  } finally {
    setup.renderer.destroy()
  }
}, 30000)
