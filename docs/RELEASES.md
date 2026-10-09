# Releases

Every push to `main` runs the same native builds, tests, dependency audit, and
repository security scan. Once all required jobs pass, Conventional Commits
with `feat`, `fix`, `perf`, or a breaking-change marker produce an automated
GitHub prerelease on the `next` channel. Documentation, CI, and refactoring
commits do not publish a release.

The release job calculates a semantic version from the last `v*` tag (or the
version in `v.mod` before the first tag), compiles Linux, macOS, and Windows
archives with that exact version, and publishes the V backend, bundled
terminal-client source/dependencies, SHA-256 sums, and a JSON source/asset
manifest together. `veasel serve` runs without Bun; `veasel tui` requires Bun
1.4.2 or newer. A failed check or platform build prevents publication. There
is no manual upload or tag-cutting step.

These automated builds are prereleases while the product remains under active
development. They are not stable compatibility promises. The mascot artwork
licensing restriction documented in `THIRD_PARTY_NOTICES.md` also applies to
redistributed builds.

## Verify an archive

Download the archive, `SHA256SUMS`, and `release.json` from the same GitHub
release. Check the archive digest against the matching entry in
`SHA256SUMS`; the manifest records the release tag, source commit, platform,
and digest. Linux and macOS downloads are `.tar.gz`; Windows is `.zip`. Extract
the archive and run `veasel --help`. Install Bun to launch its terminal client.

## Version rules

- `feat`: next minor prerelease.
- `fix`, `perf`, `revert`, or `security`: next patch prerelease.
- `!` after the type/scope or a `BREAKING CHANGE:` footer: next major
  prerelease.
- Other commit types do not publish.

Pull request titles should use Conventional Commit types so the merged commit
history produces predictable release notes and versions.
