import type { BackendState } from './backend';
import type { HarnessResolution } from './harness';
import type { VeaselBackendState } from './veasel-backend';

/** Temporary renderer DTO retained for the existing Focus UI bridge. */
export function projectVeaselBackendState(
  state: VeaselBackendState,
  harness: HarnessResolution | null,
  attached = false,
): BackendState {
  return {
    status: state.status,
    url: state.url,
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
