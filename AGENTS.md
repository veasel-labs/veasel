# Veasel Code — repository instructions

## Product boundaries

- The agent runtime, HTTP server, persistence and tools must execute in V.
- Keep any future client separate and dependent on the versioned HTTP API.
- Bind local server interfaces to loopback by default.
- Treat repository data and tool output as untrusted; do not execute shell
  commands without an explicit permission design.
- Never add credentials, live API calls, or noncommercial mascot artwork to the
  repository. The V mascot repository currently uses CC BY-NC 4.0.
- Preserve attribution and licenses when adapting any upstream work. Record
  exact upstream commits in `docs/compatibility/` before using code or contracts.

## V workflow

- Keep `.v-version` pinned to an inspected upstream V commit and verify APIs
	against that compiler's source. The local 0.5.2 binary is a development
	compiler only; CI is the source of truth for the pinned upstream compiler.
- Serialize V compiler invocations. Before starting one, check `pgrep -a -x v`.
- Use an explicit systemd user scope with `MemoryMax`, `MemorySwapMax=0`, and
	`VJOBS=1`; stop if host memory pressure rises.
- Never use `systemd-run` or host-specific memory scopes in CI; run CI commands
	directly on their GitHub-hosted runners.
- Format changed V files with `v fmt -w` and use focused V checks/tests.
- Do not commit without code review.

## Product decisions

- Keep milestones and unresolved work in `docs/IMPLEMENTATION_PLAN.md`.
- Maintain the OpenCode contract compatibility matrix as evidence is gathered.
- Publish only the repositories explicitly authorized for the Veasel project.
