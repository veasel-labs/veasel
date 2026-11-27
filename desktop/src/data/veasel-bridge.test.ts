import { describe, expect, it, vi } from 'vitest';
import { buildTimeline, pendingApproval } from '../features/focus/timeline';
import {
  approvalToEvent,
  createVeaselFocusBridge,
  messagesAndHistoryEventsToEvents,
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
    expect(toFocusProviderId('cursor-agent')).toBe('cursor-agent');
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

  it('restores the durable completion outcome after a session reload', () => {
    const events = messagesAndHistoryEventsToEvents(
      [
        { id: 1, role: 'user', content: 'fix the test' },
        { id: 2, role: 'assistant', content: 'Applied the edit.' },
      ],
      [
        { id: 11, type: 'message.created', session_id: 's1', data: {} },
        { id: 12, type: 'message.created', session_id: 's1', data: {} },
        {
          id: 13,
          type: 'session.turn_completed',
          session_id: 's1',
          data: {
            status: 'completed',
            outcome: 'completed_with_denials',
            error: 'Approvals: 1 expired (Bash). Applied: Edit math.js. Not verified.',
          },
        },
      ],
    );
    expect(events.map((event) => event.type)).toEqual(['user', 'assistant', 'turn.finished']);
    const turns = buildTimeline(events);
    expect(turns[0]?.items.at(-1)).toMatchObject({
      kind: 'turn-end',
      outcome: 'completed',
      outcomeDetail: 'completed_with_denials',
      detail: expect.stringContaining('1 expired (Bash)'),
    });
  });

  it('does not attach retained outcomes to the wrong messages when event history is truncated', () => {
    const messages = [
      { id: 1, role: 'user', content: 'older question' },
      { id: 2, role: 'assistant', content: 'older answer' },
      { id: 3, role: 'user', content: 'newer question' },
      { id: 4, role: 'assistant', content: 'newer answer' },
    ] as const;
    const journal = [
      { id: 20, type: 'message.created', session_id: 's1', data: {} },
      { id: 21, type: 'message.created', session_id: 's1', data: {} },
      {
        id: 22,
        type: 'session.turn_completed',
        session_id: 's1',
        data: { status: 'completed', outcome: 'completed_with_denials', error: 'newer turn was denied' },
      },
    ] as const;

    const events = messagesAndHistoryEventsToEvents(messages, journal);

    expect(events).toEqual(messagesToEvents(messages));
    expect(events.some((event) => event.type === 'turn.finished')).toBe(false);
    expect(events.find((event) => event.type === 'assistant')?.text).toBe('older answer');
  });

  it('ignores completion records with no corresponding chat message (queued cancellation)', () => {
    const events = messagesAndHistoryEventsToEvents(
      [],
      [
        {
          id: 1,
          type: 'session.turn_completed',
          session_id: 's1',
          data: { status: 'cancelled', outcome: 'cancelled' },
        },
      ],
    );
    expect(events).toEqual([]);
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
      expect(event.input).toEqual({ file_path: '/x/note.txt' });
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

  it('lists latest operation status per session from the canonical API', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/operations/latest?limit=100': {
          operations: [
            {
              operation: {
                id: 'op1',
                session_id: 's1',
                status: 'running',
                provider: 'codex',
                model: 'gpt-codex',
                created_at: '2026-11-16T00:00:00Z',
                updated_at: '2026-11-16T00:00:01Z',
              },
            },
          ],
        },
      }),
    });
    await expect(bridge.listOperations()).resolves.toEqual([
      {
        id: 'op1',
        sessionId: 's1',
        status: 'running',
        provider: 'codex',
        model: 'gpt-codex',
        createdAt: '2026-11-16T00:00:00Z',
        updatedAt: '2026-11-16T00:00:01Z',
      },
    ]);
  });

  it('follows latest-operation cursors until every page is read', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/operations/latest?limit=100': {
          operations: [{ operation: { id: 'op-new', session_id: 's-new', status: 'completed' } }],
          next_before: 'cursor-1',
        },
        '/v1/operations/latest?limit=100&before=cursor-1': {
          operations: [{ operation: { id: 'op-old', session_id: 's-old', status: 'running' } }],
        },
      }),
    });

    await expect(bridge.listOperations()).resolves.toMatchObject([
      { id: 'op-new', sessionId: 's-new', status: 'completed' },
      { id: 'op-old', sessionId: 's-old', status: 'running' },
    ]);
  });

  it('fails closed when the latest-operation endpoint repeats a page cursor', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/operations/latest?limit=100': { operations: [], next_before: 'cursor-1' },
        '/v1/operations/latest?limit=100&before=cursor-1': { operations: [], next_before: 'cursor-1' },
      }),
    });

    await expect(bridge.listOperations()).rejects.toThrow('repeated an operation history cursor');
  });

  it('loads completion outcomes from the durable session history endpoint', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [
          { id: 1, role: 'user', content: 'fix it' },
          { id: 2, role: 'assistant', content: 'Applied the edit.' },
        ],
        '/v1/sessions/s1/events': [
          { id: 11, type: 'message.created', session_id: 's1', data: {} },
          { id: 12, type: 'message.created', session_id: 's1', data: {} },
          {
            id: 13,
            type: 'session.turn_completed',
            session_id: 's1',
            data: {
              status: 'completed',
              outcome: 'completed_with_denials',
              error: 'Approvals: 1 expired (Bash). Applied: Edit math.js.',
            },
          },
        ],
        '/v1/sessions/s1/cli-approvals': [],
        '/v1/sessions/s1/operations': [{ status: 'completed' }],
      }),
    });

    const snapshot = await bridge.readThread('s1');
    expect(snapshot?.events.map((event) => event.type)).toEqual(['user', 'assistant', 'turn.finished']);
    expect(buildTimeline(snapshot?.events ?? [])[0]?.items.at(-1)).toMatchObject({
      kind: 'turn-end',
      outcome: 'completed',
      outcomeDetail: 'completed_with_denials',
    });
  });

  it('marks a thread awaiting-approval when a durable approval is pending', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [{ id: 1, role: 'user', content: 'edit' }],
        '/v1/sessions/s1/events': [],
        '/v1/sessions/s1/cli-approvals': [{ id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' }],
      }),
    });
    const snapshot = await bridge.readThread('s1');
    expect(snapshot?.thread.status).toBe('awaiting-approval');
    expect(snapshot?.events.some((event) => event.type === 'approval.requested')).toBe(true);
  });

  it('marks a thread running while an operation is active, so Focus can show Stop', async () => {
    for (const status of ['queued', 'running', 'cancelling']) {
      const bridge = createVeaselFocusBridge({
        baseUrl: 'http://veasel.test',
        fetch: fakeFetch({
          '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
          '/v1/sessions/s1/messages': [],
          '/v1/sessions/s1/cli-approvals': [],
          '/v1/sessions/s1/operations': [{ id: 'op1', status }],
        }),
      });
      const snapshot = await bridge.readThread('s1');
      expect(snapshot?.thread.status, status).toBe('running');
    }
    const done = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [],
        '/v1/sessions/s1/cli-approvals': [],
        '/v1/sessions/s1/operations': [{ id: 'op1', status: 'completed' }],
      }),
    });
    expect((await done.readThread('s1'))?.thread.status).toBe('idle');
    for (const [opStatus, threadStatus] of [
      ['cancelled', 'interrupted'],
      ['failed', 'error'],
      ['uncertain', 'error'],
    ] as const) {
      const bridge = createVeaselFocusBridge({
        baseUrl: 'http://veasel.test',
        fetch: fakeFetch({
          '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
          '/v1/sessions/s1/messages': [],
          '/v1/sessions/s1/cli-approvals': [],
          '/v1/sessions/s1/operations': [{ id: 'op1', status: opStatus }],
        }),
      });
      expect((await bridge.readThread('s1'))?.thread.status, opStatus).toBe(threadStatus);
    }
  });

  it('keeps awaiting-approval ahead of running when both apply', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [],
        '/v1/sessions/s1/cli-approvals': [{ id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' }],
        '/v1/sessions/s1/operations': [{ id: 'op1', status: 'running' }],
      }),
    });
    expect((await bridge.readThread('s1'))?.thread.status).toBe('awaiting-approval');
  });

  it('opens the turn for a pending approval so Focus can render the approval dialog', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        // The user message is persisted only when the turn ends, so a running turn has none yet.
        '/v1/sessions/s1/messages': [],
        '/v1/sessions/s1/cli-approvals': [{ id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' }],
      }),
    });
    const snapshot = await bridge.readThread('s1');
    const pending = pendingApproval(buildTimeline(snapshot?.events ?? [], {}));
    expect(pending?.approval?.state).toBe('pending');
  });

  it('puts a pending approval in the next turn when earlier turns are complete', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [
          { id: 1, role: 'user', content: 'first' },
          { id: 2, role: 'assistant', content: 'done' },
        ],
        '/v1/sessions/s1/cli-approvals': [{ id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' }],
      }),
    });
    const snapshot = await bridge.readThread('s1');
    const turns = buildTimeline(snapshot?.events ?? [], {});
    expect(turns.at(-1)?.turn).toBe(2);
    expect(pendingApproval(turns)?.approval?.state).toBe('pending');
  });

  it('asks for a refresh when a mid-turn approval appears and when it is decided', async () => {
    vi.useFakeTimers();
    try {
      let pending: unknown[] = [];
      let emit: (type: string, data: string) => void = () => {};
      const bridge = createVeaselFocusBridge({
        baseUrl: 'http://veasel.test',
        fetch: (async (input: string) => {
          if (input.endsWith('/cli-approvals')) return { ok: true, status: 200, json: async () => pending };
          return { ok: false, status: 404, json: async () => ({}) };
        }) as FetchLike,
        createEventStream: (_url, onEvent) => {
          emit = onEvent;
          return () => {};
        },
      });
      const updates: FocusLiveUpdate[] = [];
      const stop = bridge.onUpdate((update) => updates.push(update));
      emit('session.turn_started', JSON.stringify({ type: 'session.turn_started', session_id: 's1', data: {} }));
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'refresh')).toHaveLength(0);

      pending = [{ id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' }];
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'refresh')).toEqual([{ kind: 'refresh', threadId: 's1' }]);

      // Unchanged pending set: no further refresh. Decided (empty again): one more.
      await vi.advanceTimersByTimeAsync(2_100);
      expect(updates.filter((entry) => entry.kind === 'refresh')).toHaveLength(1);
      pending = [];
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'refresh')).toHaveLength(2);

      emit(
        'session.turn_completed',
        JSON.stringify({ type: 'session.turn_completed', session_id: 's1', data: { status: 'completed' } }),
      );
      pending = [{ id: 'a2', tool_name: 'Bash', input_json: '{}', status: 'pending' }];
      await vi.advanceTimersByTimeAsync(5_000);
      expect(updates.filter((entry) => entry.kind === 'refresh').length).toBeLessThanOrEqual(3);
      stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it('reports the backend connection lost and regained while a turn runs', async () => {
    vi.useFakeTimers();
    try {
      let answering = true;
      let emit: (type: string, data: string) => void = () => {};
      const bridge = createVeaselFocusBridge({
        baseUrl: 'http://veasel.test',
        fetch: (async (input: string) => {
          if (input.endsWith('/cli-approvals') && answering) return { ok: true, status: 200, json: async () => [] };
          return { ok: false, status: 502, json: async () => ({}) };
        }) as FetchLike,
        createEventStream: (_url, onEvent) => {
          emit = onEvent;
          return () => {};
        },
      });
      const updates: FocusLiveUpdate[] = [];
      const stop = bridge.onUpdate((update) => updates.push(update));
      emit('session.turn_started', JSON.stringify({ type: 'session.turn_started', session_id: 's1', data: {} }));
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'connection')).toHaveLength(0);

      // One failed poll is not yet "backend down"; the second consecutive one is.
      answering = false;
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'connection')).toHaveLength(0);
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'connection')).toEqual([
        { kind: 'connection', threadId: 's1', online: false },
      ]);

      answering = true;
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'connection')).toEqual([
        { kind: 'connection', threadId: 's1', online: false },
        { kind: 'connection', threadId: 's1', online: true },
      ]);
      stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it('starts watching on a delta when turn_started was missed, so a backend death is still reported', async () => {
    vi.useFakeTimers();
    try {
      let emit: (type: string, data: string) => void = () => {};
      const bridge = createVeaselFocusBridge({
        baseUrl: 'http://veasel.test',
        fetch: (async () => ({ ok: false, status: 502, json: async () => ({}) })) as FetchLike,
        createEventStream: (_url, onEvent) => {
          emit = onEvent;
          return () => {};
        },
      });
      const updates: FocusLiveUpdate[] = [];
      const stop = bridge.onUpdate((update) => updates.push(update));
      emit(
        'assistant.delta',
        JSON.stringify({ type: 'assistant.delta', session_id: 's1', data: { operation_id: 'op', delta: 'x' } }),
      );
      await vi.advanceTimersByTimeAsync(2_200);
      expect(updates.filter((entry) => entry.kind === 'connection')).toEqual([
        { kind: 'connection', threadId: 's1', online: false },
      ]);
      stop();
    } finally {
      vi.useRealTimers();
    }
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
    expect(providers).toHaveLength(5);
    expect(providers.map((provider) => provider.id)).toEqual(['claude', 'codex', 'opencode', 'muse', 'cursor-agent']);
    expect(providers.every((provider) => provider.auth === 'unknown')).toBe(true);
    expect(providers.find((provider) => provider.id === 'cursor-agent')?.capabilities.sessions).toBe(false);
  });

  it('maps verified native sign-in while keeping file presence unverified', async () => {
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
            auth_method: '',
            account_mode: '',
            auth_error: '',
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
            auth_method: '',
            account_mode: '',
            auth_error: '',
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
    expect(opencode?.auth).toBe('unknown');
    // ACP is a wired session protocol in the backend, installed or not.
    expect(opencode?.capabilities.sessions).toBe(true);
  });

  it('does not enable discovered Cursor ACP sessions until backend launch gate opens', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/providers/cli': [
          {
            id: 'cursor-agent',
            name: 'Cursor Agent',
            exec: 'cursor-agent',
            protocol: 'acp',
            installed: true,
            version: '2026.09.15-d2fe57e',
            auth_probe_present: true,
            auth_state: 'verified',
            auth_method: '',
            account_mode: '',
            auth_error: '',
            permission_modes: [],
            session_resume_verified: false,
            usage_reporting: 'unknown',
            launchable: false,
            launch_reason:
              'Cursor Agent is discovered but not launchable: authenticate(cursor_login) and permission responses are unverified.',
          },
        ],
      }),
    });
    const cursor = (await bridge.providers()).find((provider) => provider.id === 'cursor-agent');
    expect(cursor?.installed).toBe(true);
    expect(cursor?.auth).toBe('ready');
    expect(cursor?.capabilities.sessions).toBe(false);
    expect(cursor?.launchBlocker).toContain('authenticate(cursor_login)');
  });

  it('shows a provider-reported Claude.ai login without exposing account identity', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/providers/cli': [
          {
            id: 'claude-code',
            name: 'Claude Code',
            exec: 'claude',
            protocol: 'stream-json',
            installed: true,
            version: '2.1.330',
            auth_probe_present: true,
            auth_state: 'verified',
            auth_method: 'claude.ai',
            account_mode: 'max',
            auth_error: '',
            permission_modes: ['ask', 'accept-edits'],
            session_resume_verified: true,
            usage_reporting: 'adapter-reported',
          },
        ],
      }),
    });
    const claude = (await bridge.providers()).find((provider) => provider.id === 'claude');
    expect(claude?.auth).toBe('ready');
    expect(claude?.authDetail).toContain('Signed in with Claude.ai · MAX plan');
    expect(claude?.authDetail).toContain('Quota is not reported');
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

  it('sends turns with Prefer: respond-async so a turn waiting on an approval cannot block the request', async () => {
    // Without it the POST blocks until the turn ends, but a turn that is
    // waiting for the user's approval cannot end: Focus would sit on
    // "Starting…" and never surface the approval (the TUI already sends it).
    const headersSeen: Array<{ path: string; headers: Record<string, string> }> = [];
    const doFetch: FetchLike = async (input: string, init?: RequestInit) => {
      const path = input.replace('http://veasel.test', '');
      headersSeen.push({ path, headers: { ...((init?.headers as Record<string, string>) ?? {}) } });
      if (path === '/v1/sessions') {
        return {
          ok: true,
          status: 200,
          json: async () => ({ id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' }),
        };
      }
      return { ok: true, status: 202, json: async () => ({ operation_id: 'op1' }) };
    };
    const bridge = createVeaselFocusBridge({ baseUrl: 'http://veasel.test', fetch: doFetch });
    const created = await bridge.createThread({
      cwd: '/p',
      projectName: 'p',
      provider: 'claude',
      model: null,
      permissionMode: 'ask',
    });
    expect(created.ok).toBe(true);
    const outcome = await bridge.send('s1', 'fix it');
    expect(outcome.ok).toBe(true);
    const post = headersSeen.find((entry) => entry.path === '/v1/sessions/s1/messages');
    expect(post?.headers.Prefer).toBe('respond-async');
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
    for (const type of ['session.turn_started', 'session.turn_queued']) {
      expect(veaselEventToLiveUpdate({ id: 8, type, session_id: 's1', data: { operation_id: 'op-1' } })).toEqual({
        kind: 'status',
        threadId: 's1',
        status: 'running',
      });
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

describe('veasel turn outcomes (honest finish events)', () => {
  const finished = (data: Record<string, unknown>) =>
    veaselEventToLiveUpdate({ id: 9, type: 'session.turn_completed', session_id: 's1', data });

  it('keeps a partial turn visible as partial, with what was applied', () => {
    const update = finished({
      status: 'failed',
      outcome: 'partial',
      error: 'The turn stopped before it finished. Already applied: Edit math.js. These changes are not verified.',
    });
    expect(update?.kind).toBe('event');
    if (update?.kind === 'event' && update.event.type === 'turn.finished') {
      expect(update.event.outcome).toBe('failed');
      expect(update.event.outcomeDetail).toBe('partial');
      expect(update.event.detail).toContain('Edit math.js');
    }
  });

  it('marks a completed turn with denied approvals and keeps the summary', () => {
    const update = finished({
      status: 'completed',
      outcome: 'completed_with_denials',
      error: 'Approvals: 1 expired (Bash). Applied: Edit math.js. These changes are not verified.',
    });
    if (update?.kind === 'event' && update.event.type === 'turn.finished') {
      expect(update.event.outcome).toBe('completed');
      expect(update.event.outcomeDetail).toBe('completed_with_denials');
      expect(update.event.detail).toContain('expired');
    }
  });

  it('shows applied-but-unverified work on a clean completion', () => {
    const update = finished({
      status: 'completed',
      outcome: 'completed',
      error: 'Applied: Edit math.js. Not verified.',
    });
    if (update?.kind === 'event' && update.event.type === 'turn.finished') {
      expect(update.event.outcome).toBe('completed');
      expect(update.event.outcomeDetail).toBeUndefined();
      expect(update.event.detail).toContain('Applied');
    }
  });

  it('maps an uncertain outcome without claiming success or failure', () => {
    const update = finished({ status: 'uncertain', outcome: 'uncertain', error: 'The server stopped.' });
    if (update?.kind === 'event' && update.event.type === 'turn.finished') {
      expect(update.event.outcome).toBe('interrupted');
      expect(update.event.outcomeDetail).toBe('uncertain');
    }
  });

  it('still maps older servers that send no outcome', () => {
    const update = finished({ status: 'failed', error: 'The assistant turn failed.' });
    if (update?.kind === 'event' && update.event.type === 'turn.finished') {
      expect(update.event.outcome).toBe('failed');
      expect(update.event.outcomeDetail).toBeUndefined();
    }
  });

  it('refreshes durable history if the turn-completed SSE frame is missed', async () => {
    vi.useFakeTimers();
    try {
      let status = 'running';
      let emit: (type: string, data: string) => void = () => {};
      const bridge = createVeaselFocusBridge({
        baseUrl: 'http://veasel.test',
        fetch: (async (input: string) => {
          if (input.endsWith('/cli-approvals')) return { ok: true, status: 200, json: async () => [] };
          if (input.endsWith('/operations'))
            return { ok: true, status: 200, json: async () => [{ id: 'op1', status }] };
          return { ok: false, status: 404, json: async () => ({}) };
        }) as FetchLike,
        createEventStream: (_url, onEvent) => {
          emit = onEvent;
          return () => {};
        },
      });
      const updates: FocusLiveUpdate[] = [];
      const stop = bridge.onUpdate((update) => updates.push(update));
      emit(
        'session.turn_started',
        JSON.stringify({ type: 'session.turn_started', session_id: 's1', data: { operation_id: 'op1' } }),
      );
      await vi.advanceTimersByTimeAsync(0);
      expect(updates.filter((entry) => entry.kind === 'refresh')).toHaveLength(0);

      status = 'completed';
      await vi.advanceTimersByTimeAsync(1_100);
      expect(updates.filter((entry) => entry.kind === 'refresh')).toEqual([{ kind: 'refresh', threadId: 's1' }]);
      stop();
    } finally {
      vi.useRealTimers();
    }
  });
});
