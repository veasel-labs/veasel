/* eslint-disable no-empty-pattern -- Playwright requires an object-destructured first argument; these specs use no fixtures. */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { expect, test, type Locator, type Page, type TestInfo } from '@playwright/test';
import { record } from './evidence';
import type { Desktop } from './fixtures';
import {
  backendApi,
  findBackend,
  git,
  isAlive,
  launchFocusDesktop,
  readApiToken,
  readCliLog,
  REPO_NAME,
  runRepoTests,
  sha256,
  type JourneyEnv,
} from './journey-env';

/**
 * Click-driven Focus acceptance journeys (epic #689). Every UI step is a real
 * pointer/keyboard action located by role or label. Verdicts come from
 * independent oracles: the disposable repo (hash, git, the repo's own test run
 * by this file), the fake CLI's spawn log, and process liveness. What the UI
 * says is asserted only as an additional expectation, never as the oracle.
 *
 * Run only through `xvfb-run` (see docs/desktop/E2E_EVIDENCE.md); journey-env
 * refuses to launch otherwise.
 */

const TUI_SRC = path.resolve(__dirname, '..', '..', '..', 'tui', 'src');
const FIX_PROMPT = '[[fix]] Fix the failing test in src/math.js';

let desktop: Desktop;
let env: JourneyEnv;
let page: Page;
let sessionId = '';
let tracing = false;

const conversation = () => page.getByRole('log', { name: 'Conversation' });
const approval = () => page.getByRole('alertdialog', { name: 'Approval needed' });
const composer = () => page.getByRole('textbox', { name: 'Message' });
const repoFile = (relative: string) => path.join(env.repo, relative);
const snapshot = () => ({ status: git(env.repo, 'status', '--porcelain'), diff: git(env.repo, 'diff') });

async function startTracing(): Promise<void> {
  await page.context().tracing.start({ screenshots: true, snapshots: true });
  tracing = true;
}

async function launch(existing?: JourneyEnv): Promise<void> {
  const launched = await launchFocusDesktop({ existing });
  desktop = launched.desktop;
  env = launched.env;
  page = desktop.page;
  // Desktop is Focus-only now (no World badge): the form appearing means the shell is up.
  await expect(
    page
      .getByRole('heading', { name: 'What should we work on?' })
      .or(page.getByRole('navigation', { name: 'Sessions' }))
      .first(),
  ).toBeVisible({ timeout: 60_000 });
  await startTracing();
}

async function shot(testInfo: TestInfo, name: string): Promise<void> {
  await testInfo.attach(name, { body: await page.screenshot(), contentType: 'image/png' });
}

/**
 * Opens a FRESH seeded session and sends the first turn from the composer. One session per approval journey:
 * Focus mislabels turns after the first (live turn.finished events are always numbered 1), so approvals in a
 * second turn of the same session render in a stale turn and the composer stays locked (see J4c).
 */
async function startTurn(testInfo: TestInfo, text: string): Promise<string> {
  const id = await openSeededSession(testInfo);
  await composer().fill(text);
  await composer().press('Enter');
  // Independent oracle that the turn really started on the server (isolates later UI failures from send failures).
  await expect
    .poll(
      async () =>
        (await backendApi<Array<{ status: string }>>(env, await backend(), `/v1/sessions/${id}/operations`)).length +
        (await pendingApprovals()),
      { timeout: 30_000 },
    )
    .toBeGreaterThan(0)
    .catch(async () => {
      // Sync turns have no operation row until they end; fall back to the fake CLI having been spawned for this text.
      await expect
        .poll(() => readCliLog(env).filter((entry) => entry.event === 'scenario').length, { timeout: 30_000 })
        .toBeGreaterThan(0);
    });
  return id;
}

async function backend() {
  const found = findBackend(env);
  if (!found) throw new Error('Desktop backend process not found for this data dir');
  return found;
}

async function fetchRaw(route: string, method: string, body: unknown): Promise<{ status: number; body: string }> {
  const found = await backend();
  const token = readApiToken(env);
  const response = await fetch(`http://127.0.0.1:${found.port}${route}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.text() };
}

let streamSamples: number[] = [];
let serverDeltaCount = 0;
let seeded = 0;
let currentTitle = '';
let currentSession = '';

const pendingApprovals = async (): Promise<number> =>
  (
    await backendApi<Array<{ status: string }>>(env, await backend(), `/v1/sessions/${currentSession}/cli-approvals`)
  ).filter((entry) => entry.status === 'pending').length;

/** Reload and re-select the current session (a real "reopen"), which re-reads server state. */
async function reopenCurrent(): Promise<void> {
  await page.reload();
  await page
    .getByRole('navigation', { name: 'Sessions' })
    .getByRole('button', { name: new RegExp(currentTitle) })
    .click();
  await expect(conversation()).toBeVisible({ timeout: 20_000 });
}

/**
 * Waits until the BACKEND holds a pending approval (independent oracle), then makes sure the dialog is on
 * screen. If Focus did not push it live (known bug, see J3b) the session is reopened, which loads it.
 */
async function showApproval(): Promise<void> {
  await expect.poll(pendingApprovals, { timeout: 40_000 }).toBeGreaterThan(0);
  await approval()
    .waitFor({ timeout: 6_000 })
    .catch(() => reopenCurrent());
  await expect(approval()).toBeVisible({ timeout: 20_000 });
}

/**
 * Creates a session on the backend with stored preferences (#743), then opens it in the UI with a real
 * click. WORKAROUND for a product bug (see J2): the Focus start form cannot list or link a project in
 * Desktop main, so no session can be started from the form. Everything after the session exists
 * (composer, approvals, stop, reopen) is genuinely click/keyboard driven.
 */
async function openSeededSession(testInfo: TestInfo): Promise<string> {
  seeded += 1;
  const title = `journey-${seeded}`;
  currentTitle = title;
  const found = await backend();
  const created = await backendApi<{ id: string; prefs_version: number }>(env, found, '/v1/sessions', {
    method: 'POST',
    body: JSON.stringify({ title, directory: env.repo }),
  });
  await backendApi(env, found, `/v1/sessions/${created.id}`, {
    method: 'PATCH',
    body: JSON.stringify({
      preferred_provider: 'claude-code',
      permission_mode: 'ask',
      expected_prefs_version: created.prefs_version,
    }),
  });
  // The thread list loads at startup; a session created behind the UI's back appears after a reload.
  await page.reload();
  const entry = page.getByRole('navigation', { name: 'Sessions' }).getByRole('button', { name: new RegExp(title) });
  await expect(entry).toBeVisible({ timeout: 30_000 });
  await entry.click();
  await expect(conversation()).toBeVisible({ timeout: 20_000 });
  expect(await threadFromUrl()).toBe(created.id);
  currentSession = created.id;
  await shot(testInfo, `${title}-opened`);
  return created.id;
}

/** The selected session id; the app uses a hash router, so the query lives after `#/focus?`. */
function currentThread(): string | null {
  const hash = new URL(page.url()).hash;
  const query = hash.includes('?') ? hash.slice(hash.indexOf('?') + 1) : '';
  return new URLSearchParams(query).get('thread');
}

/** Independent tap on the backend's SSE stream: which events does the server really emit? */
async function tapEvents(): Promise<{ types: string[]; stop: () => void }> {
  const found = await backend();
  const token = readApiToken(env);
  const controller = new AbortController();
  const types: string[] = [];
  void fetch(`http://127.0.0.1:${found.port}/v1/events`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
    signal: controller.signal,
  })
    .then(async (response) => {
      const reader = response.body?.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (reader) {
        const chunk = await reader.read();
        if (chunk.done) break;
        buffer += decoder.decode(chunk.value, { stream: true });
        for (const match of buffer.matchAll(/^event: (.+)$/gm)) types.push(match[1] ?? '');
        buffer = buffer.slice(buffer.lastIndexOf('\n') + 1);
      }
    })
    .catch(() => undefined);
  return { types, stop: () => controller.abort() };
}

async function threadFromUrl(): Promise<string> {
  await expect.poll(currentThread).not.toBeNull();
  return currentThread() ?? '';
}

test.describe.configure({ mode: 'serial' });

test.afterEach(async ({}, testInfo) => {
  if (tracing && testInfo.status !== testInfo.expectedStatus) {
    await page.screenshot({ path: testInfo.outputPath('failure.png') }).catch(() => undefined);
  }
});

test.afterAll(async ({}, testInfo) => {
  if (tracing) {
    await page
      .context()
      .tracing.stop({ path: testInfo.outputPath('focus-journeys-trace.zip') })
      .catch(() => undefined);
  }
  await desktop?.close().catch(() => undefined);
  if (env) {
    for (const entry of readCliLog(env))
      if (entry.event === 'spawn' && isAlive(entry.pid)) process.kill(entry.pid, 'SIGKILL');
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('J1 clean first launch lists the installed CLI providers', async ({}, testInfo) => {
  await launch();
  await page.getByRole('navigation', { name: 'Destinations' }).getByRole('link', { name: 'Focus' }).click();
  await expect(page.getByRole('heading', { name: 'What should we work on?' })).toBeVisible();
  const agents = page.getByRole('group', { name: /Agent/ });
  await expect(agents.getByRole('radio', { name: /Claude Code/ })).toBeVisible();
  await expect(agents.getByRole('radio', { name: /Codex/ })).toBeVisible();
  await shot(testInfo, 'J1-providers');
  // Oracle: the backend's own discovery answer for this HOME, read directly.
  const statuses = await backendApi<Array<{ id: string; installed: boolean }>>(
    env,
    await backend(),
    '/v1/providers/cli',
  );
  const installed = statuses
    .filter((status) => status.installed)
    .map((status) => status.id)
    .sort();
  expect(installed).toEqual(expect.arrayContaining(['claude-code', 'codex']));
  expect(readCliLog(env).filter((entry) => entry.event === 'spawn')).toHaveLength(0);
  record(testInfo, 'J1', 'GET /v1/providers/cli installed ids; no CLI turn spawned', { installed });
});

test('J2 open the disposable git workspace', async ({}, testInfo) => {
  // KNOWN PRODUCT BUG (#728 side effect): the legacy ATK backend is disabled, but Focus still takes its
  // workspace path and project list from it (`backend.harness.path`, `useProjects`). Linking a folder fails
  // with "The workspace is still starting" forever and the project select never appears, so no session can
  // be started from the form. Oracle unchanged; expected to fail until Focus sources projects from the V backend.
  test.fail(true, 'Focus cannot link/list projects: it depends on the disabled legacy ATK backend (#728)');
  // The native folder picker is platform-owned; only its result is stubbed (as project-link.spec.ts does).
  await desktop.app.evaluate(({ dialog }, folder) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [folder] });
  }, env.repo);
  await testInfo.attach('atk-backend-status', {
    body: JSON.stringify(
      await page.evaluate(() =>
        (window as unknown as { atk: { backendStatus: () => Promise<unknown> } }).atk.backendStatus(),
      ),
      null,
      1,
    ),
    contentType: 'application/json',
  });
  // The workspace service warms up after launch ("still starting"); retry the real click until it links.
  await expect(async () => {
    await page.getByRole('button', { name: 'Choose a repository folder' }).click();
    await expect(page.getByLabel('Project')).toHaveValue(REPO_NAME, { timeout: 5_000 });
  }).toPass({ timeout: 20_000, intervals: [1_000, 3_000] });
  await shot(testInfo, 'J2-project');
  // Oracle: the workspace link on disk resolves to the disposable repo.
  const link = path.join(desktop.home, '.ai-workspace', 'projects', REPO_NAME);
  const resolved = fs.realpathSync(link);
  expect(resolved).toBe(fs.realpathSync(env.repo));
  record(testInfo, 'J2', 'workspace symlink realpath == disposable repo', { link, resolved });
});

test('J3 choose provider (no model) and prompt: chosen provider spawned, text streams incrementally', async ({}, testInfo) => {
  expect(runRepoTests(env.repo).code).not.toBe(0);
  // Provider and permission mode are the session's stored preferences (#743); NO model is chosen anywhere.
  sessionId = await openSeededSession(testInfo);
  await expect(page.getByTitle(/Reads freely/)).toContainText('Ask before changes');
  const tap = await tapEvents();
  await composer().fill(FIX_PROMPT);
  await composer().press('Enter');

  const lengths: number[] = [];
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline && (await pendingApprovals()) === 0) {
    const length = (
      await conversation()
        .innerText()
        .catch(() => '')
    ).length;
    if (lengths.at(-1) !== length) lengths.push(length);
    await page.waitForTimeout(80);
  }
  expect(await pendingApprovals()).toBeGreaterThan(0);
  await shot(testInfo, 'J3-turn-awaiting-approval');
  tap.stop();
  const serverDeltas = tap.types.filter((type) => type === 'assistant.delta').length;
  await testInfo.attach('sse-event-types', { body: JSON.stringify(tap.types), contentType: 'application/json' });
  streamSamples = lengths;
  serverDeltaCount = serverDeltas;
  expect(serverDeltas, 'the server must emit assistant.delta while the CLI streams').toBeGreaterThan(1);

  // Oracle (#735 regression): the only CLI process spawned for this turn is the chosen provider.
  const spawns = readCliLog(env).filter((entry) => entry.event === 'spawn');
  expect(spawns.map((entry) => entry.cli)).toEqual(['claude']);
  const operations = await backendApi<Array<{ resolved_provider?: string }>>(
    env,
    await backend(),
    `/v1/sessions/${sessionId}/operations`,
  );
  expect(operations.map((operation) => operation.resolved_provider)).toContain('claude-code');
  record(
    testInfo,
    'J3',
    'fake CLI spawn log == [claude]; operation.resolved_provider == claude-code; server emitted assistant.delta events',
    {
      spawned: spawns.map((entry) => entry.cli),
      serverDeltas,
    },
  );
});

test('J3c streamed text appears incrementally in the conversation', async () => {
  // KNOWN PRODUCT BUG: the server emitted assistant.delta events (J3 asserts that independently) but the
  // Focus conversation text did not change while the turn streamed. Oracle unchanged.
  test.fail(true, 'live assistant.delta text is not rendered in the Focus conversation');
  expect(
    streamSamples.length,
    `UI samples ${streamSamples.join(',')} vs ${serverDeltaCount} server deltas`,
  ).toBeGreaterThanOrEqual(3);
  expect(streamSamples.at(-1)).toBeGreaterThan(streamSamples[0] ?? 0);
});

test('J3b Focus shows the approval while the turn is still running (#751)', async ({}, testInfo) => {
  // KNOWN PRODUCT BUG: the Focus store loads pending approvals once per opened thread (ensureTimeline) and
  // otherwise only reacts to assistant.delta / session.turn_completed SSE events. An approval requested after the
  // last delta is never pushed, so the dialog stays invisible until the session is reopened (and the approval
  // may expire first). Oracle (backend holds a pending approval) is unchanged.
  test.fail(true, 'Focus does not show an approval requested mid-turn until the session is reopened');
  expect(await pendingApprovals()).toBeGreaterThan(0);
  try {
    await expect(approval()).toBeVisible({ timeout: 10_000 });
  } finally {
    await shot(testInfo, 'J3b-no-live-approval');
    if (!(await approval().isVisible())) {
      await reopenCurrent();
      await approval()
        .waitFor({ timeout: 10_000 })
        .catch(() => undefined);
      await testInfo.attach('after-reopen-aria', {
        body: await page.locator('main').ariaSnapshot(),
        contentType: 'text/plain',
      });
      await shot(testInfo, 'J3b-after-reopen');
    }
  }
});

test('J4 inspect the proposed edit and diff; approve turns the repo test red to green', async ({}, testInfo) => {
  const file = repoFile('src/math.js');
  const before = sha256(file);
  const red = runRepoTests(env.repo);
  expect(red.code).not.toBe(0);
  await expect(approval()).toContainText('return a - b;');
  await expect(approval()).toContainText('return a + b;');
  // Nothing may change while the human has not decided.
  expect(sha256(file)).toBe(before);
  expect(git(env.repo, 'status', '--porcelain')).toBe('');
  await shot(testInfo, 'J4-proposal');

  await approval().getByRole('button', { name: 'Allow once' }).click();
  await expect(approval()).toBeHidden({ timeout: 20_000 });
  await expect.poll(() => sha256(file), { timeout: 20_000 }).not.toBe(before);
  const green = runRepoTests(env.repo);
  expect(green.code, green.output).toBe(0);
  const diff = git(env.repo, 'diff');
  expect(diff).toContain('-  return a - b;');
  expect(diff).toContain('+  return a + b;');

  await shot(testInfo, 'J4-approved-diff');
  record(testInfo, 'J4', 'sha256(src/math.js) changed; node test.js exit red->green; git diff has the fix', {
    shaBefore: before,
    shaAfter: sha256(file),
    redExit: red.code,
    greenExit: green.code,
  });
});

test('J4b the Changes panel shows the git diff of the applied edit', async ({}, testInfo) => {
  // KNOWN PRODUCT BUG (same root cause as J2): ProjectChangesPanel reads the working tree through the disabled
  // legacy ATK backend, so it stays on "Reading working tree…" and never lists src/math.js. Oracle unchanged:
  // `git diff` in the disposable repo already contains the fix (asserted in J4).
  test.fail(true, 'Changes panel never loads: it depends on the disabled legacy ATK backend (#728)');
  const inspector = page.getByRole('complementary', { name: 'Changes and files' });
  await inspector.getByRole('tab', { name: 'Changes' }).click();
  await expect(inspector).toContainText('src/math.js', { timeout: 15_000 });
  await shot(testInfo, 'J4b-changes-panel');
  expect(git(env.repo, 'diff')).toContain('+  return a + b;');
});

test('J4c after the approved turn finishes the session returns to Ready', async () => {
  // KNOWN PRODUCT BUG: the thread status loaded with a pending approval ("Needs your answer") is never
  // cleared by the turn.finished event, so the composer stays disabled until the session is reopened.
  test.fail(true, 'thread status stays awaiting-approval after the turn completed');
  await expect(page.getByTitle(/Reads freely/)).toContainText('Ready', { timeout: 20_000 });
});

test('J5 a second proposal is rejected and changes nothing', async ({}, testInfo) => {
  const readme = repoFile('README.md');
  const readmeBefore = sha256(readme);
  const before = snapshot();
  const spawnsBefore = readCliLog(env).filter((entry) => entry.event === 'spawn').length;
  await startTurn(testInfo, '[[reject]] add a note to the README');
  await showApproval();
  await expect(approval()).toContainText('edited by fake agent');
  await shot(testInfo, 'J5-proposal');
  await approval().getByRole('button', { name: 'Don’t allow' }).click();
  await expect(approval()).toBeHidden({ timeout: 20_000 });
  await expect
    .poll(() => readCliLog(env).some((entry) => entry.event === 'edit-denied' && entry.file === 'README.md'))
    .toBe(true);
  expect(sha256(readme)).toBe(readmeBefore);
  expect(snapshot()).toEqual(before);
  expect(readCliLog(env).some((entry) => entry.event === 'edit-applied' && entry.file === 'README.md')).toBe(false);
  expect(readCliLog(env).filter((entry) => entry.event === 'spawn').length).toBe(spawnsBefore + 1);
  record(testInfo, 'J5', 'README sha256 and git status+diff identical; fake CLI logged edit-denied, no edit-applied', {
    readmeSha: readmeBefore,
  });
});

test('J6 cancelling an in-flight operation is honest and the process is gone', async ({}, testInfo) => {
  // KNOWN PRODUCT BUG (reproduced in the fixture spec): cancelling a CLI turn leaves the operation in
  // `cancelling` and the CLI process alive until the turn deadline, because run_claude_cli_turn only
  // watches its own timeout, not the cancel context. The oracle is NOT weakened: this test is
  // expected to fail until the backend kills the process on cancel; remove test.fail() then.
  test.fail(
    true,
    'Focus never shows a running installed-CLI turn (thread stays Ready, no Stop button), and cancel does not kill the CLI process (run_claude_cli_turn ignores cancellation)',
  );
  await startTurn(testInfo, '[[slow]] keep working');
  const stop = page.getByRole('button', { name: 'Stop' });
  await expect(stop).toBeVisible({ timeout: 30_000 });
  const slow = readCliLog(env)
    .filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow')
    .at(-1);
  expect(slow, 'slow CLI scenario started').toBeDefined();
  const pid = slow?.pid ?? -1;
  await expect.poll(() => isAlive(pid)).toBe(true);
  const before = snapshot();
  await stop.click();
  await expect(page.getByText('Stopped', { exact: true })).toBeVisible({ timeout: 20_000 });
  await expect.poll(() => isAlive(pid), { timeout: 20_000 }).toBe(false);
  expect(snapshot()).toEqual(before);
  await shot(testInfo, 'J6-stopped');
  // No success claim after a cancel: the transcript must not report completion for the slow turn.
  await expect(conversation()).not.toContainText('Done.');
  record(testInfo, 'J6', 'fake CLI pid no longer alive; repo unchanged; UI shows Stopped', { pid });
});

test('J7 close and reopen: the same session is still listed with its transcript', async ({}, testInfo) => {
  const savedEnv = env;
  await page
    .context()
    .tracing.stop({ path: testInfo.outputPath('before-restart-trace.zip') })
    .catch(() => undefined);
  tracing = false;
  await desktop.close();
  await launch(savedEnv);
  const sessions = page.getByRole('navigation', { name: 'Sessions' });
  const first = sessions.getByRole('button', { name: /journey-1/ });
  await expect(first).toBeVisible({ timeout: 30_000 });
  await first.click();
  expect(await threadFromUrl()).toBe(sessionId);
  await expect(conversation()).toContainText('Applied the fix to src/math.js.');
  await shot(testInfo, 'J7-reopened');
  // Oracle: the backend's stored transcript for the same id (not the rendered one).
  const messages = await backendApi<Array<{ content: string }>>(
    env,
    await backend(),
    `/v1/sessions/${sessionId}/messages`,
  );
  expect(messages.map((message) => message.content).join('\n')).toContain('Applied the fix to src/math.js.');
  // #743: the provider/mode live on the server, read independently of the UI.
  type Prefs = { preferred_provider: string; preferred_model: string; permission_mode: string; prefs_version: number };
  const stored = await backendApi<Prefs>(env, await backend(), `/v1/sessions/${sessionId}`);
  expect(stored.preferred_provider).toBe('claude-code');
  expect(stored.preferred_model ?? '').toBe('');
  expect(stored.permission_mode).toBe('ask');
  await expect(page.getByTitle(/Reads freely/)).toContainText('Ask before changes');
  // A stale writer (second window / TUI holding an old version) is refused, not silently merged.
  const stale = await fetchRaw(`/v1/sessions/${sessionId}`, 'PATCH', {
    permission_mode: 'plan',
    expected_prefs_version: stored.prefs_version - 1,
  });
  expect(stale.status).toBe(409);
  expect(stale.body).toContain('prefs_version_conflict');
  const unchanged = await backendApi<Prefs>(env, await backend(), `/v1/sessions/${sessionId}`);
  expect(unchanged.permission_mode).toBe('ask');
  record(
    testInfo,
    'J7',
    'backend transcript + stored provider/mode (#743) after restart; stale PATCH -> 409 prefs_version_conflict',
    {
      sessionId,
      messages: messages.length,
      stored,
      stalePatchStatus: stale.status,
    },
  );
});

test('J8 keyboard-only approve and reject, visible focus, Escape stops', async ({}, testInfo) => {
  // Reject README was already denied in J5; use a fresh session so each proposal is independent.
  const readme = repoFile('README.md');
  const before = sha256(readme);
  await openSeededSession(testInfo);
  await composer().fill('[[reject]] approve this README note');
  await composer().press('Enter');
  await showApproval();

  const focusedName = () =>
    page.evaluate(() => (document.activeElement as HTMLElement | null)?.textContent?.trim() ?? '');
  const visibleFocus = (locator: Locator) =>
    locator.evaluate((element) => {
      const style = getComputedStyle(element);
      return (style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) > 0) || style.boxShadow !== 'none';
    });
  const order: string[] = [];
  for (let step = 0; step < 60 && order.length < 2; step += 1) {
    await page.keyboard.press('Tab');
    const name = await focusedName();
    if (/Don’t allow|Allow for this session|Allow once/.test(name)) {
      expect(await visibleFocus(page.locator(':focus')), `focus ring on "${name}"`).toBe(true);
      order.push(name);
    }
  }
  expect(order[0]).toBe('Don’t allow');
  expect(order.at(-1)).toBe('Allow once');
  await page.keyboard.press('Enter');
  await expect(approval()).toBeHidden({ timeout: 20_000 });
  await expect.poll(() => fs.readFileSync(readme, 'utf8')).toContain('edited by fake agent');
  expect(sha256(readme)).not.toBe(before);
  await shot(testInfo, 'J8-approved-by-keyboard');

  // Keyboard reject of a shell command, then Escape stops a running turn.
  await startTurn(testInfo, '[[shell]] run the tests');
  await showApproval();
  let reached = false;
  for (let step = 0; step < 60 && !reached; step += 1) {
    await page.keyboard.press('Tab');
    reached = (await focusedName()) === 'Don’t allow';
  }
  expect(reached, 'Tab reaches "Don’t allow" in the shell approval').toBe(true);
  await page.keyboard.press('Enter');
  await expect(approval()).toBeHidden({ timeout: 20_000 });
  expect(readCliLog(env).some((entry) => entry.event === 'shell-allowed')).toBe(false);

  let axeSource: string | null = null;
  try {
    axeSource = require.resolve('axe-core/axe.min.js');
  } catch {
    axeSource = null;
  }
  if (axeSource) {
    await page.addScriptTag({ path: axeSource });
    const violations = await page.evaluate(async () => {
      const axe = (window as unknown as { axe: { run: () => Promise<{ violations: Array<{ id: string }> }> } }).axe;
      return (await axe.run()).violations.map((violation) => violation.id);
    });
    expect(violations).toEqual([]);
  } else {
    test.info().annotations.push({
      type: 'axe-skipped',
      description:
        'axe-core is only a transitive dependency (eslint-plugin-jsx-a11y), not a declared one; not imported.',
    });
  }
  record(testInfo, 'J8', 'README changed after Enter on Allow once; shell never allowed after keyboard deny', {
    focusOrder: order,
    axe: axeSource ? 'run' : 'skipped (axe-core not a declared dependency)',
  });
});

test('J8b Escape in the composer stops a running turn and the process exits', async ({}, testInfo) => {
  // Same root cause as J6: the interrupt reaches the backend but the CLI process is not terminated.
  test.fail(
    true,
    'Focus never shows a running installed-CLI turn (thread stays Ready, no Stop button), and cancel does not kill the CLI process (run_claude_cli_turn ignores cancellation)',
  );
  await startTurn(testInfo, '[[slow]] keep working');
  await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible({ timeout: 30_000 });
  const slow = readCliLog(env)
    .filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow')
    .at(-1);
  await composer().press('Escape');
  await expect.poll(() => isAlive(slow?.pid ?? -1), { timeout: 20_000 }).toBe(false);
});

test('J9 TUI client resumes the exact session; Desktop shows the TUI message', async ({}, testInfo) => {
  const found = await backend();
  const marker = `[[echo]] tui-continuity-${Date.now()}`;
  const echoesBefore = readCliLog(env).filter(
    (entry) => entry.event === 'scenario' && entry.scenario === 'echo',
  ).length;
  // Ensure the token the TUI reads is the one for THIS data dir.
  const output = execFileSync(
    'bun',
    ['run', path.join(__dirname, 'tui-resume.mjs'), TUI_SRC, `http://127.0.0.1:${found.port}`, sessionId, marker],
    {
      env: { ...process.env, VEASEL_DATA_DIR: env.dataDir, HOME: path.join(env.root, 'home') },
      encoding: 'utf8',
      timeout: 60_000,
    },
  );
  const result = JSON.parse(output.trim().split('\n').at(-1) ?? '{}') as {
    found: boolean;
    session: { preferred_provider?: string; permission_mode?: string } | null;
    directory: string | null;
    before: Array<{ content?: string }>;
    after: Array<{ content?: string }>;
  };
  expect(result.found).toBe(true);
  expect(result.directory).toBe(env.repo);
  // The TUI sees the SAME stored settings Desktop wrote (#743).
  expect(result.session?.preferred_provider).toBe('claude-code');
  expect(result.session?.permission_mode).toBe('ask');
  expect(result.before.map((message) => message.content ?? '').join('\n')).toContain('Applied the fix to src/math.js.');
  expect(result.after.map((message) => message.content ?? '').join('\n')).toContain(marker);

  // The TUI sent no provider: the server-stored preference must have routed it to the fake claude.
  expect(readCliLog(env).filter((entry) => entry.event === 'scenario' && entry.scenario === 'echo').length).toBe(
    echoesBefore + 1,
  );
  await page
    .getByRole('navigation', { name: 'Sessions' })
    .getByRole('button', { name: /journey-1/ })
    .click();
  await expect(conversation()).toContainText(marker, { timeout: 30_000 });
  await shot(testInfo, 'J9-desktop-shows-tui-message');
  record(
    testInfo,
    'J9',
    'TUI client (tui/src/api-client.ts) read the same session id + transcript; its message is in the backend transcript and visible in Desktop',
    {
      sessionId,
      marker,
    },
  );
});

test('J11 an unanswered shell approval expires: UI reports applied-with-denial, not plain failure', async ({}, testInfo) => {
  // Backend runs with VEASEL_CLI_APPROVAL_TIMEOUT_SECONDS=5 (journey-env). No test-only backend code is needed.
  // Reset the disposable repo (test-side setup, not an oracle) so the bug is present again.
  git(env.repo, 'checkout', '--', '.');
  expect(runRepoTests(env.repo).code).not.toBe(0);
  await openSeededSession(testInfo);
  await composer().fill('[[applyexpire]] fix the test then push');
  await composer().press('Enter');
  await showApproval();
  const file = repoFile('src/math.js');
  const before = sha256(file);
  await approval().getByRole('button', { name: 'Allow once' }).click();
  await expect.poll(() => sha256(file), { timeout: 20_000 }).not.toBe(before);
  // The push approval appears and is deliberately left alone until the server expires it.
  // Focus does not retire the decided Edit approval live (see J4c), so wait for the BACKEND to hold the
  // push approval and reopen the session to load it.
  await expect
    .poll(
      async () =>
        (
          await backendApi<Array<{ tool_name: string; status: string }>>(
            env,
            await backend(),
            `/v1/sessions/${currentSession}/cli-approvals`,
          )
        ).some((entry) => entry.tool_name === 'Bash' && entry.status === 'pending'),
      { timeout: 30_000 },
    )
    .toBe(true);
  await reopenCurrent();
  await expect(approval()).toContainText('git push', { timeout: 20_000 });
  await expect(approval()).toBeHidden({ timeout: 60_000 });
  await expect
    .poll(() => readCliLog(env).some((entry) => entry.event === 'push-denied'), { timeout: 20_000 })
    .toBe(true);
  await expect(conversation()).toContainText(/Done, with denied approvals|changes were applied/i, { timeout: 20_000 });
  await expect(conversation().getByText(/^Failed$/)).toHaveCount(0);
  await shot(testInfo, 'J11-applied-with-expiry');
  // Oracles: the operation outcome from the API, the file, the repo's test, and that nothing was pushed.
  const found = await backend();
  const sid = await threadFromUrl();
  const operations = await backendApi<Array<{ status: string; outcome?: string; outcome_summary?: string }>>(
    env,
    found,
    `/v1/sessions/${sid}/operations`,
  );
  const outcome = operations.at(-1);
  expect(outcome?.outcome).toBe('completed_with_denials');
  expect(runRepoTests(env.repo).code).toBe(0);
  expect(readCliLog(env).some((entry) => entry.event === 'push-allowed')).toBe(false);
  record(
    testInfo,
    'J11',
    'operation.outcome == completed_with_denials; file hash changed; repo test green; push never allowed',
    {
      outcome: outcome?.outcome,
      summary: outcome?.outcome_summary,
    },
  );
});

test('J10 backend crash mid-operation: honest error state, no phantom success', async ({}, testInfo) => {
  await startTurn(testInfo, '[[slow]] keep working until the backend dies');
  // Independent oracle that the operation is in flight: the fake CLI is streaming and alive.
  const slow = await expect
    .poll(() =>
      readCliLog(env)
        .filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow')
        .at(-1),
    )
    .toBeDefined()
    .then(() =>
      readCliLog(env)
        .filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow')
        .at(-1),
    );
  expect(isAlive(slow?.pid ?? -1)).toBe(true);
  const before = snapshot();
  const resultsBefore = readCliLog(env).filter((entry) => entry.event === 'result').length;
  const found = await backend();
  process.kill(found.pid, 'SIGKILL');
  try {
    // Desktop must SAY the backend is gone or the turn stopped (an alert, or a backend/connection/stopped message);
    // silence, or a stale "Ready", is not an honest state.
    await expect
      .poll(
        async () =>
          (await page.getByRole('alert').count()) > 0 ||
          (await page.getByText(/backend|unavailable|offline|restart|reconnect|connection|Stopped|Failed/i).count()) >
            0,
        { timeout: 60_000 },
      )
      .toBe(true);
    await shot(testInfo, 'J10-after-crash');
    // ...and must not present the interrupted turn as finished.
    await expect(conversation()).not.toContainText('Done.');
    // Oracle: no success was ever produced and the repo is untouched.
    expect(readCliLog(env).filter((entry) => entry.event === 'result').length).toBe(resultsBefore);
    expect(snapshot()).toEqual(before);
    record(
      testInfo,
      'J10',
      'backend SIGKILLed; no new fake CLI result frame; repo snapshot unchanged; UI surfaced an alert or backend/stopped message',
      {
        killedPid: found.pid,
        orphanedCliAlive: slow ? isAlive(slow.pid) : null,
      },
    );
  } finally {
    if (slow && isAlive(slow.pid)) process.kill(slow.pid, 'SIGKILL');
  }
});
