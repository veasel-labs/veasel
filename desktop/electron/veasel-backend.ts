import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
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
}

const HEALTH_TIMEOUT_MS = 30_000;

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

async function isHealthy(url: string): Promise<boolean> {
  try {
    const response = await fetch(`${url}/v1/health`);
    return response.status === 200;
  } catch {
    return false;
  }
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
    const conventional = 'http://127.0.0.1:4097';
    if (await isHealthy(conventional)) {
      this.attached = true;
      this.setState({ status: 'ready', url: conventional, problem: null });
      return this.state;
    }
    const port = await freePort();
    const url = `http://127.0.0.1:${port}`;
    const dataDir = path.join(this.options.userDataDir, 'backend');
    fs.mkdirSync(dataDir, { recursive: true });
    const env = {
      ...(this.options.env ?? process.env),
      VEASEL_PORT: String(port),
      VEASEL_DATA_DIR: dataDir,
      VEASEL_PLUGIN_DIR: path.join(dataDir, 'plugins'),
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

  private async waitHealthy(url: string): Promise<boolean> {
    const deadline = Date.now() + HEALTH_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (this.child && this.child.exitCode !== null) return false;
      if (await isHealthy(url)) return true;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    return false;
  }

  private killChild(): void {
    if (this.child && this.child.exitCode === null) this.child.kill('SIGTERM');
    this.child = null;
  }

  async stop(): Promise<void> {
    // Never kill a backend we merely attached to (the TUI may own it).
    if (!this.attached) this.killChild();
    this.attached = false;
    this.setState({ status: 'stopped', url: null, problem: null });
  }
}
