# Cross-repository resolution ledger

Epic: [veasel#689](https://github.com/veasel-labs/veasel/issues/689) ·
Architecture: [ADR-0001](../adr/0001-one-product-one-runtime.md) ·
Audit: 2026-11-23 · Method: GitHub API open-issue/open-PR enumeration, exact
`main` SHA lookup, latest-main check runs, release and updater inspection.

The prior November 15 audit is retained at
[`TRIAGE_LEDGER_2026-11-15.md`](TRIAGE_LEDGER_2026-11-15.md). Its counts and
proposed dispositions are historical and must not be used as current state.

## Current snapshot

| Repository | `main` SHA | Open issues | Open PRs | Latest relevant evidence |
| --- | --- | ---: | ---: | --- |
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | 32f66f4c1c5ada913a8fb7e967d94424266ce3d4 | 5 | 1 | PR #798 merged as 32f66f4. Exact-main CI [#45149425094](https://github.com/veasel-labs/veasel/actions/runs/45149425094) is in progress; several V shards and Linux/macOS/Windows backends were pending at capture. Draft PR #800 now contains the executable-tree sandbox fix plus the explicit, revocable per-session workspace grant formerly in #801; candidate head `6fae679d14e7eb8c67c822b7a8059c5c1817bea6` has fresh required checks running. The release remains v0.100.1-next.0 and predates #795/#796. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | 2096315d10ccdb19b1cb8ea071986bd2c641eb89 | 0 | 1 | Owner-approved first-party veasel-essentials exception merged in [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12); exact-main validation [#45075110730](https://github.com/veasel-labs/agent-toolkit/actions/runs/45075110730) passed. Draft community registration [#13](https://github.com/veasel-labs/agent-toolkit/pull/13) remains non-installable pending independent review; its network permission metadata needs correction (brag declares network access). |
| [veasel-labs/website](https://github.com/veasel-labs/website) | 590d458ee53229c98cfc067bda493b2d698209c0 | 0 | 0 | Main CI [#45081560447](https://github.com/veasel-labs/website/actions/runs/45081560447) and deployment [#45081560504](https://github.com/veasel-labs/website/actions/runs/45081560504) passed. Live Chromium review evidence: [website#171](https://github.com/veasel-labs/website/issues/171#issuecomment-7087442613). Current website release metadata remains on v0.100.1-next.0 until a new Veasel release exists. |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | 932ce09c236587a9192287894142010d998dd589 | 0 | 0 | Provenance/updater PR #63 is on main; exact PR CI [#45115664731](https://github.com/veasel-labs/homebrew-tap/actions/runs/45115664731) and post-merge main CI [#45115691332](https://github.com/veasel-labs/homebrew-tap/actions/runs/45115691332) passed, including macOS install → upgrade → uninstall. Cask currently targets the latest published v0.100.1-next.0; next-release propagation is not yet exercised. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | a5cfab4204653c7c063640861d98370bd3c2599e | 0 | 0 | Provenance PR #65 passed exact-head CI [#45113683610](https://github.com/veasel-labs/aur-package/actions/runs/45113683610) and exact-main Package CI [#45113904709](https://github.com/veasel-labs/aur-package/actions/runs/45113904709). The package installs veasel-tui.desktop when a release archive contains it; new-release installation on this HorneroOS host remains unverified. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | 7097e534eeafae932bcf427e12b0a5df398d9894 | 0 | 0 | Community-file validation [#40167738112](https://github.com/veasel-labs/.github/actions/runs/40167738112) passed on exact main; no update is required for the consolidated ownership model. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | eb36b92b5632c55b75dcb12100ca929dfaa0e9e6 | 1 | 0 | PR [#1837](https://github.com/ulises-jeremias/agent-toolkit/pull/1837) merged as eb36b92; the prepared-not-produced video workflow is documented honestly. PR-head integration, npm/Python matrices, and CodeQL passed; exact-main Validate [#45117799263](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45117799263) is queued. Umbrella issue [#1838](https://github.com/ulises-jeremias/agent-toolkit/issues/1838) stays open for real creative-production follow-ups. |
| **Total** | — | **6** | **2** | Five Veasel issues plus personal Toolkit #1838 remain open. Official registry PR #13 and Veasel PR #800 are open; #801 was closed as superseded after all its functionality was copied into #800. |

This snapshot was refreshed on 2026-11-23 after Veasel PR #798 merged and PR #801 was superseded by #800. It records six open issues and two open PRs across the seven repositories. Veasel main is 32f66f4 and exact-main CI [#45149425094](https://github.com/veasel-labs/veasel/actions/runs/45149425094) was still running at capture. The published v0.100.1-next.0 release predates Veasel #795/#796, so current-release synchronization and newer packaged acceptance remain unverified. Personal Toolkit main is eb36b92; exact-main Validate [#45117799263](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45117799263) was queued at the last observed audit. Counts and status should be refreshed after current checks finish.
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
| [official registry #13](https://github.com/veasel-labs/agent-toolkit/pull/13) | OPEN DRAFT · community Creative Studio plugin by reference | Requires independent maintainer review. Source is pinned at cc5c60d48c18ff6b5788c08f38f681c933505fbe; no source is copied. | Registry CI [#45112445890](https://github.com/veasel-labs/agent-toolkit/actions/runs/45112445890) passed and entry remains installable:false. Review found registry.yaml says network:false while upstream skills/brag/SKILL.md declares security.network:true; permission metadata is understated. | Correct the permission declaration, audit shipped skill/MCP capabilities and provenance, then request a reviewer other than the submitter. Never self-approve or mark installable before review. |
| [veasel #800](https://github.com/veasel-labs/veasel/pull/800) | OPEN DRAFT · resolves [#799](https://github.com/veasel-labs/veasel/issues/799) | Veasel MCP runtime. Branch rebased onto current main after #798 merged; head `6fae679d14e7eb8c67c822b7a8059c5c1817bea6` includes executable-tree sandboxing, Linux-only test guards, and the per-session workspace grant copied from #801. | Local Linux V transport/API tests, full `scripts/api-smoke.sh`, targeted Bun tests/typecheck and `git diff --check` passed under resource-limited scopes. Earlier PR #800 Windows check failed before adding Linux-only test guards; fresh exact-head CI is running. | Review exact-head Linux/macOS/Windows checks, fix failures, obtain review, merge under branch protection, verify exact-main CI, then close #799. |

Merged since prior ledger snapshot:

- [veasel#798](https://github.com/veasel-labs/veasel/pull/798) merged as `32f66f4c1c5ada913a8fb7e967d94424266ce3d4`. All exact-head required checks passed, including the Windows backend and Linux shards. The post-merge exact-main CI [#45149425094](https://github.com/veasel-labs/veasel/actions/runs/45149425094) is still in progress; this is not final main-green evidence.
- [veasel#801](https://github.com/veasel-labs/veasel/pull/801) was closed unmerged as **SUPERSEDED** after all 20 changed files and its session permission behavior were copied into draft PR #800. The copied code passed local V transport/API tests, full API smoke, targeted TUI tests and typecheck; PR #800 remains the integration destination and #799 remains open.
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
## Open issues and required resolution

### veasel-labs/veasel#799 — trusted MCP stdio executable/workspace sandbox

- **State / owner:** OPEN · Veasel MCP runtime and session permission UI.
- **Dependencies:** combined implementation candidate in PR #800; cross-platform required checks and review. PR #801 is being superseded after its permission changes were copied into #800.
- **Existing implementation:** Linux Bubblewrap masks home/tmp, which hides user-installed MCP executables. Existing trust was per-session but had no separate workspace write grant.
- **Change/evidence:** PR #800 resolves hidden executable/interpreter trees and symlink hops, re-exposes them read-only, and retains the operator-configured cwd boundary. Its candidate also contains PR #801's schema migration and explicit, separately revocable session-workspace grant; legacy trust migrates with no workspace access. Local V tests, full API/provider/MCP approval/rejection/error smoke, targeted TUI tests and typecheck passed. Earlier Windows checks failed before adding Linux-only sandbox-test guards; new platform CI is pending.
- **Remaining acceptance:** independent review, Linux/macOS/Windows CI, exact-main validation and packaged MCP journey. Do not close before those pass.
- **Action:** IMPLEMENT/REVIEW via PR #800; destination `veasel-labs/veasel`; candidate `18550b0a91d08563326d9296fc69a58aac8e36ba` is not on main. Keep open until complete cross-platform checks and exact-main validation pass.

### veasel-labs/veasel#549 — daily-driver product mission

- **State / owner:** OPEN · Veasel runtime, Desktop, TUI, provider adapters.
- **Dependencies:** #550 packaged real-provider journeys; #673 controlled
  benchmark; parent reconciliation in #689.
- **Evidence:** packaged Linux OpenCode coding, approval/denial, cancellation,
  independent red-to-green verification, restart persistence, and same-session
  visual TUI continuation are recorded in [#550's Nov 20 evidence
  update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
  A new packaged Linux Claude Code run is recorded in [#550's Nov 23 update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7090028693) and PR #794: it independently changed a parser and passed seven red-to-green assertions, with two approved tools and durable completed SQLite state. Playwright approval automation detached, so its evidence is not a fully stable GUI automation pass; provider model and cost remain unknown. Current release and CI evidence is listed above.
- **Remaining acceptance:** repeatable representative tasks on installed
  binaries; native macOS and Windows real-provider journeys; visual-TUI
  continuation from that Claude session; durable crash/restart outcome; and
  transparent recovery/usage evidence. Do not reuse deterministic fixtures as
  real-provider proof.
- **Action:** KEEP OPEN. Continue implementation and platform acceptance in
  `veasel-labs/veasel`; resolve only with independent packaged evidence and
  links in the issue. Current destination is `main` at `69c3646a82dc11072a9361355229b8c5b110aca6`; no final
  resolution commit exists.

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
- **Remaining acceptance:** complete native macOS and Windows install/configure/
  edit/review/test/restart journeys with real providers; test rejected changes,
  cancellation and process cleanup on those platforms; continue the Claude
  session in the actual visual TUI and verify Desktop observes the same session.
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
  passed on SHA `240d95e`. It is historical; CI for current SHA `69c3646`
  is queued in [#45117101696](https://github.com/veasel-labs/veasel/actions/runs/45117101696). A hosted runner cannot create
  network namespaces; those checks remain explicitly NOT VERIFIED there, with
  local Arch evidence recorded separately.
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


## Distribution and release reconciliation

- Veasel release [`v0.100.1-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.100.1-next.0)
  names source `c20254af8267705432449102c091185445098d25`, with Linux, macOS and
  Windows CLI and Desktop artifacts. All nine manifest digests/sizes match
  GitHub's asset metadata and all ten `SHA256SUMS` entries match; the three
  platform CLI archives were downloaded and verified locally. Installers remain
  truthfully unsigned.
- Website metadata, Website, Homebrew and AUR currently reference `v0.100.1-next.0`, whose source predates Veasel main `69c3646`. Website main `590d458` deployed successfully; Homebrew main `932ce09` passed its exact-main macOS install/upgrade/uninstall gate; AUR main `a5cfab4` passed package CI after provenance hardening. They remain truthful about the latest published artifacts, but propagation of the next Veasel release has not yet been exercised.
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
  Linux/macOS/Windows checks passed, including Windows. Current-main CI remains
  queued; community entries remain pending independent review.
- World integration #693 closed through [PR #789](https://github.com/veasel-labs/veasel/pull/789)
  at current `main`; runtime state is canonical. Visual design/accessibility
  evidence remains part of the open epic acceptance.
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
