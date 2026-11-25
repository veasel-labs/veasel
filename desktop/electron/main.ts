import { app, BrowserWindow, dialog, ipcMain, safeStorage, shell } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { projectVeaselBackendState } from './backend-state';
import { VeaselBackendSupervisor } from './veasel-backend';
import { HarnessController } from './harness-controller';
import { HARNESS_STORE_FILE, HarnessStore } from './harness-store';
import { registerIpc } from './ipc';
import { electronStorageName, McpSecretStore, mcpSecretStorePath } from './mcp-secrets';
import { PROXY_TOKEN_HEADER, startRendererServer, type RendererServer } from './renderer-server';
import { TerminalService } from './terminal';

let mainWindow: BrowserWindow | null = null;
let veaselBackend: VeaselBackendSupervisor | null = null;
let terminals: TerminalService | null = null;
let harness: HarnessController | null = null;
let mcpSecrets: McpSecretStore | null = null;
let rendererServer: RendererServer | null = null;
let ipcRegistered = false;
let shutdownTask: Promise<void> | null = null;
let shutdownComplete = false;
let shuttingDown = false;

async function chooseHarnessDirectory(defaultPath: string): Promise<string | null> {
  const options: Electron.OpenDialogOptions = {
    title: 'Choose harness folder',
    buttonLabel: 'Use as harness',
    defaultPath,
    // createDirectory is macOS-only; elsewhere the native picker offers its own
    // "new folder" action, which is an explicit user choice.
    properties: ['openDirectory', 'createDirectory'],
  };
  const result = mainWindow ? await dialog.showOpenDialog(mainWindow, options) : await dialog.showOpenDialog(options);
  return result.canceled ? null : (result.filePaths[0] ?? null);
}

async function chooseProjectDirectory(defaultPath: string): Promise<string | null> {
  const options: Electron.OpenDialogOptions = {
    title: 'Choose an existing project folder',
    buttonLabel: 'Review project link',
    defaultPath,
    properties: ['openDirectory'],
  };
  const result = mainWindow ? await dialog.showOpenDialog(mainWindow, options) : await dialog.showOpenDialog(options);
  return result.canceled ? null : (result.filePaths[0] ?? null);
}

async function resolveRendererUrl(): Promise<string> {
  const devUrl = process.env.ATK_DESKTOP_DEV_URL;
  if (devUrl) return devUrl;
  // Packaged / local production: serve dist over loopback (not file://) so
  // mutating calls to serve keep a loopback Origin. See renderer-server.ts.
  if (!rendererServer) {
    rendererServer = await startRendererServer(path.join(__dirname, '..', 'dist'), {
      // Backend bearer token: injected by the proxy only, never sent to the renderer.
      backendAuthorization: () => {
        const token = veaselBackend?.apiToken();
        return token ? `Bearer ${token}` : undefined;
      },
    });
  }
  return rendererServer.url;
}

async function createWindow(): Promise<void> {
  if (shuttingDown) return;
  if (!veaselBackend) {
    veaselBackend = new VeaselBackendSupervisor({
      userDataDir: app.getPath('userData'),
      resourcesDir: process.resourcesPath,
      workingDirectory: () => harness?.resolve().path ?? process.cwd(),
      resolveEnvironmentSecrets: () => mcpSecrets?.environment() ?? {},
      resolveClearedEnvironmentSecretNames: () => mcpSecrets?.managedNames() ?? [],
    });
    veaselBackend.onState((state) => {
      rendererServer?.setBackendTarget(state.url);
      mainWindow?.webContents.send(
        'atk:backend-state',
        projectVeaselBackendState(
          state,
          harness?.resolve() ?? null,
          veaselBackend?.isAttached(),
          rendererServer?.url ?? null,
        ),
      );
    });
    ipcMain.handle('veasel:backend-url', () => rendererServer?.url ?? null);
  }
  // Singleflight: macOS `activate` re-enters createWindow. Rebuilding the
  // services would orphan the running backend/PTYs and re-registering IPC
  // handlers throws. Reuse what exists.
  if (!harness) {
    harness = new HarnessController({
      store: new HarnessStore(path.join(app.getPath('userData'), HARNESS_STORE_FILE)),
      getSupervisor: () =>
        veaselBackend
          ? {
              restart: () => veaselBackend!.restart(),
              snapshot: () =>
                projectVeaselBackendState(
                  veaselBackend!.snapshot(),
                  harness?.resolve() ?? null,
                  veaselBackend!.isAttached(),
                ),
            }
          : null,
      fallbackDirectory: path.join(app.getPath('userData'), 'bootstrap'),
      chooseDirectory: chooseHarnessDirectory,
    });
  }
  const harnessController = harness;
  if (!mcpSecrets) {
    mcpSecrets = new McpSecretStore(mcpSecretStorePath(app.getPath('userData')), safeStorage, () =>
      electronStorageName(
        process.platform,
        process.platform === 'linux' ? safeStorage.getSelectedStorageBackend() : 'unknown',
      ),
    );
  }
  const supervisor = veaselBackend;
  if (!terminals) {
    // New shells open where serve runs; before the first start, where it will run.
    terminals = new TerminalService({
      defaultCwd: () => harnessController.resolve().path,
    });
  }

  const url = await resolveRendererUrl();
  if (shuttingDown) {
    await closeRendererServer();
    return;
  }

  const window = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1024,
    minHeight: 640,
    title: 'Veasel',
    backgroundColor: '#f6ebd7',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
    },
  });
  mainWindow = window;

  // Inject the renderer proxy capability in the main process for this exact
  // loopback origin only. The token never enters renderer JS, the page URL,
  // logs, or persisted state (see renderer-server.ts trust boundary).
  if (rendererServer && url === rendererServer.url) {
    const activeRendererServer = rendererServer;
    window.webContents.session.webRequest.onBeforeSendHeaders({ urls: [`${url}/*`] }, (details, callback) => {
      details.requestHeaders[PROXY_TOKEN_HEADER] = activeRendererServer.proxyToken;
      callback({ requestHeaders: details.requestHeaders });
    });
  }

  // Drop the reference as soon as the window closes so later sends and
  // backend-startup paths never touch a destroyed BrowserWindow.
  window.on('closed', () => {
    mainWindow = null;
  });

  if (!ipcRegistered) {
    registerIpc({
      getBackend: () =>
        veaselBackend
          ? {
              restart: () => veaselBackend!.restart(),
              snapshot: () =>
                projectVeaselBackendState(
                  veaselBackend!.snapshot(),
                  harness?.resolve() ?? null,
                  veaselBackend!.isAttached(),
                ),
            }
          : null,
      getTerminals: () => terminals,
      getWindow: () => mainWindow,
      getHarness: () => harness,
      getMcpSecrets: () => mcpSecrets,
      getPublicBackendUrl: () => rendererServer?.url ?? null,
      chooseProjectDirectory,
    });
    ipcRegistered = true;
  }

  terminals.attachWindow(() => mainWindow);

  // Navigation stays on the shell's own loopback origin; anything else
  // is denied here (external links go through the open handler below).
  mainWindow.webContents.on('will-navigate', (event, target) => {
    try {
      if (new URL(target).origin === new URL(url).origin) return;
    } catch {
      // Unparseable target: deny.
    }
    event.preventDefault();
  });

  mainWindow.webContents.setWindowOpenHandler(({ url: target }) => {
    try {
      const protocol = new URL(target).protocol;
      if (protocol === 'http:' || protocol === 'https:') void shell.openExternal(target);
    } catch {
      // Malformed URL: stay denied.
    }
    return { action: 'deny' };
  });

  try {
    await window.loadURL(`${url}/`);
  } catch (error) {
    if (shuttingDown || window.isDestroyed()) return;
    throw error;
  }
  if (shuttingDown || window.isDestroyed() || veaselBackend !== supervisor) return;

  // Start the canonical Veasel V backend after the window exists so failures are visible.
  const startupHarness = harnessController.resolve();
  if (startupHarness.source === 'fallback') {
    fs.mkdirSync(startupHarness.path, { recursive: true });
  }
  if (veaselBackend) await veaselBackend.start();
  if (shuttingDown || window.isDestroyed() || veaselBackend !== supervisor) return;
  mainWindow?.webContents.send(
    'atk:backend-state',
    projectVeaselBackendState(supervisor.snapshot(), harnessController.resolve(), supervisor.isAttached()),
  );
}

void app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    void createWindow();
  }
});

app.on('before-quit', (event) => {
  if (shutdownComplete) return;
  shuttingDown = true;
  event.preventDefault();
  void shutdown().then(
    () => {
      shutdownComplete = true;
      app.quit();
    },
    (error: unknown) => {
      console.error('Veasel Desktop shutdown failed:', error);
      shutdownComplete = true;
      app.exit(1);
    },
  );
});

async function shutdown(): Promise<void> {
  if (shutdownTask) return shutdownTask;
  shutdownTask = (async () => {
    terminals?.dispose();
    terminals = null;
    if (veaselBackend) await veaselBackend.stop();
    veaselBackend = null;
    await closeRendererServer();
  })();
  return shutdownTask;
}

async function closeRendererServer(): Promise<void> {
  const activeRendererServer = rendererServer;
  rendererServer = null;
  if (activeRendererServer) await activeRendererServer.close().catch(() => undefined);
}
