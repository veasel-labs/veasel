import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { _electron as electron, expect, type ElectronApplication, type Page } from '@playwright/test';

const APP_DIR = path.resolve(__dirname, '..', '..');
const REPO_ROOT = path.resolve(APP_DIR, '..', '..');
const packagedApp = process.env.VEASEL_E2E_APP_PATH ?? process.env.ATK_E2E_APP_PATH;

/**
 * The real V backend. CI builds it into dist/; locally any binary works via
 * VEASEL_E2E_BACKEND_BIN. This suite never builds V.
 */
function backendBinary(): string {
  const candidates = [
    process.env.VEASEL_E2E_BACKEND_BIN,
    packagedApp
      ? path.join(path.dirname(packagedApp), 'resources', 'bin', process.platform === 'win32' ? 'veasel.exe' : 'veasel')
      : undefined,
    path.join(REPO_ROOT, 'dist', process.platform === 'win32' ? 'veasel.exe' : 'veasel'),
    path.join(REPO_ROOT, 'build', process.platform === 'win32' ? 'veasel.exe' : 'veasel'),
  ].filter((candidate): candidate is string => Boolean(candidate));
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) {
    throw new Error(
      `No Veasel backend binary. Build one into dist/ or set VEASEL_E2E_BACKEND_BIN. Looked in: ${candidates.join(', ')}`,
    );
  }
  return found;
}

function assertBuilt(): void {
  if (packagedApp) {
    if (!fs.existsSync(packagedApp)) throw new Error(`Missing packaged Desktop: ${packagedApp}`);
    return;
  }
  for (const required of ['dist/index.html', 'dist-electron/main.js']) {
    if (!fs.existsSync(path.join(APP_DIR, required))) {
      throw new Error(`Missing ${required}. Run \`pnpm build:all\` before the electron project.`);
    }
  }
}

export interface Desktop {
  app: ElectronApplication;
  page: Page;
  /** Scratch root that holds HOME, user-data and any fixture data. */
  root: string;
  /** Scratch HOME; the default harness is `$HOME/.ai-workspace` when created. */
  home: string;
  /** Scratch workspace directory created when `initWorkspace` is true. */
  workspace: string;
  /** Exact backend binary started by the Electron supervisor. */
  backendBin: string;
  close: () => Promise<void>;
}

export interface OpenDesktopOptions {
  /** Create ~/.ai-workspace. Default true. */
  initWorkspace?: boolean;
  /** Persist first-run complete so existing specs land on World. Default true. */
  skipOnboarding?: boolean;
  /**
   * Extra environment for the app (and the backend it spawns). `PATH` is
   * PREPENDED to the scratch PATH rather than replacing it.
   */
  extraEnv?: Record<string, string>;
  /** Reuse an existing scratch root (relaunch). The root is then kept on close. */
  root?: string;
  /** Runs after the scratch HOME exists and before the app launches. */
  prepare?: (paths: { root: string; home: string; workspace: string }) => void | Promise<void>;
  /** Extra Electron/Chromium args (for example `--ozone-platform=x11`). */
  extraArgs?: string[];
}

/**
 * Launches the built app against the real backend inside a throwaway HOME
 * and workspace, so runs never read or write the developer's own state.
 */
export async function openDesktop(options: OpenDesktopOptions = {}): Promise<Desktop> {
  const initWorkspace = options.initWorkspace ?? true;
  const skipOnboarding = options.skipOnboarding ?? true;
  assertBuilt();
  const backendBin = backendBinary();
  const reusedRoot = options.root !== undefined;
  const root = options.root ?? fs.mkdtempSync(path.join(os.tmpdir(), 'atk-desktop-e2e-'));
  const home = path.join(root, 'home');
  // The default harness, so the supervisor resolves it without an override.
  const workspace = path.join(home, '.ai-workspace');
  fs.mkdirSync(home, { recursive: true });

  // Harness overrides from the developer's shell would point at their real workspace.
  const dropped = new Set([
    'ELECTRON_RUN_AS_NODE',
    'AGENT_TOOLKIT_WORKSPACE',
    'HARNESS_DIR',
    // A scratch app must never reach the developer's compositor or session keyring.
    'WAYLAND_DISPLAY',
    'HYPRLAND_INSTANCE_SIGNATURE',
    'DBUS_SESSION_BUS_ADDRESS',
  ]);
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !dropped.has(key)) env[key] = value;
  }
  env['HOME'] = home;
  env['XDG_CONFIG_HOME'] = path.join(home, '.config');
  env['XDG_DATA_HOME'] = path.join(home, '.local', 'share');
  // The Electron supervisor must launch this Veasel binary rather than an
  // unrelated `veasel` earlier on PATH.
  env['VEASEL_BACKEND_BIN'] = backendBin;
  const schedulerShim = process.env['ATK_E2E_SYSTEMCTL_SHIM'];
  env['PATH'] = [schedulerShim, path.dirname(backendBin), process.env.PATH]
    .filter((entry): entry is string => Boolean(entry))
    .join(path.delimiter);
  env['NO_COLOR'] = '1';
  for (const [key, value] of Object.entries(options.extraEnv ?? {})) {
    env[key] = key === 'PATH' ? [value, env['PATH']].filter(Boolean).join(path.delimiter) : value;
  }
  await options.prepare?.({ root, home, workspace });

  if (initWorkspace && !fs.existsSync(workspace)) {
    fs.mkdirSync(workspace, { recursive: true });
  }

  const args = [
    ...(packagedApp ? [] : [APP_DIR]),
    `--user-data-dir=${path.join(root, 'user-data')}`,
    ...(options.extraArgs ?? []),
  ];
  // GitHub runners have no setuid sandbox helper for Chromium.
  if (process.env.CI) args.push('--no-sandbox');
  const app = await electron.launch({ executablePath: packagedApp, args, cwd: initWorkspace ? workspace : home, env });
  const page = await app.firstWindow();
  await page.waitForLoadState('domcontentloaded');
  if (skipOnboarding) {
    await page.addInitScript(() => {
      localStorage.setItem('atk.desktop.onboarding.complete', '1');
    });
    await page.reload();
    await page.waitForLoadState('domcontentloaded');
  }

  return {
    app,
    page,
    root,
    home,
    workspace,
    backendBin,
    close: async () => {
      const process = app.process();
      let killTimer: ReturnType<typeof setTimeout> | undefined;
      try {
        await Promise.race([
          app.close(),
          new Promise<void>((resolve) => {
            killTimer = setTimeout(() => {
              try {
                process.kill('SIGKILL');
              } catch {
                // The Electron process may have exited while shutdown was pending.
              }
              resolve();
            }, 20_000);
          }),
        ]);
      } finally {
        if (killTimer) clearTimeout(killTimer);
        if (!reusedRoot) fs.rmSync(root, { recursive: true, force: true });
      }
    },
  };
}

export async function waitForBackend(page: Page): Promise<void> {
  // Readiness = the Veasel supervisor has published a backend URL and the
  // renderer proxy answers /v1/health. (The old Connected/Live badge no
  // longer renders, and the shell HUD's legacy /api/v1/health hook never
  // answers against the Veasel backend, so neither is a usable signal.)
  await expect
    .poll(
      () =>
        page.evaluate(async () => {
          const bridge = (window as unknown as { veaselDesktop?: { getBackendUrl?: () => Promise<unknown> } })
            .veaselDesktop;
          const backendUrl = bridge?.getBackendUrl ? await bridge.getBackendUrl().catch(() => null) : null;
          if (!backendUrl) return false;
          const health = await fetch('/v1/health')
            .then((r) => r.status)
            .catch(() => 0);
          return health === 200;
        }),
      { timeout: 30_000 },
    )
    .toBe(true);
}

/** Resize the window's content area; Xvfb has no window manager to clamp it. */
export async function setViewport(app: ElectronApplication, width: number, height: number): Promise<void> {
  await app.evaluate(
    async ({ BrowserWindow }, size) => {
      const [win] = BrowserWindow.getAllWindows();
      if (!win) throw new Error('Desktop window is unavailable while resizing.');
      // The production minimum is optimized for normal desktop use, while
      // responsive journeys deliberately exercise narrower renderer layouts.
      win.setMinimumSize(0, 0);
      if (win.isMaximized()) {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('Desktop window did not unmaximize within 5s.')), 5000);
          win.once('unmaximize', () => {
            clearTimeout(timer);
            resolve();
          });
          win.unmaximize();
        });
        // Give the compositor one frame to apply the restored bounds before
        // the explicit content size is requested.
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      win.setContentSize(size.width, size.height);
      return win.webContents.executeJavaScript(
        `new Promise((resolve, reject) => {
          const started = performance.now();
          const check = () => {
            if (window.innerWidth === ${size.width} && window.innerHeight === ${size.height}) {
              resolve(true);
            } else if (performance.now() - started > 10000) {
              reject(new Error(
                'Desktop viewport did not reach ${size.width}x${size.height}; actual ' +
                window.innerWidth + 'x' + window.innerHeight,
              ));
            } else {
              requestAnimationFrame(check);
            }
          };
          check();
        })`,
      );
    },
    { width, height },
  );
}
