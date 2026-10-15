export type ReviewDiff = {
  text: string
  additions: number
  removals: number
  shownLines: number
  totalLines: number
}

export type WordDiffToken = {
  text: string
  // "change" marks tokens that differ between the paired -/+ lines.
  kind: "equal" | "change"
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

export function isHunkChangeLine(line: string): boolean {
  return (line.startsWith("+") && !line.startsWith("+++")) || (line.startsWith("-") && !line.startsWith("---"))
}

export function tokenizeDiffBody(body: string): string[] {
  return body.match(/\s+|[^\s]+/g) ?? []
}

// Pair a removed line with the following added line and mark tokens that differ.
// Equal tokens stay readable without color; changed tokens carry the change kind
// so the renderer can emphasize them (and screen readers still hear the full text).
export function alignWordDiff(removedLine: string, addedLine: string): { removed: WordDiffToken[]; added: WordDiffToken[] } {
  const removedBody = removedLine.startsWith("-") ? removedLine.slice(1) : removedLine
  const addedBody = addedLine.startsWith("+") ? addedLine.slice(1) : addedLine
  const left = tokenizeDiffBody(removedBody)
  const right = tokenizeDiffBody(addedBody)
  const n = left.length
  const m = right.length
  const dp: number[][] = Array.from({ length: n + 1 }, () => Array.from({ length: m + 1 }, () => 0))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i]![j] = left[i] === right[j] ? (dp[i + 1]![j + 1]! + 1) : Math.max(dp[i + 1]![j]!, dp[i]![j + 1]!)
    }
  }
  const removed: WordDiffToken[] = []
  const added: WordDiffToken[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (left[i] === right[j]) {
      removed.push({ text: left[i]!, kind: "equal" })
      added.push({ text: right[j]!, kind: "equal" })
      i++
      j++
      continue
    }
    if (dp[i + 1]![j]! >= dp[i]![j + 1]!) {
      removed.push({ text: left[i]!, kind: "change" })
      i++
    } else {
      added.push({ text: right[j]!, kind: "change" })
      j++
    }
  }
  while (i < n) {
    removed.push({ text: left[i]!, kind: "change" })
    i++
  }
  while (j < m) {
    added.push({ text: right[j]!, kind: "change" })
    j++
  }
  return { removed, added }
}

export function isWordDiffPair(removedLine: string, addedLine: string): boolean {
  return removedLine.startsWith("-") && !removedLine.startsWith("---")
    && addedLine.startsWith("+") && !addedLine.startsWith("+++")
}
