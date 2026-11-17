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

describe('veasel Focus bridge send contract', () => {
  function capturingFetch(sent: Array<{ path: string; body: unknown }>): FetchLike {
    return async (input: string, init?: RequestInit) => {
      const path = input.replace('http://veasel.test', '');
      if (init?.body) sent.push({ path, body: JSON.parse(String(init.body)) });
      if (path === '/v1/sessions') {
        return {
          ok: true,
          status: 200,
          json: async () => ({ id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' }),
        };
      }
      return { ok: true, status: 200, json: async () => ({}) };
    };
  }

  it('omits provider when no model is chosen so the backend inherits its default', async () => {
    const sent: Array<{ path: string; body: unknown }> = [];
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: capturingFetch(sent) });
    const created = await bridge.createThread({
      cwd: '/p',
      projectName: 'p',
      provider: 'codex',
      model: null,
      permissionMode: 'ask',
    });
    expect(created.ok).toBe(true);
    const outcome = await bridge.send('s1', 'fix it');
    expect(outcome.ok).toBe(true);
    const message = sent.find((entry) => entry.path === '/v1/sessions/s1/messages');
    // The backend rejects provider-without-model; sending neither is the
    // documented inherit-default path.
    expect(message?.body).toEqual({ content: 'fix it' });
  });

  it('sends provider and model together when a model is chosen', async () => {
    const sent: Array<{ path: string; body: unknown }> = [];
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: capturingFetch(sent) });
    const created = await bridge.createThread({
      cwd: '/p',
      provider: 'claude',
      projectName: 'p',
      model: 'claude-sonnet-5',
      permissionMode: 'ask',
    });
    expect(created.ok).toBe(true);
    const outcome = await bridge.send('s1', 'fix it');
    expect(outcome.ok).toBe(true);
    const message = sent.find((entry) => entry.path === '/v1/sessions/s1/messages');
    expect(message?.body).toEqual({ content: 'fix it', provider: 'claude-code', model: 'claude-sonnet-5' });
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
