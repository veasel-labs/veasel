import { execFileSync, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { openDesktop, type Desktop } from './fixtures';

/**
 * Disposable environment for the Focus journeys. Everything lives under one
 * scratch root: HOME, XDG_*, VEASEL_DATA_DIR, the fake installed CLIs and the
 * git repository the "agent" edits. Nothing here reads the developer's real
 * config, keyring or display.
 */

const FAKE_DIR = path.join(__dirname, 'fake-cli');
export const REPO_NAME = 'focus-fixture';

export interface JourneyEnv {
  /** Backend API bearer token, chosen here and handed to the app via VEASEL_API_TOKEN; never read from disk. */
  token: string;
  root: string;
  binDir: string;
  dataDir: string;
  /** JSONL written by the fake CLIs: one line per spawn / approval / side effect. */
  cliLog: string;
  repo: string;
}

export interface CliLogEntry {
  cli: 'claude' | 'codex';
  event: string;
  pid: number;
  cwd?: string;
  argv?: string[];
  scenario?: string;
  file?: string;
  at: number;
}

/** Refuse to run anywhere but a throwaway X display: the live session must never get a window. */
export function assertIsolatedDisplay(): void {
  if (process.env['VEASEL_E2E_XVFB'] !== '1' || !process.env['DISPLAY']) {
    throw new Error(
      'Focus journeys open real windows. Run them through `xvfb-run -a` with VEASEL_E2E_XVFB=1 ' +
        '(see docs/desktop/E2E_EVIDENCE.md); refusing to touch the live display.',
    );
  }
}

export function sha256(file: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

export function git(repo: string, ...args: string[]): string {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
}

/** The repo's own test command, run by the test (not by the UI or the agent). */
export function runRepoTests(repo: string): { code: number; output: string } {
  const run = spawnSync('node', ['test.js'], { cwd: repo, encoding: 'utf8' });
  return { code: run.status ?? -1, output: `${run.stdout}${run.stderr}` };
}

export function readCliLog(env: JourneyEnv): CliLogEntry[] {
  if (!fs.existsSync(env.cliLog)) return [];
  return fs
    .readFileSync(env.cliLog, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line) as CliLogEntry);
}

export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Paths under `<root>`; the repo sits inside the default harness so the backend allows linking it. */
export function planJourneyEnv(root: string): JourneyEnv {
  const home = path.join(root, 'home');
  return {
    token: crypto.randomBytes(32).toString('hex'),
    root,
    binDir: path.join(root, 'fake-bin'),
    dataDir: path.join(root, 'veasel-data'),
    cliLog: path.join(root, 'fake-cli.jsonl'),
    repo: path.join(home, '.ai-workspace', 'repos', 'local', REPO_NAME),
  };
}

/** Installs the fake `claude`/`codex` and the credential probe files the registry looks for. */
export function installFakeClis(env: JourneyEnv, home: string): void {
  fs.mkdirSync(env.binDir, { recursive: true });
  for (const [name, source] of [
    ['claude', 'fake-claude.mjs'],
    ['codex', 'fake-codex.mjs'],
  ] as const) {
    const target = path.join(env.binDir, name);
    fs.copyFileSync(path.join(FAKE_DIR, source), target);
    fs.chmodSync(target, 0o755);
  }
  // Presence-only probes (provider_cli_registry.v); the content is never read.
  for (const probe of ['.claude/.credentials.json', '.codex/auth.json']) {
    const file = path.join(home, probe);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, '{"fake":true}\n', { mode: 0o600 });
  }
}

/** A git repo with one failing test: add() subtracts. Deterministic content and commit. */
export function createFixtureRepo(repo: string): void {
  fs.mkdirSync(path.join(repo, 'src'), { recursive: true });
  fs.writeFileSync(
    path.join(repo, 'src', 'math.js'),
    'function add(a, b) {\n  return a - b;\n}\nmodule.exports = { add };\n',
  );
  fs.writeFileSync(
    path.join(repo, 'test.js'),
    "const assert = require('node:assert');\nconst { add } = require('./src/math.js');\nassert.strictEqual(add(2, 3), 5);\nconsole.log('ok');\n",
  );
  fs.writeFileSync(path.join(repo, 'README.md'), '# Fixture\n');
  const run = (...args: string[]) => git(repo, ...args);
  run('init', '-q', '-b', 'main');
  run('config', 'user.name', 'Fixture');
  run('config', 'user.email', 'fixture@example.invalid');
  run('config', 'commit.gpgsign', 'false');
  run('add', '.');
  run('commit', '-q', '-m', 'fixture: failing add()');
}

export function backendBinaryUnderTest(): string {
  const bin = process.env['VEASEL_BACKEND_BIN'];
  if (!bin || !fs.existsSync(bin)) {
    throw new Error('Set VEASEL_BACKEND_BIN to a built `veasel` binary (the V backend Focus talks to).');
  }
  return bin;
}

export interface BackendProcess {
  pid: number;
  port: number;
}

/** The `veasel serve` Desktop spawned for this scratch data dir, found via /proc (not via the UI). */
export function findBackend(env: JourneyEnv): BackendProcess | null {
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const cmdline = fs.readFileSync(`/proc/${entry}/cmdline`, 'utf8').split('\0');
      if (path.basename(cmdline[0] ?? '') !== 'veasel' || cmdline[1] !== 'serve') continue;
      const vars = new Map(
        fs
          .readFileSync(`/proc/${entry}/environ`, 'utf8')
          .split('\0')
          .map((pair) => [pair.slice(0, pair.indexOf('=')), pair.slice(pair.indexOf('=') + 1)] as const),
      );
      if (vars.get('VEASEL_DATA_DIR') !== env.dataDir) continue;
      return { pid: Number(entry), port: Number(vars.get('VEASEL_PORT')) };
    } catch {
      // Process exited or is not ours.
    }
  }
  return null;
}

/** Authenticated request straight to the backend, bypassing the Desktop UI. */
export async function backendApi<T>(
  env: JourneyEnv,
  backend: BackendProcess,
  route: string,
  init: RequestInit = {},
): Promise<T> {
  const response = await fetch(`http://127.0.0.1:${backend.port}${route}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${env.token}`,
      ...((init.headers as Record<string, string> | undefined) ?? {}),
    },
  });
  if (!response.ok) throw new Error(`${route} -> HTTP ${response.status}: ${await response.text()}`);
  return (await response.json()) as T;
}

/** The conventional backend port Desktop would attach to instead of spawning its own. */
export async function assertNoForeignBackend(): Promise<void> {
  const alive = await fetch('http://127.0.0.1:4097/v1/health').then(
    () => true,
    () => false,
  );
  if (alive) {
    throw new Error('A Veasel backend already listens on 127.0.0.1:4097; Desktop would attach to it. Stop it first.');
  }
}

export interface LaunchOptions {
  /** Reuse a previous scratch root (J7/J9/J10 relaunch against the same data). */
  existing?: JourneyEnv;
}

/** Launch Desktop on an isolated display with the fake CLIs first on PATH. */
export async function launchFocusDesktop(options: LaunchOptions = {}): Promise<{ desktop: Desktop; env: JourneyEnv }> {
  assertIsolatedDisplay();
  await assertNoForeignBackend();
  const backendBin = backendBinaryUnderTest();
  const fresh = options.existing === undefined;
  const root = options.existing?.root ?? fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-focus-journeys-'));
  const env = options.existing ?? planJourneyEnv(root);
  // The legacy Agent Toolkit backend is disabled in Desktop (#728): no `workspace init`, and the binary the shared
  // fixture insists on is only a placeholder.
  process.env['ATK_E2E_BACKEND_BIN'] ??= backendBin;
  const desktop = await openDesktop({
    initWorkspace: false,
    root,
    extraArgs: [
      '--ozone-platform=x11',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      // Only inside the capability-dropped container (see e2e/docker); never on a developer host.
      ...(process.env['VEASEL_E2E_NO_SANDBOX'] === '1' ? ['--no-sandbox'] : []),
    ],
    extraEnv: {
      PATH: env.binDir,
      FAKE_CLI_LOG: env.cliLog,
      VEASEL_DATA_DIR: env.dataDir,
      VEASEL_API_TOKEN: env.token,
      VEASEL_BACKEND_BIN: backendBin,
      VEASEL_SECRET_STORE: 'file',
      // Bounded approval wait: long enough for a click-driven approval, short enough that J11 sees expiry.
      VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS: '45',
      XDG_STATE_HOME: path.join(root, 'home', '.local', 'state'),
      XDG_CACHE_HOME: path.join(root, 'home', '.cache'),
      NO_AT_BRIDGE: '1',
    },
    prepare: ({ home }) => {
      if (!fresh) return;
      fs.mkdirSync(env.dataDir, { recursive: true });
      installFakeClis(env, home);
    },
  });
  // The workspace is scaffolded by openDesktop; the repo goes inside it afterwards.
  if (fresh) createFixtureRepo(env.repo);
  return { desktop, env };
}

/** SIGTERM, bounded wait, then SIGKILL; resolves once the process is gone. */
export async function terminate(pid: number, waitMs = 3_000): Promise<void> {
  if (!isAlive(pid)) return;
  try {
    process.kill(pid, 'SIGTERM');
  } catch {
    return;
  }
  const deadline = Date.now() + waitMs;
  while (isAlive(pid) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 100));
  if (isAlive(pid)) {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      return;
    }
    while (isAlive(pid) && Date.now() < deadline + 3_000) await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

/** Stops every fake CLI process recorded in the spawn log (and waits for it to exit). */
export async function stopSpawnedClis(env: JourneyEnv): Promise<void> {
  for (const entry of readCliLog(env)) if (entry.event === 'spawn') await terminate(entry.pid);
}

/** Removes a scratch directory, retrying while a dying process still holds files in it. */
export async function removeDirectory(dir: string): Promise<void> {
  await fs.promises.rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
