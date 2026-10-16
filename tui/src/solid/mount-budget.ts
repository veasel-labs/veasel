import type { TranscriptBlock } from "./activity-group"

/**
 * Tail-first transcript mounting (OpenCode mount-budget pattern, Veasel blocks).
 * A collapsed activity group costs 1; an expanded group costs 1 + item count;
 * a message block costs 1.
 */
export const transcriptTailBudget = 40
export const transcriptBackfillChunk = 60

export function blockMountWeight(
  block: TranscriptBlock,
  expanded: (groupId: string) => boolean,
): number {
  if (block.type !== "activity") return 1
  if (!expanded(block.id)) return 1
  return 1 + block.items.length
}

/** First index such that blocks [index, end) spend at least `budget`. */
export function blocksBefore(weights: readonly number[], end: number, budget: number): number {
  let index = Math.min(Math.max(0, end), weights.length)
  let spent = 0
  while (index > 0 && spent < budget) {
    index -= 1
    spent += weights[index] ?? 0
  }
  return index
}

/** End index such that blocks [start, index) spend at least `budget`. */
export function blocksAfter(weights: readonly number[], start: number, budget: number): number {
  let index = Math.min(Math.max(0, start), weights.length)
  let spent = 0
  while (index < weights.length && spent < budget) {
    spent += weights[index] ?? 0
    index += 1
  }
  return index
}

export type MountWindow = {
  start: number
  end: number
  truncatedAbove: boolean
  truncatedBelow: boolean
  hiddenAbove: number
}

/** Visible slice for the current mount window. */
export function windowBlocks<T>(
  blocks: readonly T[],
  start: number,
  end: number,
): { visible: T[]; window: MountWindow } {
  const safeStart = Math.min(Math.max(0, start), blocks.length)
  const safeEnd = Math.min(Math.max(safeStart, end), blocks.length)
  return {
    visible: blocks.slice(safeStart, safeEnd) as T[],
    window: {
      start: safeStart,
      end: safeEnd,
      truncatedAbove: safeStart > 0,
      truncatedBelow: safeEnd < blocks.length,
      hiddenAbove: safeStart,
    },
  }
}

export function mountCueAbove(hiddenAbove: number): string {
  if (hiddenAbove <= 0) return ""
  const noun = hiddenAbove === 1 ? "block" : "blocks"
  return `▲ ${hiddenAbove} earlier ${noun} · scroll up to load`
}
