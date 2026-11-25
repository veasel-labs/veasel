import { describe, expect, it } from 'vitest';
import { projectVeaselBackendState, veaselRendererBackendUrl } from './backend-state';

describe('projectVeaselBackendState', () => {
  it('projects canonical backend status and workspace without legacy binary claims', () => {
    const state = projectVeaselBackendState(
      { status: 'ready', url: 'http://127.0.0.1:4097', problem: null },
      {
        path: '/tmp/workspace',
        source: 'user',
        defaultPath: '/home/test/.ai-workspace',
        overrideVar: null,
        notice: null,
      },
      true,
    );

    expect(state).toMatchObject({
      status: 'ready',
      url: 'http://127.0.0.1:4097',
      harness: { path: '/tmp/workspace' },
      attached: true,
      binary: null,
      rejected: [],
    });
  });

  it('keeps backend startup failures visible', () => {
    expect(projectVeaselBackendState({ status: 'failed', url: null, problem: 'missing binary' }, null)).toMatchObject({
      status: 'failed',
      detail: 'missing binary',
      problem: 'spawn-error',
    });
  });

  it('projects the protected renderer proxy URL instead of the backend loopback URL', () => {
    const state = projectVeaselBackendState(
      { status: 'ready', url: 'http://127.0.0.1:4097', problem: null },
      null,
      false,
      'http://127.0.0.1:43123',
    );

    expect(state.url).toBe('http://127.0.0.1:43123');
    expect(
      projectVeaselBackendState(
        { status: 'ready', url: 'http://127.0.0.1:4097', problem: null },
        null,
        false,
        null,
      ).url,
    ).toBeNull();
  });

  it('does not advertise the proxy before its backend has started', () => {
    expect(veaselRendererBackendUrl({ status: 'starting', url: null, problem: null }, 'http://127.0.0.1:43123')).toBe(
      null,
    );
    expect(
      veaselRendererBackendUrl({ status: 'ready', url: 'http://127.0.0.1:4097', problem: null }, 'http://127.0.0.1:43123'),
    ).toBe('http://127.0.0.1:43123');
  });
});
