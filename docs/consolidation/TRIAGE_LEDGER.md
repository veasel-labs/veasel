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
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | `9a2ca6b4f8ead74747826c1f199bf145db1405f4` | 4 | 2 | Core CI [#44771350387](https://github.com/veasel-labs/veasel/actions/runs/44771350387) passed on this exact SHA: Linux/macOS/Windows backend, Linux shards, Desktop/Terminal, security, and all three desktop package jobs. The Nov 22 [#45039541114](https://github.com/veasel-labs/veasel/actions/runs/45039541114) is a watchdog, not a replacement for core CI. PRs #790 and #791 are listed below; PR CI is in progress. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | `e2c218aa1302639172976d12e383abda3ae23641` | 1 | 0 | Registry validation [#44588769444](https://github.com/veasel-labs/agent-toolkit/actions/runs/44588769444) passed. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | `1e402a3c32107be92b8ebaad42bc57ba119f6e79` | 0 | 0 | Release refresh [#45038246879](https://github.com/veasel-labs/website/actions/runs/45038246879) passed; build/deploy for the current release metadata passed [#44787710645](https://github.com/veasel-labs/website/actions/runs/44787710645). |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | `edc719b52d24b0b3f0c077ce65fef89d2a7de839` | 0 | 0 | macOS cask CI [#45056896872](https://github.com/veasel-labs/homebrew-tap/actions/runs/45056896872) passed on this SHA; updater manifest + install smoke [#45056699780](https://github.com/veasel-labs/homebrew-tap/actions/runs/45056699780) passed on pre-merge PR head `e993a4be`; it is not evidence from this main SHA. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | `bb8c04675a57b1840cf65d91959d71254d62c8df` | 0 | 0 | Package CI [#44785915351](https://github.com/veasel-labs/aur-package/actions/runs/44785915351) and publisher [#44998127589](https://github.com/veasel-labs/aur-package/actions/runs/44998127589) passed. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | Community-file validation [#40167738112](https://github.com/veasel-labs/.github/actions/runs/40167738112) passed on this SHA. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | `5b788da03322d01495cc39579ddbf41657120107` | 0 | 0 | Required CI [#44704030935](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/44704030935) passed, including Linux/macOS/Windows integration. |
| **Total** | — | **5** | **2** | Four open issues in Veasel and one owner-decision issue in the official registry; both open PRs are reviewable Veasel work. |

These counts are a point-in-time snapshot. The unresolved items below stay open
until their product acceptance is met or an explicitly approved disposition is
recorded. A zero PR count does not imply all closed draft work was migrated.

## Open pull requests

| PR | State / owner | Dependencies and remaining acceptance | Evidence / destination | Required action |
| --- | --- | --- | --- | --- |
| [veasel#790](https://github.com/veasel-labs/veasel/pull/790) | OPEN DRAFT · cross-repository consolidation ledger | Ledger refresh only; update with the current PR state and retain all historical disposition caveats. | Head `14b153a2081fd8b7d1978f9b0f3a4a447150cce2`; targeted file is `docs/consolidation/TRIAGE_LEDGER.md`; CI run [#45057802399](https://github.com/veasel-labs/veasel/actions/runs/45057802399), Linux/macOS/Windows backend checks were still pending at capture. | REVIEW, update this row to the resulting head, then mark ready and merge only after required checks pass. |
| [veasel#791](https://github.com/veasel-labs/veasel/pull/791) | OPEN DRAFT · Veasel runtime / installed CLI provider outcomes | Provider-specific tool contract plus authoritative final reporting from `TurnFacts`; preserve command-only results, provider-reported test results, and incomplete/test-failure reports. Then repeat a fresh packaged Claude edit journey to resolve the current NOT VERIFIED evidence. | Head `b13610a6dae2f056dbf1e078ab97942ff0c73025` (commits `d6f51ea`, `b13610a`); added regression cases in `execution_policy_test.v`; CI [PR #791](https://github.com/veasel-labs/veasel/pull/791) is pending. Destination: Veasel `main`. | REVIEW/VERIFY; merge only with exact-head required CI green. Then publish a new package and repeat the real provider task before updating #550. |

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
  links in the issue. Current destination is `main` at `9a2ca6b4`; no final
  resolution commit exists.

### veasel-labs/veasel#550 — installed-binary cross-platform journeys

- **State / owner:** OPEN · Veasel packaged Desktop/TUI acceptance.
- **Dependencies:** supported macOS/Windows runners and authenticated provider
  accounts; #549 product mission.
- **Evidence:** Linux package journey and real visual TUI continuation are
  recorded in [the issue's latest evidence comment](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
  The evidence distinguishes rendered visual TUI continuity from a successful
  provider turn where required.
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
- **Dependencies:** #553 benchmark acceptance; trustworthy model price bounds;
  reviewed isolation for OpenCode shell children.
- **Evidence:** deterministic Responses fixtures and enforced generic spending
  bounds are recorded in [the Nov 20 issue update](https://github.com/veasel-labs/veasel/issues/673#issuecomment-7033093408).
- **Remaining acceptance:** run and independently score the same meaningful task,
  prompt, base, model, permissions and budgets through Veasel and OpenCode;
  preserve sanitized traces and versions/hashes. The pinned Muse model is not
  in the verified price schedule and shell-child isolation still needs review;
  a previously recorded budget authorization does not remove those fail-closed
  gates. No provider request or success is inferred here.
- **Action:** IMPLEMENT/REVIEW in Veasel; KEEP OPEN until the matched pair and
  budget/isolation evidence are complete.

### veasel-labs/veasel#689 — cross-repository consolidation epic

- **State / owner:** OPEN · integration owner across all seven repositories.
- **Dependencies:** #549, #550, #673 and the official plugin governance
  decision in `veasel-labs/agent-toolkit#10`; final compatibility and HorneroOS
  evidence.
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

### veasel-labs/agent-toolkit#10 — first-party registry review policy

- **State / owner:** OPEN · repository owner decision required.
- **Dependencies:** none for independent runtime and catalog implementation;
  a second maintainer remains required for community entries.
- **Evidence:** [decision brief](https://github.com/veasel-labs/agent-toolkit/issues/10#issuecomment-7019036861)
  records that invalid/all-zero pins are rejected, `veasel-essentials` has a
  valid source and narrow declared permissions, and both entries remain
  `pending-initial-review` / `installable: false`.
- **Remaining acceptance:** owner chooses A (approve the disclosed first-party
  exception for `veasel-essentials` only), B (reject), or C (amend terms). No
  agent may self-approve; `agent-toolkit-core` still needs a distinct reviewer.
- **Action:** HUMAN DECISION. Keep the catalog fail-closed until the owner
  records the decision. Destination is the official registry; no approval
  commit exists.

## Distribution and release reconciliation

- Veasel release [`v0.100.0-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.100.0-next.0)
  names source `9a2ca6b4f8ead74747826c1f199bf145db1405f4`, with Linux, macOS and
  Windows artifacts. The manifest truthfully reports installers as unsigned.
- Website metadata, Homebrew cask and AUR package are synchronized to that
  release and source. Website issue #171, Homebrew #15 and AUR #17 are closed;
  their mirror PRs #222, #61 and #62 are merged. Package install/upgrade/
  uninstall evidence is in the current-main CI links above.
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
  Official plugin installation remains governed by #10.
- World integration #693 closed through [PR #789](https://github.com/veasel-labs/veasel/pull/789)
  at current `main`; runtime state is canonical. Visual design/accessibility
  evidence remains part of the open epic acceptance.
- The official registry's invalid-pin remediation merged as PR #11. It removes
  the all-zero pin and validates provenance, but does not grant approval to
  either pending entry.
- Personal Toolkit PRs [#1832](https://github.com/ulises-jeremias/agent-toolkit/pull/1832)
  (`94291bdc`, GUI CLI redirected to Veasel Desktop), [#1833](https://github.com/ulises-jeremias/agent-toolkit/pull/1833)
  (`d1ae2d53`, publish-by-reference documentation), and [#1834](https://github.com/ulises-jeremias/agent-toolkit/pull/1834)
  (`5b788da0`, Swarm v1 disposition) are merged into current personal Toolkit
  `main`. They account for those compatibility, publishing-guidance and
  disposition slices; they do not prove every legacy Desktop capability was
  migrated or every Swarm data migration is complete. Required CI [#44704030935](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/44704030935)
  passed on current `main`.
- HorneroOS AgentSpec registration issue #418 closed through #419. A real
  HorneroOS installation/launch/reuse/cleanup check is not claimed by this
  record.

## Closeout rule

Keep #549, #550, #673, #689 and official registry #10 open while their stated
acceptance remains. Before closing any item, attach the exact destination SHA,
required CI result, packaged/runtime evidence and final resolution link. Close
#689 last; do not substitute the current zero-PR count for product completion.
