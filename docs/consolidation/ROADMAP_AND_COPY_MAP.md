# Roadmap (dependency-ordered) and source→target copy map

Epic: [#689](https://github.com/veasel-labs/veasel/issues/689) ·
Hard rule: **copy/move first (unmodified, checksum-verified, COPY-ONLY
commit), refactor second.** Cross-repo copies record source SHA/path,
license (all MIT) and attribution; per-file blob SHAs are computed at
copy time and recorded in the copy PR.

## Source commits audited

| Source | Commit |
| --- | --- |
| veasel-labs/veasel main | `bed62e5de92c0a3c8d0913d7b732af1476e7704a` |
| ulises-jeremias/agent-toolkit main | `ec993aa514bf47a28abf728a6621dbe349df72b1` |
| Toolkit Focus worktree (NOT main) | `feat/focus-opencode-acp@ac2cd125` |
| HorneroOS/hornero main | `daa6b67a0705` |
| HorneroOS/shell main | `4160b14921d2` |

## Copy map (source → target)

| Source path | Target | Form |
| --- | --- | --- |
| toolkit `apps/desktop/electron/focus/{adapter,claude,codex,opencode,service,providers,journal}.ts` + `src/types/focus.d.ts` @ac2cd125 | veasel `provider_cli_*.v` + journal spec in `store.v` | Contract port (TS stays as reference behind API); `testing/fake-*.mjs` → scripted fixtures |
| toolkit `apps/desktop/src/features/{world,valley}` + first-party sprites only | veasel GUI World (P2, after Focus) | Copy TS verbatim into GUI app; per-asset license check (LimeZu/Pixel-Agents art excluded) |
| toolkit `apps/desktop/{electron,src/features/focus,src/lib/api}` | veasel GUI (Electron/React allowed behind Veasel API) | Copy-first into `gui/`; rewire to Veasel session API second |
| toolkit `skills/*/SKILL.md` (481), `agents/*/AGENT.md` (18), `packs/`, `schemas/*.json` (19), `capabilities/targets/registry.yaml` | veasel (consume) + toolkit (stay canonical) | Verbatim; Veasel adds only an emitter target |
| toolkit `modules/agent_toolkit_core/*.v`, `modules/agent_toolkit_server/*.v`, `cmd/agent-toolkit/main.v` | toolkit (stay); veasel consumes via HTTP/library | No copy — prevents a second V runtime fork |
| hornero `agent_registry.v`, `assistant_policy.v`, `plugin_broker.v` @daa6b67a | hornero-side `AgentSpec id=veasel` | No code copy into Veasel; NDJSON ask/tool contract only |
| shell @4160b14921d2 | shell-side `.desktop`/launcher/`qs ipc` surface only | No copy |

## P0 (backlog integrity + safety gates)

1. This ledger/ADR/epic (#689). Rollback: revert docs PR.
2. #550 real installed-binary journey — gate for all parity claims.
3. Veasel secrets hardening (keychain/OAuth refresh; backward-read old
   0600 JSON). Source: `store.v`, `model_settings.v`, `provider.v`.
4. #642 implementer sandbox; #638 capability validation (fail-closed).
5. Copilot catalog truth: fix OAuth token exchange or mark unverified.
6. Toolkit: land-or-abandon stacked drafts in ledger order; #1777
   journal symlink/TOCTOU before #1796. Toolkit main stays canonical —
   no Desktop retirement in P0.

## P1 (one runtime)

7. Installed-CLI adapters in Veasel (Claude/Codex/OpenCode-ACP/Muse):
   native approvals, streaming, cancel/resume, truthful usage (ADR-0001).
8. OpenAPI completeness: `api.v` subagent CRUD/cancel/integrate +
   context-handoffs into `docs/openapi.yaml`.
9. Veasel GUI Focus (copy-first from Toolkit Desktop) on the canonical
   Veasel session API; TUI/GUI continuity E2E.
10. Hornero: `AgentSpec id=veasel`, typed-action-only OS access, Hermes
    fallback retained; shell launcher surface.
11. Toolkit compatibility shims + CLI/catalog preservation.

## P2 (parity tail)

12. World GUI (optional, cozy) after Focus parity; #552 TUI a11y gate;
    #553/#673 benchmarks; signing/notarization (toolkit #1059/#1060/
    #1063, hornero #180); reversible user-data migration; only then
    retire Toolkit Desktop and duplicate runtimes.

## Blockers (unverified — never claim PASS)

No real-task verification anywhere (#549: 0 verified tasks); Focus
canonical landing combination undecided (5 non-ancestor worktrees);
Hermes per-run tool suppression not honoured upstream; unsigned
releases; per-asset sprite licenses (207) unaudited; catalog generator
provenance (210 presets) untraced; no tests/CI executed during audit.
