# Backend caller authentication (ADR)

**Status:** Accepted. Implements the P0 item of epic #689.
**Code:** `api_auth.v`, `api_auth_nix.c.v`, `api_auth_windows.c.v`, `api_auth_cli.v`,
`Context.before_request` in `api.v`. **Tests:** `api_auth_test.v`, `scripts/api-smoke.sh`.

## Problem

The only gate was a loopback `Host` check plus a loopback `Origin` check
*when an Origin was present*. A request without Origin (curl, any local
process, a script) was accepted, and about 90 `/v1` routes were open:
sessions, workspace edits and shell-command approvals, MCP server add
(which launches a stdio command), MCP credentials, model settings, plugin
install, the SSE stream. The Desktop proxy token (#720) was never checked by
the backend.

## Decision

1. **Bearer token on every route.** `Context.before_request` runs before
   veb routing, so it covers every method, unknown routes, `HEAD`/`OPTIONS`,
   trailing-slash/case/encoding variants and SSE. Exactly one
   `Authorization: Bearer <token>` header is accepted. Query-string, cookie
   and custom-header credentials are ignored. The compare hashes both sides
   with SHA-256 and uses `crypto.subtle.constant_time_compare`, so it is
   constant-time and length-independent. Only the digest is kept in memory.
   An unconfigured verifier rejects everything (fail closed).
2. **One exemption:** `GET /v1/health` with the exact path. Without a token it
   returns `{"healthy":true,"auth":"bearer","protocol":1}` (no pid, version or
   paths; `auth`/`protocol` are the capability clients negotiate on, see
   Migration). With a valid token it
   returns the previous payload (`version`, `pid`), so the CLI stale-server
   warning and the Desktop identity probe keep working. Every other spelling
   of that path (`/v1/health/`, `/V1/health`, `%68ealth`, absolute-form,
   `POST`, `HEAD`, `OPTIONS`) requires the token.
3. **Host and Origin checks stay** and run first, so DNS-rebinding and
   cross-origin requests get 403 even with a correct token. "No Origin =>
   allowed" is gone: a request with no Origin is allowed only if it proves it
   holds the token. A loopback Origin (Desktop renderer, dev servers) also
   needs the token. Browsers cannot attach `Authorization` cross-origin
   without CORS, and the server sends no CORS headers, so web pages cannot
   call the API.
4. **401 body** is JSON `{"error": ...}` plus `WWW-Authenticate: Bearer`. It
   names the discovery mechanism (`api-token` in the data directory,
   `VEASEL_API_TOKEN`) but never a token, a real path, or another user's path.

## Token lifecycle

| Aspect | Behavior |
|---|---|
| Generation | 32 bytes from the OS CSPRNG (`crypto.rand`), 64 lowercase hex chars. |
| Location | `$VEASEL_DATA_DIR/api-token` (default `~/.local/share/veasel/api-token`). `veasel token path` prints it. |
| Override | `VEASEL_API_TOKEN` (32-512 printable ASCII chars, no whitespace). Wins over the file, is never written to disk, and disables rotation. |
| Creation | Written to a unique `api-token.tmp-<pid>-<rand>` created with `open(O_CREAT\|O_EXCL, 0600)`, fsynced, then `link()`ed into place. The final path is never partially written, and two servers starting together converge on one token. Data dir is created `0700`; an existing dir that is group/world-writable is chmod'd to `0700` or startup fails. |
| Restart | An existing valid file is reused, so a CLI/TUI/Desktop that cached the path or value keeps working and `veasel` still reuses a running backend. |
| Crash leftovers | Temp files older than 60 s are removed at startup. A private file with malformed/truncated content is replaced atomically. |
| Permission self-check | On POSIX the server refuses to start (exit 1, message tells the user to `chmod 600` or rotate) if the file is a symlink or not a regular file, is not owned by the current user, or has any group/other bit. Clients apply the same check and send no token from a bad file. A bad file is never auto-repaired. |
| Rotation | `veasel token rotate` (live server: `POST /v1/auth/rotate` with the current token; no server: rewrite the file). The new file is written to a temp file then `rename()`d, and the live verifier swaps at the same time. The old token returns 401 immediately; the new value is only written to the file, never returned. TUI and Desktop re-read the file per request. A TUI or CLI request that gets 401 re-reads the file and retries once when the value changed, so a client holding the old token recovers without a restart. Connections already open (SSE) are not cut by rotation; reconnecting needs the new token. Other processes that cached the value need a restart. Not available with `VEASEL_API_TOKEN`. |
| Windows | No POSIX modes, so ACLs are explicit. The data directory is restricted first (`icacls <dir> /inheritance:r /grant:r *<current-user-SID>:(OI)(CI)F`, SID from `whoami /user`), then stray entries are removed by SID, so a new token inherits a user-only ACL from creation; the file is then restricted again. Every start and every client read checks the DACL (read with `icacls /save`, so SIDs and SDDL aliases, never localized names) against an allowlist: the current user, `S-1-5-18` (SYSTEM) and `S-1-5-32-544` (BUILTIN\Administrators). Anything else (Everyone, `BUILTIN\Users`, Authenticated Users, other users or groups, ANONYMOUS, NETWORK, ...) makes the server refuse to start and clients refuse to send the token (fail closed). SYSTEM and Administrators are allowed because they can reach the file regardless (an administrator can take ownership), so they are outside the threat model, like same-user processes below. Commands run as argument arrays through `os.exec`; no shell string. Verified by `api_auth_windows_test.v` (allowlist and parser tests run on every OS; icacls tests on the CI Windows job). A second local user is not created on the runner; foreign SIDs are covered by the allowlist unit test. |

## Clients

- **CLI** (`headless_*`, `ensure_backend`, `veasel token`): reads
  `VEASEL_API_TOKEN` or the file in `default_data_dir()`; sends the header on
  every API call and on the health probe.
- **TUI**: `tui/src/backend-auth.ts` wraps `fetch` for the backend origin only
  (installed by both entry points); the file is re-read per request.
- **Desktop**: the main process reads the token (`readBackendApiToken`) and
  the renderer proxy injects `Authorization` per request, discarding any
  `Authorization` the renderer sends. The renderer never receives the backend
  token (it still holds only the separate `x-veasel-proxy` capability). The
  backend child is started with the canonical data dir, so TUI-first and
  Desktop-first starts share one token.
- **Scripts / external clients**: send the header; `scripts/api-smoke.sh`,
  `scripts/standalone-tui-smoke.py` and `benchmarks/repo-map-recall.mjs` read
  the file from their disposable data dir. The Harbor adapter and the other
  benchmark launchers only poll `GET /v1/health` and start the CLI with the
  same environment, so they need no change.
- `docs/openapi.yaml` declares `bearerAuth` globally and `security: []`-style
  override on `getHealth`.

## Migration: legacy backends and capability negotiation

A backend started by an older Veasel build enforces no authentication, so any
local process can drive it (approve edits, add MCP servers, ...). A new client
that silently attached to it would trust an insecure server. Every client path
that discovers or reuses a backend therefore negotiates first:

1. It probes `GET /v1/health` and an unauthenticated protected route
   (`GET /v1/capabilities`) **without any credential**. The server is `secure`
   only if health advertises `"auth":"bearer"` with `protocol >= 1` and the
   protected route answers 401.
2. A reachable server that does not prove this (old health with `version`/`pid`,
   a spoofed capability whose protected route answers 200, unparseable or
   non-200 health) is **legacy** and is refused: the client does not attach,
   does not send the token, and does not start a second backend beside it. It
   never falls back silently. An unreachable port is `absent`, which means "spawn
   our own".
3. Applies to: the CLI (`veasel`, `veasel run`, `mcp`, `config`, `skills`,
   `plugins`, `worktrees`), the TUI (both entry points), the Desktop supervisor
   (blocking error state, no renderer-visible token), the Harbor adapter (waits
   for the capability) and the scripts.

Recovery is explicit and non-destructive. Veasel **never stops or signals a
process it did not start**. The error names the port, says a legacy backend is
running, reports (from a read-only `GET /v1/operations`, when the legacy API
answers) how many turns are running or queued and will be interrupted, and gives
the steps to stop it yourself:

- Linux: `ss -ltnp "sport = :<port>"`, then `kill <pid>` (SIGTERM is graceful)
- macOS: `lsof -nP -iTCP:<port> -sTCP:LISTEN`, then `kill <pid>`
- Windows: `netstat -ano | findstr :<port>`, then `taskkill /PID <pid>`

Sessions live in SQLite and are kept; only in-flight turns are lost. The
alternative is a new backend on another port (`VEASEL_PORT`) with a **separate**
`VEASEL_DATA_DIR`. Two backends must never share one data directory (SQLite
recovery and queues assume a single owner): a current backend takes an exclusive
lock on `<data dir>/backend.lock` and refuses to start if another current backend
holds it, but a legacy process holds its directory without any lock, so that
case cannot be detected and the instructions require a separate directory.

## Alternatives considered

- **Unix domain socket / named pipe only.** Not adopted. veb (pinned V) serves
  TCP only, so this needs a different server or a proxy; Electron `fetch`, the
  TUI, curl, the Harbor adapter and every external client are URL/TCP based;
  Windows needs a separate named-pipe path. Its security gain over a 0600
  token file is small: both are same-OS-user boundaries (file mode on the
  socket instead of on the token). The one real gain, kernel peer credentials
  (`SO_PEERCRED`), still only identifies the uid, not the process. Kept as a
  future complement (socket for first-party clients, token for the rest) if
  the owner wants it.
- **Token only in the process environment / argv.** Rejected: readable in
  `/proc/<pid>/environ` and `ps`, and lost on backend reuse. Env stays as an
  explicit override only.
- **Per-launch random token handed from a launcher.** Rejected: breaks "a
  running backend is reused by later CLI/TUI invocations".
- **Origin allow-list / CORS only.** Rejected: curl and any local process omit
  Origin.
- **Rate limiting.** Not needed for a 256-bit random token.

## Limits (explicit)

- **Out of scope on Windows:** SYSTEM and local Administrators. They can read the token file (or take ownership of it) regardless of the ACL, as root can on POSIX.

- **A 0600 token is NOT a defense against malicious code running under the same OS account.** That code can read the file, read `/proc/<pid>/environ`, ptrace the TUI/Desktop, or simply act as the user. The token only separates *other* accounts, browsers/web pages, DNS rebinding and unauthenticated local clients.
- **A malicious process running as the same OS user can read the token file**
  (or `/proc/<pid>/environ`, or ptrace the TUI/Desktop) and call the API. This
  change blocks other users, browsers/web pages, DNS rebinding, and
  unauthenticated local clients; it does not defend against same-user code
  execution. OS sandboxing of the approved shell and MCP stdio remains the
  control for what a compromised tool can reach.
- Traffic is plaintext HTTP on loopback; another user cannot read the token
  from the socket, but a privileged local attacker can.
- A backend started by an older Veasel build has no auth. The CLI still reuses
  it (and prints the existing stale-version warning); restart it to get
  protection. A client built from this change talking to such a server simply
  sends an ignored header.
- Old external clients get 401 until they send the header; this is the
  intended breaking change for the unauthenticated surface.
- If the token file is replaced on disk while a server runs (for example by an
  offline `veasel token rotate` against a server running elsewhere), the
  server keeps its in-memory value until rotated through the API or
  restarted; clients then see 401.
- `veb` ordering was verified on the local V (0.5.2, `4a23b18`) and by reading
  the pinned `.v-version` source; the pinned compiler itself was not built.
