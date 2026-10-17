/** Secret text stays in state; only masks and caret geometry may be rendered. */
export type SecretState = { value: string; cursor: number; anchor: number }
export const secretInputLimit = 16_384

export function secretSelection(state: SecretState): [number, number] {
  return [Math.min(state.cursor, state.anchor), Math.max(state.cursor, state.anchor)]
}

export function replaceSecretSelection(state: SecretState, text: string): SecretState {
  const chars = Array.from(state.value)
  const [start, end] = secretSelection(state)
  const inserted = Array.from(text.replace(/[\x00-\x1f\x7f-\x9f]/g, ""))
  if (chars.length - (end - start) + inserted.length > secretInputLimit) {
    throw new Error(`Credential exceeds ${secretInputLimit} characters; input was not changed.`)
  }
  const value = [...chars.slice(0, start), ...inserted, ...chars.slice(end)].join("")
  const cursor = start + inserted.length
  return { value, cursor, anchor: cursor }
}

export function moveSecretCursor(state: SecretState, target: number, select = false): SecretState {
  const cursor = Math.max(0, Math.min(Array.from(state.value).length, target))
  return { ...state, cursor, anchor: select ? state.anchor : cursor }
}

export function deleteSecret(state: SecretState, backward: boolean): SecretState {
  if (state.cursor !== state.anchor) return replaceSecretSelection(state, "")
  const edge = Math.max(0, Math.min(Array.from(state.value).length, state.cursor + (backward ? -1 : 1)))
  return replaceSecretSelection({ ...state, anchor: edge }, "")
}
