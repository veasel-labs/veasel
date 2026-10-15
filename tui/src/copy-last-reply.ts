// Copy the latest assistant reply for paste outside the TUI. OSC 52 works in
// modern terminals (including the keyboard-exercise PTY) without host tools.

export type CopyableTurn = { role: string; content: string }

export function lastAssistantReply(
  messages: CopyableTurn[],
  streamingText = "",
): string | undefined {
  const streaming = streamingText.trim()
  if (streaming) return streamingText
  for (let index = messages.length - 1; index >= 0; index--) {
    const turn = messages[index]!
    if (turn.role === "assistant" && turn.content.trim().length > 0) return turn.content
  }
  return undefined
}

export function osc52CopySequence(text: string): string {
  const encoded = Buffer.from(text, "utf8").toString("base64")
  return `\x1b]52;c;${encoded}\x07`
}

export function writeClipboardOsc52(text: string, write = process.stdout.write.bind(process.stdout)): boolean {
  try {
    write(osc52CopySequence(text))
    return true
  } catch {
    return false
  }
}

export function copyLastReplyNotice(result: "copied" | "empty" | "failed"): string {
  if (result === "empty") return "No assistant reply to copy yet."
  if (result === "failed") return "Could not copy last reply (clipboard unavailable)."
  return "Copied last reply to the clipboard."
}
