// @vitest-environment node
import http from 'node:http';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { canonicalVeaselDataDir, probeVeaselBackend, veaselHealthIdentity } from './veasel-backend';

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
