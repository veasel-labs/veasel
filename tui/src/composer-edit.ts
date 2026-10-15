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

// Alt+D: delete from the cursor through the current or next word (readline
// kill-word). When the cursor sits on a word, only that word is removed; when
// it sits on whitespace, the spaces and the following word go together.
export function killWordForward(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  const pos = Math.min(Math.max(0, cursor), value.length)
  if (pos >= value.length) return { value, cursor: pos }
  let end = pos
  if (!/\s/.test(value[end]!)) {
    while (end < value.length && !/\s/.test(value[end]!)) end += 1
  } else {
    while (end < value.length && /\s/.test(value[end]!)) end += 1
    while (end < value.length && !/\s/.test(value[end]!)) end += 1
  }
  return {
    value: value.slice(0, pos) + value.slice(end),
    cursor: pos,
  }
}

function nextWordSpan(value: string, cursor: number): { start: number; end: number } | undefined {
  let pos = Math.min(Math.max(0, cursor), value.length)
  while (pos < value.length && /\s/.test(value[pos]!)) pos += 1
  if (pos >= value.length) return undefined
  let end = pos
  while (end < value.length && !/\s/.test(value[end]!)) end += 1
  return { start: pos, end }
}

// Alt+C: capitalize the current or next word and move past it (readline
// capitalize-word). Leading whitespace is skipped; the first letter is uppercased
// and the rest of that word is left unchanged.
export function capitalizeWord(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  const span = nextWordSpan(value, cursor)
  if (!span) {
    const pos = Math.min(Math.max(0, cursor), value.length)
    return { value, cursor: pos }
  }
  const word = value.slice(span.start, span.end)
  const capped = word.slice(0, 1).toUpperCase() + word.slice(1)
  return {
    value: value.slice(0, span.start) + capped + value.slice(span.end),
    cursor: span.end,
  }
}

// Alt+U: uppercase the current or next word and move past it (readline
// upcase-word).
export function upcaseWord(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  const span = nextWordSpan(value, cursor)
  if (!span) {
    const pos = Math.min(Math.max(0, cursor), value.length)
    return { value, cursor: pos }
  }
  const word = value.slice(span.start, span.end).toUpperCase()
  return {
    value: value.slice(0, span.start) + word + value.slice(span.end),
    cursor: span.end,
  }
}

// Alt+L: lowercase the current or next word and move past it (readline
// downcase-word).
export function downcaseWord(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  const span = nextWordSpan(value, cursor)
  if (!span) {
    const pos = Math.min(Math.max(0, cursor), value.length)
    return { value, cursor: pos }
  }
  const word = value.slice(span.start, span.end).toLowerCase()
  return {
    value: value.slice(0, span.start) + word + value.slice(span.end),
    cursor: span.end,
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

// Ctrl+T: transpose the character before the cursor with the one at the cursor
// (readline transpose-chars). At the end of the draft, swap the last two
// characters. At the start, or with fewer than two characters, this is a no-op.
export function transposeChars(
  value: string,
  cursor: number,
): { value: string; cursor: number } {
  if (value.length < 2) {
    return { value, cursor: Math.min(Math.max(0, cursor), value.length) }
  }
  const pos = Math.min(Math.max(0, cursor), value.length)
  if (pos === 0) return { value, cursor: 0 }
  if (pos === value.length) {
    return {
      value: value.slice(0, -2) + value[value.length - 1]! + value[value.length - 2]!,
      cursor: value.length,
    }
  }
  return {
    value: value.slice(0, pos - 1) + value[pos]! + value[pos - 1]! + value.slice(pos + 1),
    cursor: pos + 1,
  }
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
