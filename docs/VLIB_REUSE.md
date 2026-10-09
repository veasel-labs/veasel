# V standard library reuse map

## Policy

Before adding a dependency or implementing infrastructure, inspect the
supported V compiler's `vlib/`. Prefer its maintained modules when they cover
the need. A gap or a required product-specific policy is a valid reason for
Veasel code or a third-party adapter; importing unrelated libraries is not.
This map was verified against V `5bd67093f97f3574b36bc1a9f19f56a9c0a4ad07`
(V 0.5.2, local checkout 242 commits ahead of its recorded upstream). Recheck
the APIs against each supported compiler release.

“Use all libraries” means a complete audit and reuse of every relevant module.
It does not mean importing modules unrelated to a coding agent.

## Reuse by product area

| Area | V library and evidence | Veasel use / boundary |
|---|---|---|
| HTTP server | `vlib/veb`; `veb/README.md`, `veb/veb.v`, `veb/parse.v` | Use for versioned routes, request contexts, loopback binding and status mapping. Keep route handlers thin. |
| Server events | `vlib/veb/sse/sse.v` | Use connection takeover and `SSEConnection` for event delivery; Veasel owns durable event IDs, replay, event schema, and connection lifecycle tests. |
| HTTP client | `vlib/net/http/request.v` | Use for model/provider requests and response/progress callbacks after checking streaming and timeout semantics in the pinned V version. Do not hand-roll HTTP or TLS. |
| JSON | `vlib/json2/` | Use typed `decode[T]` and `encode[T]`; do not use obsolete `encoding.json` imports. |
| SQLite | `vlib/db/sqlite/sqlite.c.v`, `orm.v` | Use prepared parameters, WAL, busy timeout, transactions and schema introspection. Migration versions/SQL remain small product-owned code because `vlib` has no general migration runner. |
| IDs / randomness | `vlib/uuid/`, `vlib/crypto/rand/` | Use UUID v4/v7 and cryptographic random bytes where appropriate; do not substitute timestamps or `math/rand` for security-sensitive values. |
| Synchronization | `vlib/sync/` | Use mutexes, channels, wait groups and timers for shared state and workers; define ownership, shutdown and cancellation at the application layer. |
| Cancellation | `vlib/context/` | Use cancel/deadline contexts for jobs and provider calls; explicitly bridge cancellation to child process signals because V contexts do not stop processes by themselves. |
| Child processes | `vlib/os/process.v`, `vlib/os/command.c.v` | Use literal argument arrays, working directories, bounded output and explicit process lifecycle. Never interpolate untrusted input into `os.execute` shell strings. |
| Filesystem | `vlib/os/os.v`, `vlib/os/filepath.v` | Reuse path handling, `read_file`, `write_file`, `walk`, `walk_ext`, `walk_dir`, and `glob`. Add root containment, symlink and permission policy in Veasel. |
| Text search | `vlib/regex/` | Use for bounded filtering/matching. `vlib` has no indexed, ripgrep-class source search; use an explicit `rg` tool adapter or a measured bounded walker rather than claiming equivalent search. |
| Diffs | `vlib/arrays/diff/` | Evaluate generic Myers-style diff and patch generation for line changes before introducing another diff engine; wrap it with file/path policy and tests. |
| Git | No high-level Git client module found in this checkout. | Use the shell-free process adapter to invoke Git with fixed argument arrays; parse structured output and test each supported Git version. |
| MCP | `vlib/mcp/` | Reuse message, client and server protocol support for the MCP milestone. Add Veasel-specific tool policy and trust boundaries around external servers. |
| Terminal | `vlib/term/ui/`, `vlib/term/`, `vlib/readline/`, `vlib/ncurses/` | Native V has terminal input/rendering and line-editing tools. Measure its layout/widget limits against product UX. The current richer OpenTUI client remains a separate API consumer; the runtime stays V. |
| Logging | `vlib/log/`, `vlib/log/safe_log.v` | Use structured levels and thread-safe logging. Redact credentials and untrusted content in Veasel before output. |
| Benchmarks | `vlib/benchmark/` | Use reproducible V benchmarks for startup, storage, tool process overhead and other native runtime paths; record machine/compiler/workload metadata. |
| CLI parsing | `vlib/cli/` | Prefer the typed command/flag/help API as CLI options grow beyond the current simple command switch. |
| Timeouts | `vlib/time/` | Use monotonic duration/timer APIs for elapsed time, deadlines, retry delays and heartbeat intervals. |
| Tests | V test runner and `*_test.v` | Keep focused domain tests in V; add real HTTP/SSE contract smoke tests and client rendering tests where required. No external V test framework is needed. |

## Known gaps that need explicit decisions

The audited `vlib` does not supply a general SQLite migration runner, a
high-level Git API, indexed source search, a portable recursive file watcher,
OS keychain storage, telemetry exporters, or complete high-level TUI widgets.
Veasel must either own a narrow adapter with tests or select a dependency for a
documented reason. Provider streaming, process-tree cancellation, terminal
compatibility, and SQLite native-library packaging need platform validation.

## Current foundation imports

The first vertical slice uses `veb`, `veb.sse`, `json2`, `db.sqlite`, `os`,
`sync`, `uuid`, `strconv` and `time`. The next tool/provider/job milestones
should first evaluate the modules above instead of creating replacement
implementations.
