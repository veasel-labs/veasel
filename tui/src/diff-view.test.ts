import { describe, expect, test } from "bun:test"
import {
  cycleReviewDiffSurface,
  diffRenderableTheme,
  filetypeFromReviewPath,
  formatPatchSplitChrome,
  reviewDiffSurfaceHint,
} from "./diff-view"
import { themes } from "./themes"

describe("review diff surface", () => {
  test("cycles between word-diff segments and OpenTUI split", () => {
    expect(cycleReviewDiffSurface("segments")).toBe("split")
    expect(cycleReviewDiffSurface("split")).toBe("segments")
    expect(reviewDiffSurfaceHint("segments")).toContain("v split view")
    expect(reviewDiffSurfaceHint("split")).toContain("v word-diff")
  })

  test("maps theme tones onto DiffRenderable colors", () => {
    const colors = diffRenderableTheme(themes.mint)
    expect(colors.addedSignColor).toBe(themes.mint.diffAdd)
    expect(colors.removedSignColor).toBe(themes.mint.diffRemove)
    expect(colors.fg).toBe(themes.mint.body)
    expect(colors.syncScroll).toBe(true)
    expect(colors.wrapMode).toBe("none")
    expect(colors.showLineNumbers).toBe(true)
  })

  test("derives a filetype hint from the review path", () => {
    expect(filetypeFromReviewPath("src/main.v")).toBe("v")
    expect(filetypeFromReviewPath("tui/src/main.ts")).toBe("typescript")
    expect(filetypeFromReviewPath("README")).toBeUndefined()
  })

  test("formats split-view chrome without embedding the unified diff body", () => {
    const chrome = formatPatchSplitChrome({
      status: "pending",
      path: "src/main.v",
      additions: 29,
      removals: 3,
      hunkCount: 2,
      pendingInstruction: "After inspecting the diff, type /patch approve id.",
    })
    expect(chrome).toContain("OpenTUI split")
    expect(chrome).toContain("29 added, 3 removed")
    expect(chrome).toContain("2 hunks")
    expect(chrome).toContain("Press v for word-diff segments")
    expect(chrome).not.toContain("diff --git")
    expect(chrome).toContain("/patch approve")
    expect(chrome.indexOf("29 added")).toBeLessThan(chrome.indexOf("\n"))
  })
})
