// SSE helpers for the session event stream. Keep parsing and delta admission
// pure so multi-event races can be covered without a live renderer.

export type ParsedSseBlock = {
  id?: string
  event?: string
  data: string
}

// One SSE frame → one event. Avoids re-applying the same data when a block
// accidentally contains more than one `event:` line.
export function parseSseBlock(block: string): ParsedSseBlock {
  let id: string | undefined
  let event: string | undefined
  const dataLines: string[] = []
  for (const line of block.split(/\r?\n/)) {
    if (line.startsWith("id:")) id = line.slice(3).trim()
    else if (line.startsWith("event:")) event = line.slice(6).trim()
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).trimStart())
  }
  return { id, event, data: dataLines.join("\n") }
}

export function isAssistantDeltaEvent(event: string | undefined): boolean {
  return event === "assistant.delta"
}

// Admit a delta only when it belongs to the active session turn. Empty or
// mistyped payloads are ignored so races with cancel/leave cannot append junk.
export function admitAssistantDelta(input: {
  sessionId?: string
  activeSessionId?: string
  operationId?: string
  activeTurnId?: string
  delta?: unknown
}): string | undefined {
  if (!input.activeSessionId || !input.activeTurnId) return undefined
  if (input.sessionId !== input.activeSessionId) return undefined
  if (input.operationId !== input.activeTurnId) return undefined
  if (typeof input.delta !== "string" || input.delta.length === 0) return undefined
  return input.delta
}

// Append deltas in arrival order. Callers coalesce rapid frames before render.
export function appendStreamingDelta(current: string, delta: string): string {
  return current + delta
}
