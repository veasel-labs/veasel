import { describe, expect, test } from "bun:test"
import {
  defaultThemeId,
  formatThemeList,
  formatThemePreviewStatus,
  isThemeId,
  loadThemeId,
  resolveTheme,
  saveThemeId,
  themeConfigPath,
  themeIdFromSlashSuggestion,
  themes,
} from "./themes"

describe("TUI themes", () => {
  test("ships the mint product look as the default theme", () => {
    expect(defaultThemeId).toBe("mint")
    expect(themes.mint.brand).toBe("#9af7c9")
    expect(themes.mint.headerTitle).toBe("#9af7c9")
    expect(themes.mint.shellBg).toBe("#0c0f12")
    expect(themes.mint.localStatus).toBe(themes.mint.brand)
  })

  test("exposes a fixed set of selectable theme ids", () => {
    expect(Object.keys(themes).sort()).toEqual([
      "aurora",
      "contrast",
      "day",
      "ember",
      "mint",
      "mono",
      "slate",
    ])
    expect(isThemeId("mint")).toBe(true)
    expect(isThemeId("day")).toBe(true)
    expect(isThemeId("contrast")).toBe(true)
    expect(isThemeId("neon")).toBe(false)
    expect(resolveTheme("ember").id).toBe("ember")
    expect(resolveTheme("missing").id).toBe("mint")
  })

  test("ships a light day theme and a high-contrast white theme", () => {
    expect(themes.day.shellBg).toBe("#f4f7f5")
    expect(themes.day.panelBg).toBe("#ffffff")
    expect(themes.day.brand).toBe("#0f6b4c")
    expect(themes.day.inputText).toBe("#121a16")
    expect(themes.contrast.shellBg).toBe("#ffffff")
    expect(themes.contrast.body).toBe("#000000")
    expect(themes.contrast.panelBorder).toBe("#000000")
    expect(themes.contrast.statusOk).toBe("#006600")
    expect(themes.contrast.statusError).toBe("#990000")
  })

  test("loads the saved theme id and falls back safely", () => {
    const home = "/tmp/veasel-theme-home"
    const env = { XDG_CONFIG_HOME: `${home}/.config` }
    expect(themeConfigPath(env, home)).toBe(`${home}/.config/veasel/tui-theme`)
    expect(loadThemeId(env, home, () => {
      throw new Error("missing")
    })).toBe("mint")
    expect(loadThemeId({ ...env, VEASEL_TUI_THEME: "slate" }, home, () => "ember")).toBe("slate")
    expect(loadThemeId(env, home, () => "ember\n")).toBe("ember")
    expect(loadThemeId(env, home, () => "not-a-theme")).toBe("mint")
  })

  test("persists the chosen theme id", () => {
    const writes: Array<{ path: string; data: string }> = []
    saveThemeId("aurora", { XDG_CONFIG_HOME: "/tmp/veasel-cfg" }, "/tmp/unused", (path, data) => {
      writes.push({ path, data })
    })
    expect(writes).toEqual([{ path: "/tmp/veasel-cfg/veasel/tui-theme", data: "aurora" }])
  })

  test("formats a selectable theme list with the active marker", () => {
    const text = formatThemeList("mint")
    expect(text).toContain("Active: Mint (mint)")
    expect(text).toContain("● mint  Mint")
    expect(text).toContain("○ ember  Ember")
    expect(text).toContain("/theme <id>")
    expect(text).toContain("preview colors live")
  })

  test("reads a theme id from a /theme suggestion", () => {
    expect(themeIdFromSlashSuggestion("/theme ember")).toBe("ember")
    expect(themeIdFromSlashSuggestion("/theme AURORA")).toBe("aurora")
    expect(themeIdFromSlashSuggestion("/theme")).toBeUndefined()
    expect(themeIdFromSlashSuggestion("/theme neon")).toBeUndefined()
    expect(themeIdFromSlashSuggestion("/themes ember")).toBeUndefined()
  })

  test("formats a preview status that names the saved theme", () => {
    expect(formatThemePreviewStatus("ember", "mint")).toBe(
      "● preview Ember  ·  Enter keeps · Esc restores Mint",
    )
    expect(formatThemePreviewStatus("mint", "mint")).toBe("● theme Mint  ·  saved")
  })
})
