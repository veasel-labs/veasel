# Veasel Code

Veasel Code is an open-source AI coding agent with a V-native runtime and a
server-first API. The project is being built in working vertical slices; see
[`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) for the current
scope and status.

## Current status

Milestone 1 provides a V server with health/capability endpoints,
SQLite-backed sessions, a replayable event stream, and a small terminal
client. Model-backed coding and tool execution are later milestones; no agent
response is simulated here.

## Requirements

- V 0.5.2 or newer (initial API verification is against 0.5.2)
- SQLite development headers/library as required by V's `db.sqlite`
- Bun 1.3.14 or newer for the OpenTUI terminal client (not needed by the backend)

## Development

```sh
v run . serve
v run . tui
v fmt -w .
```

The server defaults to `127.0.0.1:4097`. Set `VEASEL_DATA_DIR` to choose the
directory for `veasel.sqlite3`. Remote binding is not implemented. The TUI
accepts `VEASEL_API_URL` only for an unauthenticated loopback HTTP address.

## API

Milestone 1 uses `/v1/health`, `/v1/capabilities`, `/v1/sessions`,
`/v1/sessions/:id`, and `/v1/events` (SSE). See the OpenAPI document at
[`docs/openapi.yaml`](docs/openapi.yaml).

## Verification

Run `v test main_test.v` for the SQLite domain tests and
`scripts/api-smoke.sh` for HTTP validation, session persistence across a
server restart, and SSE replay. The smoke script requires `curl` and GNU
`timeout`. For memory-bounded local V checks, see [AGENTS.md](AGENTS.md).

See [`docs/VLIB_REUSE.md`](docs/VLIB_REUSE.md) for the checked V standard
library reuse map and [`docs/RESEARCH.md`](docs/RESEARCH.md) for ecosystem and
repository practices.

## Licensing

The initial code is MIT licensed. The official Veasel mascot artwork is not
included: its upstream repository currently declares CC BY-NC 4.0. No
endorsement by the V project is implied.
