#!/usr/bin/env python3
"""Stage the immutable upload set for a verified prerelease.

Inputs are the merged CI artifacts in --assets-dir. The output directory
contains exactly the files that will be uploaded: CLI archives, standalone TUI
binaries taken from the checksum-verified archives, Desktop installers (only
when every Desktop lane verified), release.json, SHA256SUMS and the release
notes used for the GitHub release body (RELEASE_NOTES.md, not uploaded).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path

ARCHIVES = {
    "veasel-Linux.tar.gz": ("linux", "x86_64", "veasel-tui"),
    "veasel-macOS.tar.gz": ("macos", "arm64", None),
    "veasel-Windows.zip": ("windows", "x86_64", "veasel-tui.exe"),
}
STANDALONE_TUI = {
    "veasel-tui": ("linux", "x86_64", "veasel-Linux.tar.gz"),
    "veasel-tui.exe": ("windows", "x86_64", "veasel-Windows.zip"),
}
DESKTOP_KINDS = {
    ".AppImage": ("linux", "x86_64"),
    ".deb": ("linux", "x86_64"),
    ".dmg": ("macos", "arm64"),
    ".exe": ("windows", "x86_64"),
}
DESKTOP_LANES = ("linux", "macos", "windows")
UNSIGNED_NOTE = (
    "Desktop installers (AppImage, deb, dmg, NSIS exe) are UNSIGNED and not "
    "notarized. Expect OS warnings (Gatekeeper, SmartScreen). Verify them "
    "against SHA256SUMS before running."
)


class ReleaseError(Exception):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_member(archive: Path, member: str) -> bytes:
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            return package.read(member)
    with tarfile.open(archive) as package:
        handle = package.extractfile(member)
        if handle is None:
            raise ReleaseError(f"{archive.name}: {member} is not a regular file")
        return handle.read()


def parse_lanes(raw: str) -> dict[str, str]:
    lanes: dict[str, str] = {}
    for item in raw.split(","):
        name, _, result = item.partition("=")
        lanes[name.strip()] = result.strip()
    missing = [lane for lane in DESKTOP_LANES if lane not in lanes]
    if missing:
        raise ReleaseError(f"missing desktop lane results: {missing}")
    return {lane: lanes[lane] for lane in DESKTOP_LANES}


def entry(path: Path, kind: str, platform: str, arch: str) -> dict:
    item = {
        "name": path.name,
        "size": path.stat().st_size,
        "sha256": sha256(path),
        "platform": platform,
        "arch": arch,
        "kind": kind,
    }
    if kind == "desktop-installer":
        item["signed"] = False
    return item


def stage(assets_dir: Path, out_dir: Path, tag: str, version: str,
          commit: str, lanes: dict[str, str]) -> dict:
    if out_dir.exists() and any(out_dir.iterdir()):
        raise ReleaseError(f"{out_dir} must be empty")
    out_dir.mkdir(parents=True, exist_ok=True)
    assets: list[dict] = []

    for name, (platform, arch, _) in ARCHIVES.items():
        source = assets_dir / name
        if not source.is_file():
            raise ReleaseError(f"missing verified CLI archive {name}")
        shutil.copyfile(source, out_dir / name)
        assets.append(entry(out_dir / name, "cli-archive", platform, arch))

    for name, (platform, arch, archive_name) in STANDALONE_TUI.items():
        archive = assets_dir / archive_name
        provenance = json.loads(read_member(archive, "build.json"))
        data = read_member(archive, name)
        expected = provenance["tui_binary_sha256"]
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            raise ReleaseError(
                f"{name} sha256 {actual} != verified provenance {expected}")
        (out_dir / name).write_bytes(data)
        assets.append(entry(out_dir / name, "standalone-tui", platform, arch))

    desktop_ok = all(result == "success" for result in lanes.values())
    desktop_files = sorted(p for p in assets_dir.glob("veasel-desktop-*") if p.is_file())
    if desktop_ok:
        seen: set[str] = set()
        for source in desktop_files:
            if source.suffix not in DESKTOP_KINDS:
                raise ReleaseError(f"unexpected desktop asset {source.name}")
            seen.add(source.suffix)
            shutil.copyfile(source, out_dir / source.name)
            platform, arch = DESKTOP_KINDS[source.suffix]
            assets.append(entry(out_dir / source.name, "desktop-installer", platform, arch))
        missing = sorted(set(DESKTOP_KINDS) - seen)
        if missing:
            raise ReleaseError(
                f"all desktop lanes succeeded but installers are missing: {missing}")
        desktop = {"status": "available", "lanes": lanes}
    else:
        # Never attach partial Desktop output: a lane that failed, was
        # cancelled or skipped makes the whole Desktop set unavailable.
        desktop = {
            "status": "unavailable",
            "lanes": lanes,
            "reason": "one or more desktop lanes did not verify; "
                      "no desktop installers are attached to this release",
        }

    manifest = {
        "name": "Veasel Code",
        "version": version,
        "tag": tag,
        "source_commit": commit,
        "channel": "next",
        "prerelease": True,
        "desktop": desktop,
        "assets": sorted(assets, key=lambda a: a["name"]),
    }
    (out_dir / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")

    names = sorted(p.name for p in out_dir.iterdir() if p.name != "SHA256SUMS")
    (out_dir / "SHA256SUMS").write_text(
        "".join(f"{sha256(out_dir / n)}  {n}\n" for n in names))

    notes = [f"Verified prerelease `{tag}` built from `{commit}`.", ""]
    if desktop_ok:
        notes += ["Desktop installers are included.", "", UNSIGNED_NOTE]
    else:
        notes += [
            "**desktop: unavailable.** The Desktop lane did not fully verify "
            "(" + ", ".join(f"{k}={v}" for k, v in lanes.items()) + "), so this "
            "release contains the CLI/TUI assets only. No Desktop installers "
            "are attached.",
            "",
            UNSIGNED_NOTE,
        ]
    (out_dir.parent / "RELEASE_NOTES.md").write_text(
        "\n".join(notes) + "\n")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--desktop-lanes", required=True,
                        help="linux=<result>,macos=<result>,windows=<result>")
    args = parser.parse_args(argv)
    try:
        stage(args.assets_dir, args.out_dir, args.tag, args.version,
              args.commit, parse_lanes(args.desktop_lanes))
    except ReleaseError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
