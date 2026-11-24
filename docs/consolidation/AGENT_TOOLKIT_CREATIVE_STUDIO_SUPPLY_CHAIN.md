# Supply-chain review — Agent Toolkit Creative Studio

- **Review date:** 2026-11-24
- **Registry change:** [veasel-labs/agent-toolkit#13](https://github.com/veasel-labs/agent-toolkit/pull/13)
- **Pinned personal Toolkit source:** [`ulises-jeremias/agent-toolkit@cc5c60d48c18ff6b5788c08f38f681c933505fbe`](https://github.com/ulises-jeremias/agent-toolkit/tree/cc5c60d48c18ff6b5788c08f38f681c933505fbe/plugins/agent-toolkit-creative-studio)
- **Audit type:** static inspection only; no plugin code or scripts were executed.

## Provenance and license

- Plugin identity is `agent-toolkit-creative-studio`, version `1.49.0`, license `MIT` in `plugin.json`.
- The official registry PR pins the personal Toolkit plugin directory to immutable commit `cc5c60d48c18ff6b5788c08f38f681c933505fbe` and marks it `community`, `opt_in_required`, `installable: false`, and `pending-initial-review`.
- The personal Toolkit plugin vendors `brag` and `brag-slim` from `latent-spaces/brag@7c98a0830fd2810c93b1f9da7d9edef98ed6ef8a`; both skill frontmatters identify MIT and an immutable source ref. The upstream repository license at that commit is MIT.
- The pinned upstream skill bundle contains non-MIT assets. Its [`assets/music/README.md`](https://github.com/latent-spaces/brag/blob/7c98a0830fd2810c93b1f9da7d9edef98ed6ef8a/skills/brag/assets/music/README.md) identifies Sascha Ende's bundled tracks as CC BY 4.0 and supplies credit text. The licensor's [current license page](https://ende.app/en/standard-license) makes attribution optional; retain the upstream credit as provenance.
- [`references/audio.md`](https://github.com/latent-spaces/brag/blob/7c98a0830fd2810c93b1f9da7d9edef98ed6ef8a/skills/brag/references/audio.md) attributes the keyboard soundpack to OpenGameArt as CC0. [`assets/sfx/sfx-analysis.md`](https://github.com/latent-spaces/brag/blob/7c98a0830fd2810c93b1f9da7d9edef98ed6ef8a/skills/brag/assets/sfx/sfx-analysis.md) identifies Kenney; Kenney's [official support page](https://kenney.nl/support) states its game assets are CC0. Keep each upstream license/credit with any copied assets; the plugin's MIT license does not relicense them.

## Declared capabilities

- Registry PR #13 currently declares `shell: true`, `network: true`, `mcp: [kdenlive]`, no hooks, and no dangerous permissions. The generated catalog keeps the entry non-installable pending review.
- Pinned `brag/SKILL.md` declares scripts, shell, and network access (`security` lines 25–31). It instructs use of `uv` to run `scripts/analyze_music_cues.py` and install its declared Python dependencies.
- Pinned `brag-slim/SKILL.md` declares shell and network access (`security` lines 27–33); it describes optional `npx`/tool downloads and instructs the operator to ask before fetching missing tools.
- `mcp.json` defines one local stdio Kdenlive server through `uvx`, sourced from the immutable `mhbxyz/kdenlive-mcp@9abcf9474a434f2e00a9c458f0ff70c92fbc16d8` pin. It scopes `KDENLIVE_MCP_ALLOWED_ROOTS` to `${CREATIVE_PROJECT_ROOT}`.
- Static tree inspection found no executable files or hook directories in the personal Toolkit plugin path. The shell and script flags remain necessary because the instructions invoke local CLI tools and the omitted upstream analysis script.

## Material completeness finding

At personal Toolkit commit `cc5c60d48c18ff6b5788c08f38f681c933505fbe`,
`plugins/agent-toolkit-creative-studio/skills/brag/` contains `SKILL.md` and
its reference Markdown files, but not the files its own instructions describe:

- Missing `assets/` tree: the pinned upstream has 278 asset files totaling
  16,319,155 bytes, including bundled music, sound effects, and cue presets.
- Missing `scripts/analyze_music_cues.py`, `scripts/pyproject.toml`, its lock,
  and its tests; all are present under the pinned upstream skill tree.

The skill's planning docs refer to bundled tracks/presets, and `audio.md`
directs custom-track analysis to the absent Python script. The plugin can still
use other tools, but those documented paths are unavailable in this published
source tree. Reconcile this omission before treating the by-reference package
as feature-complete. Any migration must preserve upstream pins, MIT notices,
per-asset licenses/credits, and tests; do not execute the scripts as part of
this audit.

## Review disposition

**Recommendation: BLOCK marketplace approval until source completeness is
resolved and independently reviewed.** The network metadata is now truthful
on PR #13's current head (`network: true` matches both upstream skill
frontmatters); this does not satisfy the independent review gate. The plugin
also requests broad shell/network capability and includes an opt-in MCP, so a
reviewer must inspect the actual permission boundaries, source diff, licenses,
and install behavior.

This is an integrator's static audit, not the independent review required by
`REVIEW_POLICY.md`. Per the owner decision, PR #13 remains open, non-installable,
and unapproved. No reviewer identity or approval is fabricated.
