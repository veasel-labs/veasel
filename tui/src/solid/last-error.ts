/** Last structured error for LiveApp error-details dialog. */

export type LiveLastError = {
  title: string
  source: string
  context?: string
  error: string
  at: number
}

export function recordLiveLastError(
  previous: LiveLastError | undefined,
  next: Omit<LiveLastError, "at"> & { at?: number },
): LiveLastError {
  return {
    title: next.title.trim() || "Error",
    source: next.source.trim() || "veasel",
    context: next.context?.trim() || undefined,
    error: next.error.trim() || "(empty error)",
    at: next.at ?? Date.now(),
  }
}

/** Prefer a stored last error; otherwise a gentle empty-state payload. */
export function resolveLiveErrorDetails(
  last: LiveLastError | undefined,
): Omit<LiveLastError, "at"> {
  if (last) {
    return {
      title: last.title,
      source: last.source,
      context: last.context,
      error: last.error,
    }
  }
  return {
    title: "No recent errors",
    source: "live-app",
    context: "status",
    error: "No failures recorded this session. Failed requests and send errors appear here.",
  }
}
