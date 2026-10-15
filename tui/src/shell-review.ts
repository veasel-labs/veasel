export type BoundedBlock = {
  text: string
  shownLines: number
  totalLines: number
}

// Leaves the safety warning and the approve instruction on the first screen.
export function shellReviewLineBudget(terminalRows: number): number {
  return Math.max(6, terminalRows - 20)
}

function textLines(text: string): string[] {
  const normalized = text.replace(/\r\n/g, "\n").replace(/\n$/, "")
  if (normalized === "") return []
  return normalized.split("\n")
}

// Keeps the start of a long command or output and says how much was hidden.
export function formatBoundedBlock(text: string, maxLines: number): BoundedBlock {
  const lines = textLines(text)
  if (lines.length === 0) return { text: "", shownLines: 0, totalLines: 0 }
  const limit = Math.max(1, maxLines)
  if (lines.length <= limit) return { text: lines.join("\n"), shownLines: lines.length, totalLines: lines.length }
  const shown = lines.slice(0, limit)
  return {
    text: `Showing ${shown.length} of ${lines.length} lines.\n${shown.join("\n")}`,
    shownLines: shown.length,
    totalLines: lines.length,
  }
}

export function formatShellReview(input: {
  command: string
  cwd: string
  timeoutSeconds: number
  runner: string
  id: string
  pending: boolean
  output: string
  maxLines: number
}): string {
  const command = formatBoundedBlock(input.command, input.maxLines)
  const parts = [
    `CWD: ${input.cwd} · timeout ${input.timeoutSeconds}s`,
    `Runner: ${input.runner} · non-interactive stdin`,
    "Runs as your OS user, inherits its environment, and has filesystem and network access without a sandbox. Review every effect before approval.",
  ]
  if (input.pending) parts.push(`Type /command approve ${input.id} or /command reject ${input.id}.`)
  if (command.text) parts.push(command.text)
  if (!input.pending && input.output) {
    const output = formatBoundedBlock(input.output, input.maxLines)
    if (output.text) parts.push(output.text)
  }
  return parts.join("\n")
}
