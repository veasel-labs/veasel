import { describe, expect, test } from "bun:test"
import {
  clearCustomThemes,
  defaultThemeId,
  ensureThemeDirs,
  formatThemeList,
  formatThemeLoadStatusHint,
  formatThemeOpenNotice,
  formatThemePreviewStatus,
  formatThemeReloadStatus,
  isThemeActionId,
  isThemeId,
  listThemeChoices,
  loadCustomThemes,
  loadThemeId,
  parseThemeJson,
  resolveTheme,
  saveThemeId,
  themeConfigPath,
  themeIdFromSlashSuggestion,
  themeThemesDir,
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
    expect(text).toContain("/theme reload")
    expect(text).toContain("/theme open")
    expect(text).toContain("preview colors live")
  })

  test("lists reload and open ahead of theme ids in slash choices", () => {
    clearCustomThemes()
    const choices = listThemeChoices()
    expect(choices.slice(0, 2).map((item) => item.value)).toEqual(["reload", "open"])
    expect(choices.some((item) => item.value === "mint")).toBe(true)
    expect(isThemeActionId("reload")).toBe(true)
    expect(isThemeActionId("open")).toBe(true)
    expect(isThemeActionId("mint")).toBe(false)
    expect(formatThemeReloadStatus(1, 0)).toBe("● ok  ·  reloaded 1 custom theme  ·  /theme")
    expect(formatThemeReloadStatus(0, 2)).toBe("▲ attention  ·  reloaded 0 custom themes  ·  2 JSON errors  ·  /theme")
  })

  test("creates missing theme directories for /theme open", () => {
    const created: string[] = []
    const result = ensureThemeDirs({
      env: { XDG_CONFIG_HOME: "/tmp/veasel-open-cfg" },
      home: "/tmp/veasel-open-home",
      projectDir: "/tmp/veasel-open-project",
      existsDir: () => false,
      mkdir: (path) => {
        created.push(path)
      },
    })
    expect(result.userDir).toBe("/tmp/veasel-open-cfg/veasel/themes")
    expect(result.workspaceDir).toBe("/tmp/veasel-open-project/.veasel/themes")
    expect(created).toEqual([
      "/tmp/veasel-open-cfg/veasel/themes",
      "/tmp/veasel-open-project/.veasel/themes",
    ])
    const notice = formatThemeOpenNotice(result, "/tmp/veasel-open-home")
    expect(notice).toContain("THEME DIRECTORIES")
    expect(notice).toContain("/theme reload")
    expect(notice).toContain("Created:")
  })

  test("lists custom theme directories and surfaces JSON errors", () => {
    const text = formatThemeList("mint", {
      home: "/home/dev",
      scans: [
        { path: "/home/dev/.config/veasel/themes", label: "user", present: false, files: [] },
        {
          path: "/tmp/proj/.veasel/themes",
          label: "workspace",
          present: true,
          files: ["ocean.json", "broken.json"],
        },
      ],
      errors: ["/tmp/proj/.veasel/themes/broken.json: invalid JSON"],
    })
    expect(text).toContain("Custom theme directories:")
    expect(text).toContain("~/.config/veasel/themes  (user, missing — create to add JSON)")
    expect(text).toContain("/tmp/proj/.veasel/themes  (workspace, ocean.json, broken.json)")
    expect(text).toContain("Theme JSON errors (1):")
    expect(text).toContain("✖ /tmp/proj/.veasel/themes/broken.json: invalid JSON")
    expect(formatThemeLoadStatusHint(["a"])).toBe("1 theme JSON error · /theme")
    expect(formatThemeLoadStatusHint(["a", "b"])).toBe("2 theme JSON errors · /theme")
    expect(formatThemeLoadStatusHint([])).toBeUndefined()
  })

  test("reads a theme id from a /theme suggestion", () => {
    expect(themeIdFromSlashSuggestion("/theme ember")).toBe("ember")
    expect(themeIdFromSlashSuggestion("/theme AURORA")).toBe("aurora")
    expect(themeIdFromSlashSuggestion("/theme")).toBeUndefined()
    expect(themeIdFromSlashSuggestion("/theme neon")).toBeUndefined()
    expect(themeIdFromSlashSuggestion("/theme reload")).toBeUndefined()
    expect(themeIdFromSlashSuggestion("/theme open")).toBeUndefined()
    expect(themeIdFromSlashSuggestion("/themes ember")).toBeUndefined()
  })

  test("formats a preview status that names the saved theme", () => {
    expect(formatThemePreviewStatus("ember", "mint")).toBe(
      "▲ attention  ·  preview Ember  ·  Enter keeps · Esc restores Mint",
    )
    expect(formatThemePreviewStatus("mint", "mint")).toBe("● ok  ·  theme Mint  ·  saved")
  })

  test("parses custom theme JSON that extends a builtin", () => {
    clearCustomThemes()
    const parsed = parseThemeJson(
      JSON.stringify({
        id: "ocean",
        name: "Ocean",
        description: "Deep blue workspace",
        extends: "mint",
        brand: "#7dd3fc",
        shellBg: "#0a1628",
      }),
      "ocean.json",
    )
    expect(parsed.error).toBeUndefined()
    expect(parsed.theme?.id).toBe("ocean")
    expect(parsed.theme?.brand).toBe("#7dd3fc")
    expect(parsed.theme?.shellBg).toBe("#0a1628")
    expect(parsed.theme?.panelBg).toBe(themes.mint.panelBg)
  })

  test("rejects custom themes that replace builtins or use bad colors", () => {
    expect(parseThemeJson(JSON.stringify({ id: "mint", name: "Nope" }), "bad.json").error).toContain("builtin")
    expect(parseThemeJson(JSON.stringify({ id: "reload", name: "Nope" }), "bad.json").error).toContain("reserved")
    expect(parseThemeJson(JSON.stringify({ id: "open", name: "Nope" }), "bad.json").error).toContain("reserved")
    expect(parseThemeJson(JSON.stringify({ id: "neon", name: "Neon", brand: "mint" }), "bad.json").error).toContain("hex")
    expect(parseThemeJson("{", "bad.json").error).toContain("invalid JSON")
  })

  test("loads custom themes from user and project theme dirs", () => {
    clearCustomThemes()
    const home = "/tmp/veasel-custom-theme-home"
    const env = { XDG_CONFIG_HOME: `${home}/.config` }
    const userDir = themeThemesDir(env, home)
    const projectDir = "/tmp/veasel-project"
    const files = new Map<string, string>([
      [`${userDir}/ocean.json`, JSON.stringify({
        id: "ocean",
        name: "Ocean",
        extends: "mint",
        brand: "#7dd3fc",
      })],
      [`${projectDir}/.veasel/themes/forest.json`, JSON.stringify({
        id: "forest",
        name: "Forest",
        extends: "ember",
        brand: "#86efac",
      })],
      [`${projectDir}/.veasel/themes/broken.json`, "{not-json"],
    ])
    const result = loadCustomThemes({
      env,
      home,
      projectDir,
      readDir: (path) => {
        if (path === userDir) return ["ocean.json"]
        if (path === `${projectDir}/.veasel/themes`) return ["forest.json", "broken.json"]
        throw new Error(`missing ${path}`)
      },
      readFile: (path) => {
        const raw = files.get(path)
        if (raw === undefined) throw new Error(`missing ${path}`)
        return raw
      },
    })
    expect(result.loaded.map((theme) => theme.id).sort()).toEqual(["forest", "ocean"])
    expect(result.errors.some((error) => error.includes("broken.json"))).toBe(true)
    expect(result.scans).toEqual([
      { path: userDir, label: "user", present: true, files: ["ocean.json"] },
      {
        path: `${projectDir}/.veasel/themes`,
        label: "workspace",
        present: true,
        files: ["broken.json", "forest.json"],
      },
    ])
    expect(isThemeId("ocean")).toBe(true)
    expect(isThemeId("forest")).toBe(true)
    expect(resolveTheme("ocean").brand).toBe("#7dd3fc")
    expect(resolveTheme("forest").brand).toBe("#86efac")
    expect(themeIdFromSlashSuggestion("/theme ocean")).toBe("ocean")
    expect(formatThemeList("ocean", { errors: result.errors, scans: result.scans, home })).toContain("(custom)")
    expect(formatThemeList("ocean", { errors: result.errors, scans: result.scans, home })).toContain("Theme JSON errors")
    clearCustomThemes()
  })
})
