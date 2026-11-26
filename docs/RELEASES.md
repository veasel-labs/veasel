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
the SHA-256 hashes and build targets for both executables and the OpenTUI
native FFI sidecar. The archive also carries the sidecar's upstream notices in
`opentui-licenses/`. A separate `veasel-tui-runtime-<platform>` archive
contains the TUI, its matching sidecar, and those notices as a self-contained
standalone distribution. Release commands
and compiler selection are documented in [`V_BUILD_PROFILE.md`](V_BUILD_PROFILE.md).
Bun is a build-time dependency for the TypeScript TUI; release archives do not
require Bun at runtime. A failed check or platform build prevents publication.
There is no manual upload or tag-cutting step.

The no-argument `veasel` command and `veasel tui` start a local server when its
health endpoint is not already responding, then launch the bundled standalone
TUI executable beside the V backend.

These automated builds are prereleases while the product remains under active
development. They are not stable compatibility promises.

## Release immutability and Linux-first platform policy

Published release assets are immutable, because downstream consumers pin their
SHA-256 digests (website, Homebrew, AUR).

- CI stages one upload set (`tools/release/build_release_assets.py`): the CLI
  archives, standalone TUI runtime bundles (`veasel-tui-runtime-<platform>`),
  and the legacy loose `veasel-tui` / `veasel-tui.exe` plus matching native
  libraries extracted from the checksum-verified archives, Desktop installers,
  `release.json`, and
  `SHA256SUMS`. The set contains **only what verified**. `SHA256SUMS` covers
  every uploaded file except itself.
- `tools/release/publish-release.sh` creates the release as a **draft**,
  uploads, re-downloads every asset and checks it against `SHA256SUMS`, and
  only then publishes. It never uses `--clobber` and never modifies the assets
  of a published tag.
- Re-running on an existing published tag with the same full commit SHA
  verifies the published assets and skips if they are identical; if they
  differ (for example a non-reproducible rebuild) it fails loudly. A different
  commit is a tag collision and fails. A leftover unpublished draft from an
  interrupted run is discarded and recreated.
- **Linux-first gating.** Publishing requires `release-plan`, `security`,
  `tui`, `harbor-adapter` and the **Linux** backend leg to be exactly
  `success`. A red, cancelled or unavailable macOS or Windows backend leg does
  not block the release. Each backend leg records its own `job.status` in a
  `backend-status-<os>` artifact (written last, `if: always()`), and the
  `platform-status` job exposes `linux`/`macos`/`windows` outputs; a leg that
  never reported is recorded as `unavailable`.
- Each non-Linux CLI archive and each Desktop lane (Linux AppImage+deb, macOS
  dmg, Windows NSIS exe) is attached only when **its own job result is
  `success`**; a Desktop lane additionally requires its platform's CLI to be
  published. Cancelled/skipped/failed/missing never count as success, and no
  assets are fabricated. Timeouts are not raised to mask flaky jobs.
- Desktop installers are **unsigned and not notarized**; expect
  Gatekeeper/SmartScreen warnings. The release notes repeat this whenever any
  installer is attached.

### `release.json` platform contract

`release.json` has a `platforms` block keyed `linux`, `macos`, `windows`:

```json
"platforms": {
  "linux":   {"status": "published", "ci_result": "success", "arch": "x86_64",
              "desktop": {"status": "published", "kind": "desktop-installer",
                          "arch": "x86_64", "signed": false,
                          "assets": ["veasel-desktop-....AppImage", "...deb"]}},
  "windows": {"status": "failed", "ci_result": "failure", "arch": "x86_64",
              "reason": "failed - see CI", "desktop": {"status": "unavailable", ...}}
}
```

`status` is one of `published`, `unavailable` (job never reported, e.g. runner
capacity), `failed`, `cancelled`, `skipped`. `assets[]` lists every uploaded
file with `name`, `size`, `sha256`, `platform`, `arch`, `kind`. The generated
release notes list every platform that is **not** included and why. Standalone
runtime bundles use the `standalone-tui-runtime` kind; their filenames identify
the OS, and their entries carry the OS platform and architecture. The release
stager creates a bundle only for a platform whose CLI archive passed CI.

**Consumer rule (website `src/data/verified-release.json`, Homebrew cask, AUR
PKGBUILD generators):** advertise or pin a platform only if
`platforms.<p>.status == "published"` **and** a matching `assets[]` entry
exists; take the digest from that entry, never from a hard-coded asset name
alone. If the status is anything else, keep the previous pin or omit the
platform, and never present it as supported for this tag. (Today the Homebrew
cask workflow downloads `veasel-macOS.tar.gz` unconditionally and the AUR
script reads the Linux archive; the cask workflow should gate on
`platforms.macos.status`. Those repos are not changed here.)

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
