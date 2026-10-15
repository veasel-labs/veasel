import { describe, expect, test } from "bun:test"
import {
  createDiffSyntaxStyle,
  cycleReviewDiffSurface,
  diffRenderableTheme,
  diffSyntaxStyles,
  filetypeFromReviewPath,
  formatPatchSplitChrome,
  reviewDiffSurfaceHint,
  scrollDiffRenderableToHunk,
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

  test("builds a theme-mapped SyntaxStyle for filetype highlighting", () => {
    const styles = diffSyntaxStyles(themes.ember)
    expect(styles.keyword?.fg).toBe(themes.ember.brand)
    expect(styles.comment?.fg).toBe(themes.ember.meta)
    expect(styles.string?.fg).toBe(themes.ember.diffAdd)
    expect(styles.function?.fg).toBe(themes.ember.diffMeta)
    const syntax = createDiffSyntaxStyle(themes.ember)
    expect(syntax.getRegisteredNames()).toContain("keyword")
    expect(syntax.getRegisteredNames()).toContain("comment")
    syntax.destroy()
  })

  test("derives a filetype hint from the review path", () => {
    expect(filetypeFromReviewPath("src/main.v")).toBe("v")
    expect(filetypeFromReviewPath("tui/src/main.ts")).toBe("typescript")
    expect(filetypeFromReviewPath("app.tsx")).toBe("tsx")
    expect(filetypeFromReviewPath("script.sh")).toBe("bash")
    expect(filetypeFromReviewPath("Cargo.toml")).toBe("toml")
    expect(filetypeFromReviewPath("README")).toBeUndefined()
  })

  test("scrolls both DiffRenderable sides to the chosen hunk row", () => {
    const left = { scrollY: 0 }
    const right = { scrollY: 0 }
    const cleared: string[] = []
    const highlights: Array<[number, number, string]> = []
    const row = scrollDiffRenderableToHunk(
      {
        getHunkRowOffsets: () => [0, 12, 40],
        leftCodeRenderable: left,
        rightCodeRenderable: right,
        clearAllLineColors: () => {
          cleared.push("clear")
        },
        highlightLines: (start, end, color) => {
          highlights.push([start, end, color])
        },
      },
      1,
      { accent: "#9af7c9" },
    )
    expect(row).toBe(12)
    expect(left.scrollY).toBe(12)
    expect(right.scrollY).toBe(12)
    expect(cleared).toEqual(["clear"])
    expect(highlights).toEqual([[12, 39, "#9af7c9"]])
  })

  test("formats split-view chrome without embedding the unified diff body", () => {
    const chrome = formatPatchSplitChrome({
      status: "pending",
      path: "src/main.v",
      additions: 29,
      removals: 3,
      hunkCount: 2,
      hunkIndex: 1,
      pendingInstruction: "After inspecting the diff, type /patch approve id.",
    })
    expect(chrome).toContain("OpenTUI split")
    expect(chrome).toContain("29 added, 3 removed")
    expect(chrome).toContain("Hunk 2 of 2")
    expect(chrome).toContain("Press v for word-diff segments")
    expect(chrome).not.toContain("diff --git")
    expect(chrome).toContain("/patch approve")
    expect(chrome.indexOf("29 added")).toBeLessThan(chrome.indexOf("\n"))
  })
})
