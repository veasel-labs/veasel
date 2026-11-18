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

/**
 * Refuses a legacy backend, then installs the auth wrapper. The token wrapper is
 * only installed after the server proved it enforces authentication.
 */
export async function connectAuthenticated(base: string, env: NodeJS.ProcessEnv = process.env): Promise<void> {
  await requireNonLegacyBackend(base)
  installBackendAuth(base, env)
}

/** Installs the auth wrapper on the global `fetch` used by the TUI client. */
export function installBackendAuth(base: string, env: NodeJS.ProcessEnv = process.env): void {
  globalThis.fetch = withBackendAuth(base, createApiTokenSource(env), globalThis.fetch)
}

export type BackendKind = "absent" | "secure" | "legacy"

async function probe(url: string, fetchImpl: FetchLike): Promise<Response | undefined> {
  try {
    return await fetchImpl(url, { signal: AbortSignal.timeout(1500), headers: {} })
  } catch {
    return undefined
  }
}

/**
 * Classifies the server on `base` WITHOUT sending any credential: an
 * unverified server must never receive the token. `secure` requires health to
 * advertise bearer auth AND an unauthenticated protected route to be refused;
 * anything reachable that cannot prove that (an older backend, a server that
 * only claims it, unparseable output) is `legacy` (fail closed).
 */
export async function classifyBackend(base: string, fetchImpl: FetchLike = fetch): Promise<BackendKind> {
  const health = await probe(`${base}/v1/health`, fetchImpl)
  if (!health) return "absent"
  if (health.status !== 200) return "legacy"
  let body: unknown
  try {
    body = await health.json()
  } catch {
    return "legacy"
  }
  const liveness = body as { healthy?: unknown; auth?: unknown; protocol?: unknown } | null
  if (!liveness || liveness.healthy !== true || liveness.auth !== "bearer") return "legacy"
  if (typeof liveness.protocol !== "number" || liveness.protocol < 1) return "legacy"
  const protectedRoute = await probe(`${base}/v1/capabilities`, fetchImpl)
  return protectedRoute?.status === 401 ? "secure" : "legacy"
}

/** Read-only count of running/queued turns on a legacy backend (undefined if unknown). */
async function legacyActiveOperations(base: string, fetchImpl: FetchLike): Promise<number | undefined> {
  const response = await probe(`${base}/v1/operations`, fetchImpl)
  if (!response || response.status !== 200) return undefined
  try {
    const page = (await response.json()) as { operations?: Array<{ operation?: { status?: string } }> }
    if (!Array.isArray(page.operations)) return undefined
    return page.operations.filter((row) => row.operation?.status === "running" || row.operation?.status === "queued")
      .length
  } catch {
    return undefined
  }
}

export function legacyBackendMessage(port: string, active: number | undefined): string {
  const impact =
    active === undefined
      ? "It may be running turns; stopping it interrupts them."
      : active > 0
        ? `${active} turn(s) are running or queued on it and will be interrupted if you stop it.`
        : "No running or queued turns were reported (checked with a read-only request)."
  return [
    `a legacy Veasel backend without caller authentication is running on 127.0.0.1:${port} (or another server that cannot prove authentication holds that port). Any local process can control it, so Veasel will not attach to it or send it credentials. ${impact} Sessions are stored in SQLite and are kept; only in-flight turns are lost.`,
    "To recover, stop it yourself and run the command again (Veasel never stops a process it did not start):",
    `  Linux:   ss -ltnp "sport = :${port}"    then   kill <pid>`,
    `  macOS:   lsof -nP -iTCP:${port} -sTCP:LISTEN   then   kill <pid>`,
    `  Windows: netstat -ano | findstr :${port}   then   taskkill /PID <pid>`,
    "Or start a new backend on another port with VEASEL_PORT=<port> and a SEPARATE VEASEL_DATA_DIR: two backends must never share one data directory, and a legacy process holds its directory without a lock, so Veasel cannot verify that for you.",
  ].join("\n")
}

/** Throws (with the recovery text) if `base` is held by a legacy/unverifiable backend. */
export async function requireNonLegacyBackend(base: string, fetchImpl: FetchLike = fetch): Promise<BackendKind> {
  const kind = await classifyBackend(base, fetchImpl)
  if (kind === "legacy") {
    const port = new URL(base).port || "80"
    throw new Error(legacyBackendMessage(port, await legacyActiveOperations(base, fetchImpl)))
  }
  return kind
}
