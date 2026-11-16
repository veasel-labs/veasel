# ADR-0001: One product, one runtime — Veasel owns the agent engine

**Status:** Accepted (owner decisions through 2026-11-16, incl. Desktop
host, Focus provider model and plugin governance — decisions 10–12)

## Context

Three repos build overlapping agent runtimes. `veasel-labs/veasel` (main
`bed62e5de92c0a3c8d0913d7b732af1476e7704a`, MIT) has a V-native server
(`main.v serve 127.0.0.1:4097`, SQLite `store.v`), 4 direct-API provider
adapters (`provider.v`: OpenAI Chat/Responses, Anthropic, Gemini; 210
catalog presets), durable subagents, sandboxed shell, and an OpenTUI TUI —
but no installed-CLI/subscription adapters, plaintext provider keys in
`model-settings.json` (0600 only), and 0 independently verified real coding
tasks (#549/#550). `ulises-jeremias/agent-toolkit` (main
`ec993aa514bf47a28abf728a6621dbe349df72b1`, MIT) has a V core/server/CLI
plus an Electron Focus runtime with structured Claude Code / Codex /
OpenCode-ACP adapters and a JSONL journal — entirely in unmerged draft
PRs (#1783–#1799, stacked, non-ancestor worktrees), plus a cozy World GUI.
`HorneroOS/hornero` (`daa6b67a0705`, MIT) + `HorneroOS/shell`
(`4160b14921d2`) run Javi/Hermes behind `horneroctl` ABAC with an external
agent registry (#391/#390) that Veasel can join without privilege claims.

Forces: copy/move first, refactor second; never delete features before
verified parity; TS helpers may remain behind the Veasel API (V-only is
not a mandate); no subscription API access may be assumed.

## Options Considered

### Option A: Veasel is the one runtime; Toolkit keeps catalog/CLI; Hornero integrates Veasel on demand
**Pros:** single session/provider/approval truth; V core already released;
Hornero registry precedent (muse/codex AgentSpecs) is greenfield-cheap.
**Cons:** Focus TS adapters must be re-expressed against the Veasel API;
GUI migration is the largest work item.

### Option B: Toolkit Desktop becomes the product, Veasel stays a library
**Pros:** Focus/World GUI already exists in Electron/React.
**Cons:** Focus is unmerged draft work; two engines (V server + TS session
runtime in Electron main) would remain permanently; contradicts #549.

### Option C: Keep three runtimes, federate via MCP only
**Pros:** least migration.
**Cons:** preserves duplicate session/approval/usage models — the defect
this consolidation exists to remove.

## Decision

Option A. Sub-decisions:

1. **Canonical session model:** Veasel `store.v` sessions/events +
   thread>turn>event semantics and append-only JSONL journal specified
   language-neutrally (port of the Toolkit Focus journal spec at
   `feat/focus-opencode-acp@ac2cd125`); deltas are never journaled. TUI
   and GUI are projections of this one API; no duplicate engine.
2. **Dual provider plane:** direct model APIs (existing 4 adapters) and
   installed-CLI adapters (Claude Code stream-json, Codex app-server,
   OpenCode ACP, Muse where an authorized protocol exists) are
   separate capability classes. Subscription auth flows only through the
   installed CLI's own authorized auth; Veasel never accepts a
   subscription OAuth token as an API key. The `github-copilot` catalog
   entry must be fixed (Copilot OAuth + short-lived token exchange) or
   marked unverified — a PAT does not authenticate as Copilot.
3. **Usage truthfulness:** `reported=false` stays unreported, never
   estimated (`provider.v` ProviderUsage); per-provider CLI usage
   (Claude cumulative `total_cost_usd`, Codex/OpenCode null) is
   normalized and labelled, never silently summed.
4. **Secrets:** replace plaintext keys with OS keychain / OAuth refresh;
   API views expose `api_key_saved` bool only.
5. **Execution policy:** `ask|auto-edit|sandbox-auto`, MCP never auto,
   implementer subagents sandboxed (#642), fail-closed capability
   validation before launch (#638).
6. **Toolkit boundary:** skills/agents/packs/schemas (Markdown/YAML/JSON,
   MIT) are consumed verbatim; Toolkit CLI/catalog and installs stay;
   Desktop retires only after Veasel GUI parity + compatibility shims.
8. **Official plugin distribution:** `veasel-labs/agent-toolkit` is the
   official Veasel plugin distribution and community marketplace —
   curated official plugins, a Git-backed registry of externally
   maintained community plugins (referenced by repo+ref+sha, never
   vendored), provenance, review policy, version pinning, and generated
   client marketplace manifests (Claude Code/Cursor/Codex/Copilot/
   Veasel). It reuses the personal toolkit's canonical schemas,
   product manifests, validators, and bundles copy-first (seeded from
   `ulises-jeremias/agent-toolkit@ec993aa5`, see that repo's
   ATTRIBUTION.md). `ulises-jeremias/agent-toolkit` remains the
   maintainer's personal, portable collection: independent, and free
   to publish its plugins into the Veasel catalog by reference without
   duplicating source. No second CLI, plugin runtime, or catalog
   implementation may be built in either repo; runtime/session/security
   ownership stays exclusively in `veasel-labs/veasel`. Veasel's
   TUI/Desktop exposes ONE integrated plugin Library (bundled minimal
   offline skills, discovery, install, update, permission review,
   removal) consuming this catalog.
9. **Hornero boundary:** Veasel registers as an external AgentSpec
   (`horneroctl agent list|status|doctor`, dry-run launch), keeps its own
   security model (no ABAC inheritance), acts on the OS only via typed
   `horneroctl` contracts. Hermes stays until functional AND security
   parity is independently proven. Javi stays native.
10. **Desktop host (owner decision, 2026-11-16):** Veasel Desktop is a
    first-party Electron + React/Vite application reusing the Agent
    Toolkit Desktop Electron host (`apps/desktop` at
    `ulises-jeremias/agent-toolkit@cfebbb7a`), its Focus UI, components,
    styles, tests and packaging — copied verbatim first (with SHA,
    checksums and attribution), adapted only in later commits. Electron
    is a shell/client only: the Veasel V backend remains the sole
    runtime for agents, sessions, approvals, plugins and orchestration,
    and TUI and Desktop share the canonical API and SSE events. The
    host must keep the upstream security posture — sandbox,
    contextIsolation, disabled Node integration, narrow validated IPC,
    denied navigation/new-window except audited external links, strict
    CSP, loopback-only backend attach with Origin/Host validation — and
    must never expose the backend on a LAN or via a privileged helper.
    The personal Agent Toolkit Desktop retires only after verified
    Desktop parity plus a reversible user-data migration.
11. **Focus provider model (owner decision, 2026-11-16):** the GUI
    represents exactly the installed-CLI providers `claude`, `codex`,
    `opencode` and `muse` as distinct providers with their own install,
    auth-probe and capability facts (from `/v1/providers/cli`). A
    provider must never be silently mapped onto another (notably Muse
    must never render as Claude), unknown providers render as
    unsupported, and capabilities a protocol has not verified are
    advertised as unavailable.
12. **Plugin governance (owner decision, 2026-11-16):** first-party
    Veasel plugin curation is authorized subject to validated
    manifests, provenance, licenses, declared permissions and security
    tests, with documented maintainer approval recorded per listing.
    This is first-party curation, NOT independent third-party security
    review, and must never be described as such. The registry stays
    fail-closed: where policy requires a reviewer distinct from the
    submitter, either that review genuinely happens or a transparent
    first-party governance exception is proposed in
    `veasel-labs/agent-toolkit` and approved by the owner before any
    entry flips to installable — approvals and reviewer identity are
    never fabricated. Personal/community entries stay pending until
    their required review exists; their review never blocks Desktop or
    other development. Explicit local opt-in imports are a separate,
    clearly-labelled path from verified marketplace installation.

## Consequences

Positive: one backlog (epic #689), one session/approval/usage truth,
reversible copy-first migration. Negative: GUI parity gates Desktop
retirement for a long tail; CLI-adapter protocol drift (Claude/Codex/
OpenCode versions) becomes Veasel's maintenance burden; plaintext-key
migration must be backward-reading.

## References

- Epic: #689; missions #549, #629
- ulises-jeremias/agent-toolkit#1667, #1775, #1670–#1677, #1777
- HorneroOS/hornero#391, #154, #191, #407, #408; HorneroOS/shell#251
- Ledger, roadmap, copy map: `docs/consolidation/`
