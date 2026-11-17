// Bearer-token discovery for the Veasel backend API.
//
// Every backend route except GET /v1/health requires
// `Authorization: Bearer <token>`. The token is `VEASEL_API_TOKEN` when set,
// otherwise the `api-token` file in the Veasel data directory
// (`VEASEL_DATA_DIR`, default `~/.local/share/veasel`), created 0600 by the
// backend. Design and limits: docs/security/backend-caller-auth.md.

import { closeSync, constants, fstatSync, openSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

export const API_TOKEN_ENV = "VEASEL_API_TOKEN"
export const API_TOKEN_FILE = "api-token"

export function veaselDataDir(env: NodeJS.ProcessEnv = process.env, home: string = homedir()): string {
  return env.VEASEL_DATA_DIR || join(home, ".local", "share", "veasel")
}

export function apiTokenPath(env: NodeJS.ProcessEnv = process.env, home: string = homedir()): string {
  return join(veaselDataDir(env, home), API_TOKEN_FILE)
}

const GENERATED_TOKEN = /^[0-9a-f]{64}$/

// Opens the file once and validates the SAME descriptor (no stat-then-read
// race): regular file, owned by this user, no group/world access. O_NOFOLLOW
// refuses a symlink where the platform has it.
function readTokenFile(path: string): string | undefined {
  let fd: number | undefined
  try {
    fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    const stat = fstatSync(fd)
    if (!stat.isFile()) return undefined
    if (process.platform !== "win32") {
      // Mirror the server: a group/world-accessible or foreign-owned secret is not trusted.
      if ((stat.mode & 0o077) !== 0) return undefined
      if (typeof process.getuid === "function" && stat.uid !== process.getuid()) return undefined
    }
    const token = readFileSync(fd, "utf8").trim()
    // The generated format is fixed; anything else is not our token.
    return GENERATED_TOKEN.test(token) ? token : undefined
  } catch {
    return undefined
  } finally {
    if (fd !== undefined) closeSync(fd)
  }
}

/**
 * Returns a function that yields the current token. The env override is
 * constant; the file is re-read on every call so `veasel token rotate` takes
 * effect without restarting the TUI (the file is tiny).
 */
export function createApiTokenSource(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir(),
): () => string | undefined {
  return () => {
    const fromEnv = env[API_TOKEN_ENV]
    if (fromEnv) return fromEnv
    return readTokenFile(apiTokenPath(env, home))
  }
}

type FetchLike = typeof fetch

// Only bodies that can be sent twice are retried after a stale-token 401.
function isReplayable(input: Parameters<FetchLike>[0], init?: Parameters<FetchLike>[1]): boolean {
  if (input instanceof Request) return false
  const body = init?.body
  return body === undefined || body === null || typeof body === "string" || body instanceof Uint8Array
}

/**
 * Wraps `fetch` so requests to the backend origin carry the bearer token.
 * Other origins never receive it, and an explicit Authorization header wins.
 * If the backend answers 401 and the token file now holds a DIFFERENT value
 * (the token was rotated while this client held the old one), the file is
 * re-read and the request retried exactly once.
 */
export function withBackendAuth(
  base: string,
  tokenSource: () => string | undefined,
  inner: FetchLike,
): FetchLike {
  const origin = new URL(base).origin
  const wrapped = async (input: Parameters<FetchLike>[0], init?: Parameters<FetchLike>[1]) => {
    let target: URL | undefined
    try {
      target = new URL(input instanceof Request ? input.url : String(input))
    } catch {
      target = undefined
    }
    if (target?.origin !== origin) return inner(input, init)
    const token = tokenSource()
    if (!token) return inner(input, init)
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    if (headers.has("authorization")) return inner(input, { ...init, headers })
    headers.set("authorization", `Bearer ${token}`)
    const response = await inner(input, { ...init, headers })
    if (response.status !== 401 || !isReplayable(input, init)) return response
    const fresh = tokenSource()
    if (!fresh || fresh === token) return response
    headers.set("authorization", `Bearer ${fresh}`)
    return inner(input, { ...init, headers })
  }
  return Object.assign(wrapped, inner) as FetchLike
}

/** Installs the auth wrapper on the global `fetch` used by the TUI client. */
export function installBackendAuth(base: string, env: NodeJS.ProcessEnv = process.env): void {
  globalThis.fetch = withBackendAuth(base, createApiTokenSource(env), globalThis.fetch)
}
