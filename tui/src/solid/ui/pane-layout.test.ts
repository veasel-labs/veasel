import { describe, expect, test } from "bun:test"
import {
  HOME_SIDEBAR_DEFAULT,
  HOME_SIDEBAR_MIN,
  clampHomeSidebarWidth,
  loadHomeSidebarWidth,
  paneLayoutPath,
  saveHomeSidebarWidth,
  stepHomeSidebarWidth,
} from "./pane-layout"

describe("pane layout", () => {
  test("clamps sidebar width to terminal budget", () => {
    expect(clampHomeSidebarWidth(10, 80)).toBe(HOME_SIDEBAR_MIN)
    expect(clampHomeSidebarWidth(100, 80)).toBe(44) // 80 - HOME_CONTENT_MIN
    expect(clampHomeSidebarWidth(HOME_SIDEBAR_DEFAULT, 80)).toBe(HOME_SIDEBAR_DEFAULT)
    // Narrow terminals still keep the sidebar minimum.
    expect(clampHomeSidebarWidth(40, 50)).toBe(HOME_SIDEBAR_MIN)
  })

  test("steps width within clamp", () => {
    expect(stepHomeSidebarWidth(28, 2, 80)).toBe(30)
    expect(stepHomeSidebarWidth(18, -4, 80)).toBe(HOME_SIDEBAR_MIN)
  })

  test("persists and reloads preferred width", () => {
    const files = new Map<string, string>()
    const io = {
      env: { XDG_STATE_HOME: "/tmp/veasel-pane-test" },
      home: "/tmp",
      readFile: (path: string) => {
        const value = files.get(path)
        if (value === undefined) throw new Error("missing")
        return value
      },
      writeFile: (path: string, data: string) => {
        files.set(path, data)
      },
    }
    const path = paneLayoutPath(io.env, io.home)
    saveHomeSidebarWidth(34, io, 100)
    expect(files.get(path)).toContain('"homeSidebarWidth": 34')
    expect(loadHomeSidebarWidth(io, 100)).toBe(34)
    expect(loadHomeSidebarWidth(io, 50)).toBe(clampHomeSidebarWidth(34, 50))
  })
})
