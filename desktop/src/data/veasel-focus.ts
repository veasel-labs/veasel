import { useEffect, useState } from 'react';
import { FocusStore } from './focus';
import { createVeaselFocusBridge } from './veasel-bridge';

/**
 * Builds the FocusStore backed by the Veasel V backend (the only
 * runtime). The backend URL comes from the Electron main process via
 * the preload bridge; in plain-browser dev it falls back to
 * VITE_VEASEL_BACKEND_URL or the backend's default loopback port.
 */
export function useVeaselFocusStore(): FocusStore | null {
  const [store, setStore] = useState<FocusStore | null>(null);
  useEffect(() => {
    let cancelled = false;
    void resolveVeaselBackendUrl().then((baseUrl) => {
      if (cancelled || !baseUrl) return;
      setStore(new FocusStore(createVeaselFocusBridge({ baseUrl })));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return store;
}

export async function resolveVeaselBackendUrl(): Promise<string | null> {
  const desktop = typeof window !== 'undefined' ? window.veaselDesktop : undefined;
  if (desktop) {
    // The supervisor may still be starting; poll briefly instead of
    // falling through to a dead default port.
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const ready = await desktop.getBackendUrl().catch(() => null);
      // Fetch through this page's own loopback origin: the main process
      // proxies /v1/* to the backend, so there is no cross-origin fetch.
      if (ready) return window.location.origin;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  const fromEnv = (import.meta as { env?: Record<string, string | undefined> }).env?.VITE_VEASEL_BACKEND_URL;
  return fromEnv ?? 'http://127.0.0.1:4097';
}
