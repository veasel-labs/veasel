// @vitest-environment node
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import {
  canonicalVeaselDataDir,
  probeVeaselBackend,
  readBackendApiToken,
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
    expect(canonicalVeaselDataDir({}, '/home/tester')).toBe(
      path.join('/home/tester', '.local', 'share', 'veasel'),
    );
    expect(canonicalVeaselDataDir({ VEASEL_DATA_DIR: '/tmp/custom' }, '/home/tester')).toBe('/tmp/custom');
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
      const body = req.headers.authorization === 'Bearer t0k' ? { healthy: true, version: '1.0.0', pid: 7 } : { healthy: true };
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
