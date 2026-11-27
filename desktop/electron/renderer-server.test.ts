// @vitest-environment node
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { startRendererServer } from './renderer-server';

function get(url: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    http
      .get(url, (response) => {
        const chunks: Buffer[] = [];
        response.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
        response.on('end', () =>
          resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }),
        );
      })
      .on('error', reject);
  });
}

function post(url: string, body: string): Promise<{ status: number; body: string }> {
  return request(url, 'POST', body, {});
}

function request(
  url: string,
  method: string,
  body: string,
  headers: Record<string, string>,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const requestTarget = url.startsWith(target.origin)
      ? url.slice(target.origin.length) || '/'
      : `${target.pathname}${target.search}`;
    const req = http.request(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port,
        path: requestTarget,
        method,
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), ...headers },
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
        response.on('end', () =>
          resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }),
        );
      },
    );
    req.on('error', reject);
    req.end(body);
  });
}

const TOKEN = 'test-proxy-token-0123456789abcdef';

describe('startRendererServer', () => {
  const dirs: string[] = [];
  const backends: http.Server[] = [];

  afterEach(async () => {
    for (const dir of dirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
    await Promise.all(
      backends.splice(0).map(
        (server) =>
          new Promise<void>((resolve, reject) => {
            server.close((error) => (error ? reject(error) : resolve()));
          }),
      ),
    );
  });

  it('serves index.html from loopback', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), '<!doctype html><title>ok</title>');
    const server = await startRendererServer(dir);
    try {
      expect(server.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
      const response = await get(`${server.url}/`);
      expect(response.status).toBe(200);
      expect(response.body).toContain('<title>ok</title>');
    } finally {
      await server.close();
    }
  });

  it('never escapes the dist root', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), 'ok');
    const server = await startRendererServer(dir);
    try {
      const response = await get(new URL('/../etc/passwd', `${server.url}/`).href);
      expect([200, 403, 404]).toContain(response.status);
      if (response.status === 200) expect(response.body).toBe('ok');
    } finally {
      await server.close();
    }
  });

  it('proxies /api to the supervised backend once targeted', async () => {
    const backend = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, path: req.url, desktop: req.headers['x-atk-desktop'] }));
    });
    backends.push(backend);
    await new Promise<void>((resolve) => backend.listen(0, '127.0.0.1', resolve));
    const backendPort = (backend.address() as AddressInfo).port;

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), 'ok');
    const server = await startRendererServer(dir, { proxyToken: TOKEN });
    try {
      const unauthenticated = await get(`${server.url}/api/v1/health`);
      expect(unauthenticated.status).toBe(403);
      const cold = await request(`${server.url}/api/v1/health`, 'GET', '', { 'x-veasel-proxy': TOKEN });
      expect(cold.status).toBe(503);
      server.setBackendTarget(`http://127.0.0.1:${backendPort}`);
      const warm = await request(`${server.url}/api/v1/project/list`, 'POST', '{}', { 'x-veasel-proxy': TOKEN });
      expect(warm.status).toBe(200);
      expect(JSON.parse(warm.body)).toMatchObject({ ok: true, path: '/v1/project/list', desktop: '1' });
      const health = await request(`${server.url}/api/v1/health?source=desktop`, 'GET', '', {
        'x-veasel-proxy': TOKEN,
      });
      expect(health.status).toBe(200);
      expect(JSON.parse(health.body)).toMatchObject({ ok: true, path: '/v1/health?source=desktop', desktop: '1' });
      const apiRoot = await request(`${server.url}/api/v1?source=desktop`, 'GET', '', {
        'x-veasel-proxy': TOKEN,
      });
      expect(apiRoot.status).toBe(200);
      expect(JSON.parse(apiRoot.body)).toMatchObject({ ok: true, path: '/v1?source=desktop', desktop: '1' });
      const escapedApiPath = await request(`${server.url}/api/v1/%2e%2e/health`, 'GET', '', {
        'x-veasel-proxy': TOKEN,
      });
      expect(escapedApiPath.status).toBe(400);
      const canonical = await request(`${server.url}/v1/goals?workspace=%2Ftmp%2Fdemo`, 'GET', '', {
        'x-veasel-proxy': TOKEN,
      });
      expect(canonical.status).toBe(200);
      expect(JSON.parse(canonical.body)).toMatchObject({
        ok: true,
        path: '/v1/goals?workspace=%2Ftmp%2Fdemo',
        desktop: '1',
      });
    } finally {
      await server.close();
    }
  });

  it('fails closed for untrusted proxy callers and never contacts the backend', async () => {
    const hits: Array<{
      url?: string;
      desktop?: string | string[];
      proxy?: string | string[];
      fetchSite?: string | string[];
    }> = [];
    const backend = http.createServer((req, res) => {
      hits.push({
        url: req.url,
        desktop: req.headers['x-atk-desktop'],
        proxy: req.headers['x-veasel-proxy'],
        fetchSite: req.headers['sec-fetch-site'],
      });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    backends.push(backend);
    await new Promise<void>((resolve) => backend.listen(0, '127.0.0.1', resolve));
    const backendPort = (backend.address() as AddressInfo).port;

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), 'ok');
    const server = await startRendererServer(dir, { proxyToken: TOKEN });
    server.setBackendTarget(`http://127.0.0.1:${backendPort}`);
    const port = new URL(server.url).port;
    try {
      // Token-less local client (no Origin at all) must not mutate or read.
      expect((await post(`${server.url}/v1/sessions`, '{}')).status).toBe(403);
      expect((await post(`${server.url}/api/v1/jobs`, '{}')).status).toBe(403);
      expect((await get(`${server.url}/v1/sessions`)).status).toBe(403);
      // Wrong capability.
      expect((await request(`${server.url}/v1/sessions`, 'POST', '{}', { 'x-veasel-proxy': 'wrong' })).status).toBe(
        403,
      );
      // DNS rebinding: foreign Host even with the capability.
      expect(
        (
          await request(`${server.url}/v1/sessions`, 'POST', '{}', {
            'x-veasel-proxy': TOKEN,
            host: 'attacker.example',
          })
        ).status,
      ).toBe(403);
      // Foreign and cross-port Origins.
      expect(
        (
          await request(`${server.url}/v1/sessions`, 'POST', '{}', {
            'x-veasel-proxy': TOKEN,
            origin: 'https://evil.example',
          })
        ).status,
      ).toBe(403);
      expect(
        (
          await request(`${server.url}/v1/sessions`, 'POST', '{}', {
            'x-veasel-proxy': TOKEN,
            origin: 'http://127.0.0.1:1',
          })
        ).status,
      ).toBe(403);
      // Cross-site simple request (no preflight) must not be laundered.
      expect(
        (
          await request(`${server.url}/v1/sessions`, 'POST', '{}', {
            'x-veasel-proxy': TOKEN,
            'sec-fetch-site': 'cross-site',
          })
        ).status,
      ).toBe(403);
      expect(hits).toEqual([]);

      // Legitimate first-party request: stamped, token not forwarded,
      // original Sec-Fetch forwarded for the backend gate.
      const own = await request(`${server.url}/v1/sessions`, 'POST', '{}', {
        'x-veasel-proxy': TOKEN,
        origin: `http://127.0.0.1:${port}`,
        'sec-fetch-site': 'same-origin',
      });
      expect(own.status).toBe(200);
      expect(hits).toEqual([{ url: '/v1/sessions', desktop: '1', proxy: undefined, fetchSite: 'same-origin' }]);

      // Static shell stays public and hardened.
      const shell = await get(`${server.url}/`);
      expect(shell.status).toBe(200);
    } finally {
      await server.close();
    }
  });

  it('closes active proxied streams during shutdown', async () => {
    let markStreamOpen: () => void = () => undefined;
    let markStreamClosed: () => void = () => undefined;
    const streamOpen = new Promise<void>((resolve) => {
      markStreamOpen = resolve;
    });
    const streamClosed = new Promise<void>((resolve) => {
      markStreamClosed = resolve;
    });
    const backend = http.createServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: connected\n\n');
      markStreamOpen();
      res.once('close', markStreamClosed);
    });
    backends.push(backend);
    await new Promise<void>((resolve) => backend.listen(0, '127.0.0.1', resolve));
    const backendPort = (backend.address() as AddressInfo).port;

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), 'ok');
    const server = await startRendererServer(dir, { proxyToken: TOKEN });
    server.setBackendTarget(`http://127.0.0.1:${backendPort}`);
    const request = http.get(`${server.url}/api/v1/events`, { headers: { 'x-veasel-proxy': TOKEN } });
    request.on('error', () => undefined);

    await streamOpen;
    await server.close();
    await expect(streamClosed).resolves.toBeUndefined();
  });

  it('handles an upstream response stream error without taking down the renderer server', async () => {
    const backend = http.createServer((_req, res) => {
      res.on('error', () => undefined);
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: partial\n\n');
      setImmediate(() => res.destroy(new Error('upstream stream ended unexpectedly')));
    });
    backends.push(backend);
    await new Promise<void>((resolve) => backend.listen(0, '127.0.0.1', resolve));
    const backendPort = (backend.address() as AddressInfo).port;

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), 'ok');
    const server = await startRendererServer(dir, { proxyToken: TOKEN });
    server.setBackendTarget(`http://127.0.0.1:${backendPort}`);
    try {
      const responseClosed = new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), 5_000);
        const finish = () => {
          clearTimeout(timer);
          resolve(true);
        };
        const request = http.get(`${server.url}/api/v1/events`, { headers: { 'x-veasel-proxy': TOKEN } });
        request.on('error', finish);
        request.on('response', (response) => {
          response.once('close', finish);
          response.resume();
        });
      });
      await expect(responseClosed).resolves.toBe(true);
      expect((await get(`${server.url}/`)).status).toBe(200);
    } finally {
      await server.close();
    }
  });
  it('injects the backend bearer token itself and never exposes it to the renderer', async () => {
    const seen: Array<string | undefined> = [];
    const backend = http.createServer((req, res) => {
      seen.push(req.headers.authorization);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    backends.push(backend);
    await new Promise<void>((resolve) => backend.listen(0, '127.0.0.1', resolve));
    const backendPort = (backend.address() as AddressInfo).port;

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atk-renderer-'));
    dirs.push(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), 'ok');
    let current: string | undefined = 'Bearer backend-secret-1';
    const server = await startRendererServer(dir, { proxyToken: TOKEN, backendAuthorization: () => current });
    server.setBackendTarget(`http://127.0.0.1:${backendPort}`);
    try {
      const plain = await request(`${server.url}/v1/sessions`, 'GET', '', { 'x-veasel-proxy': TOKEN });
      expect(plain.status).toBe(200);
      expect(plain.body).not.toContain('backend-secret');
      // A renderer-supplied Authorization is discarded, not forwarded.
      await request(`${server.url}/v1/sessions`, 'GET', '', {
        'x-veasel-proxy': TOKEN,
        authorization: 'Bearer renderer-forged',
      });
      // Rotation is picked up per request.
      current = 'Bearer backend-secret-2';
      await request(`${server.url}/v1/sessions`, 'GET', '', { 'x-veasel-proxy': TOKEN });
      current = undefined;
      await request(`${server.url}/v1/sessions`, 'GET', '', {
        'x-veasel-proxy': TOKEN,
        authorization: 'Bearer renderer-forged',
      });
      expect(seen).toEqual([
        'Bearer backend-secret-1',
        'Bearer backend-secret-1',
        'Bearer backend-secret-2',
        undefined,
      ]);
      // The proxy token gate still fails closed before the backend is contacted.
      const before = seen.length;
      expect((await get(`${server.url}/v1/sessions`)).status).toBe(403);
      expect(seen.length).toBe(before);
    } finally {
      await server.close();
    }
  });
});
