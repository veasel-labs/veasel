// Loopback-only Veasel HTTP client shared by the Solid terminal entry.
// Safety checks match the retired imperative shell: unauthenticated loopback only.

import {
  admitAssistantDelta,
  appendStreamingDelta,
  isAssistantDeltaEvent,
  parseSseBlock,
} from "./stream-events"
import { mergeChatTurns, type ChatTurn } from "./chat-history"

export type ApiSession = {
  id: string
  title: string
  directory: string
  created_at: string
}

export type ModelProfileView = {
  model: string
  base_url: string
  api_key_saved: boolean
  max_output_tokens: number
}

export type ModelSettingsView = {
  active_provider: string
  profiles: Record<string, ModelProfileView>
  providers: import("./model-providers").ModelProvider[]
  configured_providers?: string[]
}

export type SessionTurnAccepted = {
  operation_id: string
  status: "running"
}

export type SessionTurnCompletion = {
  operation_id?: string
  status?: string
  provider?: string
  model?: string
  error?: string
}

export type SendMessageResult =
  | { kind: "async"; operationId: string }
  | { kind: "sync"; messages: ChatTurn[] }

export type EventHandlers = {
  onAssistantDelta?: (delta: string) => void
  onTurnCompleted?: (sessionId: string, completion: SessionTurnCompletion) => void
  onEvent?: (eventType: string) => void
  onReconnect?: () => void
  onConnected?: () => void
}

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]", "::1"])

/** Resolve VEASEL_API_URL / VEASEL_PORT and reject non-loopback targets. */
export function resolveLoopbackApiBase(
  env: NodeJS.ProcessEnv = process.env,
): string {
  const port = env.VEASEL_PORT ?? "4097"
  const configuredApi = env.VEASEL_API_URL ?? `http://127.0.0.1:${port}`
  const apiUrl = new URL(configuredApi)
  if (
    apiUrl.protocol !== "http:"
    || !LOOPBACK_HOSTS.has(apiUrl.hostname)
    || apiUrl.username !== ""
    || apiUrl.password !== ""
    || apiUrl.pathname !== "/"
    || apiUrl.search !== ""
    || apiUrl.hash !== ""
  ) {
    throw new Error("Veasel TUI only connects to an unauthenticated loopback API")
  }
  return apiUrl.origin
}

export class VeaselApiClient {
  readonly base: string
  private readonly signal: AbortSignal

  constructor(base: string, signal: AbortSignal = new AbortController().signal) {
    this.base = base
    this.signal = signal
  }

  async listSessions(): Promise<ApiSession[]> {
    const response = await fetch(`${this.base}/v1/sessions`, { signal: this.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return await response.json() as ApiSession[]
  }

  async createSession(title: string, directory: string): Promise<ApiSession> {
    const response = await fetch(`${this.base}/v1/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title, directory }),
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSession
  }

  async listMessages(sessionId: string): Promise<ChatTurn[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/messages`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return await response.json() as ChatTurn[]
  }

  async getModelSettings(): Promise<ModelSettingsView> {
    const response = await fetch(`${this.base}/v1/config/model`, { signal: this.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return await response.json() as ModelSettingsView
  }

  async sendMessage(
    sessionId: string,
    content: string,
    operationId: string,
    turnSignal?: AbortSignal,
  ): Promise<SendMessageResult> {
    const signal = turnSignal
      ? AbortSignal.any([this.signal, turnSignal])
      : this.signal
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/messages`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-veasel-operation-id": operationId,
          prefer: "respond-async",
        },
        body: JSON.stringify({ content }),
        signal,
      },
    )
    if (response.status === 202) {
      const accepted = await response.json() as SessionTurnAccepted
      if (accepted.operation_id !== operationId) {
        throw new Error("Server returned a different operation ID")
      }
      return { kind: "async", operationId }
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const messages = await this.listMessages(sessionId)
    return { kind: "sync", messages }
  }

  async cancelOperation(sessionId: string, operationId: string): Promise<void> {
    await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/operations/${encodeURIComponent(operationId)}/cancel`,
      { method: "POST" },
    ).catch(() => undefined)
  }

  /**
   * Long-lived SSE loop. Resolves only when signal aborts.
   * Callers supply active session/turn ids via getters so deltas stay race-safe.
   */
  async consumeEvents(
    handlers: EventHandlers,
    context: {
      activeSessionId: () => string | undefined
      activeTurnId: () => string | undefined
    },
  ): Promise<void> {
    let lastEventId = "0"
    while (!this.signal.aborted) {
      try {
        const response = await fetch(`${this.base}/v1/events`, {
          headers: { "Last-Event-ID": lastEventId, accept: "text/event-stream" },
          signal: this.signal,
        })
        if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`)
        handlers.onConnected?.()
        const reader = response.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ""
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          buffer += decoder.decode(value, { stream: true })
          const blocks = buffer.split(/\r?\n\r?\n/)
          buffer = blocks.pop() ?? ""
          for (const block of blocks) {
            const parsed = parseSseBlock(block)
            if (parsed.id) lastEventId = parsed.id
            const eventType = parsed.event
            if (!eventType || eventType === "heartbeat") continue
            if (!isAssistantDeltaEvent(eventType)) handlers.onEvent?.(eventType)
            if (
              isAssistantDeltaEvent(eventType)
              || eventType === "session.turn_completed"
            ) {
              try {
                const event = JSON.parse(parsed.data) as {
                  session_id?: string
                  data?: SessionTurnCompletion & { delta?: string }
                }
                if (isAssistantDeltaEvent(eventType)) {
                  const delta = admitAssistantDelta({
                    sessionId: event.session_id,
                    activeSessionId: context.activeSessionId(),
                    operationId: event.data?.operation_id,
                    activeTurnId: context.activeTurnId(),
                    delta: event.data?.delta,
                  })
                  if (delta) handlers.onAssistantDelta?.(delta)
                } else if (eventType === "session.turn_completed" && event.session_id) {
                  handlers.onTurnCompleted?.(event.session_id, event.data ?? {})
                }
              } catch {
                // Malformed payloads are ignored; persisted history stays authoritative.
              }
            }
          }
        }
        if (!this.signal.aborted) {
          handlers.onReconnect?.()
          await sleep(1200, this.signal)
        }
      } catch {
        if (this.signal.aborted) return
        handlers.onReconnect?.()
        await sleep(1200, this.signal)
      }
    }
  }
}

export function mergeIncomingMessages(existing: ChatTurn[], incoming: ChatTurn[]): ChatTurn[] {
  return mergeChatTurns(existing, incoming)
}

export { appendStreamingDelta }

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve()
      return
    }
    const timer = setTimeout(resolve, ms)
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer)
        resolve()
      },
      { once: true },
    )
  })
}
