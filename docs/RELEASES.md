# Releases

Every push to `main` runs the same native builds, tests, dependency audit, and
repository security scan. Once all required jobs pass, Conventional Commits
with `feat`, `fix`, `perf`, or a breaking-change marker produce an automated
GitHub prerelease on the `next` channel. Documentation, CI, and refactoring
commits do not publish a release.

Pull-request CI still cancels superseded runs so feature checks stay fast. On
`main`, later pushes queue behind the in-flight workflow instead of cancelling
it, so a verified prerelease can finish during merge bursts. Cancellation is keyed off `github.ref != main`, not event name. Cancelled main
runs that remain after other interruptions are not product failures; the
`Ensure main CI` workflow re-dispatches CI for the tip of `main` when no
successful or in-flight run exists. Publish attaches the channel tag to the
commit that finished verification; if that tag already exists for another
commit, the job skips instead of clobbering.

The release job calculates a semantic version from the last `v*` tag (or the
version in `v.mod` before the first tag), compiles Linux, macOS, and Windows
archives with that exact version, and publishes the V backend, a standalone
terminal-client executable, SHA-256 sums, and a JSON source/asset manifest
together. Each platform archive includes `build.json`, which records the V
revision, V and C compiler versions, target, exact backend build arguments, and
the SHA-256 hashes and build targets for both executables. Release commands
and compiler selection are documented in [`V_BUILD_PROFILE.md`](V_BUILD_PROFILE.md).
Bun is a build-time dependency for the TypeScript TUI; release archives do not
require Bun at runtime. A failed check or platform build prevents publication.
There is no manual upload or tag-cutting step.

The no-argument `veasel` command and `veasel tui` start a local server when its
health endpoint is not already responding, then launch the bundled standalone
TUI executable beside the V backend.

These automated builds are prereleases while the product remains under active
development. They are not stable compatibility promises.

## Release immutability and Desktop lane policy

Published release assets are immutable, because downstream consumers pin their
SHA-256 digests (website, Homebrew, AUR).

- CI stages one upload set (`tools/release/build_release_assets.py`): the three
  CLI archives, the standalone `veasel-tui` / `veasel-tui.exe` extracted from
  the checksum-verified archives, Desktop installers, `release.json`, and
  `SHA256SUMS`. `SHA256SUMS` covers every uploaded file except itself.
  `release.json` lists `name`, `size`, `sha256`, `platform`, `arch`, and `kind`
  for each asset (`signed: false` on Desktop installers).
- `tools/release/publish-release.sh` creates the release as a **draft**,
  uploads, re-downloads every asset and checks it against `SHA256SUMS`, and
  only then publishes. It never uses `--clobber` and never modifies the assets
  of a published tag.
- Re-running on an existing published tag with the same full commit SHA
  verifies the published assets and skips if they are identical; if they
  differ (for example a non-reproducible rebuild) it fails loudly. A different
  commit is a tag collision and fails. A leftover unpublished draft from an
  interrupted run is discarded and recreated.
- Desktop lane: the CLI prerelease needs the core jobs (backend, security, tui,
  harbor-adapter) to be exactly `success`. Desktop installers are attached
  only when **all three** Desktop jobs (Linux, macOS, Windows) succeeded.
  If any Desktop job failed, was cancelled, or was skipped (for example runner
  capacity), the release is CLI-only: `release.json` has
  `"desktop": {"status": "unavailable", "lanes": {...}, "reason": ...}`, the
  release notes say `desktop: unavailable`, and no partial installers are
  attached. A cancelled workflow publishes nothing. Timeouts are not raised to
  mask flaky Desktop jobs.
- Desktop installers (AppImage, deb, dmg, NSIS exe) are **unsigned and not
  notarized**; expect Gatekeeper/SmartScreen warnings. The generated release
  notes repeat this.

Run the fixture tests with `python3 -m unittest discover -s tools/release -p 'test_*.py'`.

## Verify an archive

Download the archive, `SHA256SUMS`, and `release.json` from the same GitHub
release. Check the archive digest against the matching entry in
`SHA256SUMS`; the manifest records the release tag, source commit, platform,
and digest. Linux and macOS downloads are `.tar.gz`; Windows is `.zip`. Extract
the archive and run `veasel --help`. Launch the terminal client with `veasel`;
no separate Bun installation is needed.

## Version rules

- `feat`: next minor prerelease.
- `fix`, `perf`, `revert`, or `security`: next patch prerelease.
- `!` after the type/scope or a `BREAKING CHANGE:` footer: next major
  prerelease.
- Other commit types do not publish.

Pull request titles should use Conventional Commit types so the merged commit
history produces predictable release notes and versions.
