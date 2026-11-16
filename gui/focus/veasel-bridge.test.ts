import { describe, expect, it } from 'vitest';
import {
  approvalToEvent,
  createVeaselFocusBridge,
  messagesToEvents,
  sessionToThread,
  toFocusProviderId,
  type FetchLike,
} from './veasel-bridge';

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
    expect(toFocusProviderId(null)).toBe('claude');
  });

  it('projects persisted messages into one Focus turn per user message', () => {
    const events = messagesToEvents([
      { id: 1, role: 'user', content: 'fix it' },
      { id: 2, role: 'assistant', content: 'done' },
      { id: 3, role: 'user', content: 'again' },
    ]);
    expect(events.map((event) => event.type)).toEqual(['user', 'assistant', 'user']);
    expect(events[2].turn).toBe(2);
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
    expect(threads[0].id).toBe('s1');
  });

  it('marks a thread awaiting-approval when a durable approval is pending', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/sessions/s1': { id: 's1', title: 'T', directory: '/p', created_at: '2026-11-16' },
        '/v1/sessions/s1/messages': [{ id: 1, role: 'user', content: 'edit' }],
        '/v1/sessions/s1/cli-approvals': [
          { id: 'a1', tool_name: 'Edit', input_json: '{}', status: 'pending' },
        ],
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
    expect(providers).toHaveLength(3);
    expect(providers.every((provider) => provider.auth === 'unknown')).toBe(true);
  });

  it('maps server provider facts without ever claiming a verified sign-in', async () => {
    const bridge = createVeaselFocusBridge({
      baseUrl: 'http://veasel.test',
      fetch: fakeFetch({
        '/v1/providers/cli': [
          {
            id: 'codex', name: 'OpenAI Codex', exec: 'codex', protocol: 'app-server',
            installed: true, version: 'codex-cli 0.169.0', auth_probe_present: true,
            auth_state: 'probe-present', permission_modes: ['ask'],
            session_resume_verified: true, usage_reporting: 'not-published',
          },
          {
            id: 'opencode', name: 'OpenCode', exec: 'opencode', protocol: 'acp',
            installed: false, version: '', auth_probe_present: false,
            auth_state: 'probe-missing', permission_modes: ['ask'],
            session_resume_verified: true, usage_reporting: 'adapter-reported',
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
    expect(opencode?.capabilities.sessions).toBe(false);
  });
});
