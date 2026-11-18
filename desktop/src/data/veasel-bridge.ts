/**
 * Focus <-> Veasel bridge (issue #692 step 2, epic #689).
 *
 * Implements the copied Focus `FocusBridge` contract against the canonical
 * Veasel session API (`/v1/sessions`, `/v1/sessions/:id/messages`,
 * `/v1/sessions/:id/cli-approvals`) so the GUI and the TUI share ONE
 * persistent session store — no duplicate engine (ADR-0001 decision 1).
 * The copied components under `gui/focus/` are unmodified; this adapter is
 * the new wiring layer beside them.
 *
 * Honesty rules: usage cost is `null` unless the server reports it; provider
 * install/auth state is `unknown` until a provider-status route exists;
 * approval decisions map onto the durable CLI-approvals API (approve =
 * `allow`, reject = `deny`; `allow-session` is rejected rather than widened).
 */
import type {
  FocusApprovalDecision,
  FocusBridge,
  FocusCreateThreadInput,
  FocusEvent,
  FocusLiveUpdate,
  FocusPermissionMode,
  FocusProviderId,
  FocusThreadProviderId,
  FocusProviderStatus,
  FocusResult,
  FocusThread,
  FocusThreadPatch,
  FocusThreadSnapshot,
  FocusUsage,
} from '../types/focus';

export interface VeaselSession {
  id: string;
  title: string;
  directory: string;
  created_at: string;
  /** Server-persisted choices (epic #689); absent on pre-v31 backends. */
  preferred_provider?: string;
  preferred_model?: string;
  permission_mode?: string;
  /** Optimistic-concurrency token for PATCH /v1/sessions/:id. */
  prefs_version?: number;
  /** Provider/model of the latest completed turn: what actually ran. */
  last_provider?: string;
  last_model?: string;
}

export interface VeaselMessage {
  id?: number;
  role: string;
  content: string;
  created_at?: string;
}

export interface VeaselCliProviderStatus {
  id: string;
  name: string;
  exec: string;
  protocol: string;
  installed: boolean;
  version: string;
  auth_probe_present: boolean;
  auth_state: string;
  permission_modes: string[];
  session_resume_verified: boolean;
  usage_reporting: string;
}

export interface VeaselCliApproval {
  id: string;
  tool_name: string;
  input_json: string;
  status: string;
  created_at?: string;
}

export type FetchLike = (
  input: string,
  init?: RequestInit,
) => Promise<{
  ok: boolean;
  status: number;
  json: () => Promise<unknown>;
}>;

export interface VeaselServerEvent {
  id: number;
  type: string;
  session_id: string;
  created_at?: string;
  data: {
    operation_id?: string;
    delta?: string;
    status?: string;
    error?: string;
    usage_reported?: boolean;
    input_tokens?: number;
    output_tokens?: number;
    cache_read_tokens?: number;
  };
}

/** Subscribe to a server-sent event stream; returns an unsubscribe fn. */
export type EventStreamFactory = (url: string, onEvent: (type: string, data: string) => void) => () => void;

/**
 * Maps one canonical Veasel SSE event to a Focus live update. Deltas are
 * live-only (history still comes from readThread); unknown or heartbeat
 * events map to null — nothing is invented. Turn outcomes map from the
 * recorded status; cost stays null because the event stream never
 * reports it.
 */
export function veaselEventToLiveUpdate(event: VeaselServerEvent): FocusLiveUpdate | null {
  if (!event || typeof event.session_id !== 'string' || event.session_id.length === 0) return null;
  if (event.type === 'assistant.delta') {
    if (!event.data || typeof event.data.delta !== 'string' || event.data.delta.length === 0) return null;
    return {
      kind: 'delta',
      threadId: event.session_id,
      itemId: event.data.operation_id ?? 'assistant',
      channel: 'assistant',
      text: event.data.delta,
    };
  }
  if (event.type === 'session.turn_completed') {
    const status = event.data?.status ?? '';
    const outcome = status === 'completed' ? 'completed' : status === 'failed' ? 'failed' : 'interrupted';
    return {
      kind: 'event',
      threadId: event.session_id,
      event: {
        seq: event.id,
        at: event.created_at ?? '',
        turn: 1,
        type: 'turn.finished',
        outcome,
        detail: event.data?.error ?? null,
        durationMs: null,
        usage: event.data?.usage_reported
          ? {
              inputTokens: event.data.input_tokens ?? 0,
              cachedInputTokens: event.data.cache_read_tokens ?? 0,
              outputTokens: event.data.output_tokens ?? 0,
              costUsd: null,
            }
          : null,
      },
    };
  }
  return null;
}

function defaultEventStream(url: string, onEvent: (type: string, data: string) => void): () => void {
  const EventSourceCtor = (globalThis as { EventSource?: typeof EventSource }).EventSource;
  if (!EventSourceCtor) return () => {};
  const source = new EventSourceCtor(url);
  const types = ['assistant.delta', 'session.turn_completed'];
  const listeners = types.map((type) => {
    const listener = (message: MessageEvent) => onEvent(type, String(message.data ?? ''));
    source.addEventListener(type, listener);
    return { type, listener };
  });
  return () => {
    for (const { type, listener } of listeners) source.removeEventListener(type, listener);
    source.close();
  };
}

const PROVIDER_IDS: FocusProviderId[] = ['claude', 'codex', 'opencode', 'muse'];

const PERMISSION_MODES: FocusPermissionMode[] = ['ask', 'accept-edits', 'plan', 'bypass'];

function toVeaselProviderId(provider: FocusThreadProviderId): string | null {
  if (provider === 'claude') return 'claude-code';
  if (provider === 'codex' || provider === 'opencode' || provider === 'muse') return provider;
  return null;
}

/** Veasel CLI provider ids (`claude-code`, …) collapse to Focus provider ids. */
export function toFocusProviderId(veaselProvider: string | null | undefined): FocusProviderId | 'unknown' {
  if (veaselProvider === 'claude-code' || veaselProvider === 'claude') return 'claude';
  if (veaselProvider === 'codex' || veaselProvider === 'opencode' || veaselProvider === 'muse') return veaselProvider;
  return 'unknown';
}

export function sessionToThread(
  session: VeaselSession,
  options: { provider?: FocusThreadProviderId; turns?: number; usage?: FocusUsage | null } = {},
): FocusThread {
  const cwd = session.directory ?? '';
  const projectName = cwd ? (cwd.split('/').filter(Boolean).pop() ?? null) : null;
  // Choices come from the server session, never from client memory. An unset
  // preference follows the server's global default, so the provider stays the
  // caller's fallback ('unknown' by default) rather than being guessed.
  const preferred = session.preferred_provider ? toFocusProviderId(session.preferred_provider) : null;
  const permissionMode = PERMISSION_MODES.find((mode) => mode === session.permission_mode) ?? 'ask';
  return {
    id: session.id,
    title: session.title || 'Untitled session',
    workspace: cwd,
    projectName,
    cwd,
    provider: preferred ?? options.provider ?? 'unknown',
    model: session.preferred_model ? session.preferred_model : null,
    // The model of the latest completed turn: what actually ran, which may
    // differ from the preference if the preference changed afterwards.
    resolvedModel: session.last_model ? session.last_model : null,
    permissionMode,
    providerSessionId: null,
    status: 'idle',
    createdAt: session.created_at ?? '',
    updatedAt: session.created_at ?? '',
    turns: options.turns ?? 0,
    lastError: null,
    usage: options.usage ?? { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, costUsd: null },
  };
}

/** Messages become the Focus journal: one turn per user message. */
export function messagesToEvents(messages: readonly VeaselMessage[]): FocusEvent[] {
  const events: FocusEvent[] = [];
  let turn = 0;
  let seq = 0;
  for (const message of messages) {
    seq += 1;
    const at = message.created_at ?? '';
    if (message.role === 'user') {
      turn += 1;
      events.push({ seq, at, turn, type: 'user', text: message.content });
    } else if (message.role === 'assistant') {
      events.push({
        seq,
        at,
        turn: Math.max(turn, 1),
        type: 'assistant',
        itemId: `message-${message.id ?? seq}`,
        text: message.content,
      });
    }
  }
  return events;
}

/** A pending durable CLI approval becomes a Focus approval request. */
export function approvalToEvent(approval: VeaselCliApproval, turn = 1, seq = 1): FocusEvent {
  let input: unknown = approval.input_json;
  try {
    input = JSON.parse(approval.input_json);
  } catch {
    // Keep the raw string; never drop the request.
  }
  return {
    seq,
    at: approval.created_at ?? '',
    turn,
    type: 'approval.requested',
    requestId: approval.id,
    itemId: null,
    tool: approval.tool_name,
    kind: approval.tool_name === 'Edit' || approval.tool_name === 'Write' ? 'edit' : 'other',
    title: approval.tool_name,
    input,
    canAllowForSession: false,
  };
}

function asArray<T>(payload: unknown): T[] {
  if (Array.isArray(payload)) return payload as T[];
  if (payload && typeof payload === 'object') {
    const record = payload as Record<string, unknown>;
    for (const key of ['messages', 'sessions', 'approvals', 'items']) {
      if (Array.isArray(record[key])) return record[key] as T[];
    }
  }
  return [];
}

export function createVeaselFocusBridge(options: {
  baseUrl: string;
  fetch?: FetchLike;
  provider?: FocusThreadProviderId;
  createEventStream?: EventStreamFactory;
}): FocusBridge {
  const base = options.baseUrl.replace(/\/$/, '');
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init));
  const provider = options.provider ?? 'unknown';
  async function request<T>(path: string, init?: RequestInit): Promise<T> {
    const response = await doFetch(`${base}${path}`, {
      ...init,
      headers: { 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
    });
    const payload = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    if (!response.ok) {
      throw new Error(typeof payload.error === 'string' ? payload.error : `HTTP ${response.status}`);
    }
    return payload as T;
  }

  function result<T>(fn: () => Promise<T>): Promise<FocusResult<T>> {
    return fn()
      .then((value): FocusResult<T> => ({ ok: true, value }))
      .catch((error: unknown): FocusResult<T> => ({
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      }));
  }

  async function readThreadSnapshot(id: string): Promise<FocusThreadSnapshot | null> {
    const session = await request<VeaselSession>(`/v1/sessions/${encodeURIComponent(id)}`).catch(() => null);
    if (!session || typeof session !== 'object' || !('id' in session)) return null;
    const messages = asArray<VeaselMessage>(
      await request(`/v1/sessions/${encodeURIComponent(id)}/messages`).catch(() => []),
    );
    const events = messagesToEvents(messages);
    const approvals = asArray<VeaselCliApproval>(
      await request(`/v1/sessions/${encodeURIComponent(id)}/cli-approvals`).catch(() => []),
    );
    const turn = Math.max(1, events.filter((event) => event.type === 'user').length);
    approvals
      .filter((approval) => approval.status === 'pending')
      .forEach((approval, index) => events.push(approvalToEvent(approval, turn, events.length + index + 1)));
    const thread = sessionToThread(session as VeaselSession, {
      provider,
      turns: events.filter((event) => event.type === 'user').length,
    });
    if (approvals.some((approval) => approval.status === 'pending')) thread.status = 'awaiting-approval';
    return { thread, events };
  }

  return {
    // Provider facts come from GET /v1/providers/cli. The server probe is
    // presence-only, so a present auth file still maps to Focus 'unknown'
    // (never 'ready' — sign-in is not verified), a missing one to
    // 'signed-out', and any route failure to the honest static fallback.
    async providers(): Promise<FocusProviderStatus[]> {
      const checkedAt = new Date().toISOString();
      const fallback: FocusProviderStatus[] = PROVIDER_IDS.map((id) => ({
        id,
        label: id === 'claude' ? 'Claude Code' : id === 'codex' ? 'Codex' : id === 'muse' ? 'Muse' : 'OpenCode',
        installed: false,
        binary: null,
        version: null,
        auth: 'unknown' as const,
        authDetail: 'Provider status route is unavailable.',
        signInHint: null,
        models: [],
        capabilities: { sessions: true, approvals: true, interrupt: true, resume: true, modelSwitch: false },
        checkedAt,
      }));
      const statuses = await request<VeaselCliProviderStatus[]>('/v1/providers/cli').catch(() => null);
      if (!statuses || !Array.isArray(statuses)) return fallback;
      return fallback.map((base) => {
        const status = statuses.find(
          (entry) => entry.id === base.id || (entry.id === 'claude-code' && base.id === 'claude'),
        );
        if (!status) return base;
        return {
          ...base,
          installed: status.installed,
          binary: status.installed ? status.exec : null,
          version: status.version || null,
          auth: status.auth_state === 'probe-missing' ? ('signed-out' as const) : ('unknown' as const),
          authDetail:
            status.auth_state === 'probe-present'
              ? 'Auth file present; sign-in is not verified by the Veasel API.'
              : status.auth_state === 'probe-missing'
                ? 'No auth file found for this CLI.'
                : 'Auth state is unknown.',
          capabilities: {
            ...base.capabilities,
            // Only wired protocols may claim structured sessions.
            sessions:
              status.protocol === 'stream-json' || status.protocol === 'app-server' || status.protocol === 'acp',
            resume: status.session_resume_verified,
            permissionModes: PERMISSION_MODES.filter((mode) => status.permission_modes.includes(mode)),
          },
        };
      });
    },

    async listThreads(): Promise<FocusThread[]> {
      const sessions = asArray<VeaselSession>(await request('/v1/sessions'));
      return sessions.map((session) => sessionToThread(session, { provider }));
    },

    createThread(input: FocusCreateThreadInput): Promise<FocusResult<FocusThread>> {
      return result(async () => {
        const veaselProvider = toVeaselProviderId(input.provider);
        const session = await request<VeaselSession>('/v1/sessions', {
          method: 'POST',
          body: JSON.stringify({
            title: input.title ?? '',
            directory: input.cwd,
            ...(veaselProvider ? { preferred_provider: veaselProvider } : {}),
            ...(veaselProvider && input.model ? { preferred_model: input.model } : {}),
            permission_mode: input.permissionMode,
            // Bypass is only ever sent because the caller chose it explicitly.
            ...(input.permissionMode === 'bypass' ? { confirm_bypass: true } : {}),
          }),
        });
        return sessionToThread(session, { provider: input.provider });
      });
    },

    async readThread(id: string): Promise<FocusThreadSnapshot | null> {
      return readThreadSnapshot(id);
    },

    updateThread(id: string, patch: FocusThreadPatch): Promise<FocusResult<FocusThread>> {
      return result(async () => {
        const path = `/v1/sessions/${encodeURIComponent(id)}`;
        const body: Record<string, unknown> = {};
        if (patch.title !== undefined) body.title = patch.title;
        if (patch.permissionMode !== undefined) {
          body.permission_mode = patch.permissionMode;
          if (patch.permissionMode === 'bypass') body.confirm_bypass = true;
        }
        if (patch.model !== undefined) {
          // A target change replaces provider and model together server-side.
          // A model needs its provider, so the current preference is read
          // from the server rather than a client copy.
          const current = await request<VeaselSession>(path);
          body.preferred_provider = current.preferred_provider ?? '';
          body.preferred_model = patch.model ?? '';
          body.expected_prefs_version = current.prefs_version ?? 0;
        } else if (patch.permissionMode !== undefined) {
          const current = await request<VeaselSession>(path);
          body.expected_prefs_version = current.prefs_version ?? 0;
        }
        const session = await request<VeaselSession>(path, { method: 'PATCH', body: JSON.stringify(body) });
        return sessionToThread(session, { provider });
      });
    },

    deleteThread(id: string): Promise<FocusResult<true>> {
      return result(async () => {
        await request(`/v1/sessions/${encodeURIComponent(id)}`, { method: 'DELETE' });
        return true as const;
      });
    },

    send(id: string, text: string): Promise<FocusResult<true>> {
      return result(async () => {
        // Only the prompt travels: the server resolves the target and the
        // permission mode (per-turn override > session preference > default)
        // and stamps the result on the operation, so Focus can never run a
        // different provider than the session displays.
        await request(`/v1/sessions/${encodeURIComponent(id)}/messages`, {
          method: 'POST',
          body: JSON.stringify({ content: text }),
        });
        return true as const;
      });
    },

    respondApproval(id: string, requestId: string, decision: FocusApprovalDecision): Promise<FocusResult<true>> {
      return result(async () => {
        if (decision === 'allow-session') {
          throw new Error('Session-wide approval is not widened by the Veasel API; approve per request.');
        }
        const action = decision === 'allow' ? 'approve' : 'reject';
        await request(
          `/v1/sessions/${encodeURIComponent(id)}/cli-approvals/${encodeURIComponent(requestId)}/${action}`,
          { method: 'POST', body: '{}' },
        );
        return true as const;
      });
    },

    respondUserInput(_id: string, _requestId: string, _answers: Record<string, string[]>): Promise<FocusResult<true>> {
      // Veasel runners decline interactive questions fail-closed; there is
      // no user-input channel to answer through yet. Never invent answers.
      return Promise.resolve({
        ok: false,
        error: 'Interactive questions are declined by the Veasel backend; no answer channel exists yet.',
      });
    },

    interrupt(id: string): Promise<FocusResult<true>> {
      return result(async () => {
        const operations = asArray<{ id: string; status?: string }>(
          await request(`/v1/sessions/${encodeURIComponent(id)}/operations`),
        );
        const active =
          operations.find((operation) => operation.status === 'running') ?? operations[operations.length - 1];
        if (!active) throw new Error('No active operation to interrupt.');
        await request(`/v1/sessions/${encodeURIComponent(id)}/operations/${encodeURIComponent(active.id)}/cancel`, {
          method: 'POST',
          body: '{}',
        });
        return true as const;
      });
    },

    onUpdate(listener: (update: FocusLiveUpdate) => void): () => void {
      // Live updates ride the canonical /v1/events SSE stream. Without an
      // EventSource (non-browser host, tests without a factory) this is
      // an honest no-op: readThread polling remains correct, just slower.
      const createStream = options.createEventStream ?? defaultEventStream;
      return createStream(`${base}/v1/events`, (_type, raw) => {
        let parsed: VeaselServerEvent;
        try {
          parsed = JSON.parse(raw) as VeaselServerEvent;
        } catch {
          return;
        }
        const update = veaselEventToLiveUpdate(parsed);
        if (update) listener(update);
      });
    },
  };
}
