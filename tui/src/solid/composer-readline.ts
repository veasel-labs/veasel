/**
 * Solid composer readline chords — wraps classic pure modules so LiveApp
 * matches ↑/↓ history, kill-ring, and word/line edits without OpenTUI Input bindings.
 */

import {
  capitalizeWord,
  composerLineCursor,
  downcaseWord,
  killLineForward,
  killWordBackward,
  killWordForward,
  moveWordCursor,
  transposeChars,
  upcaseWord,
} from "../composer-edit"
import {
  clearComposerLine,
  emptyComposerHistory,
  rememberComposerEntry,
  stepComposerHistory,
  type ComposerHistory,
} from "../composer-history"
import {
  emptyKillRing,
  latestKill,
  pushKill,
  yankAtCursor,
  type KillRing,
} from "../composer-kill-ring"

export type ComposerReadlineState = {
  history: ComposerHistory
  killRing: KillRing
  value: string
  cursor: number
}

export type ComposerReadlineKey = {
  name?: string
  ctrl?: boolean
  meta?: boolean
  shift?: boolean
  sequence?: string
}

export type ComposerReadlineResult =
  | { kind: "ignore" }
  | {
      kind: "apply"
      state: ComposerReadlineState
    }

export function emptyComposerReadlineState(): ComposerReadlineState {
  return {
    history: emptyComposerHistory(),
    killRing: emptyKillRing(),
    value: "",
    cursor: 0,
  }
}

export function rememberReadlineSubmit(
  state: ComposerReadlineState,
  submitted: string,
): ComposerReadlineState {
  return {
    ...state,
    history: rememberComposerEntry(state.history, submitted),
  }
}

function consumeEdit(
  state: ComposerReadlineState,
  next: { value: string; cursor: number; killed?: string },
): ComposerReadlineResult {
  if (next.value === state.value && next.cursor === state.cursor && !next.killed) {
    return { kind: "ignore" }
  }
  let killRing = state.killRing
  if (next.killed) killRing = pushKill(killRing, next.killed)
  return {
    kind: "apply",
    state: {
      ...state,
      value: next.value,
      cursor: next.cursor,
      killRing,
    },
  }
}

/** Resolve a key when autocomplete is closed. */
export function applyComposerReadlineKey(
  state: ComposerReadlineState,
  key: ComposerReadlineKey,
): ComposerReadlineResult {
  const name = key.name
  const seq = key.sequence ?? ""

  if ((key.ctrl && name === "u") || seq === "\x15") {
    if (state.value.length === 0 && state.history.offset === 0) return { kind: "ignore" }
    let killRing = state.killRing
    if (state.value.length > 0) killRing = pushKill(killRing, state.value)
    return {
      kind: "apply",
      state: {
        ...state,
        value: "",
        cursor: 0,
        history: clearComposerLine(state.history),
        killRing,
      },
    }
  }

  if ((key.meta && name === "y") || seq === "\x1by") {
    const killed = latestKill(state.killRing)
    if (!killed) return { kind: "ignore" }
    const yanked = yankAtCursor(state.value, state.cursor, killed)
    return {
      kind: "apply",
      state: { ...state, value: yanked.value, cursor: yanked.cursor },
    }
  }

  if (
    (key.ctrl && name === "w")
    || seq === "\x17"
    || (key.meta && name === "backspace")
    || seq === "\x1b\x7f"
    || seq === "\x1b\b"
  ) {
    return consumeEdit(state, killWordBackward(state.value, state.cursor))
  }

  if ((key.meta && name === "d") || seq === "\x1bd") {
    return consumeEdit(state, killWordForward(state.value, state.cursor))
  }

  if ((key.meta && name === "c") || seq === "\x1bc") {
    return consumeEdit(state, capitalizeWord(state.value, state.cursor))
  }

  if ((key.meta && name === "u") || seq === "\x1bu") {
    return consumeEdit(state, upcaseWord(state.value, state.cursor))
  }

  if ((key.meta && name === "l") || seq === "\x1bl") {
    return consumeEdit(state, downcaseWord(state.value, state.cursor))
  }

  if ((key.ctrl && name === "a") || seq === "\x01") {
    const cursor = composerLineCursor(state.value, "home")
    if (cursor === state.cursor) return { kind: "ignore" }
    return { kind: "apply", state: { ...state, cursor } }
  }

  if ((key.ctrl && name === "e") || seq === "\x05") {
    const cursor = composerLineCursor(state.value, "end")
    if (cursor === state.cursor) return { kind: "ignore" }
    return { kind: "apply", state: { ...state, cursor } }
  }

  if ((key.ctrl && name === "k") || seq === "\x0b") {
    return consumeEdit(state, killLineForward(state.value, state.cursor))
  }

  if ((key.ctrl && name === "t") || seq === "\x14") {
    return consumeEdit(state, transposeChars(state.value, state.cursor))
  }

  const wordLeft =
    (key.ctrl && name === "left")
    || (key.meta && (name === "b" || name === "left"))
    || seq === "\x1bb"
    || seq === "\x1b[1;3D"
    || seq === "\x1b\x1b[D"
  const wordRight =
    (key.ctrl && name === "right")
    || (key.meta && (name === "f" || name === "right"))
    || seq === "\x1bf"
    || seq === "\x1b[1;3C"
    || seq === "\x1b\x1b[C"
  if (wordLeft || wordRight) {
    const cursor = moveWordCursor(
      state.value,
      state.cursor,
      wordLeft ? "backward" : "forward",
    )
    if (cursor === state.cursor) return { kind: "ignore" }
    return { kind: "apply", state: { ...state, cursor } }
  }

  if (name === "up" || name === "down") {
    const stepped = stepComposerHistory(
      state.history,
      name === "up" ? "older" : "newer",
      state.value,
    )
    if (!stepped) return { kind: "ignore" }
    return {
      kind: "apply",
      state: {
        ...state,
        history: stepped.history,
        value: stepped.value,
        cursor: stepped.value.length,
      },
    }
  }

  return { kind: "ignore" }
}
