# Bundled offline Library content

This directory ships with Veasel so a fresh install can discover the
minimal first-party skill set with no network access (#706).

- `catalog.json` is the offline fallback Library catalog, used only when
  `VEASEL_CATALOG_PATH` is not set. It contains only what is physically
  bundled here; network-sourced entries are never advertised offline.
- `veasel-essentials/` is copied verbatim from
  `veasel-labs/agent-toolkit` (`plugins/veasel-essentials`, main
  `e2c218aa`, MIT license — see that repository's `LICENSE` and
  `docs/OFFLINE_SKILLS.md` for the curation rationale). The only layout
  change is that `plugin.json` sits at the package root, as Veasel's
  plugin loader requires.
- `veasel-essentials` is first-party and is approved/installable under the
  owner's explicit exception in
  [veasel-labs/agent-toolkit#10](https://github.com/veasel-labs/agent-toolkit/issues/10#issuecomment-7086420717),
  recorded by [PR #12](https://github.com/veasel-labs/agent-toolkit/pull/12).
  The vendored plugin content comes from official registry commit
  `3c1c3149c13de05585df68ff9d9d7d63598b4c87`; its approval state comes from
  registry main at `2096315d10ccdb19b1cb8ea071986bd2c641eb89`. The exception
  applies only to this first-party package. `agent-toolkit-core` remains pending
  independent review and is intentionally absent from the offline catalog.
  The bundled skill is also available to sessions offline through skill
  discovery (the `bundled` root next to the executable).
