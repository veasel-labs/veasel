// Non-interactive TUI-client continuity probe (J9). Uses the TUI's OWN API
// client and auth wrapper (tui/src), not a hand-rolled fetch, to resume an
// exact session id against a running backend, read its transcript and send one
// message. It is NOT a pty-driven TUI session (see docs/desktop/E2E_EVIDENCE.md).
//
// usage: bun run tui-resume.mjs <tui-src-dir> <api-base> <session-id> <message>
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [tuiSrc, base, sessionId, message] = process.argv.slice(2);
const load = (name) => import(pathToFileURL(path.join(tuiSrc, name)).href);
const { installBackendAuth } = await load('backend-auth.ts');
const { VeaselApiClient } = await load('api-client.ts');

installBackendAuth(base);
const client = new VeaselApiClient(base);
const sessions = await client.listSessions();
const session = sessions.find((candidate) => candidate.id === sessionId) ?? null;
const before = session ? await client.listMessages(sessionId) : [];
let sent = null;
if (session) {
  try {
    sent = await client.sendMessage(sessionId, message, randomUUID());
  } catch (error) {
    sent = { error: String(error) };
  }
}
// Give the (possibly failing) turn a moment to persist before re-reading.
await new Promise((resolve) => setTimeout(resolve, 8000));
const after = session ? await client.listMessages(sessionId) : [];
process.stdout.write(
  `${JSON.stringify({ found: Boolean(session), session, directory: session?.directory ?? null, before, sent, after })}\n`,
);
