# Veasel terminal client

The terminal client is a TypeScript OpenTUI application. It uses only the
versioned Veasel HTTP API; persistence and execution remain in the V backend.

## Run

From this directory, install the locked dependencies with `bun install`, then:

- `bun run start` — legacy imperative OpenTUI client (`src/main.ts`, default)
- `bun run start:solid` — SolidJS shell stub (`src/solid/main.tsx`; P0 chrome +
  composer only; not yet feature-complete)

From the repository root, `v run . tui` starts the legacy development client
through Bun. Standalone packaging defaults to the legacy entry; pass `--solid`
to `scripts/build-standalone.ts` for the Solid entry. Release archives compile
the client into a standalone `veasel-tui` executable beside the V backend;
installed `veasel` commands do not need a separately installed Bun runtime.
Start the V server separately with `v run . serve`. Set `VEASEL_API_URL` when
the backend listens on another loopback port.

Solid migration pins and upstream study commits:
[`docs/compatibility/opentui-solid.md`](../docs/compatibility/opentui-solid.md).

The client can list and refresh sessions, create one for the current working
directory, inspect its metadata, and reconnect to the replayable event stream.
Enter `/help` inside a session to see available commands, keyboard shortcuts,
and the review steps for file edits, shell commands, and MCP tool calls.
Provider settings use the server's catalog and active credential state. Filter
presets by typing, or press Tab to cycle through all, configured, loopback-local,
specialized-API, and OpenAI-compatible groups. Selecting a provider runs its
live model-list request before offering models; a newly entered key stays in
memory for discovery and is saved only after a model is selected. Providers
whose endpoint does not expose a compatible model list can use a manually
entered model ID.
It sends chat turns with `Prefer: respond-async`, renders durable assistant
deltas while the operation runs, and reloads the committed exchange after its
`session.turn_completed` event. This releases an HTTP worker while the model or
a human MCP approval is pending. Turns persist as `queued` before a worker
claims them and resume after server restart; claimed mid-flight work becomes
`uncertain` and is not replayed.

The startup portrait is a pixel-art adaptation of Veasel, the V language
mascot. The original mascot is by the V contributors; this adaptation is
licensed under CC BY-NC 4.0 and is not covered by Veasel Code's MIT license.
Commercial use requires separate permission from the rights holder. See
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
