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
  FocusProviderId,
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
}

export interface VeaselMessage {
  id?: number;
  role: string;
  content: string;
  created_at?: string;
}

export interface VeaselCliApproval {
  id: string;
  tool_name: string;
  input_json: string;
  status: string;
  created_at?: string;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<{
  ok: boolean;
  status: number;
  json: () => Promise<unknown>;
}>;

const PROVIDER_IDS: FocusProviderId[] = ['claude', 'codex', 'opencode'];

/** Veasel CLI provider ids (`claude-code`, …) collapse to Focus provider ids. */
export function toFocusProviderId(veaselProvider: string | null | undefined): FocusProviderId {
  if (veaselProvider === 'codex' || veaselProvider === 'opencode') return veaselProvider;
  return 'claude';
}

export function sessionToThread(
  session: VeaselSession,
  options: { provider?: FocusProviderId; turns?: number; usage?: FocusUsage | null } = {},
): FocusThread {
  const cwd = session.directory ?? '';
  const projectName = cwd ? (cwd.split('/').filter(Boolean).pop() ?? null) : null;
  return {
    id: session.id,
    title: session.title || 'Untitled session',
    workspace: cwd,
    projectName,
    cwd,
    provider: options.provider ?? 'claude',
    model: null,
    resolvedModel: null,
    permissionMode: 'ask',
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
  provider?: FocusProviderId;
}): FocusBridge {
  const base = options.baseUrl.replace(/\/$/, '');
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init));
  const provider = options.provider ?? 'claude';

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
    const session = await request<VeaselSession>(`/v1/sessions/${encodeURIComponent(id)}`).catch(
      () => null,
    );
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
    // No provider-status route exists yet: report unknown, never "ready".
    async providers(): Promise<FocusProviderStatus[]> {
      const checkedAt = new Date().toISOString();
      return PROVIDER_IDS.map((id) => ({
        id,
        label: id === 'claude' ? 'Claude Code' : id === 'codex' ? 'Codex' : 'OpenCode',
        installed: false,
        binary: null,
        version: null,
        auth: 'unknown' as const,
        authDetail: 'Provider status is not exposed by the Veasel API yet.',
        signInHint: null,
        models: [],
        capabilities: { sessions: true, approvals: true, interrupt: true, resume: true, modelSwitch: false },
        checkedAt,
      }));
    },

    async listThreads(): Promise<FocusThread[]> {
      const sessions = asArray<VeaselSession>(await request('/v1/sessions'));
      return sessions.map((session) => sessionToThread(session, { provider }));
    },

    createThread(input: FocusCreateThreadInput): Promise<FocusResult<FocusThread>> {
      return result(async () => {
        const session = await request<VeaselSession>('/v1/sessions', {
          method: 'POST',
          body: JSON.stringify({ title: input.title ?? '', directory: input.cwd }),
        });
        return sessionToThread(session, { provider: input.provider });
      });
    },

    async readThread(id: string): Promise<FocusThreadSnapshot | null> {
      return readThreadSnapshot(id);
    },

    updateThread(id: string, patch: FocusThreadPatch): Promise<FocusResult<FocusThread>> {
      return result(async () => {
        const session = await request<VeaselSession>(`/v1/sessions/${encodeURIComponent(id)}`, {
          method: 'PATCH',
          body: JSON.stringify({ title: patch.title ?? '' }),
        });
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
        await request(`/v1/sessions/${encodeURIComponent(id)}/messages`, {
          method: 'POST',
          body: JSON.stringify({ content: text }),
        });
        return true as const;
      });
    },

    respondApproval(
      id: string,
      requestId: string,
      decision: FocusApprovalDecision,
    ): Promise<FocusResult<true>> {
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

    interrupt(id: string): Promise<FocusResult<true>> {
      return result(async () => {
        const operations = asArray<{ id: string; status?: string }>(
          await request(`/v1/sessions/${encodeURIComponent(id)}/operations`),
        );
        const active = operations.find((operation) => operation.status === 'running')
          ?? operations[operations.length - 1];
        if (!active) throw new Error('No active operation to interrupt.');
        await request(
          `/v1/sessions/${encodeURIComponent(id)}/operations/${encodeURIComponent(active.id)}/cancel`,
          { method: 'POST', body: '{}' },
        );
        return true as const;
      });
    },

    onUpdate(): () => void {
      // Live SSE wiring (`/v1/events`) is a follow-up; polling readThread is
      // the honest interim. Return an unsubscribe no-op, never fake deltas.
      return () => {};
    },
  };
}
