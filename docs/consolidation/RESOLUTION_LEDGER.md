# Resolution ledger — Veasel Labs ecosystem consolidation

Epic: [#689](https://github.com/veasel-labs/veasel/issues/689) ·
Supersedes the 2026-11-15 snapshot in [TRIAGE_LEDGER.md](TRIAGE_LEDGER.md)
(proposals only; kept for history).
This is an append-only record of dated checkpoints. The opening inventory is
historical (**2026-11-25 00:57 UTC**); the 18:21 inventory below is also
historical and superseded by the later checkpoint log. Do not use either table
for current backlog counts. Method: GitHub issue/PR queries, default-branch
SHAs, latest exact-head CI, release metadata, and host acceptance artifacts.

## Historical snapshot — 2026-11-25 18:21 UTC

| Repository | main SHA | Open issues | Open PRs | Current evidence |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `9d59d61697730e95b63c8fbf7adaef038e79935d` | 5 | 8 | #828 palette route fix merged; #829–833 and older #823/#826/#827 remain open; exact-main CI `45670879316` is in progress. |
| veasel-labs/agent-toolkit | `16eb93b22e2d1df44fbfcd88e3662321163c1743` | 0 | 0 | Marketplace governance issue #10 resolved; community plugin entries still await independent review. |
| veasel-labs/website | `4a708170ace9612171bbc8168d47574786a544c1` | 0 | 0 | Release metadata updated; build/deploy workflows green; live `/downloads/` shows v0.103.3-next.0 and unsigned status. |
| veasel-labs/homebrew-tap | `37ad7cfe0bb2b3d680d562ebca4108ef7bb31159` | 0 | 0 | Release cask merged; post-merge CI green. |
| veasel-labs/aur-package | `cfd14914e35b05c2a323ba2449d0fd02c18409a6` | 0 | 0 | Package CI and publisher green; AUR RPC reports v0.103.3.next.0-1. |
| veasel-labs/.github | `6c20f546bdf7768d7563a1f8e7f324205dea0eac` | 0 | 0 | No pending governance changes. |
| ulises-jeremias/agent-toolkit | `d3a8586362f684ca24f423384c65f7f753c6e3f2` | 0 | 1 | Release 1.51.0 PR #1854 (`f802ae5`): generated-bundle check passes; core CI is queued and some ancillary checks are pending. Live agent-toolkit.io promotes portable capabilities across agents. |
| ulises-jeremias/my-ai-workspace | `220d4750e9985248eddf7667671c32c60177cf5a` | 0 | 0 | Goal-loop handoff #14 and CI-reference correction #15 merged; post-merge CI is running. |
| **Total** | | **5** | **9** | Open work remains in Veasel and the Toolkit 1.51.0 release-prep PR. |

The immutable Veasel release `v0.103.3-next.0` and its consumers are now
synchronized. The host's packaged shared-listener startup passed in both
launch orders, but this release predates #821 and does not establish the
complete daily-driver acceptance in issue #550.

## Checkpoint 2026-11-25 00:57 UTC — Desktop runtime bridge and Focus acceptance

A fresh GraphQL inventory after release propagation and merge of personal
Toolkit PR #1849 found five open issues (all in Veasel) and one open PR (#816).
This is not a zero-backlog or final acceptance claim. Veasel exact-main CI is
still running on Windows; the personal Toolkit post-merge main CI has passed.
PR #816's first Focus run exposed a renderer/backend readiness regression: the
one-shot session load could run before the backend was ready. Hosted Focus
journeys J1-J11 now pass on head `ab98496`. The final change also fail-closes
when no proxy URL exists. Required platform checks on the current head remain
in progress.

| Repository | main SHA | Open issues | Open PRs | Latest evidence / note |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `5f374635a82407b605f073d6a2c16f41f2122efb` | 5 (#549, #550, #673, #689, #693) | 1 (#816) | Exact-main run [45511878769](https://github.com/veasel-labs/veasel/actions/runs/45511878769): Windows remains in the native OS keychain round-trip step. PR #816 head `ab98496` has hosted Focus J1-J11 passing in [45521502963](https://github.com/veasel-labs/veasel/actions/runs/45521502963); required platform CI [45521503252](https://github.com/veasel-labs/veasel/actions/runs/45521503252) is running. |
| veasel-labs/agent-toolkit | `416e7de7022a75249072a78971ded9a22fd1e9f3` | 0 | 0 | Registry validation [45406129549](https://github.com/veasel-labs/agent-toolkit/actions/runs/45406129549) passed. Owner-approved `veasel-essentials` exception is first-party only; PR #13 remains intentionally fail-closed pending independent permission review. |
| veasel-labs/website | `eb88a30ae83052e2d301d4327d258db5b5aee3f3` | 0 | 0 | Website validation [45509223211](https://github.com/veasel-labs/website/actions/runs/45509223211) and deploy [45509222983](https://github.com/veasel-labs/website/actions/runs/45509222983) passed. Live product/download pages advertise verified v0.102.4 assets. |
| veasel-labs/homebrew-tap | `4a8aa45aaad17dd4df3b2e7f7c6d0865f99f538d` | 0 | 0 | Exact-main CI [45509430347](https://github.com/veasel-labs/homebrew-tap/actions/runs/45509430347) passed. The formula/cask is CLI/TUI distribution; no Desktop cask is claimed. |
| veasel-labs/aur-package | `f71aaf339ee9e05dbea0e069059f017a4ade52fc` | 0 | 0 | Post-merge package validation [45512841094](https://github.com/veasel-labs/aur-package/actions/runs/45512841094) passed. PKGBUILD source verification passed for v0.102.4; AUR description now explicitly says CLI/TUI, not Desktop. |
| veasel-labs/.github | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | Existing validation [40167738112](https://github.com/veasel-labs/.github/actions/runs/40167738112) passed; no change required. |
| ulises-jeremias/agent-toolkit | `ec7c10bb8623024b865261451a8bddb64a37f902` | 0 | 0 | PR #1849 merged; all PR checks passed across Linux/macOS/Windows and docs preview deployed. Exact-main validation [45517764139](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45517764139) passed. |
| **Total** | | **5** | **1** | No unresolved Veasel issue is being closed to lower counts. |

### Current release and installed-host evidence

- Immutable Veasel release `v0.102.4-next.0` points to source SHA
  `f01173f294830523d21d402318a1d191d70a76a7`. Website, Homebrew and AUR
  consume that release; Linux AppImage/DEB, macOS ARM DMG, Windows x64 EXE,
  CLI/TUI archives and manifest/checksum assets were verified. Installers are
  unsigned; signing credentials remain unavailable.
- User-level TUI/CLI and Desktop AppImage are installed at `0.102.4-next.0`.
  The app launcher points to the new AppImage; the previous release and
  symlinks remain backed up. `veasel tui` rendered in an isolated disposable
  profile and exited cleanly. No coding prompt or paid-provider request was
  sent. Desktop was not relaunched while the user was working in Muse.
- The system AUR package is still **not installed**. The stale yay cache that
  caused the user's checksum error was repaired against the current AUR
  `master`, and `makepkg --verifysource` passed for the official archive. A
  local privileged package-manager run is still needed to install the system
  package; the user must run `yay -S --needed veasel-code-bin` in their own
  terminal.
- Claude Code native `auth status --json` verified a Claude.ai/MAX login;
  Codex native `login status` verified a ChatGPT login. OpenCode and Muse
  remain `unknown` because no supported non-billable authenticated probe was
  confirmed. A credentials file is not treated as proof. The prior screenshot
  used the old Desktop status text; Veasel PR #814 corrected native Claude and
  Codex status reporting.
- The user reported a live Muse session. It was not terminated, relaunched, or
  used for a paid prompt. Packaged Desktop approval-dialog and Desktop↔visual
  TUI same-session acceptance remain unverified on the installed host.

### Newly merged product-positioning work

Personal Toolkit PR [#1849](https://github.com/ulises-jeremias/agent-toolkit/pull/1849)
merged at `ec7c10bb8623024b865261451a8bddb64a37f902`. The root README now
centers portable skills/agents/workflows and labels the old Desktop captures
as a historical archive. Its architecture diagram shows one Veasel backend
shared by TUI and Desktop. Historical screenshots and PXL files were retained;
no runtime source or user data was deleted.

Veasel PR [#816](https://github.com/veasel-labs/veasel/pull/816), current head
`ab9849624fd89b3fe2bcbafa7b040d11f97c17d7`, rewires Desktop runtime status,
Focus URL, restart and workspace switching to the canonical V supervisor. It
also preserves Desktop-encrypted MCP environment credentials for a backend
Desktop owns, updates E2E backend selection and corrects the Desktop guide.
Local type-check, lint, 576 unit tests, 29 targeted regression tests and
`build:all` passed under resource-bounded `systemd-run`. GitHub required CI is
still pending; the packaged UI and shared-session acceptance remain unverified.
The first hosted Focus run failed J7; the trace showed direct backend-loopback
requests and an empty session list after restart. The renderer now gets the
protected proxy URL in backend events, and the readiness probe waits for the V
supervisor's `ready` state before returning that URL. Hosted Focus J1-J11 all
passed on head `ab98496` (run `45521502963`), including J7 persistence and J9
Desktop/TUI API same-session continuity. The final fail-closed adjustment
makes missing proxy URLs remain null in both startup and post-start IPC events.
Four focused unit tests, TypeScript check, and lint pass under resource-bounded
`systemd-run`; current-head platform validation remains in `45521503252`.
The old Toolkit-specific MCP provider catalog API/UI remains a separate open
migration item and is explicitly not claimed as completed by #816.

## Checkpoint 2026-11-24 22:09 UTC — post-merge verification

The native CLI authentication status change (#814) and portable-toolkit website
positioning change (#1848) are merged. Veasel `main` is now
`f01173f294830523d21d402318a1d191d70a76a7`; personal Toolkit `main` is
`968bbaa4483ee5133e8276b6494738b6796c4a28`. This checkpoint is deliberately
not green: exact-main Veasel CI `45496637250` has a failing TUI test while the
platform backend and test-shard jobs are running. The failure was in the
existing queued-follow-up UI test; the isolated test and the complete local
704-test TUI suite passed under a 3 GiB / 2 CPU `systemd-run` scope. A CI rerun
and completion of all exact-main jobs are still required. Personal Toolkit
validation `45495906604` is still running its macOS integration job; web,
CodeQL, and MegaLinter passed. No issue has been closed to lower counts.

| Repository | main SHA | Open issues | Open PRs | Current note |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `f01173f294830523d21d402318a1d191d70a76a7` | 5 (#549, #550, #673, #689, #693) | 1 (#813) | CI `45496637250` is not green yet: terminal test `queues a follow-up and cancels it without affecting the active turn` failed once; local isolated and full TUI suite passed. Windows/Linux/macOS backend jobs remain in progress. CodeQL `45496636752` passed. |
| veasel-labs/agent-toolkit | `416e7de7022a75249072a78971ded9a22fd1e9f3` | 0 | 0 | Registry state unchanged: first-party veasel-essentials exception is owner-approved; agent-toolkit-core and PR #13 remain fail-closed pending independent review. |
| veasel-labs/website | `9f3a2285bc7824ebb5c83ff721706ab460b6deb1` | 0 | 1 (#229) | Deployment `45465994338` passed. Consumer PR awaits a new immutable source release. |
| veasel-labs/homebrew-tap | `9f2ae8fac9b366b8dd0d19921681c2d53b127db7` | 0 | 1 (#69) | CI `45466285841` passed; consumer PR awaits a new immutable source release. |
| veasel-labs/aur-package | `eb01b95dca3123514162427b67facc86caf5af8b` | 0 | 1 (#71) | Package CI `45466040535` passed; host package installation still requires successful local `yay` completion. |
| veasel-labs/.github | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | No new changes. |
| ulises-jeremias/agent-toolkit | `968bbaa4483ee5133e8276b6494738b6796c4a28` | 0 | 0 | PR #1848 merged. Live `agent-toolkit.io` serves portable-capability positioning; web, CodeQL, and MegaLinter passed; exact-main Validate/macOS integration remains in progress. |
| **Total** | | **5** | **4** | No zero-backlog or all-green claim. |

### Newly completed evidence

- Veasel #814 merged at `f01173f`. Claude Code's native non-billable
  `claude auth status --json` reported `loggedIn: true`, method `claude.ai`,
  subscription `max`; Codex `login status` reported a ChatGPT login. The
  screenshot's “Auth file present; sign-in is not verified” was a detection
  limitation, not evidence of logout. OpenCode and Muse remain unknown because
  no safe supported auth-status probe was established. Quota is not inferred.
- #814 exact-head CI passed on PR head `1eb86653bcf495458aab8ee4d82fee0b0bee49c4`,
  including Windows/Linux/macOS backend tests and the native provider status
  tests. The new `main` run must still finish independently.
- Personal Toolkit #1848 merged at `968bbaa`. Local Astro checks/build and
  browser verification passed, including 14/14 Playwright cases. Production
  `www.agent-toolkit.io` returns 200, the apex redirects to it, and the new
  portable-toolkit Open Graph image is served as PNG. Historical Desktop
  content and governed PXL source assets were retained.
- Host's cached AUR source tarball was stale. Replacing only that cache entry
  with the official release archive made `makepkg --verifysource` pass and
  produced `veasel-code-bin 0.102.3.next.0-1`; system installation is still
  unconfirmed (`pacman` reported no system package), so do not count it as
  installed.

### Current open work at this checkpoint

| Item | Current owner/state | Remaining acceptance / dependency | Action / destination |
| --- | --- | --- | --- |
| [veasel#549](https://github.com/veasel-labs/veasel/issues/549) | OPEN; daily-driver mission | Representative real-provider coding, shared Desktop/TUI session, native packaged evidence, truthful auth/quota state | IMPLEMENT/VERIFY in Veasel; keep open |
| [veasel#550](https://github.com/veasel-labs/veasel/issues/550) | OPEN; packaged acceptance | Installed-binary real task, Desktop↔visual-TUI continuation, macOS/Windows provider journey | VERIFY in Veasel; keep open |
| [veasel#673](https://github.com/veasel-labs/veasel/issues/673) | OPEN; paid matched benchmark | Owner-approved spend and valid Meta credentials; do not run until both exist | HUMAN DECISION then IMPLEMENT in Veasel |
| [veasel#689](https://github.com/veasel-labs/veasel/issues/689) | OPEN; parent epic | Child milestones, immutable release propagation, installed-host acceptance, final reconciliation | KEEP OPEN; close last |
| [veasel#693](https://github.com/veasel-labs/veasel/issues/693) | OPEN; semantic World | Installed-app visual/accessibility QA and same-session lifecycle proof with preserved PXL assets | IMPLEMENT/VERIFY in Veasel |
| [veasel#813](https://github.com/veasel-labs/veasel/pull/813) | OPEN DRAFT; updates historical TRIAGE ledger, head `843797e0` | Its current snapshot is stale after #814/#1848; preserve useful historical findings and refresh the canonical ledger before disposition | REVIEW/MERGE updated evidence or SUPERSEDE only after all unique evidence is preserved |
| [website#229](https://github.com/veasel-labs/website/pull/229) | OPEN DRAFT; release consumer | Current source release `v0.102.3-next.0` is `immutable:false`; need a newer immutable release and exact asset validation | HOLD; refresh in website after qualifying Veasel release |
| [homebrew-tap#69](https://github.com/veasel-labs/homebrew-tap/pull/69) | OPEN DRAFT; CLI consumer | Same immutable source-release dependency; exact current version/archive/checksum | HOLD; refresh and verify in Homebrew |
| [aur-package#71](https://github.com/veasel-labs/aur-package/pull/71) | OPEN DRAFT; CLI/TUI package mirror | Same immutable source-release dependency plus successful local Arch package install/update/runtime/uninstall smoke | HOLD; refresh and verify in AUR |
| [agent-toolkit #13](https://github.com/veasel-labs/agent-toolkit/pull/13) | CLOSED/MERGED but fail-closed in catalog; no independent review | `veasel-essentials` owner exception is approved; `agent-toolkit-core` remains pending independent reviewer; do not install as reviewed absent valid state | HUMAN REVIEW for community entry; preserve `installable:false` |

The latest Veasel core CI is **not green** until every job on exact main SHA
`f01173f294830523d21d402318a1d191d70a76a7` completes successfully. Local full
TUI verification used the complete 704-test suite, not only the single failed
test. Do not interpret that local result as replacing hosted
Windows/macOS/Linux backend validation.

## Checkpoint 2026-11-24 20:29 UTC — live GitHub state

Five Veasel issues remain open, with five open PRs across four repositories.
The `#1845` personal-toolkit fixes are merged. Veasel main is green; PR #814
adds truthful native CLI sign-in reporting and is still in validation. No
unresolved item was closed to reduce the count.

| Repository | main SHA | Open issues | Open PRs | Current note |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `84906a0683231ee0b60b2aef6353caa9759e5a3d` | 5 (#549, #550, #673, #689, #693) | 2 (#813, #814) | Core CI `45443047471` green on this exact SHA. #814 CI is re-running after pinned-format and fixture corrections. |
| veasel-labs/agent-toolkit | `416e7de7022a75249072a78971ded9a22fd1e9f3` | 0 | 0 | Validation `45406129549` green. Creative Studio remains pending initial review and fail-closed; owner decision for the first-party exception is recorded in #10. |
| veasel-labs/website | `9f3a2285bc7824ebb5c83ff721706ab460b6deb1` | 0 | 1 (#229) | Deploy `45465994338` green. Consumer PR awaits a GitHub immutable release. |
| veasel-labs/homebrew-tap | `9f2ae8fac9b366b8dd0d19921681c2d53b127db7` | 0 | 1 (#69) | CI `45466285841` green. Consumer PR awaits a GitHub immutable release. |
| veasel-labs/aur-package | `eb01b95dca3123514162427b67facc86caf5af8b` | 0 | 1 (#71) | Package CI `45466040535` green. Consumer PR awaits a GitHub immutable release; host package install did not complete. |
| veasel-labs/.github | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | Validation `40167738112` green. |
| ulises-jeremias/agent-toolkit | `39a7f5468e09b53cc2f4d85b5794b8f58943e4ab` | 0 | 0 | Validate, MegaLinter and CodeQL `45383209055`, `45383209233`, `45383209108` green. `#1845` merged at `d7ac3ccc69f15b460d95ffc38d8ba1f4c09b9d26`. |
| **Total** | | **5** | **5** | No zero-backlog claim. |

### Current human/external blockers

- `veasel#673`: authorize a paid matched Meta/OpenCode benchmark, or keep the benchmark blocked without spending.
- `veasel#550`: native macOS/Windows packaged real-provider journeys require those platforms and usable accounts; CI-only platform validation is not product acceptance.
- AUR `veasel-code-bin`: the official cached archive checksum is corrected, but `pacman` currently has no system package installed. User-local CLI/TUI 0.102.3 is installed with the old 0.79.13 binaries backed up; system package installation still needs a successful local `yay` run.
- Release consumers `website#229`, `homebrew-tap#69`, and `aur-package#71` correctly remain pending because Veasel `v0.102.3-next.0` is reported mutable; no tag or published asset was changed.

### Latest changes in #1845

`skill_tree_drift` now sees hidden paths and reports a missing Creative Studio
plugin directory. Python audio cue analysis rejects a window starting after
track end. Provenance records now point at locked upstream commit
`7c98a0830fd2810c93b1f9da7d9edef98ed6ef8a` and no longer claim the old
reviewed-provenance digests; both skills remain experimental. The source skill
bodies independently match the respective pinned upstream bodies. V tests,
Python tests, skills validation, Agent Plugins validation, and provenance
checks passed locally under the requested resource limits. Hosted generation
completed at run `45322452797`; the temporary workflow was removed.

## Checkpoint 2026-11-24 03:34 UTC — live GitHub state

Historical checkpoint; superseded by the 03:50 refresh above.

This checkpoint supersedes the 02:34 snapshot below. It was refreshed from
GitHub at 03:34 UTC; PR counts include drafts and this ledger PR #807.

| Repository | main SHA | Open issues | Open PRs | Current note |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `eab88d598b5ab8329dabffcd45d35aa00e2a4cab` | 4 (#549, #550, #673, #689) | 1 (#807) | #804/#806 merged; exact-main CI `45307427282` has Linux domain tests and Windows batch 2 running; macOS and six Linux shards passed. Previous main run `45304821923` is green. #807 auto-merge is waiting on its exact-head Linux/Windows gates. |
| veasel-labs/agent-toolkit | `8205dd0e09ea6c74342503152b3fc71325be1351` | 0 | 1 (#13) | #14 merged; exact-main registry validation `45273303142` passed. #13 is open, ready for review, and held fail-closed by the owner's decision pending independent review. |
| veasel-labs/website | `a195dfcd34a0934a78cb07d3499c95e98d110a38` | 0 | 0 | Release consumers remain pinned to verified `v0.101.3-next.0`; not yet refreshed to current Veasel main. |
| veasel-labs/homebrew-tap | `a84ae2f260c17ec33872c2dd6bfc59003951b3ed` | 0 | 0 | Release consumer SHA matches the verified manifest; no open work. |
| veasel-labs/aur-package | `21d52c32f1d449c5cf2fb216b980e7870646d459` | 0 | 0 | Release consumer SHA matches the verified manifest; no open work. |
| veasel-labs/.github | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | No open work. |
| ulises-jeremias/agent-toolkit | `e050f5668ca7d462b9e3189f2834e20ab9f3efbc` | 1 (#1838) | 1 (#1845) | #1845 repairs Creative Studio resource generation; exact-head required CI is running. |
| **Total** | | **5** | **3** | No zero-backlog claim. |

### Historical open-item register — checkpoint 2026-11-24 03:34 UTC

| Item | State / owner | Existing implementation and exact evidence | Remaining acceptance / dependency | Action and destination |
| --- | --- | --- | --- | --- |
| [veasel#549](https://github.com/veasel-labs/veasel/issues/549) | OPEN; Veasel daily-driver mission | Linux packaged OpenCode red-to-green journey and deterministic Focus journeys are retained; core main CI `45443047471` is green at `84906a06` | Repeatable representative real-provider edits, visual-TUI continuation of the same Desktop session, native packaged journeys, truthful readiness and usage | IMPLEMENT/VERIFY in Veasel; keep open |
| [veasel#550](https://github.com/veasel-labs/veasel/issues/550) | OPEN; installed-binary acceptance | User-local Veasel CLI/TUI `0.102.3-next.0` installed from hash-verified release; TUI launched and exited cleanly in isolated profile; AppImage backend health was verified in an isolated profile | Real disposable coding task, Desktop↔visual-TUI same-session continuation, native macOS/Windows packaged-provider legs | VERIFY in Veasel; keep open until product evidence exists |
| [veasel#673](https://github.com/veasel-labs/veasel/issues/673) | OPEN; matched-provider benchmark | Benchmark wrapper/provenance and regression work are integrated on main; no new paid request made | Matched Meta/OpenCode run requires owner-approved paid usage and available Meta credentials; configured budgets do not prove spend | HUMAN DECISION, then IMPLEMENT in Veasel; keep open meanwhile |
| [veasel#689](https://github.com/veasel-labs/veasel/issues/689) | OPEN; cross-repository parent | Seven-repository live inventory and ownership model are refreshed above | All remaining child acceptance, immutable release propagation, host/product acceptance, and final issue/PR reconciliation | KEEP OPEN; close last |
| [veasel#693](https://github.com/veasel-labs/veasel/issues/693) | OPEN; real-data World | Existing PXL assets and semantic runtime implementation remain preserved; no replacement artwork generated | Visual QA on installed app, real session-to-Focus linkage and activity lifecycle, accessibility/performance, source asset license/provenance audit | IMPLEMENT/VERIFY in Veasel; keep open |
| [veasel#813](https://github.com/veasel-labs/veasel/pull/813) | OPEN DRAFT; cross-repository triage ledger | Draft refreshes the historical Nov 15 triage snapshot; previous PR checks passed on its exact head | Reconcile its ledger with the 20:29 state above and current PR/host evidence; exact-head checks after update | UPDATE/REVIEW, then merge to Veasel `main` if exact-head checks pass |
| [veasel#814](https://github.com/veasel-labs/veasel/pull/814) | OPEN; native provider sign-in status | Host checks confirm Claude `loggedIn=true`, Claude.ai/MAX and Codex ChatGPT login; pinned V unit tests and Desktop/TUI local checks pass | Latest exact-head CI after pinned formatting and fixture corrections; current head `f57f6d6` | REVIEW/VERIFY, then merge to Veasel `main` only after required checks pass |
| [website#229](https://github.com/veasel-labs/website/pull/229) | OPEN DRAFT; verified release consumer | Website main `9f3a2285`; workflow requires immutable release metadata and does not advertise missing assets | New immutable Veasel release and exact-version consumer validation | HOLD until source release is immutable; refresh/merge after validated update |
| [homebrew-tap#69](https://github.com/veasel-labs/homebrew-tap/pull/69) | OPEN DRAFT; CLI package consumer | Homebrew main `9f2ae8fa`; immutable-release guard and exact-version CI are green | New immutable release, then verify current CLI archive/checksum and update PR | HOLD until source release is immutable; refresh/merge after validated update |
| [aur-package#71](https://github.com/veasel-labs/aur-package/pull/71) | OPEN DRAFT; AUR CLI package mirror | AUR main `eb01b95d`; immutable-release guard and package CI are green | New immutable release and successful local Arch build/install/update/uninstall/runtime smoke | HOLD until immutable source release; retry local package install after user authorization |

Human/external dependencies currently evidenced: paid usage authorization and Meta credentials for #673; native macOS/Windows machines and usable provider accounts for #550; independent plugin trust review remains required before any pending catalog entry is installable; AUR system-package installation needs the user's successful local `yay` run; signing credentials are needed only if signed installers are required. Installers remain truthfully unsigned.

## Historical checkpoint 2026-11-24 02:34 UTC (superseded below)

This historical snapshot is retained to show prior state and evidence. Its
counts, registry review status, and active PR rows are not current.

| Repository | main SHA | Open issues | Open PRs | Current note |
| --- | --- | ---: | ---: | --- |
| veasel-labs/veasel | `eab88d598b5ab8329dabffcd45d35aa00e2a4cab` | 4 (#549, #550, #673, #689) | 1 (#807, this ledger) | #804/#806 merged; CodeQL `45307427273` passed; exact-main CI `45307427282` pending behind prior run `45304821923` (Windows batch 3 active); #807 auto-merge enabled, final-head checks pending |
| veasel-labs/agent-toolkit | `8205dd0e09ea6c74342503152b3fc71325be1351` | 0 | 1 (#13) | #14 merged; exact-main registry validation `45273303142` passed; #13 is open, not draft, and awaits independent review per owner |
| veasel-labs/website | `a195dfcd34a0934a78cb07d3499c95e98d110a38` | 0 | 0 | No open work |
| veasel-labs/homebrew-tap | `a84ae2f260c17ec33872c2dd6bfc59003951b3ed` | 0 | 0 | No open work |
| veasel-labs/aur-package | `21d52c32f1d449c5cf2fb216b980e7870646d459` | 0 | 0 | No open work |
| veasel-labs/.github | `7097e534eeafae932bcf427e12b0a5df398d9894` | 0 | 0 | No open work |
| ulises-jeremias/agent-toolkit | `e050f5668ca7d462b9e3189f2834e20ab9f3efbc` | 1 (#1838) | 0 | Umbrella issue still open |
| **Total** | | **5** | **2** | No zero-backlog claim |

Current Veasel main is four commits beyond the published release source
`1d041d86a19275b6c73e2c1750890dacaf18dd97`. The latest two feature changes
are PR #804 merged at `6bf9846454ed9ce6e3dbb2a2038ef20264789984` (SQLite store
locking for CLI approval/resume) and PR #806 merged at
`eab88d598b5ab8329dabffcd45d35aa00e2a4cab` (trusted sandbox executable
pinning). Both PR-head CI runs passed on Linux,
macOS, and Windows; exact-main CI for the latest SHA is queued and must pass
before the ecosystem can claim a green latest main or refresh the release.
The previous-main run `45304821923` is still active in Windows backend batch
3; its success is not a substitute for latest-SHA run `45307427282`.

Open Veasel work (no closure implied):

- [#549](https://github.com/veasel-labs/veasel/issues/549) — product mission;
  native packaged/provider acceptance remains incomplete.
- [#550](https://github.com/veasel-labs/veasel/issues/550) — Linux evidence is
  recorded, but packaged real-provider journeys on macOS and Windows remain
  unverified.
- [#673](https://github.com/veasel-labs/veasel/issues/673) — benchmark tooling
  and pinned binaries are prepared. No paid request was made: the approved Meta
  API key is currently absent from the profile and the `VEASEL_MODEL_API_KEY`,
  `META_API_KEY`, and `MUSE_API_KEY` environment variables. Preflight and the
  matched run remain blocked until the key is made available; aggregate cap is
  USD 5 including the previously recorded approximate USD 0.35444 spend.
- [#689](https://github.com/veasel-labs/veasel/issues/689) — parent epic stays
  open until all repository, release, provider, review, and issue acceptance is
  complete; close last.

Open Veasel PR:

- [#807](https://github.com/veasel-labs/veasel/pull/807) — this ledger refresh;
  its final-head CI is pending after permission-state correction in this
  document. Auto-merge is enabled but remains gated on required checks.

Open non-Veasel items:

- [official toolkit #13](https://github.com/veasel-labs/agent-toolkit/pull/13)
  — user explicitly chose to leave it pending. Its first-party creative-studio
  registry entry remains subject to an independent permission/trust review.
  The network flag is now truthful (`true`), but the pinned source omits the
  upstream `brag` assets/scripts its docs reference; see the static
  [supply-chain report](AGENT_TOOLKIT_CREATIVE_STUDIO_SUPPLY_CHAIN.md). Keep
  non-installable; do not self-approve or merge while acceptance is outstanding.
- [personal toolkit #1838](https://github.com/ulises-jeremias/agent-toolkit/issues/1838)
  — Creative Studio umbrella remains open. Its listed remaining acceptance
  includes a second-client real-provider edit, guest-image QA render scenario,
  live graphical integrations, durable flagship-film delivery, and external
  workstation review. This issue remains in the seven-repository open-issue
  count until those outcomes are completed or validly superseded.

Human/external dependencies currently evidenced: (1) an independent reviewer
for official toolkit #13; (2) the authorized Meta credential for #673 (do not
put credentials in GitHub); (3) macOS/Windows machines with provider accounts
for #550; and (4) Apple/Windows signing credentials only if signed installers
are required. Installers continue to be represented as unsigned.

Owner decisions recorded: registry #10 approved the first-party exception for
`veasel-essentials`; official registry PR #13 remains pending and is not
self-approved, per the owner's instruction. Its current head `6be6dc84`
declares `network:true`, matching the pinned `brag` and `brag-slim` source
skills at `7c98a083`; the PR's regression test checks that this capability is
disclosed. Both skills remain experimental upstream; #13 is non-installable
until an independent trust review is complete. The #10 outcome is reflected in
official toolkit main. A separate catalog audit found
`agent-toolkit-core`'s pending, non-installable entry had understated its
pinned source's shell hook and networked GitHub MCP as `shell:false` and
`network:false`; PR [#14](https://github.com/veasel-labs/agent-toolkit/pull/14)
corrected the metadata without changing its pending review or installability.
It merged at `8205dd0e09ea6c74342503152b3fc71325be1351`; exact-main registry
validation [#45273303142](https://github.com/veasel-labs/agent-toolkit/actions/runs/45273303142) passed.

Current distribution release: `v0.101.3-next.0`, targeting
`1d041d86a19275b6c73e2c1750890dacaf18dd97`; the GitHub release contains
Linux, macOS, and Windows CLI/Desktop assets plus `release.json` and
`SHA256SUMS` ([release](https://github.com/veasel-labs/veasel/releases/tag/v0.101.3-next.0)); manifest SHA-256 is
`e16d4d20283a6742f3bfbb1b6a1f4da8ca32d20459ede01f2e146829325eb725`.
This is newer than main `dd105961` and is not a claim that current main
itself was released. Independent verification found exact consumer pins
against the manifest: website `a195dfcd` CI/deploy/refresh success
(`45177649535`, `45177649646`, `45179468992`); Homebrew `a84ae2f2` cask SHA
`2aa33d87f8eb74bd8a5c6d7bd70a16b9e1210d5c43dc990a9b68a7eaded1b280`
equals manifest `veasel-macOS.tar.gz` (`45177863518`, updater `45176481350`);
AUR `21d52c32` SHA
`d3d4c907183ba8ab8852f8d8b885aedb11c1f783c7ce8d6782ec53f4267a838a`
equals manifest `veasel-Linux.tar.gz` (`45177921284`, publish
`45176500717`). Installers remain truthfully unsigned. The exact source SHA
`1d041d86` release run `45165644241` passed Linux/macOS/Windows backend,
all Linux shards, and Linux/macOS/Windows packaging/publish; later main SHA
`dd105961` CI `45224522194` also passed.

Since the prior checkpoint, benchmark regression PR
[#805](https://github.com/veasel-labs/veasel/pull/805) merged at
`b686997effd6cb6bb0683d8ddc8fa421670e517d`. It now rejects accidental
inheritance of `VEASEL_BENCHMARK_PROXY_KEY` by the OpenCode shell wrapper.
Its exact-head Linux/macOS/Windows CI was green, including six Linux shards
and the benchmark suite. This is only a regression guard: #673 remains open
for independently pinned wrapper provenance and the owner-authorized matched
provider run. Main CI on this exact merge SHA is still in progress.

Veasel issue [#693](https://github.com/veasel-labs/veasel/issues/693) was
closed on 2026-11-20 with packaged Electron workflow `44764165441`: the
World projects canonical Focus threads, opens the same thread, and reflects
thread deletion, with responsive zoom/reduced-motion coverage and pinned
governed sprites. Its closeout comment records 166 World/shell tests and the
570-test Desktop suite. This supports the issue's scoped implementation
acceptance. It does not establish a real external-provider World launch; that
broader product evidence remains part of #549/#550 and is not claimed here.

Current implementation candidate: veasel PR #804
(`https://github.com/veasel-labs/veasel/pull/804`) now contains the original
runner-selection commit from #803 (preserved as its parent commit) plus
installed-CLI approval review in the shipped Solid TUI. It supports provider
selection per session, terminal-safe input previews,
inspection-before-approval, fail-closed truncation handling, and one-at-a-time
decisions. Local validation on 2026-11-23: `bun run typecheck`, `bun run test`
(701 tests across 142 files), standalone `bun-linux-x64` build and `--version`
smoke passed; high/critical Bun audit and `git diff --check` passed. These
local checks used bounded `systemd-run` scopes. Previous head
`574626ef45eb445362630c455971a1237f238a44` exposed two stale expectations in
the common CLI review inventory; annotations on run `45269293587` identified
them. The fix restores CLI review inventory by default and opts the retired
Classic shell out explicitly because it has no safe CLI decision surface.
Failure diagnostics added in `f6e1283` capture backend/provider exit state,
listener reachability, and bounded log tails when the macOS packaged TUI
smoke fails. A second commit `995c675` redacts Authorization, bearer, and
API-key values from dict/JSON/plain-text logs; five local redaction cases and
Python syntax validation pass in bounded `systemd-run` scopes. These changes
aim to identify the cause of two prior macOS-only failures; no root cause has
yet been proven. Exact-head checks for the refreshed branch are queued;
required Linux/macOS/Windows backend and six Linux shards are pending.
Conditional PR package/release jobs do not establish packaged-release
acceptance. The CLI session in #550 remains NOT VERIFIED as a real-provider
coding journey after write approval was denied; see
https://github.com/veasel-labs/veasel/issues/550#issuecomment-7113850660.

The previous candidate head `8768a5d19e24f4d01f5b25e915e1e008cf374ab7`
passed targeted client, security, CodeQL, coverage and version checks. Its
six Linux extra-test shards passed before CI run
[45272119996](https://github.com/veasel-labs/veasel/actions/runs/45272119996)
was canceled after a review found a P2 availability issue: approval IDs were
marked notified before review-inventory loading succeeded, so a transient
failure could suppress retry. The poller now records IDs only after successful
handling and retries on callback failure. The new regression passes; full local
TUI validation passes 702 tests across 142 files plus typecheck. A new
exact-head native matrix must finish before merge. The earlier local run also
passed the standalone Linux client build/version smoke; pinned-V backend tests
passed on the same source ancestry, all under bounded local execution.

### Active issue/PR resolution register (live 2026-11-24 UTC)

| Repository/item | State / owner | Existing implementation and evidence | Remaining acceptance / dependency | Action and destination |
| --- | --- | --- | --- | --- |
| veasel#549 | OPEN; Veasel product mission | Current release and Linux packaged OpenCode red→green journey are recorded; deterministic Focus journeys and orchestration/security work are integrated | Independently repeatable provider edit + real visual-TUI same-session continuation; cross-platform packaged journeys; truthful readiness/usage | IMPLEMENT in Veasel; keep open until #550 and full mission gates pass |
| veasel#550 | OPEN; Veasel packaged acceptance | Existing packaged GUI evidence retained; PR #803 runner selection and #804 approval UI form a combined candidate; denied write approval is recorded as NOT VERIFIED | Exact-head CI; installed-binary edit with provider approval; same session reopened/continued in visual TUI and Desktop observes it; native platform legs | REVIEW/MERGE #804, then continue packaged journeys; no fabricated provider success |
| veasel#673 | OPEN; Veasel benchmark | PR #805 merged at `b686997`; 7 focused regression tests and the wrapper env-isolation integration pass; CI exact head passed all platforms | Independently pin/review wrapper provenance and decide/authorize matched provider run within the recorded $5 aggregate ceiling; no paid call made | IMPLEMENT in Veasel only after both safety/authorization gates; remain open |
| veasel#689 | OPEN; cross-repo parent | Release consumers hash-match v0.101.3-next.0; current main and ownership boundaries documented | All active child and external acceptance gates, final green latest-main CI, truthful release, issue/PR reconciliation | KEEP LAST; close only after all seven repos and external dependencies are reconciled |
| official agent-toolkit#13 | OPEN DRAFT; registry governance | Immutable pin `ulises-jeremias/agent-toolkit@cc5c60d48c18ff6b5788c08f38f681c933505fbe`; MIT; manifest says `network:false` while included `brag` skill declares `network:true`; fail-closed | Correct the permission declaration and obtain independent non-submitter review of the complete source; owner explicitly said leave pending | HUMAN REVIEW; keep draft and non-installable, never self-approve |
| personal agent-toolkit#1838 | OPEN; Creative Studio umbrella | Creative assets/workflow, Hornero adapters, docs, QA scenario, and Veasel runtime fixes are tracked; first-cut teaser exists in evaluation-host cache | Tool-capable model completes a real creative edit; guest-image QA run; graphical GIMP/OBS/REAPER; gated Blender Lab; durable final film; workstation review | IMPLEMENT/MIGRATE by canonical repo; keep open until each remaining acceptance is proven or explicitly descoped |
| veasel#803 | OPEN DRAFT; Veasel | Original runner-selection commit `9ca5c91b7b0bf0cb406705cad370deb947a756b5` is preserved as ancestor in #804 | No independent value after combined PR lands; don't abandon it before #804 merges | SUPERSEDE by #804 only after merge; close with exact merge SHA and checks |
| veasel#804 | OPEN; Veasel | Combined runner selection + approval UI, retry-on-inventory-failure fix; local 702/142 TUI suite and typecheck pass; failure diagnostics and credential redaction at `995c675` | Exact-head required checks on the refreshed branch are queued; investigate two prior macOS smoke failures from recorded diagnostics | REVIEW/MERGE only after exact-head required CI passes; then close #803 as superseded; follow with real-provider acceptance |

Destination for #13 is the official registry only after independent review;
personal portable content remains sourced by immutable reference. There are
5 open issues and 3 open PRs before #804 merge, including drafts.

External epic dependency (outside the seven-repository count):
[HorneroOS/shell#447](https://github.com/HorneroOS/shell/issues/447) remains
open. Veasel's current release contains `veasel-tui.desktop`; Hornero Shell's
generic app launcher discovers `DesktopEntries` and its launch adapter uses
`app2unit` when present, with a direct user-process fallback. Relevant source
regressions passed (69 tests under a bounded scope). The host's installed
Veasel is still `0.79.13-next.0` and lacks the current entry; actual launch,
canonical-session use, and cleanup are therefore NOT VERIFIED on this host.
The shell's Agent Center `horneroctl agent launch` remains accurately labeled
as a dry-run proposal and is not evidence of a real launch.

Benchmark #673 remains gated: no paid provider call until the benchmark
wrapper is independently reviewed and the Meta credential is rotated. The
user's aggregate $5 ceiling remains in force; no spend was incurred in this
checkpoint.

Personal Toolkit reconciliation: main is `e050f5668ca7d462b9e3189f2834e20ab9f3efbc`,
with only umbrella #1838 open and no open PRs. Ten legacy Desktop drafts
(#1783–#1799) are closed without merge; #1808 merged. Closure alone does not
prove the capabilities were migrated: maintain the per-PR parity map and
keep any genuinely missing behavior open in its canonical destination.

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
| 691 | Installed-CLI provider adapters | veasel | IMPLEMENT | PR pending: bounded native status checks verify Claude/Codex login without prompts; host reports Claude.ai MAX and ChatGPT login; quota remains unknown. OpenCode/Muse remain unverified. |
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
- 2026-11-25 16:50 UTC: release-sync audit for Veasel `v0.103.3-next.0`.
  GitHub reports the release immutable and published, targeting source
  `1ed9ae5f3c82c5e1f70a1cb48f91f6270c159c80`; `release.json` reports Linux,
  macOS arm64 and Windows x86_64 CI/assets published, with Desktop installers
  unsigned. The release `SHA256SUMS` entries agree with `release.json` digests
  and GitHub asset SHA-256 metadata for all listed payloads checked. The
  downloaded manifest includes `veasel-tui.exe` in `assets[]` and in
  `SHA256SUMS`; an earlier audit note claiming otherwise was incorrect. This
  is a metadata cross-check; the large binary payloads were not downloaded and
  rehashed independently.
  Website main `src/data/verified-release.json` and the Homebrew cask still
  point to `v0.103.2-next.0`; AUR `PKGBUILD`/`.SRCINFO` likewise still pin
  `v0.103.2.next.0`. There are no open PRs in the three consumer repositories.
  Follow-up at that checkpoint: refresh website verified release metadata,
  Homebrew cask version/SHA, and AUR PKGBUILD plus generated `.SRCINFO` against
  `v0.103.3-next.0`, then review consumer CI/deployment or package-publisher
  results. The manifest already included `veasel-tui.exe`; the earlier audit
  note claiming otherwise was incorrect. No external repository was changed
  during this audit.

- 2026-11-25 17:12 UTC: HorneroOS host acceptance of official `v0.103.3-next.0`
  was run only in isolated temporary profiles. The release manifest SHA-256
  is `c210c4a3…238c4b`; all nine payloads were downloaded, rehashed against
  both `release.json` and `SHA256SUMS`, and the source SHA is `1ed9ae5f`
  (#820 only). In the first run AppImage-first rendered Focus and shared its
  healthy backend PID with TUI. TUI-first rendered TUI, kept the same healthy
  backend PID and had no data-dir lock conflict, but Desktop did not reach the
  Focus route, so the run failed acceptance. A diagnostic rerun was
  intermittent: it did not consistently expose a renderer page and one
  instrumented AppImage launch exited 127. This prerelease lacks #821 and is
  not accepted for daily use; no installed path or user data was changed.
  Sanitized results and hashes: `/tmp/veasel-host-acceptance-v1033-summary.json`;
  full release artifacts and logs are under `/tmp/veasel-release-acceptance-v1033-full`
  and `/tmp/veasel-host-acceptance-run-20261125-v1033-p0`.

- 2026-11-25: latest verified Veasel main is
  `dcc7bd0e1cd17de48c6406fcb29fcffede03dd90`, including #824 (correlated
  Codex JSON-RPC handshake) and #825 (Cursor ACP discovery-only). #822 Goal
  intake is integrated at `ff1af49a08744cd8b8ce1fbc0bd90f72a32f1164`.
  Main CI run `45662840256` is still pending; watchdog `45662854547` passed
  but is not a substitute for the actual CI result.
  #826 preflight hardening is on `7dc61e49`; its current CI run
  `45662647961` remains in progress with Linux/macOS/Windows backend and
  several Linux shards pending. Its earlier package/publish failures belong
  to the old base/head and do not establish failure of the current run.
  #828 palette route fix remains open; CI run `45652358285` has all reported
  checks passed except Windows backend still in progress.
  #823/#826/#827 are based on synthetic branch `feat/durable-goal-intake`
  and are not yet integrated. #823's feature diff has been reconstructed on
  current main as PR #829 (`4fa09a16`); local `goals_test.v` passed and
  independent review found no blockers, while noting CLI end-to-end output
  coverage can be expanded. Equivalent main-based PRs #830 (`c27d8511`,
  preflight; two focused V test files passed) and #831 (`7caff3db`, task
  projection; two focused V test files passed) are now open. Independent Luna
  review found no task projection blocker; it confirmed the endpoint is
  authenticated, deterministic and read-only. All three replacements require
  their GitHub checks and merge before the old stacked PRs can close as
  superseded. Current Veasel inventory is five open issues (#549/#550/#673/
  #689/#693) and seven open PRs (#823/#826/#827/#828/#829/#830/#831).
  The other six repositories have zero open PRs/issues in the live snapshot;
  their latest main workflows are green. Personal Toolkit main is
  `d3a8586362f684ca24f423384c65f7f753c6e3f2`; marketplace main is
  `16eb93b22e2d1df44fbfcd88e3662321163c1743`; Homebrew `2c2c796c`, AUR
  `0d757707`, Website `a0d4eb1b`, org `.github` `6c20f546`. The release
  consumers are nevertheless one version behind (`v0.103.2-next.0` vs
  current `v0.103.3-next.0`). Website draft #234 (`5517a182`) and Homebrew
  #74 (`5a3508d8`) now propose that exact release. AUR draft #79 (`c3c0c01e`)
  is open; its candidate workflow `45665835206`
  verified checksums, regenerated `.SRCINFO`, and built/smoke-tested Arch.
  Its PR CI run `45666108454` was `action_required` with no jobs; GitHub's run
  payload identifies `github-actions[bot]` as actor but does not expose a
  reason. A clean human-authored replacement is being prepared to obtain the
  standard PR workflow. Homebrew's macOS workflow
  `45665957394` was queued/pending; its local verifier and eight Python tests
  passed. Website's release generator, Astro checks and formatting passed;
  preview check passed but remaining PR checks had not reported. None is
  merged/deployed. Local Homebrew/macOS package-manager acceptance is
  unavailable on this Linux host.

  The existing `~/.ai-workspace` loops were inventoried in its local report;
  the resumed Codex `veasel-labs` chat produced a read-only Goal v1 handoff at
  commit `fd94aa64` in branch `codex/goal-loop-adoption-20261125`. Private
  PR #14 is open. It preserves all seven loop YAML/state histories and
  records stale release-pilot base SHAs, missing installed Toolkit Goal CLI,
  and no verified Veasel dispatcher. No timers, loop triggers or dirty user
  checkouts were changed.

- 2026-11-25: reran shared-listener packaged acceptance against the
  same official v0.103.3 assets with a corrected route wait. The previous
  helper returned as soon as Electron exposed any page, before React Router
  redirected to Focus, producing a false negative for TUI-first. The corrected
  helper waits for `/#/focus`, records page URLs and persists `summary.json`.
  Both AppImage-first and TUI-first passed: TUI visible, Focus page visible,
  authenticated backend healthy, same backend PID before and after launching
  the second UI, and both isolated backends report `0.103.3-next.0`. Artifact
  hashes match the release manifest. Evidence: `/tmp/veasel-host-acceptance-run-20261125-v1033-routeprobe/summary.json`.
  This verifies shared-listener startup only. It is the #820 source release,
  so it does not validate #821 exact-file approval, an existing session's
  Desktop↔TUI continuation, a real provider edit, restart or recovery.

- 2026-11-25 17:50 UTC: distribution and Goal progress refreshed. AUR PR #80
  merged to main at `cfd14914e35b05c2a323ba2449d0fd02c18409a6`; its exact-main
  Package CI run `45667864928` passed all 23 tests and Arch package checks.
  The separately authorized publisher run `45668419628` passed immutable
  artifact checksum verification and Arch build/install smoke, then completed
  successfully; the public AUR RPC reports `veasel-code-bin 0.103.3.next.0-1`.
  The earlier accidental metadata push was reverted, and the downgrade-guard
  failure on that revert is superseded by reviewed PR #80 and its green main CI.
  Homebrew PR #74 merged as `37ad7cfe0bb2b3d680d562ebca4108ef7bb31159`;
  its exact-head cask check and main run `45668892548` both passed. Website PR
  #234, after being marked ready, merged as
  `4a708170ace9612171bbc8168d47574786a544c1`; its build and Vercel previews
  passed. Post-merge build/deploy runs `45668989306`/`45668989394` passed and
  the live homepage contains `v0.103.3-next.0`. Local macOS Homebrew installation
  is not proven on this Linux host.

  Goal PRs reconstructed directly on current Veasel main remain open:
  #829 CLI (`4fa09a16`), #830 repository preflight (`c27d8511`) and #831
  deterministic read-only task projection (`7caff3db`). #831's client,
  security, coverage, six Linux shards and macOS backend checks have passed;
  its Linux and Windows backends remain pending. #829 has passing client,
  security, coverage, six Linux shards and macOS backend checks; Linux and
  Windows backends remain pending. #830 has one Terminal client test failure;
  GitHub has not yet exposed the failed job log because its core CI run is
  still active, while multiple backend/shard jobs remain pending. Do not merge
  these PRs until exact-head required CI passes. Veasel main remains
  `dcc7bd0e1cd17de48c6406fcb29fcffede03dd90`; core CI `45662840256` is still
  pending without jobs, and green watchdog `45662854547` is not the core gate.
  The clean main-based PRs supersede the synthetic-base drafts #823/#826/#827
  only after the replacements merge.

  Personal Toolkit Goal v1 remains in main at
  `d3a8586362f684ca24f423384c65f7f753c6e3f2`; a release-preparation PR #1854
  now bumps the portable CLI to 1.51.0 and includes Goal v1 release notes.
  Its CI/review is pending. No tag, package publication or local CLI upgrade
  has occurred. Private `~/.ai-workspace` handoff PR #14 is updated at
  `dc7ad537d6d8590587ec33bf63f6758575cc9f15`; checks passed. It preserves the
  seven loop histories, does not change timers/triggers or dirty checkouts,
  and correctly records authenticated Veasel Goal admission as integrated
  while dispatch/scheduling/recovery remain absent. Its head was refreshed to
  `5f6c1084ca9db9eb986d85b42341c1a03561eb8d` with the latest #830 timeout,
  the #828-updated Veasel main pin and #1854's actual open-PR status. Luna
  review confirmed it touched no loops/timers/user data; updated checks passed
  and the documentation merged as `f569b67f3a122751aa32e315ffc6a08f26925efb`.

- 2026-11-25 17:58 UTC: packaged acceptance harness PR #832 is open at
  `d6ed413fdbf638946c2a330c35b8ed8f76bdffa9`. It records the earlier shared-
  listener PASS and a separate rerun that failed to reach Focus and later hit
  host disk quota; it does not overwrite the successful recorded run. Luna
  review approved the checked-in evidence scope and environment isolation.
  Child processes now receive a fixed environment that excludes inherited
  credentials, proxy values, display/DBus sockets and Veasel overrides; a
  focused test injects such values and confirms none leak; the focused test and
  syntax check are wired into Linux CI. Local checks passed (`py_compile`,
  focused test, artifact hash/trust-anchor verification, `--help`, evidence
  JSON parse and `git diff --check`). PR CI remains pending.

- 2026-11-25 18:02 UTC: PR #828 passed exact-head CI across Linux, macOS,
  Windows, Desktop, Terminal, Focus journeys, security and all Linux shards;
  Luna's independent review found no routing issue. It merged as
  `9d59d61697730e95b63c8fbf7adaef038e79935d`. The PR inventory is now seven
  open Veasel PRs (#823, #826, #827, #829, #830, #831, #832). Main run
  `45670879316` has started; verify its required jobs before claiming current
  main is green.

- 2026-11-25 18:14 UTC: a one-line follow-up PR #15 in the private workspace
  corrects the handoff's exact-main CI ID to `45670879316`. Luna confirmed that
  run is pending for SHA `9d59d61697730e95b63c8fbf7adaef038e79935d`; the
  documentation change passed `git diff --check`, with PR checks pending. It
  does not touch loops, timers, or user data.

- 2026-11-25 18:16 UTC: private workspace PR #15 passed Pre-commit and context
  schema checks, then merged as `220d4750e9985248eddf7667671c32c60177cf5a`.
  Its post-merge CI run `45673431723` is in progress; no loop data or timers
  were changed.

- 2026-11-25 18:17 UTC: PR #1854's generated-artifact failure was traced to a
  stale checked-in Goal v1 resource bundle. Commit `f802ae5c` regenerates the
  bundle and matching hash; hosted check #981 passes with matching size/hash,
  and Luna review found no issue. The exact-head workflow is queued with some
  ancillary checks still pending. No merge, tag, package publication, or
  installed CLI upgrade occurred. A live
  audit of `agent-toolkit.io` confirms it leads with portable skills, agents,
  MCP templates and workflows; it separates Veasel as the integrated app and
  lists other supported agent tools.

  The failed #830 Terminal job log is now accessible: the queue/cancel UI test
  made 705 of 706 tests pass, then timed out after its second queued-turn
  cancellation while waiting for the message to disappear from the frame.
  The log does not establish whether runner timing or product state caused it;
  rerun exact-head CI before changing product behavior. Main CI run
  `45670879316` is still pending; PR #832 CI `45670205816` remains in progress.

- 2026-11-25 18:21 UTC: ledger refresh PR #833 is open against Veasel main at
  head `17246c02a19afc4f4e802d160e8e27c48443816e`; its required checks have
  started and are pending. The inventory now includes this PR, for eight open
  Veasel PRs and nine open PRs across the tracked repositories.

- 2026-11-25 19:59 UTC: reconciled the user-approved 24-agent workflow plan
  with the current Veasel plan and the read-only `~/.ai-workspace` inventory.
  The ownership boundary is: Veasel owns runtime, persistence, scheduling,
  workers, GitHub reconciliation and evidence; personal Agent Toolkit owns
  portable contracts, validators and playbooks; `~/.ai-workspace` owns its
  existing seven loop definitions and histories; `agentic-workstation` and
  HorneroOS keep privileged desktop/OS actions; the Veasel Labs Toolkit is a
  reference-based plugin marketplace, not another runtime. Website, Homebrew,
  AUR and `.github` remain distribution and governance surfaces.

  Local loop evidence is preserved in
  `~/.ai-workspace/docs/LOCAL_LOOP_HANDOFF_INVENTORY.md`,
  `~/.ai-workspace/loops-scope.md`, the seven source `loop.yaml` files and
  `~/.ai-workspace/goals/veasel-release-sync-pilot.yaml`. The inventory found
  no active matching user timer and proposes Veasel read/report-only for the
  new Veasel-Labs scope of six loops, with OSS triage draft-only. Original loops
  retain their existing permissions for existing scopes until separately
  migrated. The pasted plan reports an orphaned user systemd link whose service
  is `not-found`; the inventory does not establish this, so do not remove any
  timer/link until ownership and other schedulers are checked. The broad
  `loops-scope.md` repository list differs from the three OSS loop YAML scopes;
  each future goal/adapter must carry an explicit repository and
  `(repository, effect)` ownership manifest enforced by the executor. Cover
  issue/PR create and update, assignment, labels, comments, commit, push, close,
  merge, and release publication. No loop definition, state, report, pack,
  policy or trigger was modified. Old tier notes conflict with current loop
  YAML; current YAML and the dated inventory remain authoritative. Keep any
  private name-to-role mapping in a restricted local record, not this public
  ledger.

  The existing release-sync goal is report-only and names four public
  checkouts. Their base SHAs were pinned when the manifest was created but may
  now be stale; perform current repository preflight and revalidation before
  dispatch. Keep it intact; #550's packaged Linux Claude Code/Codex
  product journey needs a separate product-pilot manifest with its own
  permissions and evidence. Treat the pasted #819 baseline as unverified
  until installed and executed versions, source/workspace SHAs, session,
  permissions and receipts match. Do not close #550, #673 or #689 from plan
  text alone. Session-turn persistence and the deterministic task projection
  remain distinct from a scheduler, leases, evidence receipts, dispatch or a
  GitHub publisher; those remain incomplete.

  The user workflow adds these acceptance gates: Toolkit v1 offline
  validation/planning and five portable playbooks with Swarm compatibility;
  a distinct V goal scheduler and API/CLI/TUI/Focus surfaces; independent
  verifier receipts tied to exact candidate SHA and artifact digest; GitHub
  App intake separated from an idempotent draft publisher; local draft-only
  pilots before remote Linux workers; authenticated SSH tunnels, rootless
  disposable worktrees, resource limits, and publication credentials isolated
  from workers; recovery, cancellation, duplicate-effect and rollback tests;
  staged 8/12/16/24-worker runs; and a real 24-worker run with live processes
  and leases. A merge canary must verify the exact SHA, required checks,
  merge-queue candidate where applicable and post-merge `main` before widening
  automation. The existing TUI queue is not this scheduler.

  Pstack's overnight guide is a workflow reference, not a code dependency:
  earn autonomy through watched runs and checkable finish conditions, isolate
  worktrees, log each decision with evidence, pause with a resume checkpoint,
  and use an independent reviewer on a different model family. A standing
  coordinator delegates and verifies but does not implement task code. The
  complete staged checklist now lives in `docs/IMPLEMENTATION_PLAN.md`.

  `ulises-jeremias/agent-toolkit` and `veasel-labs/agent-toolkit` remain
  distinct repositories: the former owns portable tools and the latter owns
  the official marketplace registry. Personal PR #1854 remains open pending
  independent human review; no release/tag was published. Optional Desktop
  cask and `veasel-desktop-bin` work remains local-only and unverified. Existing
  CLI/TUI AUR publication is recorded in the earlier package entry; no Desktop
  package registration or publication has occurred. The Visual workshop design
  PR #834 is still gated on exact-head backend CI; screenshots reviewed so far
  came from a local frontend preview, not the installed app.

- 2026-11-25 20:12 UTC: optional Desktop distribution work reached local
  acceptance in both consumer repos, but remains uncommitted/unpublished and is
  awaiting independent review. Homebrew branch `codex/optional-desktop-installers`
  verifies the real DMG against the official release manifest/API and cask
  digest; 11 unit tests, Python compilation, workflow YAML/shell checks, and
  `git diff --check` pass. This host has no Homebrew/Ruby, so `brew style` and
  local cask install remain for macOS CI. AUR branch `codex/aur-desktop-option`
  passes 25 tests, Python/YAML/shell checks, exact `.SRCINFO` generation, and
  an Arch Docker build/install/uninstall acceptance for CLI/TUI and optional
  Desktop. No commit, push, PR, or AUR write has happened. The Desktop package
  is not registered in AUR; the prior CLI/TUI AUR publication remains as
  recorded above.

- 2026-11-25 20:17 UTC: PR #830 merged to Veasel main as `acece001`. Earlier
  ledger entries that still describe #830 as open are historical snapshots
  from before the merge. Its exact-main CI run `45683259590` remains pending;
  this records the merge and does not claim current main CI is green.

- 2026-11-25 20:18 UTC: Homebrew tap commit `4b885ff33b68e014551744fbd137c792601ce27a`
  (`Add optional Veasel Desktop cask`) landed directly on `main`, instead of
  the requested feature-branch PR, because the local checkout inherited global
  `push.default=upstream` while its feature branch tracked `origin/main`. Luna
  had reviewed the commit and local checks passed; the commit adds the optional
  ARM64 Desktop cask, manifest/signature-aware release verification, updater,
  and install/uninstall CI. No history rewrite or revert was attempted. Main
  CI run `45693669062` is queued; do not treat this integration as green until
  its exact-SHA macOS cask job passes. Local push configuration is now
  overridden to `current` in the Homebrew and AUR worktrees; use explicit
  branch refspecs for future pushes.

- 2026-11-25 20:24 UTC: Homebrew exact-main CI run `45693669062` remains queued
  for commit `4b885ff33b68e014551744fbd137c792601ce27a`. AUR package PR #81 is
  open as a draft at `f4829444fac8b351f0c0641b195764dde0151619`; it adds the
  optional Desktop package and keeps first registration behind the
  `publish-approved` workflow. Its Arch Package CI run `45694541688` is queued.
  The exact hashes and local Arch build/install/uninstall acceptance are in
  the PR body. No AUR publisher workflow, AUR RPC write, or first Desktop
  package publication has occurred.

- 2026-11-25 20:45 UTC: Distribution state reconciled. AUR package PR #81
  merged as `3c41c7046abfe6c7dcf9b0d4be963c6bad6b6961`; publisher run
  `45695024912` succeeded and AUR RPC reports `veasel-desktop-bin
  0.103.3.next.0-1`. Homebrew main CI run `45693669062` failed because the
  cask lacked `depends_on :macos`; fix PR #75 (`401cfeda`) passed its macOS
  cask CI and merged at `6ef7575145e6433b5fddad35c4d1848abd13cf8e`.

- 2026-11-25 20:45 UTC: Veasel PR #831 (deterministic goal task projection)
  merged as `7fc47928`; pixel-art workshop PR #834 merged as `bd4a8adc`.
  PR #834's preview screenshots are not installed Desktop acceptance. New PR
  #835 adds durable task/attempt state after #831; Luna static review found
  and verified fixes for unverifiable process identity, typed lifecycle
  states, and atomic state/attempt completion. The pinned-compiler CI is
  pending; local V 0.5.2 cannot parse existing `provider.v` syntax and is not
  the pinned compiler. Personal Agent Toolkit PR #1855 adds explicit `fixture`
  evidence mode; four JSON Schema checks and focused Goal V tests passed
  locally, with full PR CI pending. The seven existing
  `~/.ai-workspace/loops` definitions and scheduler state were not modified.

- 2026-11-25 20:48 UTC: Website fallback generator advanced the verified
  download metadata to `v0.104.0-next.0` after validating the remote release,
  checksums, manifest, and asset digests. Website PR #235 contains only the
  generated fallback and is awaiting CI. Homebrew fix PR #75 merged after its
  cask check passed. Keep `agent-toolkit.io` on the personal Toolkit portable
  capabilities track; this website sync only refreshes the Veasel downloads.
