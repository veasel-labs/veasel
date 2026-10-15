// Readline-style composer edits. Keep Esc free for leave-after-cancel.

// Ctrl+W / Alt+Backspace: delete the word before the cursor (and any spaces
// immediately before that word). Cursor at the start is a no-op. Cursor
// offsets match OpenTUI InputRenderable.cursorOffset (JS string indices).
export function killWordBackward(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  const pos = Math.min(Math.max(0, cursor), value.length)
  if (pos === 0) return { value, cursor: 0 }
  let end = pos
  while (end > 0 && /\s/.test(value[end - 1]!)) end -= 1
  let start = end
  while (start > 0 && !/\s/.test(value[start - 1]!)) start -= 1
  return {
    value: value.slice(0, start) + value.slice(pos),
    cursor: start,
  }
}

// Ctrl+A / Ctrl+E: jump to the start or end of the draft (readline).
export function composerLineCursor(value: string, where: "home" | "end"): number {
  return where === "home" ? 0 : value.length
}

// Ctrl+K: delete from the cursor to the end of the draft (readline kill-line).
export function killLineForward(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  const pos = Math.min(Math.max(0, cursor), value.length)
  if (pos >= value.length) return { value, cursor: pos }
  return { value: value.slice(0, pos), cursor: pos }
}

// Ctrl+← / Ctrl+→: move by whitespace-delimited words (readline / editor habit).
export function moveWordCursor(
  value: string,
  cursor: number,
  direction: "backward" | "forward",
): number {
  const pos = Math.min(Math.max(0, cursor), value.length)
  if (direction === "backward") {
    if (pos === 0) return 0
    let index = pos
    while (index > 0 && /\s/.test(value[index - 1]!)) index -= 1
    while (index > 0 && !/\s/.test(value[index - 1]!)) index -= 1
    return index
  }
  if (pos >= value.length) return value.length
  let index = pos
  while (index < value.length && !/\s/.test(value[index]!)) index += 1
  while (index < value.length && /\s/.test(value[index]!)) index += 1
  return index
}
