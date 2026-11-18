import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

/**
 * Owns the Veasel V backend child process for the Desktop shell.
 *
 * The V backend is the ONLY agent runtime (ADR-0001): this supervisor
 * only starts or attaches to `veasel serve` on loopback, never exposes
 * it on a LAN, and never runs a second engine. Binary resolution order:
 * VEASEL_BACKEND_BIN (authoritative) > bundled resources/bin > PATH.
 */

export type VeaselBackendStatus = 'starting' | 'ready' | 'failed' | 'stopped';

export interface VeaselBackendState {
  status: VeaselBackendStatus;
  url: string | null;
  problem: string | null;
}

export interface VeaselBackendOptions {
  userDataDir: string;
  resourcesDir?: string;
  env?: NodeJS.ProcessEnv;
  /** Test seam; production uses the canonical Veasel data dir. */
  dataDir?: string;
  /** Test seam; production uses the backend's conventional loopback URL. */
  conventionalUrl?: string;
}

const HEALTH_TIMEOUT_MS = 30_000;
const GENERATED_API_TOKEN = /^[0-9a-f]{64}$/;

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port = typeof address === 'object' && address ? address.port : 0;
      server.close(() => resolve(port));
    });
  });
}

export function veaselBackendBinaryCandidates(options: VeaselBackendOptions): string[] {
  const env = options.env ?? process.env;
  const exe = process.platform === 'win32' ? 'veasel.exe' : 'veasel';
  const candidates: string[] = [];
  if (env.VEASEL_BACKEND_BIN) candidates.push(env.VEASEL_BACKEND_BIN);
  if (options.resourcesDir) candidates.push(path.join(options.resourcesDir, 'bin', exe));
  candidates.push(exe);
  return candidates;
}

export interface VeaselBackendIdentity {
  version: string;
  pid: number;
}

/**
 * Canonical Veasel data dir, mirroring `default_data_dir()` in main.v:
 * `$VEASEL_DATA_DIR` or `~/.local/share/veasel`. Desktop-spawned backends
 * must use the same store as the TUI/CLI (one runtime, shared sessions),
 * never a Desktop-private directory.
 */
export function canonicalVeaselDataDir(env: NodeJS.ProcessEnv = process.env, homeDir: string = os.homedir()): string {
  return env.VEASEL_DATA_DIR ?? path.join(homeDir, '.local', 'share', 'veasel');
}

/** Identity is proven only by the Veasel health payload, never a bare 200. */
export function veaselHealthIdentity(body: unknown): VeaselBackendIdentity | null {
  if (typeof body !== 'object' || body === null) return null;
  const health = body as Record<string, unknown>;
  if (health.healthy !== true) return null;
  if (typeof health.version !== 'string' || health.version.length === 0) return null;
  if (typeof health.pid !== 'number' || !Number.isInteger(health.pid) || health.pid <= 0) return null;
  return { version: health.version, pid: health.pid };
}

/**
 * The backend's API bearer token (docs/security/backend-caller-auth.md):
 * `VEASEL_API_TOKEN` when set, else the `api-token` file in the data dir,
 * which the backend creates 0600. A group/world-accessible file is not
 * trusted (the backend refuses to serve with one). Main-process only: the
 * renderer never receives this value; the renderer proxy injects it.
 */
export function readBackendApiToken(
  env: NodeJS.ProcessEnv = process.env,
  dataDir: string = canonicalVeaselDataDir(env),
): string | null {
  if (env.VEASEL_API_TOKEN) return env.VEASEL_API_TOKEN;
  const file = path.join(dataDir, 'api-token');
  let fd: number | undefined;
  try {
    // Open once and validate the SAME descriptor (no stat-then-read race).
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return null;
    if (process.platform !== 'win32') {
      if ((stat.mode & 0o077) !== 0) return null;
      if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) return null;
    }
    const token = fs.readFileSync(fd, 'utf8').trim();
    return GENERATED_API_TOKEN.test(token) ? token : null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export type BackendKind = 'absent' | 'secure' | 'legacy';

async function probeNoCredentials(url: string): Promise<Response | undefined> {
  try {
    // No Authorization header: an unverified server must never see the token.
    return await fetch(url, { headers: {}, signal: AbortSignal.timeout(1500) });
  } catch {
    return undefined;
  }
}

/**
 * Classifies the server on `base` without sending any credential. `secure`
 * requires health to advertise bearer auth AND an unauthenticated protected
 * route to be refused; anything reachable that cannot prove that (an older
 * backend, a server that only claims it, unparseable output) is `legacy`.
 */
export async function classifyVeaselBackend(base: string): Promise<BackendKind> {
  const health = await probeNoCredentials(`${base}/v1/health`);
  if (!health) return 'absent';
  if (health.status !== 200) return 'legacy';
  let body: unknown;
  try {
    body = await health.json();
  } catch {
    return 'legacy';
  }
  const liveness = body as { healthy?: unknown; auth?: unknown; protocol?: unknown } | null;
  if (!liveness || liveness.healthy !== true || liveness.auth !== 'bearer') return 'legacy';
  if (typeof liveness.protocol !== 'number' || liveness.protocol < 1) return 'legacy';
  const protectedRoute = await probeNoCredentials(`${base}/v1/capabilities`);
  return protectedRoute?.status === 401 ? 'secure' : 'legacy';
}

async function legacyActiveOperations(base: string): Promise<number | undefined> {
  const response = await probeNoCredentials(`${base}/v1/operations`);
  if (!response || response.status !== 200) return undefined;
  try {
    const page = (await response.json()) as { operations?: Array<{ operation?: { status?: string } }> };
    if (!Array.isArray(page.operations)) return undefined;
    return page.operations.filter((row) => row.operation?.status === 'running' || row.operation?.status === 'queued')
      .length;
  } catch {
    return undefined;
  }
}

export function legacyBackendMessage(port: string, active: number | undefined): string {
  const impact =
    active === undefined
      ? 'It may be running turns; stopping it interrupts them.'
      : active > 0
        ? `${active} turn(s) are running or queued on it and will be interrupted if you stop it.`
        : 'No running or queued turns were reported (checked with a read-only request).';
  return [
    `A legacy Veasel backend without caller authentication is running on 127.0.0.1:${port} (or another server that cannot prove authentication holds that port). Any local process can control it, so Veasel Desktop will not attach to it or send it credentials. ${impact} Sessions are stored in SQLite and are kept; only in-flight turns are lost.`,
    'To recover, stop it yourself and reopen Veasel (Veasel never stops a process it did not start):',
    `  Linux:   ss -ltnp "sport = :${port}"    then   kill <pid>`,
    `  macOS:   lsof -nP -iTCP:${port} -sTCP:LISTEN   then   kill <pid>`,
    `  Windows: netstat -ano | findstr :${port}   then   taskkill /PID <pid>`,
    'Two backends must never share one data directory, and a legacy process holds its directory without a lock, so Veasel will not start another backend beside it.',
  ].join('\n');
}

export async function probeVeaselBackend(url: string, apiToken?: string | null): Promise<VeaselBackendIdentity | null> {
  try {
    // Unauthenticated health is minimal liveness; identity (version, pid)
    // is only returned to a caller holding the token.
    const response = await fetch(`${url}/v1/health`, {
      headers: apiToken ? { authorization: `Bearer ${apiToken}` } : {},
    });
    if (response.status !== 200) return null;
    return veaselHealthIdentity(await response.json());
  } catch {
    return null;
  }
}

async function isHealthy(url: string, apiToken: string | null): Promise<boolean> {
  return (await probeVeaselBackend(url, apiToken)) !== null;
}

export class VeaselBackendSupervisor {
  private child: ChildProcess | null = null;
  private attached = false;
  private state: VeaselBackendState = { status: 'stopped', url: null, problem: null };
  private readonly listeners = new Set<(state: VeaselBackendState) => void>();

  constructor(private readonly options: VeaselBackendOptions) {}

  snapshot(): VeaselBackendState {
    return this.state;
  }

  /** Current backend token (re-read so `veasel token rotate` is honoured). */
  apiToken(): string | null {
    const env = this.options.env ?? process.env;
    return readBackendApiToken(env, this.options.dataDir ?? canonicalVeaselDataDir(env));
  }

  onState(listener: (state: VeaselBackendState) => void): void {
    this.listeners.add(listener);
  }

  private setState(state: VeaselBackendState): void {
    this.state = state;
    for (const listener of this.listeners) listener(state);
  }

  /** Attach to an already-running backend when possible, else spawn one. */
  async start(): Promise<VeaselBackendState> {
    if (this.state.status === 'ready' && this.state.url) return this.state;
    this.setState({ status: 'starting', url: null, problem: null });
    // Prefer the backend's conventional port so a TUI-started backend is
    // attached to (one runtime, shared sessions) instead of duplicated;
    // only spawn our own when nothing healthy answers there.
    const conventional = this.options.conventionalUrl ?? 'http://127.0.0.1:4097';
    const kind = await classifyVeaselBackend(conventional);
    if (kind === 'legacy') {
      // Never attach to (or spawn beside) a server that does not enforce
      // authentication; block with an explicit recovery message instead.
      const port = new URL(conventional).port || '80';
      this.setState({
        status: 'failed',
        url: null,
        problem: legacyBackendMessage(port, await legacyActiveOperations(conventional)),
      });
      return this.state;
    }
    if (kind === 'secure' && (await isHealthy(conventional, this.apiToken()))) {
      this.attached = true;
      this.setState({ status: 'ready', url: conventional, problem: null });
      return this.state;
    }
    const port = await freePort();
    const url = `http://127.0.0.1:${port}`;
    // Same canonical store the TUI/CLI use: Desktop-first and TUI-first
    // startups share sessions/profile instead of splitting SQLite stores.
    const dataDir = this.options.dataDir ?? canonicalVeaselDataDir(this.options.env ?? process.env);
    fs.mkdirSync(dataDir, { recursive: true });
    const env = {
      ...(this.options.env ?? process.env),
      VEASEL_PORT: String(port),
      VEASEL_DATA_DIR: dataDir,
      VEASEL_PLUGIN_DIR: path.join(dataDir, 'plugins'),
      // Desktop is an interactive client: CLI tool requests must surface as
      // durable pending approvals the user decides in Focus, not auto-deny.
      VEASEL_CLI_INTERACTIVE_APPROVALS: '1',
    };
    let lastError: string | null = null;
    for (const candidate of veaselBackendBinaryCandidates(this.options)) {
      try {
        this.child = spawn(candidate, ['serve'], {
          env,
          stdio: ['ignore', 'pipe', 'pipe'],
          windowsHide: true,
        });
      } catch (error) {
        lastError = error instanceof Error ? error.message : String(error);
        continue;
      }
      this.watchChild(this.child);
      const started = await this.waitHealthy(url);
      if (started) {
        this.setState({ status: 'ready', url, problem: null });
        return this.state;
      }
      lastError = `backend did not become healthy at ${url}`;
      this.killChild();
    }
    this.setState({ status: 'failed', url: null, problem: lastError ?? 'veasel backend unavailable' });
    return this.state;
  }

  private stopping = false;
  private childFailed = false;

  private watchChild(child: ChildProcess): void {
    this.childFailed = false;
    child.once('error', () => {
      this.childFailed = true;
    });
    child.once('exit', (code, signal) => {
      if (this.child === child) this.child = null;
      // A spawned backend that dies after ready must not leave the shell
      // believing a dead URL is live. Attached backends are not ours to
      // supervise, and stop() suppresses its own termination.
      if (!this.stopping && !this.attached && this.state.status === 'ready') {
        this.setState({
          status: 'failed',
          url: null,
          problem: `veasel backend exited unexpectedly (${signal ?? `code ${code ?? 'unknown'}`})`,
        });
      }
    });
  }

  private async waitHealthy(url: string): Promise<boolean> {
    const deadline = Date.now() + HEALTH_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (this.childFailed) return false;
      if (this.child && this.child.exitCode !== null) return false;
      if (await isHealthy(url, this.apiToken())) return true;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    return false;
  }

  private killChild(): void {
    if (this.child && this.child.exitCode === null) this.child.kill('SIGTERM');
    this.child = null;
  }

  async stop(): Promise<void> {
    this.stopping = true;
    // Never kill a backend we merely attached to (the TUI may own it).
    if (!this.attached) this.killChild();
    this.attached = false;
    this.setState({ status: 'stopped', url: null, problem: null });
  }
}
