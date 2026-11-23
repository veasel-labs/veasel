# Resolution ledger — Veasel Labs ecosystem consolidation

Epic: [#689](https://github.com/veasel-labs/veasel/issues/689) ·
Supersedes the 2026-11-15 snapshot in [TRIAGE_LEDGER.md](TRIAGE_LEDGER.md)
(proposals only; kept for history).
Refreshed: **2026-11-19** from live `gh` state. Method: `gh issue/pr list`
+ main-branch SHAs + latest-main CI + release manifest verification.

## Checkpoint 2026-11-23 — live GitHub state

This checkpoint supersedes the older live snapshot below. It was refreshed
from GitHub on 2026-11-23; PR counts include drafts.

| Repository | main SHA | Open issues | Open PRs | Current note |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `dd105961483d8646c652a7ad898dd0ce9ab5914a` | 4 (#549, #550, #673, #689) | 2 (#803, #804) | Main CI run `45224522194` green; #803 platform CI green; #804 exact-head checks pending |
| veasel-labs/agent-toolkit | `2096315d10ccdb19b1cb8ea071986bd2c641eb89` | 0 | 1 (#13) | #13 remains pending review per owner; fail-closed permission mismatch (`network:false`, pinned `brag` declares network access) |
| veasel-labs/website | `a195dfcd34a0934a78cb07d3499c95e98d110a38` | 0 | 0 | No open work |
| veasel-labs/homebrew-tap | `a84ae2f260c17ec33872c2dd6bfc59003951b3ed` | 0 | 0 | No open work |
| veasel-labs/aur-package | `21d52c32f1d449c5cf2fb216b980e7870646d459` | 0 | 0 | No open work |
| veasel-labs/.github | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | No open work |
| ulises-jeremias/agent-toolkit | `e050f5668ca7d462b9e3189f2834e20ab9f3efbc` | 1 (#1838) | 0 | Umbrella issue still open |
| **Total** | | **5** | **3** | No zero-backlog claim |

Owner decisions recorded: registry #10 approved the first-party exception for
`veasel-essentials`; official registry PR #13 remains pending and is not
self-approved. The #10 outcome is reflected in official toolkit main.

Current implementation candidate: veasel PR #804
(`https://github.com/veasel-labs/veasel/pull/804`) adds installed-CLI approval
review to the shipped Solid TUI, with terminal-safe input previews,
inspection-before-approval, fail-closed truncation handling, and one-at-a-time
decisions. Local validation on 2026-11-23: `bun run typecheck`, all 694 Bun
tests across 141 files, standalone `bun-linux-x64` build and `--version`
smoke passed; high/critical Bun audit and `git diff --check` passed. These
local checks used bounded `systemd-run` scopes. The PR's current GitHub head
must still pass required checks; PR package/release jobs are conditional and
do not establish packaged-release acceptance. The CLI session in #550
remains NOT VERIFIED as a real-provider coding journey after write approval
was denied; see
https://github.com/veasel-labs/veasel/issues/550#issuecomment-7113850660.

Benchmark #673 remains gated: no paid provider call until the benchmark
wrapper is independently reviewed and the Meta credential is rotated. The
user's aggregate $5 ceiling remains in force; no spend was incurred in this
checkpoint.

## Checkpoint 2026-11-20 — consolidation state

| Repository | main SHA | Open issues | Open PRs | State |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `6078091357bf` | 7 | 0 | see below |
| veasel-labs/agent-toolkit | `e2c218aa` | 1 (#10) | 0 | governance decision (owner) |
| veasel-labs/website | `567903ea` | 0 | 0 | advertises v0.98.0-next.0, assets verified |
| veasel-labs/homebrew-tap | `fc5663d5` | 0 | 0 | cask v0.98.0-next.0, sha verified |
| veasel-labs/aur-package | `e86b9272` | 0 | 0 | pkg v0.98.0-next.0, sha verified |
| veasel-labs/.github | `7097e534` | 0 | 0 | unchanged, green |
| ulises-jeremias/agent-toolkit | `5b788da0` | 0 | 0 | mission #1667 closed; CLI 1.49.0 doctor green |

Closed since 2026-11-19 with linked evidence on each issue: veasel
#630–#633, #637 (PR #780), #638 (#778), #642 (#777), #691, #692, #706
(#782), #741 (#775), #748 (#776), #552, #553; official toolkit #4;
website #171; toolkit #1055, #1059–#1063, #1109, #1608, #1667–#1677,
#1770, #1775, #1804 (#1832), #1806 (#1833), #1676 (#1834) and all
eleven draft PRs (#1783–#1808: ten superseded by the Veasel Desktop
migration with per-PR parity mapping, #1799 ported as veasel#781,
#1808 merged). M1 root causes fixed: #773 (Windows JSON test) and #779
(Windows step was compile-bound, split into batches; Windows backend
passes ~50m). First complete release: v0.97.0-next.0 (all platforms
published incl. veasel-Windows.zip, main CI 44652953187 fully green);
distribution synchronized hash-verified at v0.98.0-next.0.

Still open, deliberately (no false PASS):
- veasel #549/#550 — product mission and packaged journey: Linux real-
  provider evidence complete (incl. visual-TUI continuation, PR #784);
  macOS/Windows packaged real-provider journeys not yet recorded.
- veasel #629 — orchestration parent: children all closed; real CLI
  child file work blocked by #786.
- veasel #786 — installed-CLI child turns report no usable filesystem
  tools (filed 2026-11-20 with reproduction and hypotheses).
- veasel #673 — matched real-provider OpenCode benchmark run pending
  (deterministic fixture + spend ceilings done).
- veasel #693 — World packaged visual acceptance loop pending (model
  and tests green; sprites sha-pinned).
- veasel-labs/agent-toolkit #10 — plugin governance: OWNER DECISION
  required (approve/reject/modify pending-review entries); never
  self-approved.
- HorneroOS/shell #447 (external repo) — shell-side launcher surface;
  Veasel prerequisites shipped (.desktop entry, AgentSpec, releases).
- Human blockers: macOS/Windows signing certificates and Apple/Windows
  account credentials (installers truthfully `signed: false`); Claude
  Code account re-login (OAuth expired 2026-11-20; spend limit resets
  Nov 22).

## Live snapshot (2026-11-19)

| Repository | main SHA | Open issues | Open PRs | Latest release consumer state |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `4d34bb250e18` | 20 | 1 (#773, this program) | `v0.96.11-next.0` from `4d34bb25`; `release.json` windows=`failed` |
| veasel-labs/agent-toolkit | `3c1c3149c13d` | 2 | 0 | registry: 2 entries, pending review |
| veasel-labs/website | `2244551675c2` | 1 | 1 | fallback pinned `v0.79.13-next.0` |
| veasel-labs/homebrew-tap | `64b75827cf37` | 1 | 1 | cask `0.96.9-next.0` |
| veasel-labs/aur-package | `b2f628b730b1` | 1 | 1 | pkg `0.96.9.next.0` |
| veasel-labs/.github | `7097e534eeaf` | 0 | 0 | — |
| ulises-jeremias/agent-toolkit | `d611d89acdbb` | 24 | 11 | legacy Desktop drafts stacked |
| **Total (excl. #773)** | | **49** | **14** | |

Main CI at refresh: veasel CI run `44460716042` on `4d34bb25` = **failure**
(Windows backend only; Linux/macOS/Desktop/Terminal/security passed).
`Ensure main CI` watchdog runs are green and are **not** core CI evidence.

## M1 — Windows backend (P0)

Root cause proven 2026-11-19: `api_auth_test.v:532` interpolated a Windows
temp path into JSON (`{"directory":"${root}"}`); `C:\Users\...` is invalid
JSON (`\U` escape), server returns 400. Fix: [veasel#773](https://github.com/veasel-labs/veasel/pull/773)
(`json2.encode(SessionInput{...})` + round-trip regression + diagnostic
assertion). Local Linux: `v test api_auth_test.v` PASS. Native Windows CI
on #773 is the platform proof; merge requires it, then a fully green CI
run on the exact merge SHA.

## veasel-labs/veasel — 20 issues

| # | Title (short) | Owner | Action | Evidence / remaining |
| --- | --- | --- | --- | --- |
| 689 | EPIC One Product, One Runtime | veasel | KEEP-LAST | Close last, after M9 reconciliation |
| 549 | Product mission: daily driver | veasel | IMPLEMENT | Do not close on CI alone; needs #550 evidence |
| 550 | Real installed-binary journey (all OS) | veasel | IMPLEMENT | Linux packaged evidence exists; macOS/Windows legs + visual-TUI continuation NOT VERIFIED |
| 552 | Terminal UX/keyboard/a11y gate | veasel | IMPLEMENT | PTY size-matrix exists; full a11y gate pending |
| 553 | Reproducible benchmarks | veasel | IMPLEMENT | Includes #673 |
| 673 | OpenCode Responses benchmark case | veasel | IMPLEMENT | Child of #553 |
| 691 | Installed-CLI provider adapters | veasel | IMPLEMENT | Claude/OpenCode live-proven; Codex quota-blocked, Copilot resume unverified |
| 692 | Focus copy-first migration | veasel | REVIEW | Substantially landed; close only after parity checklist vs #689 C/D |
| 706 | Integrated plugin Library | veasel | IMPLEMENT | Depends on official agent-toolkit#4 + governance #10 |
| 693 | Cozy World (P2) | veasel | IMPLEMENT | After Focus parity; PXL license audit first (207 sprites) |
| 629 | Orchestration epic | veasel | KEEP | Close after children #630–#638 |
| 630 | Cross-provider routing/concurrency | veasel | IMPLEMENT | Foundation: durable SubagentRun exists |
| 631 | Isolated implementation + integration | veasel | IMPLEMENT | Needs #642 |
| 632 | Context handoff | veasel | IMPLEMENT | |
| 633 | TUI delegation UX | veasel | IMPLEMENT | |
| 637 | Cumulative token/spending budgets | veasel | IMPLEMENT | Token reservations enforced; money caps only with trustworthy pricing |
| 638 | Capability validation | veasel | IMPLEMENT | Unknown must stay unknown |
| 642 | Implementer sandbox | veasel | IMPLEMENT | Partial via child-shell sandbox; wiring to implementer profile remains |
| 741 | MCP credentials → OS keychain | veasel | IMPLEMENT | Next security slice; inventory already in issue |
| 748 | Native macOS/Windows confinement CI | veasel | IMPLEMENT | Needs native runners; not closable from Linux |

## veasel-labs/agent-toolkit — 2 issues

| # | Title | Action | Note |
| --- | --- | --- | --- |
| 4 | First curated plugins + offline skills | IMPLEMENT | Feeds veasel#706; fix all-zero SHA in `veasel-essentials` |
| 10 | Governance: first-party curation exception | HUMAN DECISION | Owner-only; never self-approve. Entries stay `installable:false` until decided |

## veasel-labs/website — 1 issue, 1 PR

| Item | Action | Evidence |
| --- | --- | --- |
| #171 website quality review | IMPLEMENT | After release sync so download accuracy is testable |
| PR #216 → `v0.95.0-next.0` | SUPERSEDE | Stale: current verified is `v0.96.11-next.0` (`4d34bb25`). Close after a fresh refresh PR (or bot run) targets 0.96.11 with verified hashes; its CI was `action_required` |

## veasel-labs/homebrew-tap — 1 issue, 1 PR

| Item | Action | Evidence |
| --- | --- | --- |
| #15 macOS install E2E | IMPLEMENT (macOS) | Blocked on macOS arm64 host; not verifiable from Linux |
| PR #54 → `v0.96.11-next.0` | MERGE after CI | Hash verified 2026-11-19: cask sha256 `9022593f…` == `veasel-macOS.tar.gz` in release `SHA256SUMS`/`release.json` (`4d34bb25`). Draft, mergeable, no status checks reported |

## veasel-labs/aur-package — 1 issue, 1 PR

| Item | Action | Evidence |
| --- | --- | --- |
| #17 Arch install E2E | IMPLEMENT | `accept-package-install.sh` exists; run in Arch container |
| PR #56 → `v0.96.11-next.0` | MERGE after CI | Hash verified: `c29e2704…` == `veasel-Linux.tar.gz` in release manifest. Draft, mergeable, no status checks reported |

## veasel-labs/.github — clean

0 issues, 0 PRs. No decorative work; audit only if consolidation requires it.

## ulises-jeremias/agent-toolkit — 24 issues, 11 draft PRs

Ownership rule: portable skills/agents/packs/CLI stay here; the Desktop
product runtime consolidates into Veasel. No draft merges blindly into
this repo's Desktop; each gets parity proof first (see epic §7/§8).

Draft PRs (all DRAFT, stacked): #1783 (base, hundreds of files), #1785,
#1786, #1788, #1789, #1790, #1793, #1794, #1796, #1799, #1808 (vendored
upstream skills — audit license/pins/permissions before any merge).
Per-PR disposition (PORT / EXTRACT / MERGE-portable / CLOSE-redundant)
is recorded here as parity evidence lands; none closed yet.

Issues by group — Desktop-migration (#1667 mission, #1668, #1669, #1670,
#1671, #1770, #1775): MIGRATE acceptance to Veasel, close only on parity.
World/UI (#1673, #1692, #1695, #1109): MIGRATE missing UX to Veasel.
Provider/skills (#1674, #1675, #1676, #1608, #1804, #1806): KEEP portable;
#1608 Gemini resume needs protocol proof or owner scope decision.
Security/release (#1672, #1677, #1777, #1055, #1059, #1060, #1063):
#1777/#1672 patch-or-retire with evidence; #1059/#1060 signing are
HUMAN BLOCKERS if certificates/accounts are absent — never claim signed.

## Human decisions required (minimum set)

1. `veasel-labs/agent-toolkit#10` — governance exception (owner only).
2. Signing/notarization credentials (macOS Apple ID/cert, Windows cert)
   for personal-toolkit #1059/#1060 and any signed-installer claim.
3. Website bot workflow approval if `action_required` recurs on the
   refreshed release PR.

## Checkpoint log

- 2026-11-19: M0 refreshed (49/14 confirmed). M1 fix opened as veasel#773.
  Homebrew#54 / AUR#56 hashes verified against `v0.96.11-next.0` manifest.
- 2026-11-19: Homebrew#54 merged (`350c6136`), AUR#56 merged (`d91a75df`)
  after approving the bot `action_required` runs (44480775612 / 44483268100);
  post-merge main CI green (44584805844 / 44584845108). Issues
  [homebrew#15](https://github.com/veasel-labs/homebrew-tap/issues/15) and
  [aur#17](https://github.com/veasel-labs/aur-package/issues/17) closed DONE
  with that evidence (unsigned installers and visual-TUI limits noted).
- 2026-11-19: Website#216 disposition = SUPERSEDE-pending. Its verifier
  requires `veasel-Windows.zip`; no complete release exists since Windows
  CI broke, so the hourly refresh correctly cannot advance. After #773
  merges and a complete release publishes, automation opens a fresh PR;
  #216 is then closed as superseded. Do not merge #216 (targets 0.95.0).
- 2026-11-19: #741 implemented as veasel#775 (MCP headers + OAuth refresh
  tokens into OS keychain, fake-backend migration/fail-closed/rollback
  tests green locally on Linux; native jobs on the PR are the platform
  proof). Remaining totals after closures: 47 issues / 16 PRs (incl. #773,
  #774, #775).
