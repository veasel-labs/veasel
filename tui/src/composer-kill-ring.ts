// Minimal readline-style kill ring for the session composer. Alt+Y yanks;
// Ctrl+Y stays OSC-52 last-reply clipboard and must not be stolen.

export type KillRing = {
  entries: string[]
}

const killRingCap = 32

export function emptyKillRing(): KillRing {
  return { entries: [] }
}

export function pushKill(ring: KillRing, text: string): KillRing {
  if (!text) return ring
  const entries = [...ring.entries, text]
  if (entries.length > killRingCap) entries.splice(0, entries.length - killRingCap)
  return { entries }
}

export function latestKill(ring: KillRing): string | undefined {
  if (ring.entries.length === 0) return undefined
  return ring.entries[ring.entries.length - 1]
}

// Insert yanked text at the cursor (does not mutate the ring).
export function yankAtCursor(
  value: string,
  cursor: number,
  text: string,
): { value: string; cursor: number } {
  const pos = Math.min(Math.max(0, cursor), value.length)
  if (!text) return { value, cursor: pos }
  return {
    value: value.slice(0, pos) + text + value.slice(pos),
    cursor: pos + text.length,
  }
}
