import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
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
  /** Test seam; production uses the same loopback port as the terminal launcher. */
  conventionalUrl?: string;
  /** Working directory for a newly spawned server; an attached server keeps its owner’s cwd. */
  workingDirectory?: () => string;
  /** Secure Desktop-owned MCP credentials, decrypted only for the child process environment. */
  resolveEnvironmentSecrets?: () => Record<string, string>;
  /** Previously managed names removed from the secure store; strip stale inherited values. */
  resolveClearedEnvironmentSecretNames?: () => string[];
}

const HEALTH_TIMEOUT_MS = 30_000;
const STOP_GRACE_MS = 5_000;
const KILL_GRACE_MS = 1_000;
const GENERATED_API_TOKEN = /^[0-9a-f]{64}$/;

export function resolveVeaselBackendUrl(env: NodeJS.ProcessEnv): string {
  const value = env.VEASEL_PORT?.trim();
  const requested = value && /^\+?\d+$/.test(value) ? Number(value) : 0;
  // Mirror main.v: unset, invalid, or out-of-range values use port 4097.
  const port = requested > 0 && requested < 65536 ? requested : 4097;
  return `http://127.0.0.1:${port}`;
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

export function veaselBackendEnvironment(
  inherited: NodeJS.ProcessEnv,
  secrets: Record<string, string>,
  clearedNames: string[],
): NodeJS.ProcessEnv {
  const environment = { ...inherited };
  for (const name of clearedNames) delete environment[name];
  return { ...environment, ...secrets };
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
      signal: AbortSignal.timeout(1500),
    });
    if (response.status !== 200) return null;
    return veaselHealthIdentity(await response.json());
  } catch {
    return null;
  }
}

export class VeaselBackendSupervisor {
  private child: ChildProcess | null = null;
  private starting: Promise<VeaselBackendState> | null = null;
  private attached = false;
  private state: VeaselBackendState = { status: 'stopped', url: null, problem: null };
  private readonly listeners = new Set<(state: VeaselBackendState) => void>();

  constructor(private readonly options: VeaselBackendOptions) {}

  snapshot(): VeaselBackendState {
    return this.state;
  }

  isAttached(): boolean {
    return this.attached;
  }

  /** Restart only a child owned by Desktop. An attached TUI server is never stopped. */
  async restart(): Promise<boolean> {
    if (this.starting) await this.starting;
    if (this.attached) return false;
    await this.stop();
    return (await this.start()).status === 'ready';
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
  start(): Promise<VeaselBackendState> {
    if (this.starting) return this.starting;
    if (this.state.status === 'ready' && this.state.url) return Promise.resolve(this.state);
    this.stopping = false;
    this.starting = Promise.resolve()
      .then(() => this.startOrAttach())
      .finally(() => {
        this.starting = null;
      });
    return this.starting;
  }

  private async startOrAttach(): Promise<VeaselBackendState> {
    if (this.stopping) return this.state;
    this.setState({ status: 'starting', url: null, problem: null });
    const url = this.options.conventionalUrl ?? resolveVeaselBackendUrl(this.options.env ?? process.env);
    if (await this.useExistingBackend(url)) return this.state;
    // The terminal discovers the backend on this same port in either start order.
    const dataDir = this.options.dataDir ?? canonicalVeaselDataDir(this.options.env ?? process.env);
    fs.mkdirSync(dataDir, { recursive: true });
    const env = {
      ...veaselBackendEnvironment(
        this.options.env ?? process.env,
        this.options.resolveEnvironmentSecrets?.() ?? {},
        this.options.resolveClearedEnvironmentSecretNames?.() ?? [],
      ),
      VEASEL_PORT: new URL(url).port || '80',
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
          cwd: this.options.workingDirectory?.(),
          stdio: ['ignore', 'pipe', 'pipe'],
          windowsHide: true,
        });
      } catch (error) {
        lastError = error instanceof Error ? error.message : String(error);
        continue;
      }
      this.watchChild(this.child);
      const started = await this.waitHealthy(url, this.child);
      if (started && !this.stopping) {
        this.setState({ status: 'ready', url, problem: null });
        return this.state;
      }
      lastError = `backend did not become healthy at ${url}`;
      await this.killChild();
      // A terminal launcher may have won the bind race in the meantime.
      if (await this.useExistingBackend(url)) return this.state;
    }
    this.setState({ status: 'failed', url: null, problem: lastError ?? 'veasel backend unavailable' });
    return this.state;
  }

  private async useExistingBackend(url: string): Promise<boolean> {
    if (this.stopping) return true;
    const kind = await classifyVeaselBackend(url);
    if (this.stopping) return true;
    if (kind === 'absent') return false;
    const port = new URL(url).port || '80';
    if (kind === 'legacy') {
      const active = await legacyActiveOperations(url);
      if (!this.stopping) {
        this.setState({ status: 'failed', url: null, problem: legacyBackendMessage(port, active) });
      }
      return true;
    }
    const identity = await probeVeaselBackend(url, this.apiToken());
    if (this.stopping) return true;
    if (identity) {
      this.attached = true;
      this.setState({ status: 'ready', url, problem: null });
    } else {
      this.setState({
        status: 'failed',
        url: null,
        problem: `A Veasel backend at ${url} is using a different profile or credential. Use the same VEASEL_DATA_DIR and token as the terminal, or choose another VEASEL_PORT for a separate profile.`,
      });
    }
    return true;
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

  private async waitHealthy(url: string, child: ChildProcess): Promise<boolean> {
    const deadline = Date.now() + HEALTH_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (this.stopping || this.childFailed || this.child !== child || child.exitCode !== null) return false;
      const kind = await classifyVeaselBackend(url);
      if (kind === 'secure') {
        const identity = await probeVeaselBackend(url, this.apiToken());
        if (identity) return identity.pid === child.pid && this.child === child;
      } else if (kind === 'legacy') {
        return false;
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    return false;
  }

  private async killChild(): Promise<void> {
    const child = this.child;
    this.child = null;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    await new Promise<void>((resolve) => {
      let settled = false;
      let killTimer: ReturnType<typeof setTimeout> | undefined;
      let graceTimer: ReturnType<typeof setTimeout> | undefined;
      const finish = () => {
        if (settled) return;
        settled = true;
        if (graceTimer) clearTimeout(graceTimer);
        if (killTimer) clearTimeout(killTimer);
        child.removeListener('exit', onExit);
        child.removeListener('error', onError);
        resolve();
      };
      const onExit = () => finish();
      const onError = () => finish();
      child.once('exit', onExit);
      child.once('error', onError);
      if (child.exitCode !== null || child.signalCode !== null) {
        finish();
        return;
      }
      killTimer = setTimeout(() => {
        try {
          child.kill('SIGKILL');
        } catch {
          // already gone
        }
        graceTimer = setTimeout(finish, KILL_GRACE_MS);
      }, STOP_GRACE_MS);
      try {
        if (!child.kill('SIGTERM')) finish();
      } catch {
        finish();
      }
    });
  }

  async stop(): Promise<void> {
    this.stopping = true;
    this.setState({ status: 'stopped', url: null, problem: null });
    // Never kill a backend we merely attached to (the TUI may own it).
    if (!this.attached) await this.killChild();
    await this.starting?.catch(() => undefined);
    this.attached = false;
  }
}
