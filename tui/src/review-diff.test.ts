import { describe, expect, test } from "bun:test"
import { alignWordDiff, formatReviewDiff, reviewDiffLineBudget } from "./review-diff"
import { noticeSegments, transcriptPlainText } from "./transcript"

function sampleDiff(extra = 0): string {
  const lines = [
    "diff --git a/src/main.v b/src/main.v",
    "--- a/src/main.v",
    "+++ b/src/main.v",
    "@@ -1,2 +1,3 @@",
    "-old line",
  ]
  for (let index = 1; index <= extra; index++) lines.push(`+kept line ${String(index).padStart(2, "0")}`)
  lines.push("+TAIL-SENTINEL")
  return `${lines.join("\n")}\n`
}

describe("formatReviewDiff", () => {
  test("counts real changes and ignores file headers", () => {
    const review = formatReviewDiff(sampleDiff(2), 20)
    expect(review.additions).toBe(3)
    expect(review.removals).toBe(1)
    expect(review.text.startsWith("3 added, 1 removed.\n")).toBe(true)
    expect(review.text).toContain("+TAIL-SENTINEL")
    expect(review.shownLines).toBe(review.totalLines)
  })

  test("hides the tail of a diff that is taller than the terminal", () => {
    expect(reviewDiffLineBudget(40)).toBe(22)
    const review = formatReviewDiff(sampleDiff(28), reviewDiffLineBudget(40))
    expect(review.totalLines).toBeGreaterThan(review.shownLines)
    expect(review.text).toContain(`Showing ${review.shownLines} of ${review.totalLines} lines.`)
    expect(review.text).toContain("diff --git a/src/main.v b/src/main.v")
    expect(review.text).not.toContain("TAIL-SENTINEL")
  })

  test("keeps an empty proposal explicit", () => {
    expect(formatReviewDiff(" \n", 10).text).toBe("The proposal has no diff.")
  })

  test("does not tone the summary as an added line", () => {
    const review = formatReviewDiff(sampleDiff(1), 20)
    const segments = noticeSegments(review.text)
    expect(segments[0]).toMatchObject({ tone: "notice" })
    expect(segments.some((segment) => segment.tone === "diffAdd" && segment.text.includes("kept"))).toBe(true)
    expect(segments.some((segment) => segment.tone === "diffRemove" && (segment.text === "-" || segment.text.includes("old")))).toBe(true)
  })
})

describe("alignWordDiff", () => {
  test("marks only the tokens that changed between paired lines", () => {
    const aligned = alignWordDiff("-const answer = 1", "+const answer = 2")
    expect(aligned.removed.map((token) => `${token.kind}:${token.text}`)).toEqual([
      "equal:const",
      "equal: ",
      "equal:answer",
      "equal: ",
      "equal:=",
      "equal: ",
      "change:1",
    ])
    expect(aligned.added.map((token) => `${token.kind}:${token.text}`)).toEqual([
      "equal:const",
      "equal: ",
      "equal:answer",
      "equal: ",
      "equal:=",
      "equal: ",
      "change:2",
    ])
  })

  test("tones only changed tokens in notice segments for paired lines", () => {
    const notice = [
      "REVIEW",
      "src/main.v",
      "@@ -1 +1 @@",
      "-const answer = 1",
      "+const answer = 2",
    ].join("\n")
    const segments = noticeSegments(notice)
    expect(transcriptPlainText(segments)).toBe(`${notice}\n\n`)
    expect(segments).toContainEqual({ text: "1", tone: "diffRemove" })
    expect(segments).toContainEqual({ text: "2", tone: "diffAdd" })
    expect(segments).toContainEqual({ text: "const", tone: "notice" })
    expect(segments).toContainEqual({ text: "answer", tone: "notice" })
  })
})
