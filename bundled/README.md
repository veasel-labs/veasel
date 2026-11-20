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
- The entry's review stays `pending-initial-review` and `installable`
  stays false: promotion is the owner's governance decision
  (veasel-labs/agent-toolkit#10) and is never self-approved here. The
  bundled skill itself is available to sessions offline through skill
  discovery (the `bundled` root next to the executable), independent of
  Library installation.
