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
| [veasel-labs/veasel](https://github.com/veasel-labs/veasel) | 1d041d86a19275b6c73e2c1750890dacaf18dd97 | 4 | 1 | Exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) passed all backend, Linux shard, security, Desktop/Terminal, and Linux/macOS/Windows package jobs. Updated #549 with current product evidence and open gates ([comment](https://github.com/veasel-labs/veasel/issues/549#issuecomment-7102509149)). Ledger PR #802 is open; its earlier exact-head run [#45175730133](https://github.com/veasel-labs/veasel/actions/runs/45175730133) was cancelled because this ledger snapshot changed; no pass is claimed. |
| [veasel-labs/agent-toolkit](https://github.com/veasel-labs/agent-toolkit) | 2096315d10ccdb19b1cb8ea071986bd2c641eb89 | 0 | 1 | Owner-approved first-party `veasel-essentials` exception merged in [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12). [PR #13](https://github.com/veasel-labs/agent-toolkit/pull/13) remains open and non-installable by the owner's decision; independent review is still required, and `network:false` conflicts with the vendored `brag` skill's declared network permission. |
| [veasel-labs/website](https://github.com/veasel-labs/website) | a195dfcd34a0934a78cb07d3499c95e98d110a38 | 0 | 0 | Release metadata PR #227 merged for v0.101.3-next.0; exact-head CI [#45176846478](https://github.com/veasel-labs/website/actions/runs/45176846478), exact-main CI [#45177649535](https://github.com/veasel-labs/website/actions/runs/45177649535), and deployment [#45177649646](https://github.com/veasel-labs/website/actions/runs/45177649646) passed. |
| [veasel-labs/homebrew-tap](https://github.com/veasel-labs/homebrew-tap) | a84ae2f260c17ec33872c2dd6bfc59003951b3ed | 0 | 0 | Cask update PR #67 merged for v0.101.3-next.0; exact-head install/upgrade/runtime/uninstall CI [#45177514872](https://github.com/veasel-labs/homebrew-tap/actions/runs/45177514872) and exact-main CI [#45177863518](https://github.com/veasel-labs/homebrew-tap/actions/runs/45177863518) passed. |
| [veasel-labs/aur-package](https://github.com/veasel-labs/aur-package) | 21d52c32f1d449c5cf2fb216b980e7870646d459 | 0 | 0 | AUR mirror PR #69 merged for v0.101.3-next.0; publisher run [#45176500717](https://github.com/veasel-labs/aur-package/actions/runs/45176500717) built and published it to AUR, and exact-main Package CI [#45177921284](https://github.com/veasel-labs/aur-package/actions/runs/45177921284) passed. PR event was `action_required`, not counted as a pass. |
| [veasel-labs/.github](https://github.com/veasel-labs/.github) | 7097e534eeafae932bcf427e12b0a5df398d9894 | 0 | 0 | No organization-level change is currently required. |
| [ulises-jeremias/agent-toolkit](https://github.com/ulises-jeremias/agent-toolkit) | 69e92db9eafdedf66ae648fea8af480e7fb5d60c | 1 | 2 | Issue [#1838](https://github.com/ulises-jeremias/agent-toolkit/issues/1838) remains open. PR #1839's restricted source is blocked; #1842 merged the fail-closed updater policy; #1843 isolates the license-verified MIT `unslop` update. Exact-main Validate [#45192646990](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45192646990) is running on this SHA; CodeQL [#45192646984](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45192646984) passed and MegaLinter [#45192647375](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45192647375) is running. |
| **Total** | — | **5** | **4** | Four Veasel issues and personal Toolkit #1838 remain open. Open PRs: Veasel #802, official registry #13, personal Toolkit #1839 and #1843. |

This snapshot was refreshed on 2026-11-23 by re-querying all seven GitHub repositories. It records five open issues and four open PRs, including this ledger PR and the still-pending official registry #13 and personal Toolkit PRs #1839 and #1843. Personal Toolkit PR #1842 has merged at `69e92db9eafdedf66ae648fea8af480e7fb5d60c`; PR-head CI passed 50 checks with three conditional skips, while exact-main Validate is still running. Veasel main is `1d041d86`; its exact-main run [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) passed every required backend, shard, security, client, and packaging job. The packaged MCP smoke used a local deterministic provider, the installed MCP server and a separately approved read/write boundary probe; no paid provider call occurred. Current issue/PR state is authoritative over older historical counts.
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
| [Veasel #802](https://github.com/veasel-labs/veasel/pull/802) | OPEN DRAFT · cross-repository ledger refresh · this ledger commit is the PR head; use the linked PR for its exact OID because recording its own OID would change that OID | Refreshes the seven-repository inventory, dispositions, and current CI/evidence state; the snapshot records 5 open issues and 4 open PRs. | Veasel `docs/consolidation/TRIAGE_LEDGER.md`; earlier exact-head run [#45175730133](https://github.com/veasel-labs/veasel/actions/runs/45175730133) was cancelled after the snapshot changed. | Push this snapshot, rerun exact-head required checks, then merge through the established branch policy. |
| [official registry #13](https://github.com/veasel-labs/agent-toolkit/pull/13) | OPEN · community Creative Studio plugin by reference · head `ff6a56316dfa00ce9147f54d4880a2ad3c6af6cf` | User decision: leave pending. Requires independent maintainer review. Source is pinned at `cc5c60d48c18ff6b5788c08f38f681c933505fbe`; no source is copied. `network:false` conflicts with `skills/brag/SKILL.md` declaring `security.network:true`. | Registry CI [#45112445890](https://github.com/veasel-labs/agent-toolkit/actions/runs/45112445890) passed; entry remains `installable:false`. | Keep pending and fail-closed. Correct permission metadata, audit capabilities/provenance, then obtain independent review. Never self-approve or mark installable before review. |
| [personal Toolkit #1839](https://github.com/ulises-jeremias/agent-toolkit/pull/1839) | OPEN DRAFT · upstream skill sync · head `8ba04e205a00ed80ffe675bdbaef83a7b3c7f1e7` | Review exact upstream diff, license, attribution and permissions. The `web-design-guidelines` source has `NOASSERTION` licensing and distribution restrictions; the `command.md` source declares MIT but does not grant rights to the entire vendored skill. | Personal Toolkit; no destination outside the portable capability repository. | Keep pending until licensing and provenance for every vendored file are resolved; do not merge experimental/unreviewed content as trusted. |
| [personal Toolkit #1843](https://github.com/ulises-jeremias/agent-toolkit/pull/1843) | OPEN DRAFT · license-verified `unslop` upstream refresh · head `3d7d630dfd62e67a6095387e2ff796902b8bff5d` | Includes only `quality/unslop` at `cursor/plugins@2f87c854`; excludes the `web-design-guidelines` wrapper from #1839. Updates the stale per-skill pin and corrects its trust label to experimental. | Upstream MIT license checksum exactly matches; permission declarations unchanged and false/empty. Local provenance, upstream, skills, and diff checks pass. Exact-head validation [#45185796258](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45185796258) passed 51 checks with three conditional skips; CodeQL [#45185796350](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45185796350) passed. | Mark ready and merge after #1842 exact-main CI passes; then close #1839 only as a rejected restricted update, explicitly recording that the license-verified `unslop` portion was preserved in this PR. |

Merged during this audit:

- [personal Toolkit #1841](https://github.com/ulises-jeremias/agent-toolkit/pull/1841) merged as `2a032f2fbf91a36edf4784b907489a19bb8f79f7` after exact-head Linux/macOS/Windows integration and security checks passed. The `setup-uv` v10.4.0 pin matches upstream tag commit `1db35dd8eee11c5894872e0b383ae6c406cf738d`.
- [personal Toolkit #1840](https://github.com/ulises-jeremias/agent-toolkit/pull/1840) merged at `465a8d69f71224259e035ca35c4d3ee54c30d3df` after exact PR-head validation run [#45172137137](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45172137137) passed. It records packaged MCP and creative-tool compatibility evidence while explicitly leaving real-provider creative edits and same-session visual TUI continuation unverified. Post-merge main runs [#45179562504](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45179562504) and [#45179562294](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45179562294) were queued/in progress at capture.
- [personal Toolkit #1842](https://github.com/ulises-jeremias/agent-toolkit/pull/1842) merged at `69e92db9eafdedf66ae648fea8af480e7fb5d60c` after exact-head CI [#45186218528](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45186218528) passed 50 checks with three conditional skips, including macOS/Linux V module and Swarm E2E jobs; CodeQL [#45186218253](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45186218253) passed. Exact-main Validate [#45192646990](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45192646990) and MegaLinter [#45192647375](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45192647375) are still running at this snapshot; CodeQL [#45192646984](https://github.com/ulises-jeremias/agent-toolkit/actions/runs/45192646984) passed. The change blocks automatic redistribution of policy-restricted sources and removes stale human review attribution when content is updated.

Merged since prior ledger snapshot:

- Website [#226](https://github.com/veasel-labs/website/pull/226) merged at `afb040fc5323a21b4068301ca3e92eeb8f0301f6`; exact-main CI [#45174518559](https://github.com/veasel-labs/website/actions/runs/45174518559) and deployment [#45174518531](https://github.com/veasel-labs/website/actions/runs/45174518531) passed.
- Homebrew [#66](https://github.com/veasel-labs/homebrew-tap/pull/66) merged at `10c4e1bd1093cef50120b07d70cd19953968bebd`; exact-main macOS install/upgrade/runtime/uninstall CI [#45174595770](https://github.com/veasel-labs/homebrew-tap/actions/runs/45174595770) passed.
- AUR mirror [#68](https://github.com/veasel-labs/aur-package/pull/68) merged at `4240773a2d844189251df601524d44a0681b7c1b`. The publisher run [#45171464630](https://github.com/veasel-labs/aur-package/actions/runs/45171464630) regenerated `.SRCINFO`, built the Arch package and published the exact package metadata to AUR. Its GitHub PR event [#45171635702](https://github.com/veasel-labs/aur-package/actions/runs/45171635702) was `action_required`; exact-main Package CI [#45174696226](https://github.com/veasel-labs/aur-package/actions/runs/45174696226) passed.
- Website [#227](https://github.com/veasel-labs/website/pull/227) merged at `a195dfcd34a0934a78cb07d3499c95e98d110a38` for release `v0.101.3-next.0` from Veasel `1d041d86`. Exact PR-head CI [#45176846478](https://github.com/veasel-labs/website/actions/runs/45176846478), exact-main CI [#45177649535](https://github.com/veasel-labs/website/actions/runs/45177649535), and deployment [#45177649646](https://github.com/veasel-labs/website/actions/runs/45177649646) passed.
- Homebrew [#67](https://github.com/veasel-labs/homebrew-tap/pull/67) merged at `a84ae2f260c17ec33872c2dd6bfc59003951b3ed`; exact PR-head install/upgrade/runtime/uninstall CI [#45177514872](https://github.com/veasel-labs/homebrew-tap/actions/runs/45177514872) and exact-main CI [#45177863518](https://github.com/veasel-labs/homebrew-tap/actions/runs/45177863518) passed.
- AUR mirror [#69](https://github.com/veasel-labs/aur-package/pull/69) merged at `21d52c32f1d449c5cf2fb216b980e7870646d459`; publisher [#45176500717](https://github.com/veasel-labs/aur-package/actions/runs/45176500717) built and published the package, while exact-main Package CI [#45177921284](https://github.com/veasel-labs/aur-package/actions/runs/45177921284) passed. The action-required PR event is not claimed as a pass.
- [veasel#799](https://github.com/veasel-labs/veasel/issues/799) closed as DONE after packaged MCP invocation, explicit session workspace grant/revocation and outside-path denial; full exact-main backend/shard/security/client/package CI passed on `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Evidence: [issue comment](https://github.com/veasel-labs/veasel/issues/799#issuecomment-7101176559), main run [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241).
- [veasel#800](https://github.com/veasel-labs/veasel/pull/800) merged as `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed all required jobs, including Linux/macOS/Windows backends and package smoke. Exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) subsequently passed every backend, shard, security, client and package job.
- [veasel#801](https://github.com/veasel-labs/veasel/pull/801) was closed as **SUPERSEDED** after its session workspace permission implementation was copied into #800. The PR #800 package artifact passed installed MCP invocation and workspace boundary checks; the initial synchronous approval harness timed out, then the durable async operation completed after explicit approval. Full evidence appears under #799.
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
## Issue dispositions and required resolution

### veasel-labs/veasel#799 — RESOLVED: trusted MCP stdio executable/workspace sandbox

- **State / owner:** CLOSED DONE · Veasel MCP runtime and session permission UI.
- **Dependencies:** none remain for the reported sandbox regression.
- **Existing implementation:** Linux Bubblewrap masks home/tmp, which hides user-installed MCP executables. Existing trust was per-session but had no separate workspace write grant.
- **Change/evidence:** PR [#800](https://github.com/veasel-labs/veasel/pull/800) merged at `1d041d86a19275b6c73e2c1750890dacaf18dd97`. Its exact PR-head CI [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) passed Linux/macOS/Windows backend, Linux shards and package jobs. The change preserves PATH symlink lookup while exposing only executable/interpreter trees read-only, and adds the explicit, revocable per-session workspace write grant; legacy trust migrates without a write grant.
- **Packaged evidence:** the Linux artifact from PR run [#45153660067](https://github.com/veasel-labs/veasel/actions/runs/45153660067) ran the installed `mcp-kdenlive` server via its home-installed PATH command; a local deterministic OpenAI-compatible fixture requested the read-only `diagnose_environment` call, the call was inspected and explicitly approved, and the packaged operation completed through required Bubblewrap. A second packaged MCP fixture wrote a marker inside the explicitly granted session workspace and reported that a sibling outside sentinel was unreadable; the marker was visible on the host and the outside sentinel remained unchanged. Both used disposable data/workspace directories and zero paid provider calls. An initial synchronous harness waited on the approval gate until its timeout; switching to the durable operation and approving the inspected MCP call completed successfully. This was a harness correction, not a product timeout.
- **Resolution:** exact-main CI [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241) succeeded on `1d041d86a19275b6c73e2c1750890dacaf18dd97`, including Linux/macOS/Windows backends, all six Linux shards, security, Desktop/Terminal, and Linux/macOS/Windows packaging. Packaged acceptance and grant lifecycle are recorded in [the issue evidence](https://github.com/veasel-labs/veasel/issues/799#issuecomment-7101176559); issue closed completed.
- **Action:** DONE in `veasel-labs/veasel`, commit `1d041d86a19275b6c73e2c1750890dacaf18dd97`; exact-main and packaged evidence linked above.

### veasel-labs/veasel#549 — daily-driver product mission

- **State / owner:** OPEN · Veasel runtime, Desktop, TUI, provider adapters.
- **Dependencies:** #550 packaged real-provider journeys; #673 controlled
  benchmark; parent reconciliation in #689.
- **Evidence:** packaged Linux OpenCode coding, approval/denial, cancellation,
  independent red-to-green verification, restart persistence, and same-session
  visual TUI continuation are recorded in [#550's Nov 20 evidence
  update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7034671256).
  A new packaged Linux Claude Code run is recorded in [#550's Nov 23 update](https://github.com/veasel-labs/veasel/issues/550#issuecomment-7090028693) and PR #794: it independently changed a parser and passed seven red-to-green assertions, with two approved tools and durable completed SQLite state. Playwright approval automation detached, so its evidence is not a fully stable GUI automation pass; provider model and cost remain unknown. The parent status was refreshed in [#549's Nov 23 update](https://github.com/veasel-labs/veasel/issues/549#issuecomment-7102509149). Current release and CI evidence is listed above.
- **Remaining acceptance:** repeatable representative tasks on installed
  binaries; native macOS and Windows real-provider journeys; visual-TUI
  continuation from that Claude session; durable crash/restart outcome; and
  transparent recovery/usage evidence. Do not reuse deterministic fixtures as
  real-provider proof.
- **Action:** KEEP OPEN. Continue implementation and platform acceptance in
  `veasel-labs/veasel`; resolve only with independent packaged evidence and
  links in the issue. Current destination is `main` at
  `1d041d86a19275b6c73e2c1750890dacaf18dd97`; no final
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
  passed on SHA `240d95e`. The latest Veasel main `1d041d86` also passed all
  required checks in [#45165644241](https://github.com/veasel-labs/veasel/actions/runs/45165644241); this does not prove a live matched benchmark. Network-namespace
  enforcement remains unverified on hosted runners; prior local Arch evidence
  is recorded separately.
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

As of 2026-11-23, the latest published release is
[`v0.101.3-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.101.3-next.0),
source `1d041d86a19275b6c73e2c1750890dacaf18dd97`. GitHub reports SHA-256
digests for `release.json`, `SHA256SUMS`, Linux CLI/Desktop, macOS CLI/Desktop,
and Windows CLI/Desktop assets. Website, Homebrew, and AUR updater PRs #227,
#67, and #69 were reviewed and merged; their current `main` SHAs and CI runs
appear in the snapshot table. Website CI/deployment and Homebrew install,
upgrade, runtime, and uninstall checks passed on the exact updated heads. The
AUR publisher built and published the package, and exact-main Package CI passed.
Its `pull_request` event was `action_required` because the workflow uses
`GITHUB_TOKEN` to create it; that event is not counted as a pass.

- Veasel release [`v0.100.1-next.0`](https://github.com/veasel-labs/veasel/releases/tag/v0.100.1-next.0)
  names source `c20254af8267705432449102c091185445098d25`, with Linux, macOS and
  Windows CLI and Desktop artifacts. All nine manifest digests/sizes match
  GitHub's asset metadata and all ten `SHA256SUMS` entries match; the three
  platform CLI archives were downloaded and verified locally. Installers remain
  truthfully unsigned.
- The earlier v0.100.1 and v0.101.2 distribution audits are historical. Consumer `main` branches now reference v0.101.3-next.0 via the merged PRs #227, #67, and #69.
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
