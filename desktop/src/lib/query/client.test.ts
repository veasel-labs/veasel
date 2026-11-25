import { afterEach, describe, expect, it, vi } from 'vitest';
import { resolveBackendUrl } from './client';

afterEach(() => {
  delete window.atk;
  delete window.veaselDesktop;
});

describe('resolveBackendUrl', () => {
  it('uses the protected Veasel Desktop proxy instead of the disabled legacy bridge', async () => {
    window.atk = {
      backendStatus: vi.fn(async () => ({ status: 'stopped' }) as never),
    } as unknown as Window['atk'];
    window.veaselDesktop = { getBackendUrl: vi.fn(async () => 'http://127.0.0.1:43123') };

    await expect(resolveBackendUrl()).resolves.toBe('http://127.0.0.1:43123');
    expect(window.atk?.backendStatus).not.toHaveBeenCalled();
  });
});
