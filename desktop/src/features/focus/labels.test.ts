import { describe, expect, it } from 'vitest';
import type { FocusProviderStatus } from '../../types/focus';
import { providerBlocker } from './labels';

const provider = (patch: Partial<FocusProviderStatus> = {}): FocusProviderStatus => ({
  id: 'opencode',
  label: 'OpenCode',
  installed: true,
  binary: 'opencode',
  version: 'opencode v2.3.2',
  // The Veasel bridge's presence-only probe can never produce 'ready':
  // probe-present maps to 'unknown' for every provider.
  auth: 'unknown',
  authDetail: 'Auth file present; sign-in is not verified by the Veasel API.',
  signInHint: null,
  models: [],
  capabilities: { sessions: true, approvals: true, interrupt: true, resume: true, modelSwitch: false },
  checkedAt: '2026-11-18T00:00:00.000Z',
  ...patch,
});

describe('providerBlocker', () => {
  it('lets an installed OpenCode with a present auth file start a session, like every other provider', () => {
    expect(providerBlocker(provider())).toBeNull();
    expect(providerBlocker(provider({ id: 'claude', label: 'Claude Code' }))).toBeNull();
  });

  it('still blocks providers that are missing or signed out', () => {
    expect(providerBlocker(provider({ installed: false }))).toMatch(/Not installed/);
    expect(providerBlocker(provider({ auth: 'signed-out' }))).toMatch(/login command/);
    expect(
      providerBlocker(
        provider({
          capabilities: { sessions: false, approvals: true, interrupt: true, resume: true, modelSwitch: false },
        }),
      ),
    ).toMatch(/not available/);
  });

  it('surfaces the backend reason for a discovered but disabled runner', () => {
    const reason =
      'Cursor Agent is discovered but not launchable until ACP authentication and permission handling are verified.';
    expect(providerBlocker(provider({ id: 'cursor-agent', launchBlocker: reason }))).toBe(reason);
  });
});
