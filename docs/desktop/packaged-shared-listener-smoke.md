# Packaged Desktop and TUI shared-listener smoke

This Linux x86_64 acceptance harness checks that the published AppImage and
standalone TUI can start in either order while reusing the same local V backend.
It verifies all three artifacts against a release manifest, isolates HOME,
XDG paths, Veasel data, ports, and renderer profile under a new temporary
directory, then checks authenticated loopback health, backend PID, the TUI
connected view, and the Desktop Focus route.

The harness supplies no provider credentials or proxy configuration to its
child processes and makes no provider request. It is not a network sandbox;
the operating system still permits network access.

The Desktop renderer is launched headlessly and inspected through its
loopback-only DevTools endpoint. This is a startup and shared-listener smoke,
not evidence of visible Desktop interaction, a coding session, provider
authentication, approval handling, edits, restart recovery, or macOS/Windows
behavior. Keep those gates separate in issue #550.

## Run against a release

Download the release manifest and the Linux AppImage, standalone TUI, and CLI
archive. Supply the expected version and a manifest SHA-256 obtained from a
trusted, independently reviewed release record. The harness fails closed if
the manifest digest, artifact names, sizes, or SHA-256 values differ.

```sh
python3 scripts/packaged-shared-listener-smoke.py \
  --release-manifest /path/to/release.json \
  --manifest-sha256 <trusted-release-manifest-sha256> \
  --appimage /path/to/veasel-desktop-VERSION-linux-x86_64.AppImage \
  --tui /path/to/veasel-tui \
  --cli-archive /path/to/veasel-Linux.tar.gz \
  --expected-version VERSION \
  --work-dir /tmp/veasel-shared-listener-VERSION
```

The work directory must not already exist. It contains per-order logs and a
sanitized `summary.json`; preserve that summary with the release evidence. The
harness terminates its launchers and only signals a detached backend when the
authenticated health response reports the exact PID created by that run.

## Recorded release result

[`evidence/shared-listener-v0.103.3-next.0.json`](evidence/shared-listener-v0.103.3-next.0.json)
records both launch orders passing against the hash-verified `v0.103.3-next.0`
Linux release artifacts. That source contains shared-listener PR #820. It
predates #821, so it does not verify exact-file approval behavior.
