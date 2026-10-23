/** @jsxImportSource @opentui/solid */
import { testRender } from "@opentui/solid"
import { expect, test } from "bun:test"
import { SessionTabs } from "./session-tabs"

test("session tabs keep the active session and controls visible at narrow widths", async () => {
  const tabs = Array.from({ length: 20 }, (_, index) => ({
    id: `session-${index}`,
    title: index === 10 ? "CURRENT SESSION" : `Session ${String(index).padStart(2, "0")} long project title`,
  }))

  const setup = await testRender(
    () => (
      <box width="100%" height="100%">
        <SessionTabs
          tabs={tabs}
          activeId="session-10"
          onSelect={() => {}}
          onNew={() => {}}
          onCloseActive={() => {}}
        />
      </box>
    ),
    { width: 120, height: 4 },
  )

  try {
    for (const width of [32, 40, 80, 120]) {
      setup.resize(width, 4)
      await setup.renderOnce()
      const frame = setup.captureCharFrame()
      expect(frame).toContain("+")
      expect(frame).toContain("✕")
      expect(frame).toContain("CUR")
      expect(frame.split("\n").every((line) => line.length <= width)).toBe(true)
    }
  } finally {
    setup.renderer.destroy()
  }
})
