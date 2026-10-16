# TUI device pairing (OpenCode parity)

**Upstream:** OpenCode `dialog-pair.tsx` + `server.pair` auxiliary client flow.

**Veasel decision:** **N/A** for the current product boundary.

Veasel binds the agent runtime to loopback HTTP by default and does not expose an
OpenCode-style pairing endpoint for secondary clients. The Solid TUI surfaces an
honest **Device pairing** dialog (command palette → “Device pairing”) that points
here instead of a non-functional QR / code flow.

**If requirements change:** document the new HTTP contract in `docs/openapi.yaml`
before adding a real pairing dialog.
