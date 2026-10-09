# Contributing to Veasel Code

Thanks for helping build a safe, fast coding agent in V. Start with the current
implementation status in `docs/IMPLEMENTATION_PLAN.md`; documented plans are
not claims that a feature already works.

## Development

- Use the V compiler revision in `.v-version` for reproducible builds.
- Keep V checks resource-bounded: `VJOBS=1 v fmt -verify .`, `VJOBS=1 v test .`,
  then `VJOBS=1 v -o /tmp/veasel .`.
- Run `scripts/api-smoke.sh` for HTTP and persistence changes.
- In `tui/`, use `bun install --frozen-lockfile` and `bun run typecheck`.
- Add tests for behavior and update OpenAPI, compatibility notes, and user docs
  when interfaces or support claims change.

## Security-sensitive changes

Do not execute provider or plugin supplied text through a shell. Preserve
workspace boundaries, redact credentials from logs, validate network redirects,
and document explicit user approval for actions with side effects. Report
vulnerabilities privately using `SECURITY.md`.

## Pull requests

Explain the user problem, implementation, validation, and relevant security or
performance effects. Keep changes focused and report limitations honestly.
