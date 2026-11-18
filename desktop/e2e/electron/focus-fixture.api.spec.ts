/* eslint-disable no-empty-pattern -- Playwright requires an object-destructured first argument; these specs use no fixtures. */
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { expect, test } from '@playwright/test';
import {
  backendBinaryUnderTest,
  backendApi,
  createFixtureRepo,
  git,
  installFakeClis,
  isAlive,
  planJourneyEnv,
  readCliLog,
  runRepoTests,
  sha256,
  type BackendProcess,
  type JourneyEnv,
} from './journey-env';

/**
 * Proves the fake installed-CLI fixture and every oracle the click-driven
 * journeys rely on, against the REAL V backend over HTTP and WITHOUT Electron
 * or a display. If one of these fails, a journey result would be meaningless.
 */

interface Operation {
  id: string;
  status?: string;
}
interface Approval {
  id: string;
  tool_name: string;
  status: string;
}

let env: JourneyEnv;
let backend: BackendProcess;
let child: ChildProcess;

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = (server.address() as net.AddressInfo).port;
      server.close(() => resolve(port));
    });
  });
}

async function until<T>(
  what: string,
  probe: () => Promise<T | null | undefined | false> | T | null | undefined | false,
  ms = 30_000,
): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
}

const api = <T>(route: string, init?: RequestInit) => backendApi<T>(env, backend, route, init);
const asyncTurn = { Prefer: 'respond-async' };

async function newSession(): Promise<string> {
  const session = await api<{ id: string }>('/v1/sessions', {
    method: 'POST',
    body: JSON.stringify({ title: 'fixture', directory: env.repo }),
  });
  return session.id;
}

async function send(session: string, content: string, provider?: string, wait = false): Promise<void> {
  await api(`/v1/sessions/${session}/messages`, {
    method: 'POST',
    headers: wait ? {} : asyncTurn,
    body: JSON.stringify({ content, ...(provider ? { provider } : {}), permission_mode: 'ask' }),
  });
}

const pendingApprovals = async (session: string) =>
  (await api<Approval[]>(`/v1/sessions/${session}/cli-approvals`)).filter((approval) => approval.status === 'pending');

test.describe.configure({ mode: 'serial' });

test.beforeAll(async () => {
  const bin = backendBinaryUnderTest();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-focus-api-'));
  env = planJourneyEnv(root);
  const home = path.join(root, 'home');
  fs.mkdirSync(env.dataDir, { recursive: true });
  installFakeClis(env, home);
  createFixtureRepo(env.repo);
  const port = await freePort();
  child = spawn(bin, ['serve'], {
    env: {
      ...process.env,
      HOME: home,
      XDG_CONFIG_HOME: path.join(home, '.config'),
      XDG_DATA_HOME: path.join(home, '.local', 'share'),
      XDG_STATE_HOME: path.join(home, '.local', 'state'),
      VEASEL_PORT: String(port),
      VEASEL_DATA_DIR: env.dataDir,
      VEASEL_PLUGIN_DIR: path.join(env.dataDir, 'plugins'),
      VEASEL_SECRET_STORE: 'file',
      VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS: '5',
      VEASEL_CLI_INTERACTIVE_APPROVALS: '1',
      FAKE_CLI_LOG: env.cliLog,
      PATH: `${env.binDir}${path.delimiter}${process.env['PATH'] ?? ''}`,
    },
    stdio: [
      'ignore',
      fs.openSync(path.join(root, 'backend.log'), 'a'),
      fs.openSync(path.join(root, 'backend.log'), 'a'),
    ],
  });
  backend = { pid: child.pid ?? -1, port };
  await until('backend health', async () => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/health`).catch(() => null);
    return response?.ok;
  });
});

test.afterEach(async ({}, testInfo) => {
  if (testInfo.status !== testInfo.expectedStatus) {
    console.log(`backend log:\n${fs.readFileSync(path.join(env.root, 'backend.log'), 'utf8').slice(-3000)}`);
    console.log(`fake CLI log:\n${JSON.stringify(readCliLog(env), null, 1)}`);
    const sessions = await api<Array<{ id: string }>>('/v1/sessions').catch(() => []);
    for (const session of sessions) {
      console.log(
        `operations ${session.id}: ${JSON.stringify(await api(`/v1/sessions/${session.id}/operations`).catch((e) => String(e)))}`,
      );
    }
  }
});

test.afterAll(() => {
  child?.kill('SIGKILL');
  if (env) fs.rmSync(env.root, { recursive: true, force: true });
});

test('discovery lists the installed fake CLIs', async () => {
  const statuses = await api<Array<{ id: string; installed: boolean; version: string }>>('/v1/providers/cli');
  const byId = new Map(statuses.map((status) => [status.id, status]));
  expect(byId.get('claude-code')?.installed).toBe(true);
  expect(byId.get('claude-code')?.version).toContain('fake');
  expect(byId.get('codex')?.installed).toBe(true);
});

test('#751 oracle: with an EMPTY global config the chosen CLI provider still runs; the spawned provider is the chosen one', async () => {
  const chosen = await newSession();
  await send(chosen, '[[echo]] hello', 'claude-code');
  await until('claude result', () =>
    readCliLog(env).some((entry) => entry.cli === 'claude' && entry.event === 'result'),
  );
  const spawns = readCliLog(env).filter((entry) => entry.event === 'spawn');
  expect(spawns.map((entry) => entry.cli)).toEqual(['claude']);
  const lastProvider = await until(
    'last_provider',
    async () => (await api<{ last_provider?: string }>(`/v1/sessions/${chosen}`)).last_provider,
  );
  expect(lastProvider).toBe('claude-code');

  // Control for #735: with no provider on the turn and no global default, the backend must refuse
  // rather than run something else, so the "spawned == chosen" oracle above can really fail.
  const unchosen = await newSession();
  await expect(send(unchosen, '[[echo]] hello again', undefined, true)).rejects.toThrow(/HTTP [45]\d\d/);
  expect(readCliLog(env).filter((entry) => entry.event === 'spawn')).toHaveLength(1);
});

test('oracle: approve turns the repo test red -> green and changes the file hash and git diff', async () => {
  const before = sha256(path.join(env.repo, 'src', 'math.js'));
  expect(runRepoTests(env.repo).code).not.toBe(0);
  expect(git(env.repo, 'status', '--porcelain')).toBe('');

  const session = await newSession();
  await send(session, '[[fix]] fix add()', 'claude-code');
  const [approval] = await until('edit approval', async () => {
    const pending = await pendingApprovals(session);
    return pending.length > 0 ? pending : null;
  });
  expect(approval?.tool_name).toBe('Edit');
  // Nothing may change before a human decision.
  expect(sha256(path.join(env.repo, 'src', 'math.js'))).toBe(before);
  await api(`/v1/sessions/${session}/cli-approvals/${approval?.id}/approve`, { method: 'POST', body: '{}' });
  await until('edit applied', () => readCliLog(env).some((entry) => entry.event === 'edit-applied'));

  expect(sha256(path.join(env.repo, 'src', 'math.js'))).not.toBe(before);
  expect(git(env.repo, 'diff', '--stat')).toContain('src/math.js');
  expect(runRepoTests(env.repo).code).toBe(0);
  git(env.repo, 'checkout', '--', '.');
});

test('oracle: reject leaves the repo byte-identical with no side effects', async () => {
  const readme = path.join(env.repo, 'README.md');
  const before = sha256(readme);
  const head = git(env.repo, 'rev-parse', 'HEAD');
  const session = await newSession();
  await send(session, '[[reject]] note in readme', 'claude-code');
  const [approval] = await until('readme approval', async () => {
    const pending = await pendingApprovals(session);
    return pending.length > 0 ? pending : null;
  });
  await api(`/v1/sessions/${session}/cli-approvals/${approval?.id}/reject`, { method: 'POST', body: '{}' });
  await until('denial recorded', () =>
    readCliLog(env).some((entry) => entry.event === 'edit-denied' && entry.file === 'README.md'),
  );
  expect(sha256(readme)).toBe(before);
  expect(git(env.repo, 'status', '--porcelain')).toBe('');
  expect(git(env.repo, 'rev-parse', 'HEAD')).toBe(head);
});

test('oracle: cancelling an in-flight operation kills the CLI process', async () => {
  // KNOWN PRODUCT BUG: the operation stays `cancelling` and the process lives until the turn
  // deadline. Expected to fail; when the backend is fixed this test flips and test.fail() must go.
  test.fail(true, 'cancel does not terminate the installed CLI process');
  const session = await newSession();
  await send(session, '[[slow]] keep going', 'claude-code');
  const spawned = await until('slow spawn', () =>
    readCliLog(env).find((entry) => entry.cli === 'claude' && entry.event === 'scenario' && entry.scenario === 'slow'),
  );
  expect(isAlive(spawned.pid)).toBe(true);
  const operation = await until('running operation', async () => {
    const operations = await api<Operation[]>(`/v1/sessions/${session}/operations`);
    return operations.find((candidate) => candidate.status === 'running');
  });
  await api(`/v1/sessions/${session}/operations/${operation.id}/cancel`, { method: 'POST', body: '{}' });
  await until('process gone', () => !isAlive(spawned.pid), 20_000);
});

test('#743 oracle: preferences are server-persisted; stale PATCH is 409; expired approval yields an honest outcome', async () => {
  const session = await newSession();
  const created = await api<{ prefs_version: number; permission_mode: string }>(`/v1/sessions/${session}`);
  const patched = await api<{ preferred_provider: string; permission_mode: string; prefs_version: number }>(
    `/v1/sessions/${session}`,
    {
      method: 'PATCH',
      body: JSON.stringify({
        preferred_provider: 'claude-code',
        permission_mode: 'ask',
        expected_prefs_version: created.prefs_version,
      }),
    },
  );
  expect(patched.preferred_provider).toBe('claude-code');
  expect(patched.prefs_version).toBeGreaterThan(created.prefs_version);
  // A second writer holding the old version must be refused, not silently win.
  await expect(
    api(`/v1/sessions/${session}`, {
      method: 'PATCH',
      body: JSON.stringify({ permission_mode: 'plan', expected_prefs_version: created.prefs_version }),
    }),
  ).rejects.toThrow(/HTTP 409.*prefs_version_conflict/s);

  // Turn without a per-turn provider: the stored preference decides (and an empty global config is fine).
  await send(session, '[[applyexpire]] fix then push');
  const [approval] = await until('edit approval', async () => {
    const pending = await pendingApprovals(session);
    return pending.length > 0 ? pending : null;
  });
  await api(`/v1/sessions/${session}/cli-approvals/${approval?.id}/approve`, { method: 'POST', body: '{}' });
  // The push approval is never answered: it must expire and be denied in-band.
  await until(
    'push approval to expire',
    async () => readCliLog(env).some((entry) => entry.event === 'push-denied'),
    40_000,
  );
  const operation = await until('completed operation', async () => {
    const operations = await api<Array<{ status: string; outcome?: string; outcome_summary?: string }>>(
      `/v1/sessions/${session}/operations`,
    );
    return operations.find((candidate) => candidate.status !== 'running' && candidate.status !== 'queued');
  });
  expect(operation.outcome).toBe('completed_with_denials');
  expect(runRepoTests(env.repo).code).toBe(0);
  expect(readCliLog(env).some((entry) => entry.event === 'push-allowed')).toBe(false);
  git(env.repo, 'checkout', '--', '.');
});
