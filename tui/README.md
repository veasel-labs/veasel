# Veasel terminal client

The terminal client is a TypeScript OpenTUI + SolidJS application. It uses only
the versioned Veasel HTTP API; persistence and execution remain in the V
backend.

## Run

From this directory, install the locked dependencies with `bun install`, then:

- `bun run start` — SolidJS OpenTUI client (`src/solid/main.tsx`, default):
  session home, live loopback HTTP turns, SSE assistant deltas, MODEL SETTINGS
- `bun run start:classic` — retired imperative OpenTUI shell
  (`src/classic-main.ts`) kept for emergency comparison only

From the repository root, `v run . tui` starts the Solid development client
through Bun (`bun run start`). Standalone packaging defaults to the Solid
entry; pass `--classic` to `scripts/build-standalone.ts` for the retired
imperative shell. Release archives compile the client into a standalone
`veasel-tui` executable beside the V backend; installed `veasel` commands do
not need a separately installed Bun runtime. Start the V server separately
with `v run . serve`. Set `VEASEL_API_URL` when the backend listens on another
loopback port.

Solid migration pins and upstream study commits:
[`docs/compatibility/opentui-solid.md`](../docs/compatibility/opentui-solid.md).

The client can list and refresh sessions, create one for the current working
directory, inspect its metadata, and reconnect to the replayable event stream.
Enter `/help` inside a session (classic parity path) or use the Solid home
chords (`n` new session, Enter open, `s` MODEL SETTINGS, `q` quit). Provider
settings use the server's catalog and active credential state. It sends chat
turns with `Prefer: respond-async`, renders durable assistant deltas while the
operation runs, and reloads the committed exchange after its
`session.turn_completed` event.

The startup screen uses a 32×32 pixel portrait of Veasel's original mustelid
companion, rendered as 16 rows of Unicode half-blocks. Its teal, cream, coral,
and highlight colors follow the active theme. The art is MIT-licensed and does
not reuse the V language mascot artwork; the upstream mascot's CC BY-NC 4.0
license is recorded in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
