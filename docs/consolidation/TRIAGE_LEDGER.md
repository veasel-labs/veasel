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
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | 1d041d86a19275b6c73e2c1750890dacaf18dd97 | 5 | 0 | PR #800 merged at this SHA. Exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed all required platform jobs. Post-merge exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) is still in progress; Windows and Linux backends were running at capture. Packaged MCP invocation and workspace boundary checks passed; #799 stays open until exact-main CI finishes green. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | 2096315d10ccdb19b1cb8ea071986bd2c641eb89 | 0 | 1 | Owner-approved first-party `veasel-essentials` exception merged in [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12). [PR #13](https://github.com/veasel-labs/agent-toolkit/pull/13) remains open and non-installable by the owner's decision; independent review is still required, and `network:false` conflicts with the vendored `brag` skill's declared network permission. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | ab5c4f361a6ab52f89035b6ed7aadc5e8510524f | 0 | 0 | Exact-main deployment and live website review were previously recorded; website follows the latest published Veasel release, not an unpublished commit. |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | cf0cb2aca37cc317ba6f308e5b197c7804dd3606 | 0 | 0 | Main includes manifest verification and updater deduplication; exact-main macOS install → upgrade → uninstall passed. Propagation of a newer Veasel release has not been exercised. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | a249305caecfad573caa0c6ca83c1d98754e41a1 | 0 | 0 | Main package CI passed with release provenance checks. Install/update/uninstall on a fresh Arch system for a newer release is not verified. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | 7097e534eeafae932bcf427e12b0a5df398d9894 | 0 | 0 | No organization-level change is currently required. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | eb36b92b5632c55b75dcb12100ca929dfaa0e9e6 | 1 | 3 | Issue [#1838](https://github.com/ulises-jeremias/agent-toolkit/issues/1838) remains open. Open PRs are #1839 (vendored skill sync), #1840 (creative validation docs), and #1841 (setup-uv dependency update); their current heads and remaining review are recorded below. |
| **Total** | — | **6** | **4** | Five Veasel issues and personal Toolkit #1838 remain open. Open PRs: official registry #13 and personal Toolkit #1839–#1841. |

This snapshot was refreshed on 2026-11-23 by re-querying all seven GitHub repositories. It records six open issues and four open PRs. Veasel main is `1d041d86`; its exact-main run [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) is not green evidence until every required job completes. The packaged MCP smoke used a local deterministic provider, the installed MCP server and a separately approved read/write boundary probe; no paid provider call occurred. Current issue/PR state is authoritative over older historical counts.
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
| [official registry #13](https://github.com/veasel-labs/agent-toolkit/pull/13) | OPEN · community Creative Studio plugin by reference · head `ff6a56316dfa00ce9147f54d4880a2ad3c6af6cf` | User decision: leave pending. Requires independent maintainer review. Source is pinned at `cc5c60d48c18ff6b5788c08f38f681c933505fbe`; no source is copied. `network:false` conflicts with `skills/brag/SKILL.md` declaring `security.network:true`. | Registry CI [#45112445890](https://github.com/veasel-labs/agent-toolkit/actions/runs/45112445890) passed; entry remains `installable:false`. | Keep pending and fail-closed. Correct permission metadata, audit capabilities/provenance, then obtain independent review. Never self-approve or mark installable before review. |
| [personal Toolkit #1839](https://github.com/ulises-jeremias/agent-toolkit/pull/1839) | OPEN DRAFT · upstream skill sync · head `8ba04e205a00ed80ffe675bdbaef83a7b3c7f1e7` | Review exact upstream diff, license, attribution and permissions. The `web-design-guidelines` source has `NOASSERTION` licensing and distribution restrictions; the `command.md` source declares MIT but does not grant rights to the entire vendored skill. | Personal Toolkit; no destination outside the portable capability repository. | Keep pending until licensing and provenance for every vendored file are resolved; do not merge experimental/unreviewed content as trusted. |
| [personal Toolkit #1840](https://github.com/ulises-jeremias/agent-toolkit/pull/1840) | OPEN DRAFT · creative validation documentation · head `a61c493a898fbfe976de93ad05808204d2f60158` | Adds current compatibility/validation evidence and explicitly records Veasel limitations and #799. Review against current product and issue evidence. | Personal Toolkit docs. | Review factual accuracy and evidence links; keep draft until reviewed and no longer dependent on unfinished claims. |
| [personal Toolkit #1841](https://github.com/ulises-jeremias/agent-toolkit/pull/1841) | OPEN · `astral-sh/setup-uv` dependency update · head `de05c0888ccff987c8eaf20bd42615b1543aaf3b` | Verify pinned action update and exact-head required checks. Previous check run was cancelled, not passed. | Personal Toolkit workflow dependency. | Review source/action pin and run required checks on the current head before merging. |

Merged since prior ledger snapshot:

- [veasel#800](https://github.com/veasel-labs/veasel/pull/800) merged as `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed all required jobs, including Linux/macOS/Windows backends and package smoke. The exact-main run [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) is still in progress at this ledger refresh; do not treat the watchdog as the core CI result.
- [veasel#801](https://github.com/veasel-labs/veasel/pull/801) was closed as **SUPERSEDED** after its session workspace permission implementation was copied into #800. The PR #800 package artifact passed isolated config/session/grant/revoke smoke with the real installed MCP command; an end-to-end tool invocation timed out and #799 remains open.
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
## Open issues and required resolution

### veasel-labs/veasel#799 — trusted MCP stdio executable/workspace sandbox

- **State / owner:** OPEN · Veasel MCP runtime and session permission UI.
- **Dependencies:** packaged runtime evidence after PR #800; exact-main CI on the merge SHA.
- **Existing implementation:** Linux Bubblewrap masks home/tmp, which hides user-installed MCP executables. Existing trust was per-session but had no separate workspace write grant.
- **Change/evidence:** PR [#800](https://github.com/veasel-labs/veasel/pull/800) merged at `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Its exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed Linux/macOS/Windows backend, Linux shards and package jobs. The change preserves PATH symlink lookup while exposing only executable/interpreter trees read-only, and adds the explicit, revocable per-session workspace write grant; legacy trust migrates without a write grant.
- **Packaged evidence:** the Linux artifact from PR run [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) ran the installed `mcp-kdenlive` server via its home-installed PATH command; a local deterministic OpenAI-compatible fixture requested the read-only `diagnose_environment` call, the call was inspected and explicitly approved, and the packaged operation completed through required Bubblewrap. A second packaged MCP fixture wrote a marker inside the explicitly granted session workspace and reported that a sibling outside sentinel was unreadable; the marker was visible on the host and the outside sentinel remained unchanged. Both used disposable data/workspace directories and zero paid provider calls. An initial synchronous harness waited on the approval gate until its timeout; switching to the durable operation and approving the inspected MCP call completed successfully. This was a harness correction, not a product timeout.
- **Remaining acceptance:** exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) was still running at the last check. Verify that it completes successfully on `1d041d86a19275b6c73e2c1750890dacaf18dd97`, including supported-platform backends and package jobs, before closing #799.
- **Action:** IMPLEMENT/VERIFY in Veasel; destination `veasel-labs/veasel`, commit `1d041d86a19275b6c73e2c1750890dacaf18dd97`; KEEP OPEN until packaged invocation and exact-main CI are verified.

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
