# Cross-repository resolution ledger

Epic: [veasel#689](https://github.com/veasel-labs/veasel/issues/689) ·
Architecture: [ADR-0001](../adr/0001-one-product-one-runtime.md) ·
Audit: 2026-11-24 · Method: GitHub API open-issue/open-PR enumeration, exact
`main` SHA lookup, latest-main check runs, release and updater inspection.

The prior November 15 audit is retained at
[`TRIAGE_LEDGER_2026-11-15.md`](TRIAGE_LEDGER_2026-11-15.md). Its counts and
proposed dispositions are historical and must not be used as current state.

## Current snapshot

| Repository | `main` SHA | Open issues | Open PRs | Latest relevant evidence |
| --- | --- | ---: | ---: | --- |
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | 56f2c6b30008f4e68f74e21e4767789962b91640 | 5 | 1 | Exact-main core CI [#45360661252](https://github.com/veasel-labs/veasel/actions/runs/45360661252) passed on this SHA, including Windows, macOS, Linux, six Linux shards, Desktop, Terminal, and security. Open ledger refresh [#809](https://github.com/veasel-labs/veasel/pull/809) at `ffe4e009e809c5cbc730f4d8041c654c7baa2f39` also passed exact-head Windows/Linux/macOS checks in [#45365723057](https://github.com/veasel-labs/veasel/actions/runs/45365723057); its snapshot is being refreshed before merge. Latest release remains `v0.102.1-next.0` from `eab88d598b5ab8329dabffcd45d35aa00e2a4cab`. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | 8205dd0e09ea6c74342503152b3fc71325be1351 | 0 | 1 | Exact-main Validate [#45273303142](https://github.com/veasel-labs/agent-toolkit/actions/runs/45273303142) passed. The owner approved the narrow first-party `veasel-essentials` exception (#10/#12). Community [PR #13](https://github.com/veasel-labs/agent-toolkit/pull/13) remains non-installable at head `6be6dc8462d32e3c1c7a17806a051b3a0d456179`; that head correctly declares `network:true` to match `brag`, and includes a regression asserting the entry remains non-installable. The owner's direction is to keep it pending for independent review. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | 40f78446b02517abd452abc256e1c29e9ce58a8d | 0 | 0 | Release metadata PR #228 merged for v0.102.1-next.0. Exact-main CI [#45326905628](https://github.com/veasel-labs/website/actions/runs/45326905628) and deployment [#45326905565](https://github.com/veasel-labs/website/actions/runs/45326905565) passed. |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | 5b732843aba04fcfd9bc21c0a77a29d53b08d791 | 0 | 0 | Cask update PR #68 merged for v0.102.1-next.0; current-main CI [#45326961698](https://github.com/veasel-labs/homebrew-tap/actions/runs/45326961698) passed. PR-head install/upgrade/runtime/uninstall smoke passed before merge. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | bb2090236f76dd91d0aac3212a74e5e1b324fdcf | 0 | 0 | AUR mirror PR #70 merged for v0.102.1-next.0; current-main Package CI [#45327011543](https://github.com/veasel-labs/aur-package/actions/runs/45327011543) passed. Build/install/upgrade/uninstall smoke passed before merge. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | 7097e534eeafae932bcf427e12b0a5df398d9894 | 0 | 0 | No organization-level change is currently required. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | 6303544045e3fc6ffbc5f085215eececdf7a7789 | 1 | 1 | Issue [#1838](https://github.com/ulises-jeremias/agent-toolkit/issues/1838) remains open. Release [v1.50.0](https://github.com/ulises-jeremias/agent-toolkit/releases/tag/v1.50.0) resolves to this SHA; release CI [#45371940996](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45371940996) passed all five platform builds, artifact upload, PyPI and Docker. All 10 platform binary/archive hashes match the manifest, `SHA256SUMS`, and GitHub asset digests. Personal Homebrew formula PR #62 merged at `b555488e5041b3decb28b013d4c47c779d630fe8`; AUR updater verified `1.50.0-1` in [#45375027630](https://github.com/ulises-jeremias/aur-packages/actions/runs/45375027630). Draft release lifecycle fix [#1847](https://github.com/ulises-jeremias/agent-toolkit/pull/1847) remains open for human review after the PR-head checks. |
| **Total (seven requested repositories)** | — | **6** | **3** | Veasel issues #549, #550, #673, #689, #693 and personal Toolkit #1838 remain open. Open PRs are Veasel #809, official registry #13, and personal Toolkit #1847. The owner decision on #13 and complete cross-platform real-provider, World visual, package lifecycle, HorneroOS, and signing evidence remain genuine dependencies. |

This live snapshot was re-queried on 2026-11-24. Exact-main Veasel CI passed on `56f2c6b30008f4e68f74e21e4767789962b91640`; Windows authentication tests were included, not skipped. The current Veasel release remains `v0.102.1-next.0` from `eab88d598b5ab8329dabffcd45d35aa00e2a4cab`; Website, official Homebrew and official AUR remain synchronized. World issue #693 was reopened after packaged visual review because the map does not yet meet the requested cozy visual quality; runtime semantics remain real-data-backed. Personal Toolkit `v1.50.0` has complete verified artifacts and successful PyPI/Docker/npm plus Homebrew/AUR propagation, but native Homebrew/AUR install/upgrade/uninstall smoke remains outstanding. The new draft-release gate and current live inventory are recorded in open PR #1847 and this PR respectively. Current GitHub state overrides older historical counts below.

### Latest fully downloaded artifact smoke (historical release)

Downloaded the Linux CLI archive for `v0.101.3-next.0` from the immutable release. Its SHA256 (`d3d4c907183ba8ab8852f8d8b885aedb11c1f783c7ce8d6782ec53f4267a838a`) matched both `SHA256SUMS` and `release.json`; the manifest source and packaged `build.json` record `1d041d86a19275b6c73e2c1750890dacaf18dd97`. The extracted binary SHA256 is `368bdd478e2f806ce1f484043c6d078070e49bfaa26bff8dd0897fb3695a7d2e` and reports `0.101.3-next.0`. In a fresh temporary `VEASEL_DATA_DIR`, the packaged backend started on an isolated local port, `GET /v1/health` returned `{"healthy":true,"auth":"bearer","protocol":1}`, and the generated API token had mode `0600`. This is a packaged backend/health smoke only: no provider call, GUI journey, user-profile install, upgrade, or TUI continuation is claimed. The host's pre-existing PATH binary reports `0.79.13-next.0`; it was not modified. Full sanitized record: [#550 comment](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7106642142).

The unresolved items below stay open until their product acceptance is met or an explicitly approved disposition is recorded. A low issue/PR count does not imply all closed draft work was migrated.

### Veasel `main` branch protection

On Nov 22, the required checks were expanded from the existing four to twelve.
The required contexts are:

- `Version plan`, `Security scan`, and `Terminal client`.
- `V backend / linux`, `V backend / macOS`, and `V backend / Windows`.
- `V extra tests / linux (shards 0–5)`.

All are bound to the GitHub Actions app. This makes the supported platform
backends and Linux test shards merge gates; it does not replace the separate
release artifact and packaged provider acceptance gates.

## Open pull requests

| PR | State / owner | Dependencies and remaining acceptance | Evidence / destination | Required action |
| --- | --- | --- | --- | --- |
| [Veasel #809](https://github.com/veasel-labs/veasel/pull/809) | OPEN · live cross-repository inventory · prior head `ffe4e009e809c5cbc730f4d8041c654c7baa2f39` | Refresh issue/PR counts, exact-main evidence, current release state, and the reopened World visual gap. | Prior exact-head CI [#45365723057](https://github.com/veasel-labs/veasel/actions/runs/45365723057) passed Windows (49 minutes), Linux, macOS, six Linux shards, Desktop, Terminal, and security. This ledger update supersedes the old inventory; the new head and checks are linked from the PR. | Wait for the refreshed snapshot to pass exact-head checks, then merge and verify the resulting exact-main SHA. |
| [official registry #13](https://github.com/veasel-labs/agent-toolkit/pull/13) | OPEN · community Creative Studio plugin by reference · head `6be6dc8462d32e3c1c7a17806a051b3a0d456179` | Owner decision: leave pending until independent review. Source is pinned by immutable reference; no source is copied. | The current diff declares `network:true`, matching `skills/brag/SKILL.md`, and adds a regression that checks the generated catalog preserves the permission while `installable` stays false. The source `cc5c60d48c18ff6b5788c08f38f681c933505fbe` and MIT license are recorded in the manifest. | Keep non-installable pending independent review. Do not self-approve or promote trust. |
| [personal Toolkit #1847](https://github.com/ulises-jeremias/agent-toolkit/pull/1847) | DRAFT · defer public release until distribution gates pass · head `c68347b9e69a8f2b0db0ce6b8349cbc027e06237` | Future tag releases remain draft until binary assets, SBOM, PyPI, and Docker succeed. | YAML parse, workflow dependency/permission assertions and `git diff --check` passed locally. PR checks completed; the initial Docker PR smoke failed with HTTP 404 while v1.50.0 assets were still uploading, then the failed job was rerun successfully after artifact publication. | Keep draft for maintainer review. Confirm same repository token access to draft assets in the next release before treating the lifecycle gate as fully exercised. |

## Remaining open issue outside the Veasel Labs organization

### ulises-jeremias/agent-toolkit#1838 — AI-Native Creative Studio ecosystem

- **State / owner:** OPEN · personal Agent Toolkit owns portable creative skills,
  agents, MCP packaging and workflows; HorneroOS owns native OS integration;
  Veasel consumes approved capabilities by reference and owns its session runtime.
- **Dependencies:** external `agentic-workstation#236` owner review and
  HorneroOS `hornero#474` merge; actual HorneroOS installation to validate
  `shell#447`; an authenticated, tool-capable model for the second-client Veasel
  workflow; remaining creative workflow/video production and graphical-app
  acceptance. Do not self-approve or infer acceptance from source CI.
- **Landed evidence:** Toolkit #1835/#1837 and HorneroOS docs #151/QA #97 are
  merged; host-side Kdenlive, Blender, Inkscape, audio and `horneroctl`
  workflows are recorded in the issue. Veasel #800 provides packaged MCP
  approval/sandbox evidence. The v1.50.0 release is tied to main
  `6303544045e3fc6ffbc5f085215eececdf7a7789`; release artifacts, manifest and
  checksums plus PyPI/Docker/npm and downstream Homebrew/AUR propagation are
  recorded in [the latest issue evidence](https://github.com/ulises-jeremias/agent-toolkit/issues/1838#issuecomment-7129227513).
- **Remaining acceptance:** clean Homebrew and Arch install/upgrade/uninstall
  smoke; next-tag verification of the draft-until-gates-pass workflow in open
  PR #1847; merge/review blockers above; a real Veasel session completing a
  creative edit; actual HorneroOS shell launch/session reuse/cleanup; and the
  outstanding flagship footage and application-specific workflows. Signing
  remains truthful as unsigned until credentials and platform verification
  exist.
- **Action / destination:** IMPLEMENT/REVIEW in the owning repositories; keep
  open until each accepted workflow is completed or explicitly descoped by its
  owner. Do not close the umbrella based solely on release or host-side app
  smoke evidence.

## Adjacent personal Toolkit distribution PRs (not counted in the seven-repository inventory)

| PR | State / owner | Remaining acceptance | Evidence | Required action |
| --- | --- | --- | --- | --- |
| [personal Homebrew tap #61](https://github.com/ulises-jeremias/homebrew-tap/pull/61) | MERGED at `94585d355059db374f013f4d3da161c87f0eca8c` · install sidecar with verified versioned archive | Formula updater validates manifest version/tag/source SHA against resolved GitHub tag, archive metadata and digest. | v1.50.0 updater created formula PR [#62](https://github.com/ulises-jeremias/homebrew-tap/pull/62), revalidated after [automation fix #63](https://github.com/ulises-jeremias/homebrew-tap/pull/63), and merged at `b555488e5041b3decb28b013d4c47c779d630fe8`. Old version-only PRs #52–#60 were superseded after checking their complete diffs. | Run actual clean macOS install, offline skill listing, upgrade and uninstall; no local macOS install is claimed. |
| [personal AUR packages #10](https://github.com/ulises-jeremias/aur-packages/pull/10) | MERGED at `f5e65953ee686715fb3d4fef788db69410d020b7` · install sidecar with verified versioned archive | PKGBUILD installs bundle to `/usr/share/agent-toolkit/data`, rejects missing sidecars for archive-based updates, and checks manifest tag/source SHA/platform/digest. | The v1.50.0 updater run [#45375027630](https://github.com/ulises-jeremias/aur-packages/actions/runs/45375027630) succeeded after AUR propagation delay and verified `agent-toolkit-bin@1.50.0-1`. | Run actual clean Arch build/install, offline skill listing, upgrade and uninstall; this updater result is not an install smoke. |

Merged during this audit:

- Veasel [#807](https://github.com/veasel-labs/veasel/pull/807) squash-merged at
  `a72a2f5d82f5a4169068c73782fc8c05027c83e0`. It refreshes this live
  cross-repository inventory without product code changes. Exact-main CI
  [#45342354902](https://github.com/veasel-labs/veasel/actions/runs/45342354902)
  passed on that commit, including Windows, macOS, Linux, six Linux shards,
  Desktop, Terminal, and Security. Conditional packaging/release jobs were
  skipped because the change is documentation-only.
- Veasel [#808](https://github.com/veasel-labs/veasel/pull/808) merged at
  `56f2c6b30008f4e68f74e21e4767789962b91640`. It refreshes this ledger and
  passed PR-head Linux/macOS/Windows CI; exact-main CI [#45360661252](https://github.com/veasel-labs/veasel/actions/runs/45360661252)
  completed successfully on the merge SHA, including Windows backend and all
  Linux shards.
- Personal Toolkit [#1845](https://github.com/ulises-jeremias/agent-toolkit/pull/1845)
  merged at `d7ac3ccc69f15b460d95ffc38d8ba1f4c09b9d26`; exact PR-head source
  Electron, fresh-HOME packaged E2E, Validate, parity and Linux/macOS/Windows
  package/linkage checks passed. Later exact-main checks on the resulting
  Toolkit lineage include the full v1.50.0 release validation listed above;
  do not confuse that release proof with a fresh-HOME package lifecycle smoke.
- Adjacent personal distribution PRs [Homebrew #61](https://github.com/ulises-jeremias/homebrew-tap/pull/61)
  and [AUR #10](https://github.com/ulises-jeremias/aur-packages/pull/10)
  merged at `94585d355059db374f013f4d3da161c87f0eca8c` and
  `f5e65953ee686715fb3d4fef788db69410d020b7`, respectively. v1.50.0
  propagation was verified in the release, Homebrew updater and AUR updater
  workflows; clean local package lifecycle smoke remains outstanding.
- Veasel [#804](https://github.com/veasel-labs/veasel/pull/804) merged at
  `6bf9846454ed9ce6e3dbb2a2038ef20264789984`. It carries the original runner
  picker commit from [#803](https://github.com/veasel-labs/veasel/pull/803)
  (`9ca5c91b7b0bf0cb406705cad370deb947a756b5`) plus durable TUI approval
  review; #803 was closed without merge after its code was included in #804.
  The current exact-main core CI passed at `eab88d598b5ab8329dabffcd45d35aa00e2a4cab`
  in [#45307427282](https://github.com/veasel-labs/veasel/actions/runs/45307427282).
  #550 remains open for native macOS/Windows real-provider journeys; the
  failed packaged Codex attempt remains NOT VERIFIED. [Current #550 status](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7123306150).
- [personal Toolkit #1841](https://github.com/ulises-jeremias/agent-toolkit/pull/1841) merged as `2a032f2fbf91a36edf4784b907489a19bb8f79f7` after exact-head Linux/macOS/Windows integration and security checks passed. The `setup-uv` v10.4.0 pin matches upstream tag commit `1db35dd8eee11c5894872e0b383ae6c406cf738d`.
- [personal Toolkit #1840](https://github.com/ulises-jeremias/agent-toolkit/pull/1840) merged at `465a8d69f71224259e035ca35c4d3ee54c30d3df` after exact PR-head validation run [#45172137137](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45172137137) passed. It records packaged MCP and creative-tool compatibility evidence while explicitly leaving real-provider creative edits and same-session visual TUI continuation unverified. Post-merge main runs [#45179562504](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45179562504) and [#45179562294](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45179562294) were queued/in progress at capture.
- [personal Toolkit #1842](https://github.com/ulises-jeremias/agent-toolkit/pull/1842) merged at `69e92db9eafdedf66ae648fea8af480e7fb5d60c` after exact-head CI [#45186218528](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45186218528) passed 50 checks with three conditional skips, including macOS/Linux V module and Swarm E2E jobs; CodeQL [#45186218253](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45186218253) passed. Its main Validate was superseded as a latest-main gate when #1843 merged. The change blocks automatic redistribution of policy-restricted sources and removes stale human review attribution when content is updated.
- [personal Toolkit #1843](https://github.com/ulises-jeremias/agent-toolkit/pull/1843) merged at `c79191a3931422e135d43c00c3838211d0610905` after exact-head validation [#45185796258](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45185796258) passed 51 checks with three conditional skips and CodeQL [#45185796350](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45185796350) passed. At this snapshot, exact-main Validate [#45194414408](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45194414408) is queued; CodeQL [#45194414371](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45194414371), MegaLinter [#45194414386](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45194414386), and Web [#45194414528](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45194414528) passed. It contains only the MIT-verified `unslop` update and keeps the trust tier experimental.
- [personal Toolkit #1844](https://github.com/ulises-jeremias/agent-toolkit/pull/1844) merged at `e050f5668ca7d462b9e3189f2834e20ab9f3efbc`; exact-head Validate [#45197988009](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45197988009) passed including Linux/macOS/Windows integration, Python 3.10–3.14 on Linux/macOS, Linux/macOS V modules, Windows npm launchers, provenance/catalog, and Linux/macOS Swarm E2E. Exact-head CodeQL [#45197987898](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45197987898), web [#45197987931](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45197987931), CodeRabbit, and required CI passed. The offline first-party skill keeps the MIT rules and license, removes the `NOASSERTION`/no-redistribution wrapper source, sets network access false, and leaves trust experimental. Exact-main Validate, CodeQL, Web and MegaLinter all passed after merge at the SHA recorded in the current snapshot above.
- [personal Toolkit #1839](https://github.com/ulises-jeremias/agent-toolkit/pull/1839) closed after the proposed changes were accounted for. The `unslop` change landed in #1843; the MIT `command.md` rules remain in the bundled reference and first-party replacement from #1844. The source wrapper with `NOASSERTION` licensing and redistribution prohibited was rejected. [The closure note](https://github.com/ulises-jeremias/agent-toolkit/pull/1839#issuecomment-7105639687) links the exact commits and states that no restricted source was accepted.

Merged since prior ledger snapshot:

- Website [#226](https://github.com/veasel-labs/website/pull/226) merged at `afb040fc5323a21b4068301ca3e92eeb8f0301f6`; exact-main CI [#45174518559](https://github.com/veasel-labs/website/actions/runs/45174518559) and deployment [#45174518531](https://github.com/veasel-labs/website/actions/runs/45174518531) passed.
- Homebrew [#66](https://github.com/veasel-labs/homebrew-tap/pull/66) merged at `10c4e1bd1093cef50120b07d70cd19953968bebd`; exact-main macOS install/upgrade/runtime/uninstall CI [#45174595770](https://github.com/veasel-labs/homebrew-tap/actions/runs/45174595770) passed.
- AUR mirror [#68](https://github.com/veasel-labs/aur-package/pull/68) merged at `4240773a2d844189251df601524d44a0681b7c1b`. The publisher run [#45171464630](https://github.com/veasel-labs/aur-package/actions/runs/45171464630) regenerated `.SRCINFO`, built the Arch package and published the exact package metadata to AUR. Its GitHub PR event [#45171635702](https://github.com/veasel-labs/aur-package/actions/runs/45171635702) was `action_required`; exact-main Package CI [#45174696226](https://github.com/veasel-labs/aur-package/actions/runs/45174696226) passed.
- Website [#227](https://github.com/veasel-labs/website/pull/227) merged at `a195dfcd34a0934a78cb07d3499c95e98d110a38` for release `v0.101.3-next.0` from Veasel `1d041d86`. Exact PR-head CI [#45176846478](https://github.com/veasel-labs/website/actions/runs/45176846478), exact-main CI [#45177649535](https://github.com/veasel-labs/website/actions/runs/45177649535), and deployment [#45177649646](https://github.com/veasel-labs/website/actions/runs/45177649646) passed.
- Homebrew [#67](https://github.com/veasel-labs/homebrew-tap/pull/67) merged at `a84ae2f260c17ec33872c2dd6bfc59003951b3ed`; exact PR-head install/upgrade/runtime/uninstall CI [#45177514872](https://github.com/veasel-labs/homebrew-tap/actions/runs/45177514872) and exact-main CI [#45177863518](https://github.com/veasel-labs/homebrew-tap/actions/runs/45177863518) passed.
- AUR mirror [#69](https://github.com/veasel-labs/aur-package/pull/69) merged at `21d52c32f1d449c5cf2fb216b980e7870646d459`; publisher [#45176500717](https://github.com/veasel-labs/aur-package/actions/runs/45176500717) built and published the package, while exact-main Package CI [#45177921284](https://github.com/veasel-labs/aur-package/actions/runs/45177921284) passed. The action-required PR event is not claimed as a pass.
- [veasel#799](https://github.com/veasel-labs/veasel/issues/799) closed as DONE after packaged MCP invocation, explicit session workspace grant/revocation and outside-path denial; full exact-main backend/shard/security/client/package CI passed on `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Evidence: [issue comment](https://github.com/veasel-labs/veasel/issues/799#issuecomment-7101176559), main run [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241).
- [veasel#800](https://github.com/veasel-labs/veasel/pull/800) merged as `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed all required jobs, including Linux/macOS/Windows backends and package smoke. Exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) subsequently passed every backend, shard, security, client and package job.
- [veasel#801](https://github.com/veasel-labs/veasel/pull/801) was closed as **SUPERSEDED** after its session workspace permission implementation was copied into #800. The PR #800 package artifact passed installed MCP invocation and workspace boundary checks; the initial synchronous approval harness timed out, then the durable async operation completed after explicit approval. Full evidence appears under #799.
- [veasel#798](https://github.com/veasel-labs/veasel/pull/798) merged as `32f66f4c1c5ada913a8fb7e967d94424266ce3d4`. All exact-head required checks passed, including the Windows backend and Linux shards. Post-merge exact-main CI [#45149425094](https://github.com/veasel-labs/veasel/actions/runs/45149425094) completed successfully on that SHA; newer code must pass its own exact-main run.
- [veasel#801](https://github.com/veasel-labs/veasel/pull/801) was closed as **SUPERSEDED** after its session workspace permission implementation was copied into #800; the merged code and resulting acceptance are recorded above and under #799.
- [veasel#790](https://github.com/veasel-labs/veasel/pull/790) merged as `a594e4ef23002761e7b29386655b345166ad96a4`; it refreshed the cross-repository ledger.
- [veasel#791](https://github.com/veasel-labs/veasel/pull/791) merged as `c20254af8267705432449102c091185445098d25`. It fixes installed CLI provider final reporting from durable `TurnFacts` and published `v0.100.1-next.0` with verified manifest/checksums. Full Linux/macOS/Windows main CI and packaging passed on that SHA in [#45070709828](https://github.com/veasel-labs/veasel/actions/runs/45070709828).
- [veasel#792](https://github.com/veasel-labs/veasel/pull/792) merged as `49a7a710078d47d6bd8598be7eb8807487e8c427`; exact-main core CI [#45088107243](https://github.com/veasel-labs/veasel/actions/runs/45088107243) passed.
- [veasel#793](https://github.com/veasel-labs/veasel/pull/793) merged at `240d95ebd5bd93ba2637314dadf6b335b055ac83`. It adds the deterministic matched Responses-provider benchmark and shell isolation harness. Exact-main CI [#45106567453](https://github.com/veasel-labs/veasel/actions/runs/45106567453) passed on `240d95e`. That is not the current head: CI for `69c3646` is queued in [#45117101696](https://github.com/veasel-labs/veasel/actions/runs/45117101696), and the prior `716d6b0` main run [#45112294620](https://github.com/veasel-labs/veasel/actions/runs/45112294620) remains in progress. No paid Meta request is claimed.
- [veasel#794](https://github.com/veasel-labs/veasel/pull/794) merged as `e95638c8c33d22e323be86f3464dde344fca7c62`. Exact PR-head Linux/macOS/Windows checks passed. It records one Linux packaged Claude coding journey and its limitations; issue #550 remains open. Post-merge main CI for later SHA `69c3646` is queued in [#45117101696](https://github.com/veasel-labs/veasel/actions/runs/45117101696); exact-main validation is not yet complete.
- Personal Toolkit PR [#1835](https://github.com/ulises-jeremias/agent-toolkit/pull/1835) was squash-merged as `cc5c60d48c18ff6b5788c08f38f681c933505fbe`; its four changes are integrated, but original commit IDs are not retained on `main`. It adds the reviewed, opt-in portable Creative Studio skills/agents/catalog product, pins the MCP server, and applies approval-gated OpenCode permissions. Exact-head validation for V, catalog/provenance, security, Windows integration, and packaged Desktop clean-machine journeys passed. The separate Electron package/linkage release workflow [#45074181542](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181542) was cancelled after ~50 minutes in unrelated macOS packaging jobs; it is recorded as cancelled, not passed. Follow-up main CI runs #45082787618–#45082787731 completed successfully on the merge SHA; no new package release is claimed.

- [veasel#795](https://github.com/veasel-labs/veasel/pull/795) merged as 69c3646a82dc11072a9361355229b8c5b110aca6, parent 716d6b00a174c313ddb903984fa610844deab22c. Required exact-head checks passed, including Windows; it synchronizes the bundled Veasel Essentials catalog with the explicit owner-approved first-party exception. Post-merge main CI [#45117101696](https://github.com/veasel-labs/veasel/actions/runs/45117101696) is queued and is the outstanding exact-main gate.
- [veasel#796](https://github.com/veasel-labs/veasel/pull/796) merged in parent 716d6b00a174c313ddb903984fa610844deab22c; exact-head Linux/macOS/Windows CI passed, including Windows backend and standalone TUI ConPTY smoke. It adds veasel-tui.desktop to the Linux CLI archive. The latest published release predates this change, so HorneroOS package/launcher acceptance still requires a new release and actual host launch.
- Distribution provenance PRs [Homebrew #63](https://github.com/veasel-labs/homebrew-tap/pull/63) and [AUR #65](https://github.com/veasel-labs/aur-package/pull/65) are merged. Exact PR and exact-main CI passed; Homebrew's macOS cask lifecycle passed. AUR verifies source tag, manifest, source SHA and release asset digests; the next release is still needed to verify propagation of Veasel #796's desktop entry.
- Personal Toolkit PR [#1837](https://github.com/ulises-jeremias/agent-toolkit/pull/1837) merged as eb36b92b5632c55b75dcb12100ca929dfaa0e9e6 after all exact-head required checks passed. It adds the flagship capture/production plan and explicitly says the real video has not been produced. The new umbrella issue [#1838](https://github.com/ulises-jeremias/agent-toolkit/issues/1838) remains open because real filming, additional workflows, and the second-client Veasel plugin journey are unfinished.
## Issue dispositions and required resolution

### veasel-labs/veasel#799 — RESOLVED: trusted MCP stdio executable/workspace sandbox

- **State / owner:** CLOSED DONE · Veasel MCP runtime and session permission UI.
- **Dependencies:** none remain for the reported sandbox regression.
- **Existing implementation:** Linux Bubblewrap masks home/tmp, which hides user-installed MCP executables. Existing trust was per-session but had no separate workspace write grant.
- **Change/evidence:** PR [#800](https://github.com/veasel-labs/veasel/pull/800) merged at `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Its exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed Linux/macOS/Windows backend, Linux shards and package jobs. The change preserves PATH symlink lookup while exposing only executable/interpreter trees read-only, and adds the explicit, revocable per-session workspace write grant; legacy trust migrates without a write grant.
- **Packaged evidence:** the Linux artifact from PR run [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) ran the installed `mcp-kdenlive` server via its home-installed PATH command; a local deterministic OpenAI-compatible fixture requested the read-only `diagnose_environment` call, the call was inspected and explicitly approved, and the packaged operation completed through required Bubblewrap. A second packaged MCP fixture wrote a marker inside the explicitly granted session workspace and reported that a sibling outside sentinel was unreadable; the marker was visible on the host and the outside sentinel remained unchanged. Both used disposable data/workspace directories and zero paid provider calls. An initial synchronous harness waited on the approval gate until its timeout; switching to the durable operation and approving the inspected MCP call completed successfully. This was a harness correction, not a product timeout.
- **Resolution:** exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) succeeded on `1d041d86a19275b6c73e2c1750890dacaf18dd97`, including Linux/macOS/Windows backends, all six Linux shards, security, Desktop/Terminal, and Linux/macOS/Windows packaging. Packaged acceptance and grant lifecycle are recorded in [the issue evidence](https://github.com/veasel-labs/veasel/issues/799#issuecomment-7101176559); issue closed completed.
- **Action:** DONE in `veasel-labs/veasel`, commit `1d041d86a19275b6c73e2c1750890dacaf18dd97`; exact-main and packaged evidence linked above.

### veasel-labs/veasel#549 — daily-driver product mission

- **State / owner:** OPEN · Veasel runtime, Desktop, TUI, provider adapters.
- **Dependencies:** #550 packaged real-provider journeys; #673 controlled
  benchmark; parent reconciliation in #689.
- **Evidence:** packaged Linux OpenCode coding, approval/denial, cancellation,
  independent red-to-green verification, restart persistence, and same-session
  visual TUI continuation are recorded in [#550's Nov 20 evidence
  update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
  A new packaged Linux Claude Code run is recorded in [#550's Nov 23 update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7090028693) and PR #794: it independently changed a parser and passed seven red-to-green assertions, with two approved tools and durable completed SQLite state. Playwright approval automation detached, so its evidence is not a fully stable GUI automation pass; provider model and cost remain unknown. The parent status was refreshed in [#549's Nov 23 update](https://github.com/veasel-labs/veasel/issues/549#issuecomment-7102509149). Current release and CI evidence is listed above.
- **Remaining acceptance:** repeatable representative tasks on installed
  binaries; native macOS and Windows real-provider journeys; durable
  crash/restart outcome; and transparent recovery/usage evidence. The
  packaged OpenCode same-session visual-TUI continuation is already recorded;
  do not reuse deterministic fixtures as real-provider proof.
- **Action:** KEEP OPEN. Continue implementation and platform acceptance in
  `veasel-labs/veasel`; resolve only with independent packaged evidence and
  links in the issue. Current destination is `main` at
  `56f2c6b30008f4e68f74e21e4767789962b91640`; the merged ledger-only change
  passed exact-main CI [#45360661252](https://github.com/veasel-labs/veasel/actions/runs/45360661252),
  including the Windows backend. No final resolution commit exists.

### veasel-labs/veasel#550 — installed-binary cross-platform journeys

- **State / owner:** OPEN · Veasel packaged Desktop/TUI acceptance.
- **Dependencies:** supported macOS/Windows runners and authenticated provider
  accounts; #549 product mission.
- **Evidence:** Linux package journey and real visual TUI continuation are
  recorded in [the Nov 20 evidence comment](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
  The packaged Claude edit journey, limitations, SHA256s, test oracle, and
  durable operation result are recorded in [the Nov 23 evidence update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7090028693)
  and merged [PR #794](https://github.com/veasel-labs/veasel/pull/794).
  The evidence distinguishes rendered visual TUI continuity from a successful
  provider turn where required. The installed CLI outcome contradiction was fixed
  in PR #791; [the follow-up](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7085930868)
  explicitly retains the prior journey as NOT VERIFIED pending a fresh packaged run.
  The earlier Windows auth failure was the test's invalid interpolated JSON (`\U` in `C:\Users\...`), fixed by PR #773. The full Windows backend and standalone TUI ConPTY smoke passed on PR #796; packaged real-provider journeys on macOS and Windows remain unverified. [The root-cause follow-up](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7086183011)
  records the repro and current check status.
  [A packaged Linux Codex CLI attempt](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7113850660)
  on 2026-11-23 selected the provider but did not edit the disposable repository:
  one write approval was denied, no Git change or independent test resulted,
  and usage/cost was unavailable. It is
  classified NOT VERIFIED. PR [#804](https://github.com/veasel-labs/veasel/pull/804)
  merged at `6bf9846454ed9ce6e3dbb2a2038ef20264789984`, adding installed CLI
  selection and explicit TUI review for durable approvals. Its merge and CI do
  not retroactively change that journey's result. [The 2026-11-24 status
  comment](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7123306150)
  links the merge, current-main CI, and the still-unverified native-platform
  acceptance. A later packaged Linux Claude Code attempt is documented in
  [the Nov 24 evidence update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7128170052): the actual provider responded, but two edit approvals expired; there were no changes or independent tests, so coding acceptance remains NOT VERIFIED. The run consumed 36,515 input and 1,504 output tokens; cost was not reported, and no retry was made.
- **Remaining acceptance:** complete native macOS and Windows install/configure/
  edit/review/test/restart journeys with real providers; test rejected changes,
  cancellation and process cleanup on those platforms. Packaged OpenCode
  Desktop-to-visual-TUI same-session continuation is verified on Linux; do not
  claim that as native macOS or Windows provider acceptance.
- **Action:** IMPLEMENT/VERIFY in Veasel; KEEP OPEN until platform and provider
  evidence is attached. Current CI proves platform backend/package jobs, not
  these real-provider journeys.

### veasel-labs/veasel#673 — matched Veasel/OpenCode benchmark

- **State / owner:** OPEN · Veasel benchmark harness and provider isolation.
- **Dependencies:** #553 benchmark acceptance; reviewed isolation for OpenCode
  shell children; provider-specific cost controls.
- **Evidence:** deterministic Responses fixtures and enforced generic spending
  bounds are recorded in [the Nov 20 issue update](https://github.com/veasel-labs/veasel/issues/673#issuecomment-7033093408).
- **Remaining acceptance:** PR #793 merged the deterministic adapter and
  isolation wrapper at `240d95ebd5bd93ba2637314dadf6b335b055ac83`; its
  exact-main CI [#45106567453](https://github.com/veasel-labs/veasel/actions/runs/45106567453)
  passed on SHA `240d95e`. Baseline Veasel main `eab88d59` passed all required
  checks in [#45307427282](https://github.com/veasel-labs/veasel/actions/runs/45307427282);
  latest main `56f2c6b30008f4e68f74e21e4767789962b91640` passed exact-main
  CI in [#45360661252](https://github.com/veasel-labs/veasel/actions/runs/45360661252),
  including Windows. This does not prove a live matched benchmark.
  Neither run proves a live matched benchmark. Network-namespace
  enforcement remains unverified on hosted runners; prior local Arch evidence
  is recorded separately.
  The pinned model's published pricing can inform a reservation but cannot by
  itself prove an enforced total-spend cap. The user previously authorized up
  to USD 5 after key rotation, but no live provider request has been made.
  Review the shell boundary and reservation implementation before any call.
  Then run and independently score the same meaningful task,
  prompt, base, model, permissions and budgets through Veasel and OpenCode;
  preserve sanitized traces and versions/hashes. No provider call or benchmark
  success is inferred here.
- **Action:** IMPLEMENT/REVIEW in Veasel; KEEP OPEN until the matched pair and
  budget/isolation evidence are complete.

### veasel-labs/veasel#689 — cross-repository consolidation epic

- **State / owner:** OPEN · integration owner across all seven repositories.
- **Dependencies:** #549, #550 and #673; final compatibility and HorneroOS
  evidence. The first-party governance decision in official registry #10 is
  resolved; external community entries still need independent review.
- **Evidence:** ADR-0001, implementation history, security/orchestration,
  Library and World merges are present in current Veasel history. Current repo
  inventory and all still-open work are recorded above and below.
- **Remaining acceptance:** resolve all issues in this ledger with truthful
  evidence; account for the closed-but-unmerged legacy Toolkit drafts; finish
  real-provider/platform acceptance; make the visual World design/accessibility
  review explicit; verify HorneroOS launch on an actual installation; and
  reconcile distribution/signing expectations. The semantic World merge does
  not by itself prove every visual-quality target in the epic.
- **Action:** KEEP OPEN and close LAST after every repository, acceptance gate,
  release and user-data migration is independently reconciled.

### veasel-labs/veasel#693 — cozy World visual acceptance

- **State / owner:** OPEN again · Veasel World scene and Desktop visual design.
- **Dependencies:** preserve the authored PXL sprite system and provenance;
  align terrain scale/composition with the cozy RPG-quality visual target;
  retain real runtime state and keyboard/Focus parity.
- **Evidence:** PR [#789](https://github.com/veasel-labs/veasel/pull/789)
  integrated the semantic World using real runtime state. Packaged `v0.102.1-next.0`
  launched on Wayland and exposed the accessible World map. The visual review
  found a broad, mostly flat green field with sparse landmarks at default zoom;
  roads, waterways, vegetation, and architecture do not form the requested
  cohesive cozy scene. Screenshot SHA256 and review are recorded in
  [the issue update](https://github.com/veasel-labs/veasel/issues/693#issuecomment-7128115047);
  launch verification was corrected in [the follow-up](https://github.com/veasel-labs/veasel/issues/693#issuecomment-7128314289).
- **Remaining acceptance:** improve the authored composition without replacing
  governed PXL assets, then review compact/high-zoom/reduced-motion layouts and
  real packaged Electron behavior. The scene must remain truthful when no
  workspace or active session exists.
- **Action:** IMPLEMENT/REVIEW; keep open. Do not use the runtime integration
  PR or screenshots alone as proof that the visual acceptance is complete.


## Distribution and release reconciliation

As of 2026-11-24, the latest published release is
[`v0.102.1-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.102.1-next.0),
source `eab88d598b5ab8329dabffcd45d35aa00e2a4cab`. Its `release.json`,
`SHA256SUMS`, and Linux/macOS/Windows CLI and Desktop artifacts have published
SHA-256 digests; all nine artifact digests and sizes were verified against the
manifest. Website/Homebrew/AUR updates #228/#68/#70 are merged and current-main
CI and deployment/package checks passed on the SHAs above. Homebrew's actual
install/upgrade/runtime/uninstall and AUR build/install/upgrade/uninstall
smokes passed on the exact PR heads. Unsigned installers remain explicitly
unsigned. The AUR publisher workflow reports success; no action-required PR
event is represented as a CI pass.

- Historical Veasel release [`v0.100.1-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.100.1-next.0)
  names source `c20254af8267705432449102c091185445098d25`, with Linux, macOS and
  Windows CLI and Desktop artifacts. All nine manifest digests/sizes match
  GitHub's asset metadata and all ten `SHA256SUMS` entries match; the three
  platform CLI archives were downloaded and verified locally. Installers remain
  truthfully unsigned.
- The earlier v0.100.1, v0.101.2, and v0.101.3 distribution audits are historical. Consumer `main` branches now reference v0.102.1-next.0 via PRs #228, #68, and #70.
- Homebrew's repeated updater failure was reproduced in [run
  #44996193101](https://github.com/veasel-labs/homebrew-tap/actions/runs/44996193101):
  it rebased a stale branch containing 117 commits and conflicted on three
  add/add files although the cask already matched the release. The workflow now
  verifies the release manifest, skips branch/PR mutation for an already-current
  cask, keeps the macOS install smoke, deduplicates only same-repo updater PRs
  against `main`, and creates new branches from current `main`. The updater
  smoke passed in [#45056699780](https://github.com/veasel-labs/homebrew-tap/actions/runs/45056699780)
  on pre-merge PR head `e993a4be`, not on current `main`; current-main CI
  [#45056896872](https://github.com/veasel-labs/homebrew-tap/actions/runs/45056896872)
  passed after the follow-up review and behavior fix merged as [PR #61](https://github.com/veasel-labs/homebrew-tap/pull/61).
- **Process note:** commit `93a596048e2524e0cec8a9437167be5a0857d0d0` reached
  Homebrew `main` directly because the checkout's push default mapped a short
  branch push to its upstream `main`. The error was reported immediately; no
  history was rewritten. The follow-up change received independent review and
  merged through PR #61. Use a fully qualified destination ref on future pushes.
- Signing/notarization is not claimed. Apple notarization and Windows signing
  still require valid certificates/account access if signed installers are a
  product requirement.

## Closed-but-unmerged work that still needs capability accounting

The personal Toolkit's old stacked Desktop PRs are no longer open. PR #1808
merged; #1783, #1785, #1786, #1788, #1789, #1790, #1793, #1794, #1796 and #1799
were closed without merge. Their closure is not evidence of migration. Compare
their Focus behavior, tests and governed PXL assets against Veasel `main`
copy-first; port missing portable capabilities to the personal Toolkit and
product capabilities to Veasel with provenance. Do not resurrect the stack or
the retired Desktop runtime wholesale.

## Completed slices (evidence, not blanket epic closure)

- Orchestration issues #629–#638 were resolved in Veasel. Real OpenCode-parent
  to Codex-child lineage and deterministic cancellation/budget/context proof
  are recorded in [#629](https://github.com/veasel-labs/veasel/issues/629#issuecomment-7041293535).
- MCP credential storage #741, implementer isolation #642 and native
  confinement tests #748 were resolved with PRs #775–#777 and cross-platform
  evidence in their linked issue comments. These do not close the parent
  daily-driver or product-mission gates.
- Veasel Library #706 closed through PR #782; runtime/catalog work is integrated.
  After the owner's explicit first-party exception in official registry PR #12,
  Veasel PR #795 merged as 69c3646, synchronizing the bundled catalog and
  adding offline install/discovery/removal regression coverage. Its exact-head
  Linux/macOS/Windows checks passed, including Windows. Post-merge exact-main
  CI [#45342354902](https://github.com/veasel-labs/veasel/actions/runs/45342354902)
  passed on `a72a2f5d82f5a4169068c73782fc8c05027c83e0`; the newer docs merge
  `56f2c6b` also passed exact-main CI [#45360661252](https://github.com/veasel-labs/veasel/actions/runs/45360661252),
  including Windows. Community entries remain pending
  independent review as directed.
- World integration #693 was initially closed through [PR #789](https://github.com/veasel-labs/veasel/pull/789)
  after semantic runtime integration. It was reopened after packaged visual
  review; see the current #693 disposition above. Runtime state is canonical,
  but visual design/accessibility acceptance is not complete.
- Official registry governance issue [#10](https://github.com/veasel-labs/agent-toolkit/issues/10) is closed with the owner's explicit decision, “Aprobar excepción first-party de veasel-essentials.” [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12) merged as `2096315d10ccdb19b1cb8ea071986bd2c641eb89`, marked only first-party `veasel-essentials` approved, updated generated catalogs, and documented the transparent owner exception. Exact-main validation [#45075110730](https://github.com/veasel-labs/agent-toolkit/actions/runs/45075110730) passed. Community `agent-toolkit-core` remains pending; no independent review is claimed. The first-party bundled source keeps its pin by containing repository commit and its manifest/skill hashes were verified before approval.
- The official registry's invalid-pin remediation merged as PR #11. It removes
  the all-zero pin and validates provenance; community `agent-toolkit-core`
  remains pending and non-installable until independent review.
- Personal Toolkit PRs [#1832](https://github.com/ulises-jeremias/agent-toolkit/pull/1832)
  (`94291bdc`, GUI CLI redirected to Veasel Desktop), [#1833](https://github.com/ulises-jeremias/agent-toolkit/pull/1833)
  (`d1ae2d53`, publish-by-reference documentation), and [#1834](https://github.com/ulises-jeremias/agent-toolkit/pull/1834)
  (`5b788da0`, Swarm v1 disposition) and [#1835](https://github.com/ulises-jeremias/agent-toolkit/pull/1835)
  (`cc5c60d4`, Creative Studio portable skills/agents) are merged into current
  personal Toolkit `main`. They account for compatibility, publishing guidance,
  Swarm v1 disposition, and this reviewed portable capability slice; they do not
  prove every legacy Desktop capability was migrated or every Swarm data
  migration is complete. Exact-main CI runs #45082787618–#45082787731 completed
  successfully; this does not establish a new published Toolkit release.
- HorneroOS AgentSpec registration issue #418 closed through #419. A real
  HorneroOS installation/launch/reuse/cleanup check is not claimed by this
  record.

## Closeout rule

Keep #549, #550, #673 and #689 open while their stated acceptance remains.
Before closing any item, attach the exact destination SHA,
required CI result, packaged/runtime evidence and final resolution link. Close
#689 last; do not substitute the current zero-PR count for product completion.
