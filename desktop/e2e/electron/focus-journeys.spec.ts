import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { expect, test, type Locator, type Page, type TestInfo } from '@playwright/test';
import { record } from './evidence';
import { waitForBackend, type Desktop } from './fixtures';
import {
  backendApi,
  findBackend,
  git,
  isAlive,
  launchFocusDesktop,
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
  await waitForBackend(page);
  await startTracing();
}

async function shot(testInfo: TestInfo, name: string): Promise<void> {
  await testInfo.attach(name, { body: await page.screenshot(), contentType: 'image/png' });
}

async function sendFromComposer(text: string): Promise<void> {
  await composer().fill(text);
  await composer().press('Enter');
}

async function backend() {
  const found = findBackend(env);
  if (!found) throw new Error('Desktop backend process not found for this data dir');
  return found;
}

async function threadFromUrl(): Promise<string> {
  await expect.poll(() => new URL(page.url()).searchParams.get('thread')).not.toBeNull();
  return new URL(page.url()).searchParams.get('thread') ?? '';
}

test.describe.configure({ mode: 'serial' });

test.afterEach(async ({}, testInfo) => {
  if (tracing && testInfo.status !== testInfo.expectedStatus) {
    await page.screenshot({ path: testInfo.outputPath('failure.png') }).catch(() => undefined);
  }
});

test.afterAll(async ({}, testInfo) => {
  if (tracing) {
    await page.context().tracing.stop({ path: testInfo.outputPath('focus-journeys-trace.zip') }).catch(() => undefined);
  }
  await desktop?.close().catch(() => undefined);
  if (env) {
    for (const entry of readCliLog(env)) if (entry.event === 'spawn' && isAlive(entry.pid)) process.kill(entry.pid, 'SIGKILL');
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
  const statuses = await backendApi<Array<{ id: string; installed: boolean }>>(env, await backend(), '/v1/providers/cli');
  const installed = statuses.filter((status) => status.installed).map((status) => status.id).sort();
  expect(installed).toEqual(expect.arrayContaining(['claude-code', 'codex']));
  expect(readCliLog(env).filter((entry) => entry.event === 'spawn')).toHaveLength(0);
  record(testInfo, 'J1', 'GET /v1/providers/cli installed ids; no CLI turn spawned', { installed });
});

test('J2 open the disposable git workspace', async ({}, testInfo) => {
  // The native folder picker is platform-owned; only its result is stubbed (as project-link.spec.ts does).
  await desktop.app.evaluate(({ dialog }, folder) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [folder] });
  }, env.repo);
  await page.getByRole('button', { name: 'Choose a repository folder' }).click();
  await expect(page.getByLabel('Project')).toHaveValue(REPO_NAME);
  await shot(testInfo, 'J2-project');
  // Oracle: the workspace link on disk resolves to the disposable repo.
  const link = path.join(desktop.home, '.ai-workspace', 'projects', REPO_NAME);
  const resolved = fs.realpathSync(link);
  expect(resolved).toBe(fs.realpathSync(env.repo));
  record(testInfo, 'J2', 'workspace symlink realpath == disposable repo', { link, resolved });
});

test('J3 choose provider (no model) and prompt: chosen provider spawned, text streams incrementally', async ({}, testInfo) => {
  expect(runRepoTests(env.repo).code).not.toBe(0);
  await page.getByRole('radio', { name: /Claude Code/ }).check();
  await page.getByLabel('Permissions').selectOption({ label: 'Ask before changes' });
  // No model choice: either there is no Model control or it stays on the provider default.
  const model = page.getByLabel('Model');
  if (await model.count()) await expect(model).toHaveValue('');
  await page.getByRole('textbox', { name: 'Task' }).fill(FIX_PROMPT);
  await page.getByRole('button', { name: 'Start session' }).click();
  await expect(conversation()).toBeVisible({ timeout: 20_000 });
  sessionId = await threadFromUrl();

  const lengths: number[] = [];
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline && !(await approval().isVisible())) {
    const length = (await conversation().innerText().catch(() => '')).length;
    if (lengths.at(-1) !== length) lengths.push(length);
    await page.waitForTimeout(80);
  }
  await expect(approval()).toBeVisible();
  await shot(testInfo, 'J3-approval-pending');
  expect(lengths.length, `stream samples: ${lengths.join(',')}`).toBeGreaterThanOrEqual(4);
  expect(lengths.at(-1)).toBeGreaterThan(lengths[0] ?? 0);

  // Oracle (#735 regression): the only CLI process spawned for this turn is the chosen provider.
  const spawns = readCliLog(env).filter((entry) => entry.event === 'spawn');
  expect(spawns.map((entry) => entry.cli)).toEqual(['claude']);
  const operations = await backendApi<Array<{ provider?: string }>>(env, await backend(), `/v1/sessions/${sessionId}/operations`);
  expect(operations.map((operation) => operation.provider)).toContain('claude-code');
  record(testInfo, 'J3', 'fake CLI spawn log == [claude]; operation.provider == claude-code; >=4 distinct stream lengths', {
    spawned: spawns.map((entry) => entry.cli),
    streamSamples: lengths.length,
  });
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

  // The UI's own git diff view must agree with the oracle diff.
  const inspector = page.getByRole('complementary', { name: 'Changes and files' });
  await inspector.getByRole('tab', { name: 'Changes' }).click();
  await expect(inspector).toContainText('src/math.js');
  await shot(testInfo, 'J4-approved-diff');
  record(testInfo, 'J4', 'sha256(src/math.js) changed; node test.js exit red->green; git diff has the fix', {
    shaBefore: before,
    shaAfter: sha256(file),
    redExit: red.code,
    greenExit: green.code,
  });
});

test('J5 a second proposal is rejected and changes nothing', async ({}, testInfo) => {
  const readme = repoFile('README.md');
  const readmeBefore = sha256(readme);
  const before = snapshot();
  const spawnsBefore = readCliLog(env).filter((entry) => entry.event === 'spawn').length;
  await sendFromComposer('[[reject]] add a note to the README');
  await expect(approval()).toBeVisible({ timeout: 30_000 });
  await expect(approval()).toContainText('README.md');
  await shot(testInfo, 'J5-proposal');
  await approval().getByRole('button', { name: 'Don’t allow' }).click();
  await expect(approval()).toBeHidden({ timeout: 20_000 });
  await expect.poll(() => readCliLog(env).some((entry) => entry.event === 'edit-denied' && entry.file === 'README.md')).toBe(true);
  expect(sha256(readme)).toBe(readmeBefore);
  expect(snapshot()).toEqual(before);
  expect(readCliLog(env).some((entry) => entry.event === 'edit-applied' && entry.file === 'README.md')).toBe(false);
  expect(readCliLog(env).filter((entry) => entry.event === 'spawn').length).toBe(spawnsBefore + 1);
  record(testInfo, 'J5', 'README sha256 and git status+diff identical; fake CLI logged edit-denied, no edit-applied', {
    readmeSha: readmeBefore,
  });
});

test('J6 cancelling an in-flight operation is honest and the process is gone', async ({}, testInfo) => {
  await sendFromComposer('[[slow]] keep working');
  const stop = page.getByRole('button', { name: 'Stop' });
  await expect(stop).toBeVisible({ timeout: 30_000 });
  const slow = readCliLog(env).filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow').at(-1);
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
  await page.context().tracing.stop({ path: testInfo.outputPath('before-restart-trace.zip') }).catch(() => undefined);
  tracing = false;
  await desktop.close();
  await launch(savedEnv);
  const sessions = page.getByRole('navigation', { name: 'Sessions' });
  await expect(sessions.getByRole('button').first()).toBeVisible({ timeout: 30_000 });
  await sessions.getByRole('button').first().click();
  expect(await threadFromUrl()).toBe(sessionId);
  await expect(conversation()).toContainText('Applied the fix to src/math.js.');
  await shot(testInfo, 'J7-reopened');
  // Oracle: the backend's stored transcript for the same id (not the rendered one).
  const messages = await backendApi<Array<{ content: string }>>(env, await backend(), `/v1/sessions/${sessionId}/messages`);
  expect(messages.map((message) => message.content).join('\n')).toContain('Applied the fix to src/math.js.');
  record(testInfo, 'J7', 'GET /v1/sessions/:id/messages after restart contains the first turn', {
    sessionId,
    messages: messages.length,
  });
});

test('J8 keyboard-only approve and reject, visible focus, Escape stops', async ({}, testInfo) => {
  // Reject README was already denied in J5; use a fresh session so each proposal is independent.
  const readme = repoFile('README.md');
  const before = sha256(readme);
  await page.getByRole('button', { name: 'New session' }).press('Enter');
  await page.getByRole('textbox', { name: 'Task' }).fill('[[reject]] approve this README note');
  await page.keyboard.press('Control+Enter');
  await expect(approval()).toBeVisible({ timeout: 30_000 });

  const focusedName = () => page.evaluate(() => (document.activeElement as HTMLElement | null)?.textContent?.trim() ?? '');
  const visibleFocus = (locator: Locator) =>
    locator.evaluate((element) => {
      const style = getComputedStyle(element);
      return (style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) > 0) || style.boxShadow !== 'none';
    });
  const order: string[] = [];
  for (let step = 0; step < 6 && order.length < 3; step += 1) {
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
  await composer().click();
  await sendFromComposer('[[shell]] run the tests');
  await expect(approval()).toBeVisible({ timeout: 30_000 });
  await page.keyboard.press('Tab');
  expect(await focusedName()).toBe('Don’t allow');
  await page.keyboard.press('Enter');
  await expect(approval()).toBeHidden({ timeout: 20_000 });
  expect(readCliLog(env).some((entry) => entry.event === 'shell-allowed')).toBe(false);

  await composer().click();
  await sendFromComposer('[[slow]] keep working');
  await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible({ timeout: 30_000 });
  const slow = readCliLog(env).filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow').at(-1);
  await composer().press('Escape');
  await expect.poll(() => isAlive(slow?.pid ?? -1), { timeout: 20_000 }).toBe(false);

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
      description: 'axe-core is only a transitive dependency (eslint-plugin-jsx-a11y), not a declared one; not imported.',
    });
  }
  record(testInfo, 'J8', 'README changed after Enter on Allow once; shell never allowed after keyboard deny; slow pid dead after Escape', {
    focusOrder: order,
    axe: axeSource ? 'run' : 'skipped (axe-core not a declared dependency)',
  });
});

test('J9 TUI client resumes the exact session; Desktop shows the TUI message', async ({}, testInfo) => {
  const found = await backend();
  const marker = `tui-continuity-${Date.now()}`;
  // Ensure the token the TUI reads is the one for THIS data dir.
  const output = execFileSync('bun', ['run', path.join(__dirname, 'tui-resume.mjs'), TUI_SRC, `http://127.0.0.1:${found.port}`, sessionId, marker], {
    env: { ...process.env, VEASEL_DATA_DIR: env.dataDir, HOME: path.join(env.root, 'home') },
    encoding: 'utf8',
    timeout: 60_000,
  });
  const result = JSON.parse(output.trim().split('\n').at(-1) ?? '{}') as {
    found: boolean;
    directory: string | null;
    before: Array<{ content?: string }>;
    after: Array<{ content?: string }>;
  };
  expect(result.found).toBe(true);
  expect(result.directory).toBe(env.repo);
  expect(result.before.map((message) => message.content ?? '').join('\n')).toContain('Applied the fix to src/math.js.');
  expect(result.after.map((message) => message.content ?? '').join('\n')).toContain(marker);

  const operations = await backendApi<Array<{ provider?: string }>>(env, found, `/v1/sessions/${sessionId}/operations`);
  expect(operations.some((operation) => operation.provider === 'claude-code')).toBe(true);
  await page.getByRole('navigation', { name: 'Sessions' }).getByRole('button').first().click();
  await expect(conversation()).toContainText(marker, { timeout: 30_000 });
  await shot(testInfo, 'J9-desktop-shows-tui-message');
  record(testInfo, 'J9', 'TUI client (tui/src/api-client.ts) read the same session id + transcript; its message is in the backend transcript and visible in Desktop', {
    sessionId,
    marker,
  });
});

test('J10 backend crash mid-operation: honest error state, no phantom success', async ({}, testInfo) => {
  await composer().click();
  await sendFromComposer('[[slow]] keep working until the backend dies');
  await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible({ timeout: 30_000 });
  const slow = readCliLog(env).filter((entry) => entry.event === 'scenario' && entry.scenario === 'slow').at(-1);
  const before = snapshot();
  const resultsBefore = readCliLog(env).filter((entry) => entry.event === 'result').length;
  const found = await backend();
  process.kill(found.pid, 'SIGKILL');
  try {
    // The shell must stop claiming a live backend...
    await expect(page.getByRole('status').filter({ hasText: /^(Connected|Live)/ })).toBeHidden({ timeout: 45_000 });
    await shot(testInfo, 'J10-after-crash');
    // ...and must not present the interrupted turn as finished.
    await expect(conversation()).not.toContainText('Done.');
    // Oracle: no success was ever produced and the repo is untouched.
    expect(readCliLog(env).filter((entry) => entry.event === 'result').length).toBe(resultsBefore);
    expect(snapshot()).toEqual(before);
    record(testInfo, 'J10', 'backend SIGKILLed; no new fake CLI result frame; repo snapshot unchanged; backend badge left Connected', {
      killedPid: found.pid,
      orphanedCliAlive: slow ? isAlive(slow.pid) : null,
    });
  } finally {
    if (slow && isAlive(slow.pid)) process.kill(slow.pid, 'SIGKILL');
  }
});

test.fixme('J11 an unanswered shell approval expires', async () => {
  // The approval wait is bounded by max_agent_turn_duration, a 10-minute constant (api.v:18);
  // there is no environment knob, so expiry cannot be observed deterministically in a CI-sized run.
});
