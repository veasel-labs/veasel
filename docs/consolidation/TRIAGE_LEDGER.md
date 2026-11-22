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
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | `c20254af8267705432449102c091185445098d25` | 4 | 0 | PR #791 merged at this exact SHA. Latest-main CI [#45070709828](https://github.com/veasel-labs/veasel/actions/runs/45070709828) is queued/pending; no green result is claimed yet. The pre-merge run [#45066764281](https://github.com/veasel-labs/veasel/actions/runs/45066764281) completed successfully on Linux, macOS and Windows, including all six Linux shards, Windows auth batches, native keychain, packaged binaries and ConPTY TUI smoke, plus Desktop/Terminal, Focus, Harbor, security and CodeQL. Earlier main run [#45068873225](https://github.com/veasel-labs/veasel/actions/runs/45068873225) on `a594e4e` is still running. Main branch protection now requires the existing four checks plus macOS backend, Windows backend and all six Linux extra-test shards; exact required contexts are recorded below. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | `e2c218aa1302639172976d12e383abda3ae23641` | 1 | 0 | Registry validation [#44588769444](https://github.com/veasel-labs/agent-toolkit/actions/runs/44588769444) passed. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | `1e402a3c32107be92b8ebaad42bc57ba119f6e79` | 0 | 0 | Release refresh [#45038246879](https://github.com/veasel-labs/website/actions/runs/45038246879) passed; build/deploy for the current release metadata passed [#44787710645](https://github.com/veasel-labs/website/actions/runs/44787710645). |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | `edc719b52d24b0b3f0c077ce65fef89d2a7de839` | 0 | 0 | macOS cask CI [#45056896872](https://github.com/veasel-labs/homebrew-tap/actions/runs/45056896872) passed on this SHA; updater manifest + install smoke [#45056699780](https://github.com/veasel-labs/homebrew-tap/actions/runs/45056699780) passed on pre-merge PR head `e993a4be`; it is not evidence from this main SHA. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | `bb8c04675a57b1840cf65d91959d71254d62c8df` | 0 | 0 | Package CI [#44785915351](https://github.com/veasel-labs/aur-package/actions/runs/44785915351) and publisher [#44998127589](https://github.com/veasel-labs/aur-package/actions/runs/44998127589) passed. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | Community-file validation [#40167738112](https://github.com/veasel-labs/.github/actions/runs/40167738112) passed on this SHA. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | `5b788da03322d01495cc39579ddbf41657120107` | 0 | 1 | Latest-main CI [#44704030935](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/44704030935) passed, including Linux/macOS/Windows integration. Draft PR #1835 has an updated exact-head matrix running; see below. |
| **Total** | — | **5** | **1** | Four open issues in Veasel and one owner-decision issue in the official registry. Open PR #1835 is incomplete and has failing checks. |

These counts are a point-in-time snapshot. The unresolved items below stay open
until their product acceptance is met or an explicitly approved disposition is
recorded. A zero PR count does not imply all closed draft work was migrated.

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
| [personal agent-toolkit#1835](https://github.com/ulises-jeremias/agent-toolkit/pull/1835) | OPEN DRAFT · portable Creative Studio capabilities | Adds 8 skills, 6 agents, 8 MCP entries, opt-in product, docs/catalogs and 250 generated plugin files. Preserve the portable ownership boundary; review upstream provenance, per-tool permissions, package claims and the generated catalog diff. | New head `075a501079699632d94729ef7be8f98fb914f275` (original commit and corrective commits `eb9470ee`, `0b1d8798` preserved) on base `5b788da03322d01495cc39579ddbf41657120107`. Independent review found OpenCode Bash/Edit were unrestricted, source checks only sampled the first MiB, legacy hash limits were silent, and `doctor` ignored nonzero version-command exit status; the new commit sets OpenCode permissions to `ask`, hashes complete files, warns on legacy partial/missing hashes, and rejects broken core tools. It also fixes JSON doctor exit status, profile parity and README inventory/pack docs. Independent final review then found an unpinned MCP launch and stale README product count; head `075a5010` pins the server to evaluated upstream commit `9abcf9474a434f2e00a9c458f0ff70c92fbc16d8`, declares optional `uvx`, documents the same pinned install, and lists all six products. Local targeted pytest: 16 passed for creative studio, product schema and skill coverage, plus the prior 18 targeted tests; JSON parsing and `git diff --check` pass. Fresh exact-head checks on `075a5010` are running: validation [#45074181542](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181542), package [#45074181510](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181491), desktop [#45074181546](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181546), clean-machine [#45074181576](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45074181576); additional format/parity workflows are also running. Original failure evidence: [#45060229153](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45060229153); macOS packaging/linkage were cancelled at ~60 minutes in [#45060229204](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45060229204), not passed. Destination: personal Toolkit `main`. | REVIEW/VERIFY; keep draft until exact-head CI (including macOS package/linkage) passes and a reviewer examines the 296-file source/generated diff. Do not close while portable capability work is unaccounted. |

Merged since prior ledger snapshot:

- [veasel#790](https://github.com/veasel-labs/veasel/pull/790) merged as `a594e4ef23002761e7b29386655b345166ad96a4`; it refreshed the cross-repository ledger.
- [veasel#791](https://github.com/veasel-labs/veasel/pull/791) merged as current `main` `c20254af8267705432449102c091185445098d25`. It fixes installed CLI provider final reporting from durable `TurnFacts`. PR-head checks passed Linux/macOS, all six Linux shards, and the full Windows backend including native keychain and packaged TUI artifact smoke. Main CI on the resulting SHA is queued/pending as noted above. The real packaged Claude journey is still NOT VERIFIED; see [#550 follow-up](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7085930868).

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
  valid relative source and narrow declared permissions, and both entries remain
  `pending-initial-review` / `installable: false`. `agent-toolkit-core` is pinned
  to immutable commit `7bd44a7b4cc64afc4908b49977589666c1978920` (the unsigned
  `v1.49.0` tag resolves to that commit); its Docker MCP server uses a GitHub
  token and its hook executes Bash, so a distinct reviewer should confirm the
  declared `network: false` / `shell: false` interpretation before approval.
  `veasel-essentials` is pinned by the official registry commit because it uses
  a relative source; its bundled `plugin.json` and `SKILL.md` hashes match. The
  resolver emits a warning for that relative ref, and `PROVENANCE.md` should
  explain this first-party pin policy as explicitly as the registry does.
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
  passed on current `main` before the new draft #1835; its checks and state are recorded above.
- HorneroOS AgentSpec registration issue #418 closed through #419. A real
  HorneroOS installation/launch/reuse/cleanup check is not claimed by this
  record.

## Closeout rule

Keep #549, #550, #673, #689 and official registry #10 open while their stated
acceptance remains. Before closing any item, attach the exact destination SHA,
required CI result, packaged/runtime evidence and final resolution link. Close
#689 last; do not substitute the current zero-PR count for product completion.
