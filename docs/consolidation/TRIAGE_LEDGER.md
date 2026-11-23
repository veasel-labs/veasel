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
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | `e95638c8c33d22e323be86f3464dde344fca7c62` | 4 | 2 | Post-merge core CI [#45109130951](https://github.com/veasel-labs/veasel/actions/runs/45109130951) is pending on this exact SHA; CodeQL passed. The prior main CI [#45106567453](https://github.com/veasel-labs/veasel/actions/runs/45106567453) is still running on its older `240d95e` SHA. Verified prerelease [`v0.100.1-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.100.1-next.0) remains based on `c20254a`; all nine manifest asset digests match GitHub metadata, and signing remains explicitly false. Draft PRs #795 and #796 remain open. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | `2096315d10ccdb19b1cb8ea071986bd2c641eb89` | 0 | 0 | Owner-approved first-party exception merged in [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12); exact-main validation [#45075110730](https://github.com/veasel-labs/agent-toolkit/actions/runs/45075110730) passed. `agent-toolkit-core` remains pending and non-installable. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | `590d458ee53229c98cfc067bda493b2d698209c0` | 0 | 0 | Release-metadata CI [#45081076364](https://github.com/veasel-labs/website/actions/runs/45081076364) passed on the exact proposed SHA; merge landed with main CI [#45081560447](https://github.com/veasel-labs/website/actions/runs/45081560447) and deployment [#45081560504](https://github.com/veasel-labs/website/actions/runs/45081560504) successful. Live Chromium review evidence: [website#171](https://github.com/veasel-labs/website/issues/171#issuecomment-7087442613). |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | `004860b04a9c3393af2a7178ae6155e19c053596` | 0 | 0 | Main cask CI [#45081630804](https://github.com/veasel-labs/homebrew-tap/actions/runs/45081630804) passed. Updater [#45081036921](https://github.com/veasel-labs/homebrew-tap/actions/runs/45081036921) verified the new release archive, performed install smoke, and opened #62; exact-PR CI [#45081167752](https://github.com/veasel-labs/homebrew-tap/actions/runs/45081167752) passed install, upgrade, and uninstall acceptance. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | `6bd394cc742d64f8618815655cb8c0cbe92ac4ad` | 0 | 0 | Package CI [#45081790113](https://github.com/veasel-labs/aur-package/actions/runs/45081790113) passed on this exact main SHA. Release publish [#45081036506](https://github.com/veasel-labs/aur-package/actions/runs/45081036506) built/installed the package and confirmed CLI version/runtime before mirroring #63. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | Community-file validation [#40167738112](https://github.com/veasel-labs/.github/actions/runs/40167738112) passed on this SHA. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | `cc5c60d48c18ff6b5788c08f38f681c933505fbe` | 0 | 1 | PR #1835 and its main checks are complete; draft PR #1836 (`8cf7f004`) retires future Electron release assets while preserving CLI distributions and old data. Exact-head local tests/type-check pass; cross-platform GitHub CI is pending. |
| **Total** | — | **4** | **3** | Four open issues remain in Veasel; the open PRs are Veasel #795/#796 and personal Toolkit #1836. The other five repositories have no open items. |

This snapshot was refreshed on 2026-11-23 after Veasel #793 and #794 merged, official registry issue #10 was resolved by the owner's first-party exception, release-propagation PRs Website #223, Homebrew #62 and AUR #63 merged, and personal Toolkit PR #1835 merged. It counts Veasel PRs #795/#796 and Toolkit PR #1836. The `v0.100.1-next.0` release remains based on `c20254a`; exact-main CI for `e95638c` is pending. The unresolved items below stay open
until their product acceptance is met or an explicitly approved disposition is
recorded. A low PR count does not imply all closed draft work was migrated.

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
| [veasel#795](https://github.com/veasel-labs/veasel/pull/795) | OPEN DRAFT · owner-approved offline Library entry | Synchronizes the bundled catalog with owner exception #10 and adds install/discovery/remove acceptance. It was based on `49a7a71`; this branch now merges `e95638c` to resolve its ledger conflict. | Owner exception applies only to first-party `veasel-essentials`; `agent-toolkit-core` remains absent pending independent review. Plugin-focused tests passed before ledger refresh. Merge commit makes the exact-head checks pending again. | REVIEW merged code and ledger, finish exact-head CI, then update #706's closure context with evidence. |
| [veasel#796](https://github.com/veasel-labs/veasel/pull/796) | OPEN DRAFT · Linux CLI launcher packaging | Adds the `veasel-tui.desktop` entry to the Linux CLI archive and asserts the archive contains it. The AUR package has a conditional consumer for the entry. | Head `1247386`; Linux shards passed; Linux/Windows backend checks were pending at last query, while other checks passed. Exact release artifacts and HorneroOS launcher behavior still depend on a new release. | REVIEW package contents, complete exact-head CI, merge, and verify on the host after a published artifact exists. |
| [personal Toolkit #1836](https://github.com/ulises-jeremias/agent-toolkit/pull/1836) | OPEN DRAFT · retire legacy Electron release channel | Keep Desktop packaging CI on PRs, stop attaching Electron packages to future releases, make the legacy updater check OS/architecture assets, and point current docs at Veasel. | Head `8cf7f004`; 8 update-check tests, Desktop type-check, YAML publication assertions, and diff check pass locally. GitHub PR CI is pending, including packaged Electron compatibility jobs. Old releases and local data are untouched; no migration is claimed. | REVIEW and finish exact-head CI before merge. |

Merged since prior ledger snapshot:

- [veasel#790](https://github.com/veasel-labs/veasel/pull/790) merged as `a594e4ef23002761e7b29386655b345166ad96a4`; it refreshed the cross-repository ledger.
- [veasel#791](https://github.com/veasel-labs/veasel/pull/791) merged as `c20254af8267705432449102c091185445098d25`. It fixes installed CLI provider final reporting from durable `TurnFacts` and published `v0.100.1-next.0` with verified manifest/checksums. Full Linux/macOS/Windows main CI and packaging passed on that SHA in [#45070709828](https://github.com/veasel-labs/veasel/actions/runs/45070709828).
- [veasel#792](https://github.com/veasel-labs/veasel/pull/792) merged as `49a7a710078d47d6bd8598be7eb8807487e8c427`; exact-main core CI [#45088107243](https://github.com/veasel-labs/veasel/actions/runs/45088107243) passed.
- [veasel#793](https://github.com/veasel-labs/veasel/pull/793) merged at `240d95ebd5bd93ba2637314dadf6b335b055ac83`. It adds the deterministic matched Responses-provider benchmark and shell isolation harness. Exact-main CI [#45106567453](https://github.com/veasel-labs/veasel/actions/runs/45106567453) was still running on `240d95e`; no paid Meta request is claimed.
- [veasel#794](https://github.com/veasel-labs/veasel/pull/794) merged as `e95638c8c33d22e323be86f3464dde344fca7c62`. Exact PR-head Linux/macOS/Windows checks passed. It records one Linux packaged Claude coding journey and its limitations; issue #550 remains open. Post-merge main CI [#45109130951](https://github.com/veasel-labs/veasel/actions/runs/45109130951) is pending on this SHA.
- Personal Toolkit PR [#1835](https://github.com/ulises-jeremias/agent-toolkit/pull/1835) was squash-merged as `cc5c60d48c18ff6b5788c08f38f681c933505fbe`; its four changes are integrated, but original commit IDs are not retained on `main`. It adds the reviewed, opt-in portable Creative Studio skills/agents/catalog product, pins the MCP server, and applies approval-gated OpenCode permissions. Exact-head validation for V, catalog/provenance, security, Windows integration, and packaged Desktop clean-machine journeys passed. The separate Electron package/linkage release workflow [#45074181542](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181542) was cancelled after ~50 minutes in unrelated macOS packaging jobs; it is recorded as cancelled, not passed. Follow-up main CI runs #45082787618–#45082787731 completed successfully on the merge SHA; no new package release is claimed.

## Open issues and required resolution

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
  links in the issue. Current destination is `main` at `e95638c8c33d22e323be86f3464dde344fca7c62`; no final
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
  The earlier Windows auth failure was the test's invalid interpolated JSON
  (`\U` in `C:\Users\...`), fixed by PR #773; its native regression passes in
  Windows batch 1. [The root-cause follow-up](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7086183011)
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
  was still running on that prior main SHA. A hosted runner cannot create
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
- Website metadata, Homebrew cask and AUR package now all point to `v0.100.1-next.0` and its source SHA. Release refresh PRs [Website #223](https://github.com/veasel-labs/website/pull/223), [Homebrew #62](https://github.com/veasel-labs/homebrew-tap/pull/62), and [AUR #63](https://github.com/veasel-labs/aur-package/pull/63) merged as `590d458`, `004860b`, and `6bd394c`; their exact-main CI and deployment passed. Live website review and actual Homebrew cask install/upgrade/uninstall are linked above. The AUR update workflow built and installed the exact generated package before publishing and mirroring it; the subsequent main package CI passed on `6bd394c`.
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
  The owner approved first-party `veasel-essentials` in official registry PR
  #12, but Veasel main still carried the pre-decision offline catalog. Draft
  PR #795 synchronizes that catalog and tests offline install/discovery/removal;
  until it merges, the installed Library's bundled fallback does not reflect
  the new approval. Community entries stay blocked until independent review.
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
