# Cross-repository resolution ledger

Epic: [veasel#689](https://github.com/veasel-labs/veasel/issues/689) ·
Architecture: [ADR-0001](../adr/0001-one-product-one-runtime.md) ·
Audit: 2026-11-22 · Method: GitHub API open-issue/open-PR enumeration, exact
`main` SHA lookup, latest-main check runs, release and updater inspection.

The prior November 15 audit is retained at
[`TRIAGE_LEDGER_2026-11-15.md`](TRIAGE_LEDGER_2026-11-15.md). Its counts and
proposed dispositions are historical and must not be used as current state.

## Current snapshot

| Repository | `main` SHA | Open issues | Open PRs | Latest relevant evidence |
| --- | --- | ---: | ---: | --- |
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | `c20254af8267705432449102c091185445098d25` | 4 | 1 | Latest-main CI [#45070709828](https://github.com/veasel-labs/veasel/actions/runs/45070709828) passed on this exact SHA, including Linux/macOS/Windows backend, all six Linux shards, native Windows auth regression and Credential Manager, ConPTY, Desktop/Terminal, security, and Linux/macOS/Windows packaging. Verified prerelease [`v0.100.1-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.100.1-next.0) targets this SHA; all manifest hashes/sizes match GitHub API digests, all ten checksum entries match, and unsigned status is explicit. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | `2096315d10ccdb19b1cb8ea071986bd2c641eb89` | 0 | 0 | Owner-approved first-party exception merged in [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12); exact-main validation [#45075110730](https://github.com/veasel-labs/agent-toolkit/actions/runs/45075110730) passed. `agent-toolkit-core` remains pending and non-installable. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | `590d458ee53229c98cfc067bda493b2d698209c0` | 0 | 0 | Release-metadata CI [#45081076364](https://github.com/veasel-labs/website/actions/runs/45081076364) passed on the exact proposed SHA; merge landed with main CI [#45081560447](https://github.com/veasel-labs/website/actions/runs/45081560447) and deployment [#45081560504](https://github.com/veasel-labs/website/actions/runs/45081560504) successful. Live Chromium review evidence: [website#171](https://github.com/veasel-labs/website/issues/171#issuecomment-7087442613). |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | `004860b04a9c3393af2a7178ae6155e19c053596` | 0 | 0 | Main cask CI [#45081630804](https://github.com/veasel-labs/homebrew-tap/actions/runs/45081630804) passed. Updater [#45081036921](https://github.com/veasel-labs/homebrew-tap/actions/runs/45081036921) verified the new release archive, performed install smoke, and opened #62; exact-PR CI [#45081167752](https://github.com/veasel-labs/homebrew-tap/actions/runs/45081167752) passed install, upgrade, and uninstall acceptance. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | `6bd394cc742d64f8618815655cb8c0cbe92ac4ad` | 0 | 0 | Package CI [#45081790113](https://github.com/veasel-labs/aur-package/actions/runs/45081790113) passed on this exact main SHA. Release publish [#45081036506](https://github.com/veasel-labs/aur-package/actions/runs/45081036506) built/installed the package and confirmed CLI version/runtime before mirroring #63. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | Community-file validation [#40167738112](https://github.com/veasel-labs/.github/actions/runs/40167738112) passed on this SHA. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | `cc5c60d48c18ff6b5788c08f38f681c933505fbe` | 0 | 0 | PR #1835 merged at this SHA. Main validation is in progress: [Validate #45082787685](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45082787685), [Desktop #45082787719](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45082787719), and [clean-machine Desktop #45082787731](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45082787731). |
| **Total** | — | **4** | **1** | Four open issues are in Veasel. The only open PR is the Veasel evidence ledger #792; the other six repositories have no open items. |

This snapshot was refreshed on 2026-11-22 after resolving official registry issue #10, merging release-propagation PRs Website #223, Homebrew #62 and AUR #63, merging personal Toolkit PR #1835, and completing Veasel `c20254a` main CI/release; it counts only open PR #792. The unresolved items below stay open
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
| [veasel#792](https://github.com/veasel-labs/veasel/pull/792) | OPEN DRAFT · consolidation evidence ledger | Documentation-only update of this ledger; the latest edit must pass CI on its exact head before merge. | Previous head `0b6abee` predates consumer synchronization and personal Toolkit PR #1835 merge; this update records green Veasel main, release `v0.100.1-next.0`, Website `590d458`, Homebrew `004860b`, AUR `6bd394c`, and personal Toolkit `cc5c60d`. | REVIEW, then merge only after all required checks on the updated head pass. |

Merged since prior ledger snapshot:

- [veasel#790](https://github.com/veasel-labs/veasel/pull/790) merged as `a594e4ef23002761e7b29386655b345166ad96a4`; it refreshed the cross-repository ledger.
- [veasel#791](https://github.com/veasel-labs/veasel/pull/791) merged as current `main` `c20254af8267705432449102c091185445098d25`. It fixes installed CLI provider final reporting from durable `TurnFacts`. Full main CI and Linux/macOS/Windows desktop packaging passed on this exact SHA in [#45070709828](https://github.com/veasel-labs/veasel/actions/runs/45070709828). It published `v0.100.1-next.0` from this SHA with verified manifest and checksums. The real packaged Claude journey is still NOT VERIFIED; see [#550 evidence](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7087233125).
- Personal Toolkit PR [#1835](https://github.com/ulises-jeremias/agent-toolkit/pull/1835) merged as `cc5c60d48c18ff6b5788c08f38f681c933505fbe`, preserving its original commits. It adds the reviewed, opt-in portable Creative Studio skills/agents/catalog product, pins the MCP server, and applies approval-gated OpenCode permissions. Exact-head validation for V, catalog/provenance, security, Windows integration, and packaged Desktop clean-machine journeys passed. The separate Electron package/linkage release workflow [#45074181542](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181542) was cancelled after ~50 minutes in unrelated macOS packaging jobs; it is recorded as cancelled, not passed. New personal main CI is in progress on the merge SHA (runs #45082787618–#45082787731); no latest-main pass is claimed yet.

## Open issues and required resolution

### veasel-labs/veasel#549 — daily-driver product mission

- **State / owner:** OPEN · Veasel runtime, Desktop, TUI, provider adapters.
- **Dependencies:** #550 packaged real-provider journeys; #673 controlled
  benchmark; parent reconciliation in #689.
- **Evidence:** packaged Linux OpenCode coding, approval/denial, cancellation,
  independent red-to-green verification, restart persistence, and same-session
  visual TUI continuation are recorded in [#550's Nov 20 evidence
  update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
  Current release and CI evidence is listed above.
- **Remaining acceptance:** meaningful repeatable coding tasks on installed
  binaries; native macOS and Windows real-provider journeys; confirm provider
  auth/quota state after the Nov 22 reset and record Claude edit evidence only
  if authentication is usable; complete transparent recovery/usage evidence.
  Do not reuse deterministic fixtures as real-provider proof.
- **Action:** KEEP OPEN. Continue implementation and platform acceptance in
  `veasel-labs/veasel`; resolve only with independent packaged evidence and
  links in the issue. Current destination is `main` at `c20254af8267705432449102c091185445098d25`; no final
  resolution commit exists.

### veasel-labs/veasel#550 — installed-binary cross-platform journeys

- **State / owner:** OPEN · Veasel packaged Desktop/TUI acceptance.
- **Dependencies:** supported macOS/Windows runners and authenticated provider
  accounts; #549 product mission.
- **Evidence:** Linux package journey and real visual TUI continuation are
  recorded in [the Nov 20 evidence comment](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
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
  cancellation and process cleanup on those platforms. Claude edit success is
  still NOT VERIFIED until a post-reset authenticated turn independently edits
  and passes its task oracle.
- **Action:** IMPLEMENT/VERIFY in Veasel; KEEP OPEN until platform and provider
  evidence is attached. Current CI proves platform backend/package jobs, not
  these real-provider journeys.

### veasel-labs/veasel#673 — matched Veasel/OpenCode benchmark

- **State / owner:** OPEN · Veasel benchmark harness and provider isolation.
- **Dependencies:** #553 benchmark acceptance; reviewed isolation for OpenCode
  shell children. Meta's current [official pricing and rate-limit page](https://dev.meta.ai/docs/pricing-rate-limits)
  lists Muse Spark 1.3 Contributor at $0.10/M input and $0.20/M output tokens;
  Contributor mode permits prompts, code, files, context, and responses to be
  used for future model training.
- **Evidence:** deterministic Responses fixtures and enforced generic spending
  bounds are recorded in [the Nov 20 issue update](https://github.com/veasel-labs/veasel/issues/673#issuecomment-7033093408).
  The current isolation branch adds a Veasel 0.79.5 Meta Responses adapter,
  per-run proxy-only credentials and Linux Bubblewrap/Unix-relay tests; 88
  local tests passed without contacting Meta. This is branch evidence only and
  awaits PR review and required CI on its exact head.
- **Remaining acceptance:** run and independently score the same meaningful task,
  prompt, base, model, permissions and budgets through Veasel and OpenCode;
  preserve sanitized traces and versions/hashes. The proxy uses the published
  Contributor rates, reserves input at the uncached rate, and caps the pinned
  run at its case budget. Rotate/update the Meta credential after reviewing the
  isolation change. No provider request or success is inferred here.
- **Remaining blocker:** rotate/update the Meta credential after review, then
  run only the owner-authorized bounded benchmark and independently score both
  attempts. No live provider request has been made by this adapter work.
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
  First-party `veasel-essentials` is installable after owner-approved PR #12;
  community entries stay blocked until independent review.
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
  migration is complete. The exact merge SHA's current-main CI is still running
  (runs #45082787618–#45082787731), so no post-merge green result is claimed.
- HorneroOS AgentSpec registration issue #418 closed through #419. A real
  HorneroOS installation/launch/reuse/cleanup check is not claimed by this
  record.

## Closeout rule

Keep #549, #550, #673 and #689 open while their stated acceptance remains.
Before closing any item, attach the exact destination SHA,
required CI result, packaged/runtime evidence and final resolution link. Close
#689 last; do not substitute the current zero-PR count for product completion.
