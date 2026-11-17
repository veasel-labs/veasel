import { symlinkSync } from "node:fs"
import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { apiTokenPath, createApiTokenSource, withBackendAuth } from "./backend-auth"

let dir: string
const T1 = "a".repeat(64)
const T2 = "b".repeat(64)

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "veasel-tui-auth-"))
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

describe("api token discovery", () => {
  test("env override wins over the file", () => {
    writeFileSync(join(dir, "api-token"), `${T1}\n`, { mode: 0o600 })
    const source = createApiTokenSource({ VEASEL_DATA_DIR: dir, VEASEL_API_TOKEN: "env-token" }, dir)
    expect(source()).toBe("env-token")
  })

  test("reads the data-dir file and picks up rotation without restart", () => {
    const path = join(dir, "api-token")
    writeFileSync(path, `${T1}\n`, { mode: 0o600 })
    const source = createApiTokenSource({ VEASEL_DATA_DIR: dir }, dir)
    expect(source()).toBe(T1)
    writeFileSync(path, `${T2}\n`, { mode: 0o600 })
    expect(source()).toBe(T2)
  })

  test("refuses a group/world readable file and a missing file", () => {
    const path = join(dir, "api-token")
    const source = createApiTokenSource({ VEASEL_DATA_DIR: dir }, dir)
    expect(source()).toBeUndefined()
    writeFileSync(path, "tok\n", { mode: 0o600 })
    chmodSync(path, 0o644)
    if (process.platform !== "win32") expect(source()).toBeUndefined()
  })

  test("refuses a symlinked file and a malformed token", () => {
    const real = join(dir, "real")
    writeFileSync(real, `${T1}\n`, { mode: 0o600 })
    symlinkSync(real, join(dir, "api-token"))
    const source = createApiTokenSource({ VEASEL_DATA_DIR: dir }, dir)
    if (process.platform !== "win32") expect(source()).toBeUndefined()
    rmSync(join(dir, "api-token"))
    writeFileSync(join(dir, "api-token"), "not-a-token\n", { mode: 0o600 })
    expect(source()).toBeUndefined()
  })

  test("default location is under the user data dir", () => {
    expect(apiTokenPath({}, "/home/u")).toBe("/home/u/.local/share/veasel/api-token")
  })
})

describe("withBackendAuth", () => {
  const base = "http://127.0.0.1:4097"
  const capture = () => {
    const seen: Array<{ url: string; auth: string | null }> = []
    const inner = (async (input: RequestInfo | URL, init?: RequestInit) => {
      seen.push({ url: String(input), auth: new Headers(init?.headers).get("authorization") })
      return new Response("{}")
    }) as typeof fetch
    return { seen, inner }
  }

  test("re-reads the token and retries once after a 401 from a rotated token", async () => {
    let current = "old"
    const seen: Array<string | null> = []
    const inner = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      const auth = new Headers(init?.headers).get("authorization")
      seen.push(auth)
      return new Response("{}", { status: auth === "Bearer new" ? 200 : 401 })
    }) as typeof fetch
    const source = () => {
      const value = current
      // Rotation happens while the request is in flight.
      current = "new"
      return value
    }
    const wrapped = withBackendAuth(base, source, inner)
    const response = await wrapped(`${base}/v1/sessions`, { method: "POST", body: "{}" })
    expect(response.status).toBe(200)
    expect(seen).toEqual(["Bearer old", "Bearer new"])
  })

  test("does not retry when the token did not change, or the body cannot be replayed", async () => {
    const seen: Array<string | null> = []
    const inner = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      seen.push(new Headers(init?.headers).get("authorization"))
      return new Response("{}", { status: 401 })
    }) as typeof fetch
    const same = await withBackendAuth(base, () => "same", inner)(`${base}/x`)
    expect(same.status).toBe(401)
    expect(seen).toEqual(["Bearer same"])
    seen.length = 0
    let n = 0
    const rotating = withBackendAuth(base, () => `t${n++}`, inner)
    await rotating(`${base}/x`, { method: "POST", body: new ReadableStream() as unknown as BodyInit })
    expect(seen).toHaveLength(1)
  })

  test("adds the bearer token for the backend origin only", async () => {
    const { seen, inner } = capture()
    const wrapped = withBackendAuth(base, () => "tok", inner)
    await wrapped(`${base}/v1/sessions`, { method: "POST", headers: { "content-type": "application/json" } })
    await wrapped("https://example.com/v1/sessions")
    expect(seen[0]!.auth).toBe("Bearer tok")
    expect(seen[1]!.auth).toBeNull()
  })

  test("never overrides an explicit Authorization header and tolerates a missing token", async () => {
    const { seen, inner } = capture()
    await withBackendAuth(base, () => "tok", inner)(`${base}/x`, { headers: { authorization: "Bearer mine" } })
    await withBackendAuth(base, () => undefined, inner)(`${base}/x`)
    expect(seen[0]!.auth).toBe("Bearer mine")
    expect(seen[1]!.auth).toBeNull()
  })
})
