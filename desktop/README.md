# Veasel Desktop

Veasel Desktop is the graphical client for Veasel Code. It uses the same V
backend, data directory, provider settings and persisted sessions as the
`veasel` terminal client. There is one runtime; Electron owns window, secure
loopback proxy, native dialogs and terminal transport only.

See [ADR-033](../../docs/adrs/ADR-033-electron-desktop.md), the
[Desktop UX architecture](../../docs/desktop/UX_ARCHITECTURE.md), and the
[Desktop guide](../../docs/desktop/README.md) for current product behavior and
known limits.

## Architecture

- **Veasel V is the only backend.** The main process starts or securely attaches
  to `veasel serve`. It serves the renderer through a same-origin loopback
  proxy that injects the backend token without exposing it to renderer code.
- **Focus and World are views over the same runtime.** Sessions and provider
  configuration live in Veasel's canonical data directory and are shared with
  the TUI.
- **Electron is infrastructure.** Its narrow preload bridge handles backend
  lifecycle, workspace selection, native project dialogs and node-pty
  terminals. It does not run another agent engine.
- **Portable capabilities remain in Agent Toolkit.** Skills, agents, context
  packs and workflow assets can be used by Veasel or other supported coding
  tools; the Toolkit Desktop is a legacy product and is not this application.

The interface includes Focus, World, Operations, Workspace, Library, People,
Insights, Terminal and Settings. The workspace selector chooses the directory
used when Desktop starts its own backend. If Desktop attaches to a backend
started by the TUI, it does not stop or restart that process.

## Develop

Run these commands from this directory; pnpm uses the repository lockfile.

```bash
pnpm install
pnpm --filter veasel-desktop dev
pnpm --filter veasel-desktop dev:electron
pnpm --filter veasel-desktop gen:api
```

For renderer development, `VITE_ATK_BACKEND_URL` can point at a Veasel backend
(default `http://127.0.0.1:4097`). In Electron, Desktop uses its protected
same-origin proxy instead.

## Gates

```bash
pnpm --filter veasel-desktop lint
pnpm --filter veasel-desktop type-check
pnpm --filter veasel-desktop test
pnpm --filter veasel-desktop build
pnpm --filter veasel-desktop build:all
pnpm --filter veasel-desktop test:e2e
pnpm --filter veasel-desktop dist:dir
```

For Electron E2E against a packaged app, set `VEASEL_E2E_APP_PATH` to its
executable and `VEASEL_E2E_BACKEND_BIN` to a Veasel Code binary:

```bash
VEASEL_E2E_APP_PATH=/path/to/veasel-desktop \
VEASEL_E2E_BACKEND_BIN=/path/to/veasel \
pnpm --filter veasel-desktop test:e2e --project=electron
```

The suite uses a throwaway HOME and Veasel data directory. Never point its
environment at personal provider credentials or a production workspace.

## TypeScript and linting

Renderer and Electron main are checked independently by `type-check`; ESLint
uses the repository's strict TypeScript and accessibility rules. The desktop
package keeps its own scripts and shares the root V release/version workflow.
