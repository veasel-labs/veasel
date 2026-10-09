# Veasel terminal client

The terminal client is a TypeScript OpenTUI application. It uses only the
versioned Veasel HTTP API; persistence and execution remain in the V backend.

## Run

From this directory, install the locked dependencies with `bun install`, then
run `bun run start`. From the repository root, `v run . tui` starts the same
client. Start the V server separately with `v run . serve`. Set
`VEASEL_API_URL` when the backend listens on another loopback port.

The initial client can list and refresh sessions, create one for the current
working directory, inspect its metadata, and reconnect to the replayable event
stream. It reports that agent execution is unavailable rather than simulating
an agent response.

The startup portrait is a pixel-art adaptation of Veasel, the V language
mascot. The original mascot is by the V contributors; this adaptation is
licensed under CC BY-NC 4.0 and is not covered by Veasel Code's MIT license.
Commercial use requires separate permission from the rights holder. See
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
