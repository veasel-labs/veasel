# Triage ledger — cross-repo backlog consolidation

Epic: [#689](https://github.com/veasel-labs/veasel/issues/689) ·
ADR: [0001](../adr/0001-one-product-one-runtime.md) ·
Audit date: 2026-11-15 · Method: `gh issue/pr list --state open`
(74 open: 63 issues + 11 PRs), bodies inspected for all anchors.

Dispositions are **proposals**: SUPERSEDE closes only after the owner
confirms scope parity and a successor is linked; nothing was closed by
this audit. DONE = 0 intentionally — every candidate is still open and
the 10 Toolkit rescue PRs are unmerged drafts.

| Repo | KEEP | SUPERSEDE | REHOME | UNRELATED |
| --- | --- | --- | --- | --- |
| veasel-labs/veasel (13) | 13 | 0 | 0 | 0 |
| ulises-jeremias/agent-toolkit (33) | 26 | 7 | 0 | 0 |
| HorneroOS/hornero (11) | 9 | 0 | 1 | 1 |
| HorneroOS/shell (17) | 15 | 1 | 1 | 0 |

## veasel-labs/veasel — all KEEP under #549 / epic #689

#549 mission · #550 P0 real-binary journey · #552 P0 TUI/a11y ·
#553 P1 benchmarks · #629 sub-epic · #630→#629 routing/concurrency ·
#631→#629 isolation · #632→#629 handoff · #633→#629 TUI delegate ·
#637→#629 budgets · #638→#630 capability validation ·
#642→#631 implementer sandbox · #673→#553 OpenCode Responses case.

## ulises-jeremias/agent-toolkit

KEEP (15 issues): #1055, #1059, #1060, #1063, #1608, #1667, #1672,
#1674, #1675, #1676, #1677, #1692, #1770, #1775, #1777.
KEEP (11 PRs, stacked, preserve — do not close): #1783 base, then
#1793/#1794/#1788/#1790, #1785→#1786/#1789, #1796 (on
fix/focus-journal-private-root), #1799 (on #1793), #1803 direct to main.
SUPERSEDE (7, after owner parity confirmation): #1109→#1775/PR1783 ·
#1668→#1775/#1770/PR1788 · #1669→#1775/PR1793 · #1670→#1775/PR1793/1794
(retain as contract reference) · #1671→#1775/PR1783/1790/1793/1796 ·
#1673→#1775/PR1785/1789/1786 · #1695→#1775/PR1783.

## HorneroOS/hornero

KEEP (9): #62, #154, #178, #179, #180, #191, #407, #408, #414.
Note: #414/#408/#407 have merged PRs (#415/#411/#410) but remain OPEN —
acceptance closure, not reimplementation.
REHOME (1): #391 tracking → agent-toolkit#1674 (workflow runtime);
implementation slices #389/#390 stay in Hornero (already merged).
UNRELATED (1): #373 live Wi-Fi password bug.

## HorneroOS/shell

KEEP (15): #24, #77, #220, #221, #222, #227, #228, #237, #239, #240,
#257, #333, #352, #421, #423.
SUPERSEDE (1): #47→#228 (perf baseline remainder).
REHOME (1): #251 signing catalogue → HorneroOS/hornero#408+#180; shell
keeps only the client-enforcement slice.
