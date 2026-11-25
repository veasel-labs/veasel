import type { BackendState } from './backend';
import type { HarnessResolution } from './harness';
import type { VeaselBackendState } from './veasel-backend';

/** Report the renderer proxy only after the backend behind it is ready. */
export function veaselRendererBackendUrl(state: VeaselBackendState | null, publicUrl: string | null): string | null {
  return state?.status === 'ready' && state.url ? publicUrl : null;
}

/** Temporary renderer DTO retained for the existing Focus UI bridge. */
export function projectVeaselBackendState(
  state: VeaselBackendState,
  harness: HarnessResolution | null,
  attached = false,
  publicUrl?: string | null,
): BackendState {
  return {
    status: state.status,
    // The renderer must use the same-origin capability-gated proxy. Exposing
    // the backend's direct loopback URL bypasses the proxy's bearer injection
    // and produces cross-origin requests from the Electron renderer.
    url: state.url ? (publicUrl === undefined ? state.url : publicUrl) : null,
    version: null,
    detail: state.problem,
    restarts: 0,
    harness,
    binary: null,
    rejected: [],
    problem: state.status === 'failed' ? 'spawn-error' : null,
    attached,
  };
}
