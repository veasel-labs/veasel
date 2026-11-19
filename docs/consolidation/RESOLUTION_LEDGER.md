# Resolution ledger — Veasel Labs ecosystem consolidation

Epic: [#689](https://github.com/veasel-labs/veasel/issues/689) ·
Supersedes the 2026-11-15 snapshot in [TRIAGE_LEDGER.md](TRIAGE_LEDGER.md)
(proposals only; kept for history).
Refreshed: **2026-11-19** from live `gh` state. Method: `gh issue/pr list`
+ main-branch SHAs + latest-main CI + release manifest verification.

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
