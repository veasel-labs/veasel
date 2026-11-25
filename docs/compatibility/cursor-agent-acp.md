# Cursor Agent CLI ACP discovery

## Observed environment

On HorneroOS on 2026-11-25, the installed `cursor-agent` reported version
`2026.09.15-d2fe57e`. A non-mutating `cursor-agent status --format json` probe
reported `isAuthenticated: true`; no credential file or token was read. ACP
`initialize` succeeded. Cursor's `authenticate` request using
`methodId: "cursor_login"` opens a separate browser challenge. Sending
`session/new` without completing that authentication returned
`Authentication required`.

These observations establish local discovery and initialization only. They do
not establish that a Veasel session can authenticate, resume, or safely handle
Cursor permission requests.

## Current backend behavior

Veasel may report the installed version and the CLI's boolean auth status. It
does not read or persist Cursor credentials and does not invoke the browser
login flow. Cursor remains disabled in the CLI runner picker and the backend
launch gate rejects it with the missing ACP authentication and permission
contracts. The current generic ACP runner does not send `authenticate` and its
permission-option mapping has only been verified for OpenCode and Muse.

Cursor's official ACP guide says clients should initialize, authenticate with
`cursor_login`, then create/load a session. It lists `allow-once`,
`allow-always`, and `reject-once` permission responses. These details are not
treated as a verified Veasel adapter contract until exercised against the
installed CLI, including rejection, cancellation, resume, and permission
prompts.

## References

- [Cursor CLI ACP](https://cursor.com/docs/cli/acp)
- [Cursor CLI authentication](https://prod.cursor.com/docs/cli/reference/authentication)
