export type ReviewDiff = {
  text: string
  additions: number
  removals: number
  shownLines: number
  totalLines: number
}

// Leaves room for the review title, path, summary, and the approve instruction.
export function reviewDiffLineBudget(terminalRows: number): number {
  return Math.max(8, terminalRows - 18)
}

function changedLines(lines: string[]): { additions: number; removals: number } {
  let additions = 0
  let removals = 0
  for (const line of lines) {
    if (line.startsWith("+") && !line.startsWith("+++")) additions++
    else if (line.startsWith("-") && !line.startsWith("---")) removals++
  }
  return { additions, removals }
}

function diffLines(diff: string): string[] {
  const normalized = diff.replace(/\r\n/g, "\n").replace(/\n$/, "")
  if (normalized.trim() === "") return []
  return normalized.split("\n")
}

// Summarizes a proposal in text and keeps only the first screen of a long diff.
// The + and - markers stay on the visible lines.
export function formatReviewDiff(diff: string, maxLines: number): ReviewDiff {
  const lines = diffLines(diff)
  const { additions, removals } = changedLines(lines)
  if (lines.length === 0) {
    return {
      text: "The proposal has no diff.",
      additions: 0,
      removals: 0,
      shownLines: 0,
      totalLines: 0,
    }
  }
  const limit = Math.max(1, maxLines)
  const shown = lines.slice(0, Math.min(lines.length, limit))
  const summary = shown.length < lines.length
    ? `${additions} added, ${removals} removed. Showing ${shown.length} of ${lines.length} lines.`
    : `${additions} added, ${removals} removed.`
  return {
    text: `${summary}\n${shown.join("\n")}`,
    additions,
    removals,
    shownLines: shown.length,
    totalLines: lines.length,
  }
}
