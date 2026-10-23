// Loopback-only Veasel HTTP client shared by the Solid terminal entry.
// Safety checks match the retired imperative shell: unauthenticated loopback only.

import {
  admitAssistantDelta,
  appendStreamingDelta,
  isAssistantDeltaEvent,
  parseSseBlock,
} from "./stream-events"
import { mergeChatTurns, type ChatTurn } from "./chat-history"
import type { WorkspaceRepositoryMap } from "./repository-map"

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

export type ApiSessionOperation = {
  id: string
  session_id: string
  status: "queued" | "running" | "cancelling" | "completed" | "failed" | "cancelled" | "uncertain" | string
  provider: string
  model: string
  error: string
  input_tokens?: number
  output_tokens?: number
  usage_reported?: boolean
  cache_read_tokens?: number
  cache_creation_tokens?: number
  cache_reported?: boolean
  reasoning_tokens?: number
  reasoning_reported?: boolean
  created_at: string
  updated_at: string
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

export type ApiGlobalUsageSummary = {
  sessions: number
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

export type ApiPluginLink = {
  name: string
  path: string
  version?: string
  description?: string
  display_name?: string
  skill_count?: number
  mcp_server_count?: number
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

export type ApiReviewSandboxPreview = {
  mode: string
  will_wrap: boolean
  backend: string
  network?: string
}

export type ApiShellCommandStatus =
  | "pending"
  | "running"
  | "succeeded"
  | "failed"
  | "timed_out"
  | "output_limited"
  | "rejected"
  | "uncertain"

export type ApiShellCommandSummary = {
  id: string
  command: string
  cwd: string
  timeout_seconds: number
  status: ApiShellCommandStatus
  exit_code?: number
  output?: string
  created_at?: string
  updated_at?: string
  sandbox?: ApiReviewSandboxPreview
}

export type ApiMcpToolCallStatus =
  | "pending"
  | "approved"
  | "running"
  | "completed"
  | "rejected"
  | "failed"
  | "cancelled"
  | "uncertain"

export type ApiMcpToolCallSummary = {
  id: string
  operation_id: string
  plugin_name: string
  server_name: string
  tool_name: string
  arguments_bytes?: number
  status: ApiMcpToolCallStatus
  reviewed_at?: string
  created_at?: string
  updated_at?: string
  stdio_sandbox?: ApiReviewSandboxPreview
}

export type ApiMcpToolCallApproval = ApiMcpToolCallSummary & {
  arguments_json: string
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

  async renameSession(sessionId: string, title: string): Promise<ApiSession> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}`,
      {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ title }),
        signal: this.signal,
      },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSession
  }

  async forkSession(sessionId: string): Promise<ApiSession> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/fork`,
      { method: "POST", signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSession
  }

  async deleteSession(sessionId: string): Promise<{ deleted: string }> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}`,
      { method: "DELETE", signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { deleted: string }
  }

  async listMessages(
    sessionId: string,
    options?: { before?: number | string; limit?: number },
  ): Promise<ChatTurn[]> {
    const params = new URLSearchParams()
    if (options?.before !== undefined) params.set("before", String(options.before))
    if (options?.limit !== undefined) params.set("limit", String(options.limit))
    const query = params.size > 0 ? `?${params}` : ""
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/messages${query}`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return await response.json() as ChatTurn[]
  }

  async getHealth(): Promise<{ healthy: boolean; version: string }> {
    const response = await fetch(`${this.base}/v1/health`, { signal: this.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { healthy: boolean; version: string }
  }

  async getModelSettings(): Promise<ModelSettingsView> {
    const response = await fetch(`${this.base}/v1/config/model`, { signal: this.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return await response.json() as ModelSettingsView
  }

  async updateModelSettings(input: {
    provider: string
    model: string
    base_url?: string
    api_key?: string
    clear_api_key?: boolean
    max_output_tokens?: number
  }): Promise<ModelSettingsView> {
    const response = await fetch(`${this.base}/v1/config/model`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(input),
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ModelSettingsView
  }

  async listProviderModels(provider: string): Promise<{
    provider: string
    models: import("./model-providers").ModelCatalogEntry[]
  }> {
    const query = new URLSearchParams({ provider })
    const response = await fetch(`${this.base}/v1/config/models?${query}`, {
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as {
      provider: string
      models: import("./model-providers").ModelCatalogEntry[]
    }
  }

  /** Discover models with optional in-body credentials (not persisted by this call). */
  async discoverProviderModels(input: {
    provider: string
    base_url?: string
    api_key?: string
    clear_api_key?: boolean
  }): Promise<{
    provider: string
    models: import("./model-providers").ModelCatalogEntry[]
  }> {
    const response = await fetch(`${this.base}/v1/config/models`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(input),
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as {
      provider: string
      models: import("./model-providers").ModelCatalogEntry[]
    }
  }

  async getUsage(): Promise<ApiGlobalUsageSummary> {
    const response = await fetch(`${this.base}/v1/usage`, {
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiGlobalUsageSummary
  }

  async getSessionUsage(sessionId: string): Promise<ApiSessionUsageSummary> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/usage`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSessionUsageSummary
  }

  async listSessionOperations(sessionId: string): Promise<ApiSessionOperation[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/operations`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSessionOperation[]
  }

  async listSessionMcpServers(sessionId: string): Promise<ApiSessionPluginMcpServer[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/mcp-servers`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiSessionPluginMcpServer[]
  }

  async setSessionMcpServerTrust(
    sessionId: string,
    pluginName: string,
    serverName: string,
    trusted: boolean,
  ): Promise<ApiSessionPluginMcpServer[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/mcp-servers`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ plugin_name: pluginName, server_name: serverName, trusted }),
        signal: this.signal,
      },
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

  async addConfiguredMcpServer(input: {
    name: string
    transport: "stdio" | "streamable-http"
    command?: string
    args?: string[]
    url?: string
    scope: "user" | "project"
    directory?: string
  }): Promise<{ name: string; transport: string; scope?: string }> {
    const response = await fetch(`${this.base}/v1/mcp-servers`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...input, enabled: true }),
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { name: string; transport: string; scope?: string }
  }

  async updateConfiguredMcpServer(name: string, input: {
    enabled: boolean
    scope: "user" | "project"
    directory?: string
  }): Promise<{ name: string; enabled: boolean }> {
    const query = new URLSearchParams()
    if (input.scope === "project") {
      query.set("scope", "project")
      if (input.directory) query.set("directory", input.directory)
    }
    const suffix = query.size ? `?${query}` : ""
    const response = await fetch(`${this.base}/v1/mcp-servers/${encodeURIComponent(name)}${suffix}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: input.enabled }),
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { name: string; enabled: boolean }
  }

  async removeConfiguredMcpServer(name: string, scope: "user" | "project", directory?: string): Promise<void> {
    const query = new URLSearchParams()
    if (scope === "project") {
      query.set("scope", "project")
      if (directory) query.set("directory", directory)
    }
    const suffix = query.size ? `?${query}` : ""
    const response = await fetch(`${this.base}/v1/mcp-servers/${encodeURIComponent(name)}${suffix}`, {
      method: "DELETE",
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
  }

  async listPlugins(directory: string): Promise<{
    plugins: Array<{
      name: string
      skills: Array<{ name: string; description: string; source?: string; scope?: string }>
    }>
  }> {
    const query = new URLSearchParams({ directory })
    const response = await fetch(`${this.base}/v1/plugins?${query}`, { signal: this.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as {
      plugins: Array<{
        name: string
        skills: Array<{ name: string; description: string; source?: string; scope?: string }>
      }>
    }
  }

  async listPluginLinks(): Promise<{
    links: ApiPluginLink[]
    diagnostics?: Array<{ component: string; message: string }>
  }> {
    const response = await fetch(`${this.base}/v1/plugins/links`, { signal: this.signal })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as {
      links: ApiPluginLink[]
      diagnostics?: Array<{ component: string; message: string }>
    }
  }

  async addPluginLink(path: string, replace = false): Promise<ApiPluginLink> {
    const response = await fetch(`${this.base}/v1/plugins/links`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path, replace }),
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiPluginLink
  }

  async removePluginLink(name: string): Promise<void> {
    const response = await fetch(`${this.base}/v1/plugins/links/${encodeURIComponent(name)}`, {
      method: "DELETE",
      signal: this.signal,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
  }

  async getWorkspaceMap(sessionId: string, hint = ""): Promise<WorkspaceRepositoryMap> {
    const query = hint.trim().length > 0 ? `?hint=${encodeURIComponent(hint.trim())}` : ""
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/map${query}`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as WorkspaceRepositoryMap
  }

  async listSessionSkills(sessionId: string): Promise<Array<{ plugin_name: string; skill_name: string }>> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/skills`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as Array<{ plugin_name: string; skill_name: string }>
  }

  async setSessionSkill(
    sessionId: string,
    pluginName: string,
    skillName: string,
    enabled: boolean,
  ): Promise<Array<{ plugin_name: string; skill_name: string }>> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/skills`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ plugin_name: pluginName, skill_name: skillName, enabled }),
        signal: this.signal,
      },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as Array<{ plugin_name: string; skill_name: string }>
  }

  async invokeSessionSkill(
    sessionId: string,
    pluginName: string,
    skillName: string,
  ): Promise<{ plugin_name: string; skill_name: string; pending: Array<{ plugin_name: string; skill_name: string }> }> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/skills/invoke`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ plugin_name: pluginName, skill_name: skillName }),
        signal: this.signal,
      },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as {
      plugin_name: string
      skill_name: string
      pending: Array<{ plugin_name: string; skill_name: string }>
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

  async decideWorkspaceEdit(
    sessionId: string,
    editId: string,
    decision: "approve" | "reject",
  ): Promise<{ id: string; status: string }> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/edits/${encodeURIComponent(editId)}/${decision}`,
      { method: "POST", signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { id: string; status: string }
  }

  async listWorkspaceCommands(sessionId: string): Promise<ApiShellCommandSummary[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/commands`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiShellCommandSummary[]
  }

  async getWorkspaceCommand(
    sessionId: string,
    commandId: string,
  ): Promise<ApiShellCommandSummary> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/commands/${encodeURIComponent(commandId)}`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiShellCommandSummary
  }

  async decideWorkspaceCommand(
    sessionId: string,
    commandId: string,
    decision: "approve" | "reject",
  ): Promise<{ id: string; status: string }> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/workspace/commands/${encodeURIComponent(commandId)}/${decision}`,
      { method: "POST", signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { id: string; status: string }
  }

  async listMcpToolCalls(sessionId: string): Promise<ApiMcpToolCallSummary[]> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/mcp-tool-calls`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiMcpToolCallSummary[]
  }

  async getMcpToolCall(sessionId: string, callId: string): Promise<ApiMcpToolCallApproval> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/mcp-tool-calls/${encodeURIComponent(callId)}`,
      { signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as ApiMcpToolCallApproval
  }

  async decideMcpToolCall(
    sessionId: string,
    callId: string,
    decision: "approve" | "reject",
  ): Promise<{ id: string; status: string }> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/mcp-tool-calls/${encodeURIComponent(callId)}/${decision}`,
      { method: "POST", signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    return await response.json() as { id: string; status: string }
  }

  async sendMessage(
    sessionId: string,
    content: string,
    operationId: string,
    turnSignal?: AbortSignal,
    executionPolicy?: string,
  ): Promise<SendMessageResult> {
    const signal = turnSignal
      ? AbortSignal.any([this.signal, turnSignal])
      : this.signal
    const body: { content: string; execution_policy?: string } = { content }
    if (executionPolicy && executionPolicy !== "ask") {
      body.execution_policy = executionPolicy
    }
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/messages`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-veasel-operation-id": operationId,
          prefer: "respond-async",
        },
        body: JSON.stringify(body),
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

  async cancelOperation(sessionId: string, operationId: string): Promise<SessionTurnCompletion> {
    const response = await fetch(
      `${this.base}/v1/sessions/${encodeURIComponent(sessionId)}/operations/${encodeURIComponent(operationId)}/cancel`,
      { method: "POST", signal: this.signal },
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`)
    const result = await response.json() as SessionTurnCompletion
    if (result.operation_id !== operationId
      || !["cancelling", "completed", "failed", "cancelled", "uncertain"].includes(result.status ?? "")) {
      throw new Error("Invalid cancellation response")
    }
    return result
  }

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
