#!/usr/bin/env python3
"""Stage the immutable upload set for a verified prerelease.

Inputs are the merged CI artifacts in --assets-dir. The output directory
contains exactly the files that will be uploaded: CLI archives, standalone TUI
runtime bundles, legacy loose TUI binaries and their OpenTUI native sidecars
taken from the checksum-verified archives, per-platform Desktop installers
(each only when its own job succeeded), release.json, SHA256SUMS and the
release notes used for the GitHub release body (RELEASE_NOTES.md, not uploaded).
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path

PLATFORMS = ("linux", "macos", "windows")
# platform -> (archive name, arch, standalone TUI member name or None)
ARCHIVES = {
    "linux": ("veasel-Linux.tar.gz", "x86_64", "veasel-tui"),
    "macos": ("veasel-macOS.tar.gz", "arm64", None),
    "windows": ("veasel-Windows.zip", "x86_64", "veasel-tui.exe"),
}
NATIVE_LIBRARIES = {
    "linux": "libopentui.so",
    "macos": "libopentui.dylib",
    "windows": "opentui.dll",
}
PLATFORM_LABELS = {"linux": "Linux", "macos": "macOS", "windows": "Windows"}
DESKTOP_KINDS = {
    ".AppImage": ("linux", "x86_64"),
    ".deb": ("linux", "x86_64"),
    ".dmg": ("macos", "arm64"),
    ".exe": ("windows", "x86_64"),
}
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


def read_members(archive: Path, prefix: str) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                if not name.startswith(prefix) or name.endswith("/"):
                    continue
                relative = name.removeprefix(prefix)
                if Path(relative).name != relative or "\\" in relative:
                    raise ReleaseError(f"{archive.name}: unsafe member {name}")
                files[relative] = package.read(name)
    else:
        with tarfile.open(archive) as package:
            for member in package.getmembers():
                if not member.name.startswith(prefix):
                    continue
                if member.isdir():
                    continue
                if not member.isfile():
                    raise ReleaseError(f"{archive.name}: {member.name} is not a regular file")
                relative = member.name.removeprefix(prefix)
                if Path(relative).name != relative or "\\" in relative:
                    raise ReleaseError(f"{archive.name}: unsafe member {member.name}")
                source = package.extractfile(member)
                if source is None:
                    raise ReleaseError(f"{archive.name}: {member.name} could not be read")
                files[relative] = source.read()
    if "LICENSE" not in files or not files["LICENSE"]:
        raise ReleaseError(f"{archive.name}: OpenTUI license notice is missing")
    return files


def create_runtime_bundle(tui_name: str, tui_data: bytes, native_name: str,
                          native_data: bytes, legal_files: dict[str, bytes],
                          platform: str) -> bytes:
    if platform == "windows":
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as package:
            for name, data in ((tui_name, tui_data), (native_name, native_data),
                               *((f"opentui-licenses/{name}", data) for name, data in legal_files.items())):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                package.writestr(info, data)
        return output.getvalue()

    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as package:
            for name, data in ((tui_name, tui_data), (native_name, native_data),
                               *((f"opentui-licenses/{name}", data) for name, data in legal_files.items())):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o755 if name == tui_name else 0o644
                info.mtime = 0
                package.addfile(info, io.BytesIO(data))
    return output.getvalue()


def parse_results(raw: str, what: str) -> dict[str, str]:
    """Parse `linux=success,macos=failure,windows=` into a full 3-key dict.

    A missing or empty value means the job never reported (for example it
    never got a runner) and is reported as `unavailable`, never as success.
    """
    results: dict[str, str] = {}
    for item in filter(None, (part.strip() for part in raw.split(","))):
        name, _, result = item.partition("=")
        if name.strip() not in PLATFORMS:
            raise ReleaseError(f"unknown platform {name!r} in {what}")
        results[name.strip()] = result.strip()
    return {p: results.get(p, "") for p in PLATFORMS}


STATUS_BY_RESULT = {
    "success": "published",
    "failure": "failed",
    "cancelled": "cancelled",
    "skipped": "skipped",
}
REASONS = {
    "failed": "failed - see CI",
    "cancelled": "cancelled - see CI",
    "skipped": "skipped - an upstream job did not pass",
    "unavailable": "unavailable - job did not report (for example runner capacity)",
}


def status_of(result: str) -> str:
    return STATUS_BY_RESULT.get(result, "unavailable")


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
          commit: str, cli: dict[str, str], lanes: dict[str, str]) -> dict:
    """Stage the upload set. `cli`/`lanes` map platform -> CI job result.

    Linux CLI must have succeeded. Every other platform (CLI or Desktop) is
    included only when its job result is exactly `success`; its assets are then
    required to exist. Anything else is absent and reported, never fabricated.
    """
    if cli["linux"] != "success":
        raise ReleaseError(
            f"linux CLI job result is {cli['linux']!r}; a Linux release requires success")
    if out_dir.exists() and any(out_dir.iterdir()):
        raise ReleaseError(f"{out_dir} must be empty")
    out_dir.mkdir(parents=True, exist_ok=True)
    assets: list[dict] = []
    platforms: dict[str, dict] = {}

    for platform in PLATFORMS:
        name, arch, tui_name = ARCHIVES[platform]
        status = status_of(cli[platform])
        block: dict = {"status": status, "ci_result": cli[platform] or "none",
                       "arch": arch}
        if status == "published":
            source = assets_dir / name
            if not source.is_file():
                raise ReleaseError(f"{platform} job succeeded but {name} is missing")
            shutil.copyfile(source, out_dir / name)
            assets.append(entry(out_dir / name, "cli-archive", platform, arch))
            provenance = json.loads(read_member(source, "build.json"))
            native_name = NATIVE_LIBRARIES[platform]
            native_data = read_member(source, native_name)
            native_digest = hashlib.sha256(native_data).hexdigest()
            if (provenance.get("tui_native_library") != native_name
                    or provenance.get("tui_native_library_sha256") != native_digest):
                raise ReleaseError(
                    f"{native_name} sha256 {native_digest} != verified OpenTUI native provenance")
            tui_filename = provenance["tui_binary"]
            tui_data = read_member(source, tui_filename)
            tui_digest = hashlib.sha256(tui_data).hexdigest()
            if provenance.get("tui_binary_sha256") != tui_digest:
                raise ReleaseError(
                    f"{tui_filename} sha256 {tui_digest} != verified TUI provenance")
            legal_files = read_members(source, "opentui-licenses/")
            bundle_name = f"veasel-tui-runtime-{PLATFORM_LABELS[platform]}"
            bundle_suffix = ".zip" if platform == "windows" else ".tar.gz"
            bundle_data = create_runtime_bundle(
                tui_filename, tui_data, native_name, native_data, legal_files, platform)
            (out_dir / f"{bundle_name}{bundle_suffix}").write_bytes(bundle_data)
            assets.append(entry(out_dir / f"{bundle_name}{bundle_suffix}",
                                "standalone-tui-runtime", platform, arch))
            if tui_name:
                (out_dir / tui_name).write_bytes(tui_data)
                assets.append(entry(out_dir / tui_name, "standalone-tui", platform, arch))
                (out_dir / native_name).write_bytes(native_data)
                assets.append(entry(out_dir / native_name, "standalone-tui-native", platform, arch))
        else:
            block["reason"] = REASONS.get(status, REASONS["unavailable"])
        platforms[platform] = block

    for platform in PLATFORMS:
        cli_ok = platforms[platform]["status"] == "published"
        result = lanes[platform]
        status = status_of(result) if cli_ok else "unavailable"
        desk: dict = {"status": status, "ci_result": result or "none",
                      "arch": ARCHIVES[platform][1], "kind": "desktop-installer",
                      "signed": False, "assets": []}
        if status == "published":
            kinds = [s for s, (p, _) in DESKTOP_KINDS.items() if p == platform]
            files = sorted(f for f in assets_dir.glob("veasel-desktop-*")
                           if f.is_file() and f.suffix in kinds)
            if {f.suffix for f in files} != set(kinds):
                raise ReleaseError(
                    f"{platform} desktop job succeeded but installers are missing "
                    f"(expected {sorted(kinds)}, found {[f.name for f in files]})")
            for source in files:
                shutil.copyfile(source, out_dir / source.name)
                assets.append(entry(out_dir / source.name, "desktop-installer",
                                    platform, desk["arch"]))
                desk["assets"].append(source.name)
        else:
            desk["reason"] = (REASONS.get(status, REASONS["unavailable"]) if cli_ok
                              else f"unavailable - {platform} CLI build not published")
        platforms[platform]["desktop"] = desk

    desk_states = [platforms[p]["desktop"]["status"] for p in PLATFORMS]
    desktop_summary = ("available" if all(s == "published" for s in desk_states)
                       else "partial" if any(s == "published" for s in desk_states)
                       else "unavailable")
    manifest = {
        "name": "Veasel Code",
        "version": version,
        "tag": tag,
        "source_commit": commit,
        "channel": "next",
        "prerelease": True,
        "platforms": platforms,
        "desktop": {"status": desktop_summary},
        "assets": sorted(assets, key=lambda a: a["name"]),
    }
    (out_dir / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")

    names = sorted(p.name for p in out_dir.iterdir() if p.name != "SHA256SUMS")
    (out_dir / "SHA256SUMS").write_text(
        "".join(f"{sha256(out_dir / n)}  {n}\n" for n in names))

    pretty = {"linux": "Linux", "macos": "macOS", "windows": "Windows"}
    notes = [f"Verified prerelease `{tag}` built from `{commit}`.", "",
             "Included platforms: " + ", ".join(
                 pretty[p] for p in PLATFORMS if platforms[p]["status"] == "published") + "."]
    missing = []
    for p in PLATFORMS:
        block = platforms[p]
        if block["status"] != "published":
            missing.append(f"- {pretty[p]} CLI: {block['status']} - {block['reason']}")
        d = block["desktop"]
        if d["status"] != "published":
            missing.append(f"- {pretty[p]} Desktop: {d['status']} - {d['reason']}")
    if missing:
        notes += ["", "**Not included in this release** (do not assume coverage):"] + missing
    if desktop_summary != "unavailable":
        notes += ["", UNSIGNED_NOTE]
    (out_dir.parent / "RELEASE_NOTES.md").write_text("\n".join(notes) + "\n")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--cli-results", required=True,
                        help="linux=<result>,macos=<result>,windows=<result>")
    parser.add_argument("--desktop-lanes", required=True,
                        help="same format, Desktop job results")
    args = parser.parse_args(argv)
    try:
        stage(args.assets_dir, args.out_dir, args.tag, args.version,
              args.commit, parse_results(args.cli_results, 'cli'),
              parse_results(args.desktop_lanes, 'desktop'))
    except ReleaseError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
