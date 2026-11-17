// @vitest-environment node
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { startRendererServer, type RendererServer } from './renderer-server';

const SECRET = 'outside-secret-do-not-serve';

/** Send raw bytes so malformed targets reach the server unmodified. */
function raw(port: number, requestLine: string, headers: string[] | null = null): Promise<{ status: number; body: string }> {
  return new Promise((resolve) => {
    const hdrs = headers ?? [`Host: 127.0.0.1:${port}`];
    const socket = net.connect(port, '127.0.0.1');
    let data = '';
    socket.setTimeout(3000, () => socket.destroy());
    socket.on('data', (c) => (data += c.toString('utf8')));
    const done = (): void => {
      const m = /^HTTP\/1\.[01] (\d{3})/.exec(data);
      resolve({ status: m ? Number(m[1]) : 0, body: data });
    };
    socket.on('close', done);
    socket.on('error', () => undefined);
    socket.write(`${requestLine}\r\n${hdrs.join('\r\n')}${hdrs.length ? '\r\n' : ''}Connection: close\r\n\r\n`);
  });
}

describe('renderer-server hardening', () => {
  let tmp: string;
  let dist: string;
  let server: RendererServer;
  let port: number;

  beforeEach(async () => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'veasel-hardening-'));
    dist = path.join(tmp, 'dist');
    fs.mkdirSync(dist);
    fs.writeFileSync(path.join(dist, 'index.html'), '<html>ok</html>');
    fs.writeFileSync(path.join(tmp, 'secret.txt'), SECRET);
    fs.symlinkSync(path.join(tmp, 'secret.txt'), path.join(dist, 'link.txt'));
    fs.symlinkSync(tmp, path.join(dist, 'linkdir'));
    server = await startRendererServer(dist, { proxyToken: 'tok' });
    port = Number(new URL(server.url).port);
  });

  afterEach(async () => {
    await server.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  async function expectAlive(): Promise<void> {
    const res = await raw(port, 'GET / HTTP/1.1');
    expect(res.status).toBe(200);
    expect(res.body).toContain('<html>ok</html>');
  }

  const malformed = [
    '/%',
    '/%zz',
    '/%E0%A4%A',
    '/%00',
    '/a%00.html',
    '/..%2f..%2fetc/passwd',
    '/%2e%2e/%2e%2e/etc/passwd',
    '/%2e%2e/',
    '/..%5c..%5csecret.txt',
    '/%5c..%5csecret.txt',
    '/%252e%252e/%252e%252e/secret.txt',
    '/..%252f..%252fsecret.txt',
    '/' + 'a'.repeat(20000),
    '/' + '%41'.repeat(5000),
  ];

  for (const target of malformed) {
    it(`survives and never leaks for ${target.slice(0, 40)}`, async () => {
      const res = await raw(port, `GET ${target} HTTP/1.1`);
      expect(res.body).not.toContain(SECRET);
      expect(res.body).not.toContain('root:');
      expect([0, 200, 400, 403, 404, 414, 431]).toContain(res.status);
      await expectAlive();
    });
  }

  it('rejects malformed escapes with 400/403/404 (not a crash)', async () => {
    for (const t of ['/%', '/%zz', '/%00']) {
      const res = await raw(port, `GET ${t} HTTP/1.1`);
      expect([400, 403, 404]).toContain(res.status);
    }
    await expectAlive();
  });

  it('does not serve a symlinked file that points outside the root', async () => {
    const res = await raw(port, 'GET /link.txt HTTP/1.1');
    expect(res.body).not.toContain(SECRET);
    expect([403, 404]).toContain(res.status);
  });

  it('does not traverse a symlinked directory that points outside the root', async () => {
    const res = await raw(port, 'GET /linkdir/secret.txt HTTP/1.1');
    expect(res.body).not.toContain(SECRET);
    expect([403, 404]).toContain(res.status);
  });

  it('rejects static requests with a rebinding Host', async () => {
    for (const host of ['evil.example.com', `evil.example.com:${port}`, '127.0.0.1:1', `localhost:${port}`]) {
      const res = await raw(port, 'GET / HTTP/1.1', [`Host: ${host}`]);
      expect(res.status, host).toBe(403);
      expect(res.body).not.toContain('<html>ok</html>');
    }
    await expectAlive();
  });

  it('rejects static requests with an absent Host', async () => {
    const res = await raw(port, 'GET / HTTP/1.0', []);
    expect([400, 403]).toContain(res.status);
    expect(res.body).not.toContain('<html>ok</html>');
    await expectAlive();
  });

  it('survives garbage on the wire (clientError)', async () => {
    const res = await raw(port, 'NOT HTTP AT ALL \x00\x01', []);
    expect(res.body).not.toContain(SECRET);
    await expectAlive();
  });

  it('keeps proxy token gate for /api with correct Host', async () => {
    const res = await raw(port, 'GET /api/x HTTP/1.1');
    expect(res.status).toBe(403);
  });
});
