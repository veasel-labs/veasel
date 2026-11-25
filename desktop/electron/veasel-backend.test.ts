// @vitest-environment node
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  VeaselBackendSupervisor,
  canonicalVeaselDataDir,
  classifyVeaselBackend,
  probeVeaselBackend,
  readBackendApiToken,
  resolveVeaselBackendUrl,
  veaselBackendEnvironment,
  veaselHealthIdentity,
} from './veasel-backend';

describe('veaselHealthIdentity', () => {
  it('accepts only the real Veasel health payload', () => {
    expect(veaselHealthIdentity({ healthy: true, version: '0.92.0-next.0', pid: 4242 })).toEqual({
      version: '0.92.0-next.0',
      pid: 4242,
    });
  });

  it('rejects foreign or incomplete 200 payloads', () => {
    expect(veaselHealthIdentity({})).toBeNull();
    expect(veaselHealthIdentity({ healthy: true })).toBeNull();
    expect(veaselHealthIdentity({ healthy: false, version: '1.0.0', pid: 1 })).toBeNull();
    expect(veaselHealthIdentity({ healthy: true, version: '', pid: 1 })).toBeNull();
    expect(veaselHealthIdentity({ healthy: true, version: '1.0.0', pid: 0 })).toBeNull();
    expect(veaselHealthIdentity({ healthy: true, version: '1.0.0', pid: '42' })).toBeNull();
    expect(veaselHealthIdentity(null)).toBeNull();
    expect(veaselHealthIdentity('healthy')).toBeNull();
  });
});

describe('canonicalVeaselDataDir', () => {
  it('mirrors the V default_data_dir contract', () => {
    expect(canonicalVeaselDataDir({}, '/home/tester')).toBe(path.join('/home/tester', '.local', 'share', 'veasel'));
    expect(canonicalVeaselDataDir({ VEASEL_DATA_DIR: '/tmp/custom' }, '/home/tester')).toBe('/tmp/custom');
  });
});

describe('resolveVeaselBackendUrl', () => {
  it('uses the terminal launcher port, including its fallback for invalid values', () => {
    expect(resolveVeaselBackendUrl({ VEASEL_PORT: '5100' })).toBe('http://127.0.0.1:5100');
    for (const port of [undefined, '0', '65536', '-2', 'random']) {
      expect(resolveVeaselBackendUrl({ VEASEL_PORT: port })).toBe('http://127.0.0.1:4097');
    }
  });
});

describe('veaselBackendEnvironment', () => {
  it('injects only explicitly stored secrets and removes deleted secret names', () => {
    expect(
      veaselBackendEnvironment(
        { PATH: '/usr/bin', MCP_OLD_TOKEN: 'stale-inherited-value' },
        { MCP_API_TOKEN: 'encrypted-store-value' },
        ['MCP_OLD_TOKEN'],
      ),
    ).toEqual({ PATH: '/usr/bin', MCP_API_TOKEN: 'encrypted-store-value' });
  });
});

describe('probeVeaselBackend', () => {
  const servers: http.Server[] = [];
  afterEach(async () => {
    await Promise.all(
      servers.splice(0).map(
        (server) =>
          new Promise<void>((resolve, reject) => {
            server.close((error) => (error ? reject(error) : resolve()));
          }),
      ),
    );
  });

  async function serve(body: unknown, status = 200): Promise<string> {
    const server = http.createServer((_req, res) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  }

  it('identifies a real Veasel backend', async () => {
    const url = await serve({ healthy: true, version: '0.92.0-next.0', pid: 99 });
    await expect(probeVeaselBackend(url)).resolves.toEqual({ version: '0.92.0-next.0', pid: 99 });
  });

  it('refuses a foreign process that merely returns 200', async () => {
    const url = await serve({ healthy: true });
    await expect(probeVeaselBackend(url)).resolves.toBeNull();
  });

  it('refuses non-200 and unreachable backends', async () => {
    const url = await serve({ healthy: true, version: '1.0.0', pid: 1 }, 500);
    await expect(probeVeaselBackend(url)).resolves.toBeNull();
    await expect(probeVeaselBackend('http://127.0.0.1:1')).resolves.toBeNull();
  });
});

const T1 = 'c'.repeat(64);

describe('readBackendApiToken', () => {
  it('prefers VEASEL_API_TOKEN, then a private api-token file', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-token-'));
    try {
      expect(readBackendApiToken({}, dir)).toBeNull();
      fs.writeFileSync(path.join(dir, 'api-token'), `${T1}\n`, { mode: 0o600 });
      expect(readBackendApiToken({}, dir)).toBe(T1);
      expect(readBackendApiToken({ VEASEL_API_TOKEN: 'env-token' }, dir)).toBe('env-token');
      if (process.platform !== 'win32') {
        fs.chmodSync(path.join(dir, 'api-token'), 0o644);
        expect(readBackendApiToken({}, dir)).toBeNull();
        fs.rmSync(path.join(dir, 'api-token'));
        fs.writeFileSync(path.join(dir, 'real'), `${T1}\n`, { mode: 0o600 });
        fs.symlinkSync(path.join(dir, 'real'), path.join(dir, 'api-token'));
        expect(readBackendApiToken({}, dir)).toBeNull();
      }
      fs.rmSync(path.join(dir, 'api-token'), { force: true });
      fs.writeFileSync(path.join(dir, 'api-token'), 'malformed\n', { mode: 0o600 });
      expect(readBackendApiToken({}, dir)).toBeNull();
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('sends the token on health probes so identity is disclosed only to it', async () => {
    const seen: Array<string | undefined> = [];
    const server = http.createServer((req, res) => {
      seen.push(req.headers.authorization);
      const body =
        req.headers.authorization === 'Bearer t0k' ? { healthy: true, version: '1.0.0', pid: 7 } : { healthy: true };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    try {
      await expect(probeVeaselBackend(url)).resolves.toBeNull();
      await expect(probeVeaselBackend(url, 't0k')).resolves.toEqual({ version: '1.0.0', pid: 7 });
      expect(seen).toEqual([undefined, 'Bearer t0k']);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});

describe('legacy backend negotiation', () => {
  const servers: http.Server[] = [];
  afterEach(async () => {
    await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
  });

  async function fake(mode: 'legacy' | 'spoof' | 'garbage' | 'secure') {
    const authSeen: Array<string | undefined> = [];
    const server = http.createServer((req, res) => {
      authSeen.push(req.headers.authorization);
      const send = (status: number, body: string) => {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(body);
      };
      if (req.url === '/v1/health') {
        if (mode === 'garbage') return send(200, 'not json');
        if (mode === 'legacy') return send(200, JSON.stringify({ healthy: true, version: '0.0.9', pid: 4242 }));
        if (mode === 'secure' && req.headers.authorization === `Bearer ${T1}`) {
          return send(200, JSON.stringify({ healthy: true, auth: 'bearer', protocol: 1, version: '1.0.0', pid: 7 }));
        }
        return send(200, JSON.stringify({ healthy: true, auth: 'bearer', protocol: 1 }));
      }
      if (req.url === '/v1/operations') {
        return send(200, JSON.stringify({ operations: [{ operation: { status: 'running' } }] }));
      }
      return send(mode === 'secure' ? 401 : 200, '{}');
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const port = (server.address() as AddressInfo).port;
    return { url: `http://127.0.0.1:${port}`, port: String(port), authSeen };
  }

  it('classifies current, legacy, spoofing, garbled and absent servers', async () => {
    expect(await classifyVeaselBackend((await fake('secure')).url)).toBe('secure');
    expect(await classifyVeaselBackend((await fake('legacy')).url)).toBe('legacy');
    expect(await classifyVeaselBackend((await fake('spoof')).url)).toBe('legacy');
    expect(await classifyVeaselBackend((await fake('garbage')).url)).toBe('legacy');
    expect(await classifyVeaselBackend('http://127.0.0.1:1')).toBe('absent');
  });

  it('blocks on a legacy backend: no attach, no spawn, no token sent, recovery text shown', async () => {
    const legacy = await fake('legacy');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-legacy-'));
    fs.writeFileSync(path.join(dir, 'api-token'), `${T1}\n`, { mode: 0o600 });
    try {
      const supervisor = new VeaselBackendSupervisor({
        userDataDir: dir,
        dataDir: dir,
        env: { VEASEL_BACKEND_BIN: '/nonexistent/veasel-must-not-spawn' },
        conventionalUrl: legacy.url,
      });
      const state = await supervisor.start();
      expect(state.status).toBe('failed');
      expect(state.url).toBeNull();
      expect(state.problem).toContain('legacy Veasel backend');
      expect(state.problem).toContain(`127.0.0.1:${legacy.port}`);
      expect(state.problem).toContain('1 turn(s) are running or queued');
      expect(state.problem).toContain('taskkill');
      expect(legacy.authSeen.every((header) => header === undefined)).toBe(true);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('attaches to a current backend and sends the token only after it proved auth', async () => {
    const secure = await fake('secure');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-secure-'));
    fs.writeFileSync(path.join(dir, 'api-token'), `${T1}\n`, { mode: 0o600 });
    try {
      const supervisor = new VeaselBackendSupervisor({
        userDataDir: dir,
        dataDir: dir,
        env: { VEASEL_PORT: secure.port },
      });
      const state = await supervisor.start();
      expect(state.status).toBe('ready');
      expect(state.url).toBe(secure.url);
      expect(supervisor.isAttached()).toBe(true);
      await expect(supervisor.restart()).resolves.toBe(false);
      expect(supervisor.snapshot().status).toBe('ready');
      expect(secure.authSeen.slice(0, 2)).toEqual([undefined, undefined]);
      expect(secure.authSeen).toContain(`Bearer ${T1}`);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('does not start another backend when a different profile owns the configured port', async () => {
    const secure = await fake('secure');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-other-profile-'));
    try {
      const supervisor = new VeaselBackendSupervisor({
        userDataDir: dir,
        dataDir: dir,
        env: { VEASEL_PORT: secure.port, VEASEL_API_TOKEN: 'different-profile' },
      });
      const state = await supervisor.start();
      expect(state.status).toBe('failed');
      expect(state.url).toBeNull();
      expect(state.problem).toContain('different profile or credential');
      expect(supervisor.isAttached()).toBe(false);
      expect(fs.readdirSync(dir)).toEqual([]);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it.skipIf(process.platform === 'win32')('starts an owned backend on the port a terminal will discover', async () => {
    const portProbe = http.createServer();
    await new Promise<void>((resolve) => portProbe.listen(0, '127.0.0.1', resolve));
    const port = String((portProbe.address() as AddressInfo).port);
    await new Promise<void>((resolve) => portProbe.close(() => resolve()));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-desktop-first-'));
    const bin = path.join(dir, 'veasel-test-backend');
    fs.writeFileSync(
      bin,
      `#!/usr/bin/env node
const http = require('node:http');
http.createServer((request, response) => {
  if (request.url === '/v1/health') {
    const health = { healthy: true, auth: 'bearer', protocol: 1 };
    if (request.headers.authorization === 'Bearer ' + process.env.VEASEL_API_TOKEN) {
      Object.assign(health, { version: 'test', pid: process.pid });
    }
    response.end(JSON.stringify(health));
  } else {
    response.writeHead(401).end();
  }
}).listen(Number(process.env.VEASEL_PORT), '127.0.0.1');
`,
      { mode: 0o700 },
    );
    const supervisor = new VeaselBackendSupervisor({
      userDataDir: dir,
      dataDir: dir,
      env: { PATH: process.env.PATH, VEASEL_PORT: port, VEASEL_BACKEND_BIN: bin, VEASEL_API_TOKEN: T1 },
    });
    try {
      const url = `http://127.0.0.1:${port}`;
      const startup = supervisor.start();
      expect(supervisor.start()).toBe(startup);
      await expect(startup).resolves.toMatchObject({ status: 'ready', url });
      expect(supervisor.isAttached()).toBe(false);
      await expect(probeVeaselBackend(url, T1)).resolves.toMatchObject({ version: 'test' });
    } finally {
      await supervisor.stop();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it.skipIf(process.platform === 'win32')('stops an owned backend before it becomes healthy', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-stopping-startup-'));
    const bin = path.join(dir, 'veasel-test-backend');
    const marker = path.join(dir, 'started');
    fs.writeFileSync(
      bin,
      `#!/usr/bin/env node
require('node:fs').writeFileSync(process.env.VEASEL_TEST_MARKER, 'started');
setInterval(() => {}, 1000);
`,
      { mode: 0o700 },
    );
    const supervisor = new VeaselBackendSupervisor({
      userDataDir: dir,
      dataDir: dir,
      env: { PATH: process.env.PATH, VEASEL_BACKEND_BIN: bin, VEASEL_TEST_MARKER: marker },
      conventionalUrl: 'http://127.0.0.1:1',
    });
    try {
      const startup = supervisor.start();
      await vi.waitFor(() => expect(fs.existsSync(marker)).toBe(true));
      await supervisor.stop();
      await expect(startup).resolves.toMatchObject({ status: 'stopped', url: null });
      expect(supervisor.snapshot().status).toBe('stopped');
    } finally {
      await supervisor.stop();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
