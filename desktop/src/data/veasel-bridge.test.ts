import { describe, expect, it } from 'vitest';
import {
  approvalToEvent,
  createVeaselFocusBridge,
  messagesToEvents,
  sessionToThread,
  toFocusProviderId,
  veaselEventToLiveUpdate,
  type FetchLike,
} from './veasel-bridge';
import type { FocusLiveUpdate } from '../types/focus';

describe('veasel Focus bridge mapping', () => {
  it('maps Veasel sessions to Focus threads without inventing usage cost', () => {
    const thread = sessionToThread(
      { id: 's1', title: 'Fix math', directory: '/home/u/project', created_at: '2026-11-16T00:00:00Z' },
      { provider: 'claude', turns: 2 },
    );
    expect(thread.id).toBe('s1');
    expect(thread.projectName).toBe('project');
    expect(thread.turns).toBe(2);
    expect(thread.usage.costUsd).toBeNull();
    expect(thread.status).toBe('idle');
  });

  it('collapses Veasel provider ids to Focus provider ids', () => {
    expect(toFocusProviderId('claude-code')).toBe('claude');
    expect(toFocusProviderId('codex')).toBe('codex');
    expect(toFocusProviderId('opencode')).toBe('opencode');
    expect(toFocusProviderId('muse')).toBe('muse');
    // Unknown providers must never be silently presented as Claude.
    expect(toFocusProviderId(null)).toBe('unknown');
    expect(toFocusProviderId('something-else')).toBe('unknown');
  });

  it('projects persisted messages into one Focus turn per user message', () => {
    const events = messagesToEvents([
      { id: 1, role: 'user', content: 'fix it' },
      { id: 2, role: 'assistant', content: 'done' },
      { id: 3, role: 'user', content: 'again' },
    ]);
    expect(events.map((event) => event.type)).toEqual(['user', 'assistant', 'user']);
    expect(events[2]?.turn).toBe(2);
  });

  it('projects pending CLI approvals as Focus approval requests with parsed input', () => {
    const event = approvalToEvent({
      id: 'a1',
      tool_name: 'Edit',
      input_json: '{"file_path":"/x/note.txt"}',
      status: 'pending',
    });
    expect(event.type).toBe('approval.requested');
    if (event.type === 'approval.requested') {
      expect(event.requestId).toBe('a1');
      expect(event.kind).toBe('edit');
      expect(event.canAllowForSession).toBe(false);
    }
  });
});

describe('veasel Focus bridge HTTP behavior', () => {
  function fakeFetch(routes: Record<string, unknown>): FetchLike {
    return async (input: string) => {
      const path = input.replace('http://veasel.test', '');
      if (path in routes) {
        return { ok: true, status: 200, json: async () => routes[path] };
      }
      return { ok: false, status: 404, json: async () => ({ error: `no route ${path}` }) };
    };
  }

  it('lists threads from the canonical session API', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions': [{ id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' }],
      }),
    });
    const threads = await bridge.listThreads();
    expect(threads).toHaveLength(1);
    expect(threads[0]?.id).toBe('s1');
  });

  it('marks a thread awaiting-approval when a durable approval is pending', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [{ id: 1, role: 'user', content: 'edit' }],
        '/v1/sessions/s1/cli-approvals': [{ id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' }],
      }),
    });
    const snapshot = await bridge.readThread('s1');
    expect(snapshot?.thread.status).toBe('awaiting-approval');
    expect(snapshot?.events.some((event) => event.type === 'approval.requested')).toBe(true);
  });

  it('never widens a session-wide approval decision', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({}),
    });
    const outcome = await bridge.respondApproval('s1', 'a1', 'allow-session');
    expect(outcome.ok).toBe(false);
  });

  it('reports provider auth as unknown instead of ready', async () => {
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: fakeFetch({}) });
    const providers = await bridge.providers();
    expect(providers).toHaveLength(4);
    expect(providers.map((provider) => provider.id)).toEqual(['claude', 'codex', 'opencode', 'muse']);
    expect(providers.every((provider) => provider.auth === 'unknown')).toBe(true);
  });

  it('maps server provider facts without ever claiming a verified sign-in', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/providers/cli': [
          {
            id: 'codex',
            name: 'OpenAI Codex',
            exec: 'codex',
            protocol: 'app-server',
            installed: true,
            version: 'codex-cli 0.169.0',
            auth_probe_present: true,
            auth_state: 'probe-present',
            permission_modes: ['ask'],
            session_resume_verified: true,
            usage_reporting: 'not-published',
          },
          {
            id: 'opencode',
            name: 'OpenCode',
            exec: 'opencode',
            protocol: 'acp',
            installed: false,
            version: '',
            auth_probe_present: false,
            auth_state: 'probe-missing',
            permission_modes: ['ask'],
            session_resume_verified: true,
            usage_reporting: 'adapter-reported',
          },
        ],
      }),
    });
    const providers = await bridge.providers();
    const codex = providers.find((provider) => provider.id === 'codex');
    expect(codex?.installed).toBe(true);
    expect(codex?.version).toBe('codex-cli 0.169.0');
    expect(codex?.auth).toBe('unknown');
    expect(codex?.capabilities.sessions).toBe(true);
    const opencode = providers.find((provider) => provider.id === 'opencode');
    expect(opencode?.auth).toBe('signed-out');
    // ACP is a wired session protocol in the backend, installed or not.
    expect(opencode?.capabilities.sessions).toBe(true);
  });
});

describe('veasel Focus bridge session preferences (server-persisted)', () => {
  type Call = { method: string; path: string; body: unknown };

  /** A tiny in-memory Veasel server: the single source of truth for choices. */
  function fakeServer(initial: Record<string, unknown> = {}) {
    const calls: Call[] = [];
    let session: Record<string, unknown> = {
      id: 's1',
      title: 'T',
      directory: '/p',
      created_at: '2026-11-16',
      preferred_provider: '',
      preferred_model: '',
      permission_mode: 'ask',
      prefs_version: 0,
      last_provider: '',
      last_model: '',
      ...initial,
    };
    const fetch: FetchLike = async (input, init) => {
      const path = input.replace('http://veasel.test', '');
      const method = init?.method ?? 'GET';
      const body = init?.body ? JSON.parse(String(init.body)) : undefined;
      calls.push({ method, path, body });
      if (path === '/v1/sessions' && method === 'POST') {
        session = {
          ...session,
          preferred_provider: body.preferred_provider ?? '',
          preferred_model: body.preferred_model ?? '',
          permission_mode: body.permission_mode ?? 'ask',
        };
        return { ok: true, status: 201, json: async () => session };
      }
      if (path === '/v1/sessions/s1' && method === 'GET') {
        return { ok: true, status: 200, json: async () => session };
      }
      if (path === '/v1/sessions/s1' && method === 'PATCH') {
        if (body.expected_prefs_version !== session.prefs_version) {
          return {
            ok: false,
            status: 409,
            json: async () => ({
              error: 'Session preferences changed; reload and retry.',
              code: 'prefs_version_conflict',
              session,
            }),
          };
        }
        session = {
          ...session,
          ...(body.preferred_provider !== undefined ? { preferred_provider: body.preferred_provider } : {}),
          ...(body.preferred_model !== undefined ? { preferred_model: body.preferred_model } : {}),
          ...(body.permission_mode !== undefined ? { permission_mode: body.permission_mode } : {}),
          ...(body.title !== undefined ? { title: body.title } : {}),
          prefs_version: (session.prefs_version as number) + 1,
        };
        return { ok: true, status: 200, json: async () => session };
      }
      if (path === '/v1/sessions' && method === 'GET') {
        return { ok: true, status: 200, json: async () => [session] };
      }
      return { ok: true, status: 200, json: async () => ({}) };
    };
    return { fetch, calls };
  }

  it('creates the session with its choices on the server instead of a client-only map', async () => {
    const server = fakeServer();
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    const created = await bridge.createThread({
      cwd: '/p',
      projectName: 'p',
      provider: 'codex',
      model: null,
      permissionMode: 'plan',
    });
    expect(created.ok).toBe(true);
    const create = server.calls.find((call) => call.method === 'POST' && call.path === '/v1/sessions');
    expect(create?.body).toMatchObject({ preferred_provider: 'codex', permission_mode: 'plan' });
    expect(create?.body).not.toHaveProperty('confirm_bypass');
    if (created.ok) {
      expect(created.value.provider).toBe('codex');
      expect(created.value.permissionMode).toBe('plan');
    }
  });

  it('survives a reload: a brand-new bridge reads the same choices back from the server', async () => {
    const server = fakeServer();
    const first = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    await first.createThread({
      cwd: '/p',
      projectName: 'p',
      provider: 'claude',
      model: 'claude-sonnet-5',
      permissionMode: 'accept-edits',
    });
    const reloaded = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    const threads = await reloaded.listThreads();
    expect(threads[0]).toMatchObject({ provider: 'claude', model: 'claude-sonnet-5', permissionMode: 'accept-edits' });
    const snapshot = await reloaded.readThread('s1');
    expect(snapshot?.thread).toMatchObject({
      provider: 'claude',
      model: 'claude-sonnet-5',
      permissionMode: 'accept-edits',
    });
  });

  it('shows the truthful last-executed model separately from the preference', async () => {
    const server = fakeServer({
      preferred_provider: 'codex',
      last_provider: 'claude-code',
      last_model: 'claude-sonnet-5',
    });
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    const snapshot = await bridge.readThread('s1');
    expect(snapshot?.thread.provider).toBe('codex');
    expect(snapshot?.thread.model).toBeNull();
    expect(snapshot?.thread.resolvedModel).toBe('claude-sonnet-5');
  });

  it('sends only the prompt: the server resolves turn > session > default', async () => {
    const server = fakeServer({ preferred_provider: 'codex', permission_mode: 'plan' });
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    const outcome = await bridge.send('s1', 'fix it');
    expect(outcome.ok).toBe(true);
    const message = server.calls.find((call) => call.path === '/v1/sessions/s1/messages');
    expect(message?.body).toEqual({ content: 'fix it' });
  });

  it('updates choices with the expected prefs_version read from the server', async () => {
    const server = fakeServer({ prefs_version: 4 });
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    const updated = await bridge.updateThread('s1', { permissionMode: 'accept-edits' });
    expect(updated.ok).toBe(true);
    const patch = server.calls.find((call) => call.method === 'PATCH');
    expect(patch?.body).toEqual({ permission_mode: 'accept-edits', expected_prefs_version: 4 });
  });

  it('does not clobber the title when only a choice changes', async () => {
    const server = fakeServer();
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    await bridge.updateThread('s1', { model: null, permissionMode: 'ask' });
    const patch = server.calls.find((call) => call.method === 'PATCH');
    expect(patch?.body).not.toHaveProperty('title');
  });

  it('surfaces a version conflict honestly instead of applying a stale choice', async () => {
    const server = fakeServer({ prefs_version: 1 });
    // A concurrent writer (the TUI) bumps the version between read and patch.
    const racing: FetchLike = async (input, init) => {
      if ((init?.method ?? 'GET') === 'PATCH') {
        const body = JSON.parse(String(init?.body));
        body.expected_prefs_version = 0;
        return server.fetch(input, { ...init, body: JSON.stringify(body) });
      }
      return server.fetch(input, init);
    };
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: racing });
    const outcome = await bridge.updateThread('s1', { permissionMode: 'plan' });
    expect(outcome.ok).toBe(false);
    if (!outcome.ok) expect(outcome.error).toContain('changed');
  });

  it('only asks the server to confirm bypass when the user chose bypass explicitly', async () => {
    const server = fakeServer();
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: server.fetch });
    await bridge.updateThread('s1', { permissionMode: 'bypass' });
    const patch = server.calls.find((call) => call.method === 'PATCH');
    expect(patch?.body).toMatchObject({ permission_mode: 'bypass', confirm_bypass: true });
    const other = fakeServer();
    const calm = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: other.fetch });
    await calm.updateThread('s1', { permissionMode: 'plan' });
    expect(other.calls.find((call) => call.method === 'PATCH')?.body).not.toHaveProperty('confirm_bypass');
  });
});

const sseFetch: FetchLike = async () => ({ ok: true, status: 200, json: async () => ({}) });

describe('veasel SSE live updates', () => {
  it('maps assistant deltas and turn completions, ignores everything else', () => {
    const delta = veaselEventToLiveUpdate({
      id: 7,
      type: 'assistant.delta',
      session_id: 's1',
      created_at: '2026-11-16T00:00:00Z',
      data: { operation_id: 'op-1', delta: 'hel' },
    });
    expect(delta).toEqual({
      kind: 'delta',
      threadId: 's1',
      itemId: 'op-1',
      channel: 'assistant',
      text: 'hel',
    });
    const done = veaselEventToLiveUpdate({
      id: 9,
      type: 'session.turn_completed',
      session_id: 's1',
      created_at: '2026-11-16T00:01:00Z',
      data: { operation_id: 'op-1', status: 'completed', usage_reported: true, input_tokens: 10, output_tokens: 5 },
    });
    expect(done?.kind).toBe('event');
    if (done?.kind === 'event' && done.event.type === 'turn.finished') {
      expect(done.event.outcome).toBe('completed');
      expect(done.event.usage?.inputTokens).toBe(10);
      expect(done.event.usage?.costUsd).toBeNull();
    }
    expect(veaselEventToLiveUpdate({ id: 1, type: 'heartbeat', session_id: 's1', data: {} })).toBeNull();
    expect(veaselEventToLiveUpdate({ id: 2, type: 'assistant.delta', session_id: 's1', data: {} })).toBeNull();
  });

  it('delivers mapped updates through onUpdate and unsubscribes cleanly', async () => {
    const stream: { handler: ((type: string, data: string) => void) | null } = { handler: null };
    let closed = false;
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: sseFetch,
      createEventStream: (_url, onEvent) => {
        stream.handler = onEvent;
        return () => {
          closed = true;
        };
      },
    });
    const updates: FocusLiveUpdate[] = [];
    const unsubscribe = bridge.onUpdate((update) => updates.push(update));
    stream.handler?.(
      'assistant.delta',
      JSON.stringify({
        id: 3,
        type: 'assistant.delta',
        session_id: 's9',
        created_at: '',
        data: { operation_id: 'op', delta: 'x' },
      }),
    );
    expect(updates).toHaveLength(1);
    expect(updates[0]?.kind).toBe('delta');
    unsubscribe();
    expect(closed).toBe(true);
  });

  it('stays an honest no-op without an event stream factory', () => {
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: sseFetch });
    const unsubscribe = bridge.onUpdate(() => {
      throw new Error('must not fire');
    });
    expect(typeof unsubscribe).toBe('function');
    unsubscribe();
  });
});
