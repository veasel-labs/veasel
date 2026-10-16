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

/** Git worktree row from GET /v1/sessions/{id}/workspace/git/worktrees. */
export type ApiGitWorktree = {
  path: string
  head?: string
  branch?: string
  locked: boolean
  missing: boolean
  is_main: boolean
}

export type ApiGitWorktreeCatalog = {
  worktrees: ApiGitWorktree[]
}

export type AddGitWorktreeInput = {
  path: string
  branch?: string
  new_branch?: string
}

export type ApiWorkspaceEditStatus =
  | "pending"
  | "applying"
  | "applied"
  | "rejected"
  | "conflict"
  | "interrupted"

export type ApiSessionUsageSummary = {
  session_id: string
  completed_turns: number
  reported_turns: number
  input_tokens: number
  output_tokens: number
  usage_reported: boolean
  cache_read_tokens: number
  cache_creation_tokens: number
  cache_reported: boolean
  reasoning_tokens: number
  reasoning_reported: boolean
  cost: string
}

export type ApiSessionPluginMcpServer = {
  plugin_name: string
  server_name: string
}

export type ApiWorkspaceEditSummary = {
  id: string
  path: string
  status: ApiWorkspaceEditStatus
  created_at?: string
  updated_at?: string
}

export type ApiWorkspaceEditProposal = ApiWorkspaceEditSummary & {
  session_id?: string
  diff: string
}

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

  async getSessionUsage(sessionId: string): Promise<ApiSessionUsageSummary> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/usage`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSessionUsageSummary
  }

  async listSessionMcpServers(sessionId: string): Promise<ApiSessionPluginMcpServer[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/mcp-servers`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSessionPluginMcpServer[]
  }

  async listConfiguredMcpServers(directory: string): Promise<{
    servers: Array<{
      name: string
      scope?: string
      enabled: boolean
      transport: string
      command?: string
      url_origin?: string
    }>
  }> {
    const query = new URLSearchParams({ directory })
    const response = await fetch(`${this.base}/v1/mcp-servers?${query}`, {
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as {
      servers: Array<{
        name: string
        scope?: string
        enabled: boolean
        transport: string
        command?: string
        url_origin?: string
      }>
    }
  }

  async listGitWorktrees(sessionId: string): Promise<ApiGitWorktreeCatalog> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/git/worktrees`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiGitWorktreeCatalog
  }

  async addGitWorktree(
    sessionId: string,
    input: AddGitWorktreeInput,
  ): Promise<ApiGitWorktree> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/git/worktrees`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(input),
        signal: this.signal,
      },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiGitWorktree
  }

  async listWorkspaceEdits(sessionId: string): Promise<ApiWorkspaceEditSummary[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/edits`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiWorkspaceEditSummary[]
  }

  async getWorkspaceEdit(sessionId: string, editId: string): Promise<ApiWorkspaceEditProposal> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/edits/${encodeURIComponent(editId)}`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiWorkspaceEditProposal
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
