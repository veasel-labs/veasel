export type BoundedBlock = {
  text: string
  shownLines: number
  totalLines: number
}

export type ApprovedShellSandboxCapability = "bubblewrap" | "seatbelt" | null

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

export function approvedShellSandboxWarning(capability: ApprovedShellSandboxCapability): string {
  if (capability === "bubblewrap") {
    return "On Linux, approval still runs as your OS user inside Bubblewrap: read-only host, writable workspace, sensitive home/runtime mounts hidden, network isolated by default. Inherited environment may still carry credentials. Review every effect before approval."
  }
  if (capability === "seatbelt") {
    return "On macOS, approval still runs as your OS user inside Seatbelt (sandbox-exec): host readable, writes limited to the workspace and temp, home/Volumes reads denied outside the workspace, network isolated by default. Inherited environment may still carry credentials. Review every effect before approval."
  }
  return "Runs as your OS user, inherits its environment, and has filesystem and network access without an OS sandbox (platform sandbox unavailable or VEASEL_SHELL_SANDBOX=off). Review every effect before approval."
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
  sandboxCapability?: ApprovedShellSandboxCapability
  /** @deprecated Prefer sandboxCapability. */
  bubblewrapCapable?: boolean
}): string {
  const capability: ApprovedShellSandboxCapability = input.sandboxCapability
    ?? (input.bubblewrapCapable === true ? "bubblewrap" : null)
  const command = formatBoundedBlock(input.command, input.maxLines)
  const parts = [
    `CWD: ${input.cwd} · timeout ${input.timeoutSeconds}s`,
    `Runner: ${input.runner} · non-interactive stdin`,
    approvedShellSandboxWarning(capability),
  ]
  if (input.pending) parts.push(`Type /command approve ${input.id} or /command reject ${input.id}.`)
  if (command.text) parts.push(command.text)
  if (!input.pending && input.output) {
    const output = formatBoundedBlock(input.output, input.maxLines)
    if (output.text) parts.push(output.text)
  }
  return parts.join("\n")
}
