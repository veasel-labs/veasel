#!/usr/bin/env python3
"""Extract Veasel binaries from a CI archive after checking build provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tarfile
import zipfile
from pathlib import Path


def extract_verified(archive: Path, destination: Path) -> tuple[Path, Path]:
    destination.mkdir(parents=True, exist_ok=True)
    legal_files: dict[str, bytes] = {}
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            manifest_data = package.read("build.json")
            manifest = json.loads(manifest_data)
            names = (manifest["binary"], manifest["tui_binary"])
            native_name = manifest["tui_native_library"]
            if any(Path(name).name != name for name in (*names, native_name)) or len(set((*names, native_name))) != 3:
                raise ValueError("build.json contains unsafe or duplicate binary names")
            binaries = [package.read(name) for name in names]
            native_data = package.read(native_name)
            for member_name in package.namelist():
                if member_name.startswith("opentui-licenses/") and not member_name.endswith("/"):
                    relative_name = member_name.removeprefix("opentui-licenses/")
                    if Path(relative_name).name != relative_name or "\\" in relative_name:
                        raise ValueError(f"unsafe OpenTUI license member: {member_name}")
                    legal_files[relative_name] = package.read(member_name)
    else:
        with tarfile.open(archive, "r:gz") as package:
            manifest_file = package.extractfile("build.json")
            if manifest_file is None:
                raise ValueError("package is missing build.json")
            manifest = json.loads(manifest_file.read())
            names = (manifest["binary"], manifest["tui_binary"])
            native_name = manifest["tui_native_library"]
            if any(Path(name).name != name for name in (*names, native_name)) or len(set((*names, native_name))) != 3:
                raise ValueError("build.json contains unsafe or duplicate binary names")
            binaries = []
            for name in names:
                member = package.getmember(name)
                if not member.isfile():
                    raise ValueError(f"package member is not a regular file: {name}")
                source = package.extractfile(member)
                if source is None:
                    raise ValueError(f"package member could not be read: {name}")
                binaries.append(source.read())
            native_member = package.getmember(native_name)
            if not native_member.isfile():
                raise ValueError(f"OpenTUI package member is not a regular file: {native_member.name}")
            native_source = package.extractfile(native_member)
            if native_source is None:
                raise ValueError(f"OpenTUI package member could not be read: {native_member.name}")
            native_data = native_source.read()
            for member in package.getmembers():
                if member.name.startswith("opentui-licenses/"):
                    if not member.isfile():
                        if member.isdir():
                            continue
                        raise ValueError(f"OpenTUI license member is not a regular file: {member.name}")
                    relative_name = member.name.removeprefix("opentui-licenses/")
                    if Path(relative_name).name != relative_name or "\\" in relative_name:
                        raise ValueError(f"unsafe OpenTUI license member: {member.name}")
                    source = package.extractfile(member)
                    if source is None:
                        raise ValueError(f"OpenTUI license member could not be read: {member.name}")
                    legal_files[relative_name] = source.read()

    if not native_data:
        raise ValueError(f"OpenTUI native library is empty: {native_name}")
    if "LICENSE" not in legal_files or not legal_files["LICENSE"]:
        raise ValueError("package is missing the OpenTUI license notice")

    native_digest = hashlib.sha256(native_data).hexdigest()
    if native_digest != manifest["tui_native_library_sha256"]:
        raise ValueError(f"{native_name} sha256 {native_digest} != build.json tui_native_library_sha256")

    expected = (manifest["binary_sha256"], manifest["tui_binary_sha256"])
    paths = tuple(destination / name for name in names)
    for path, data, digest in zip(paths, binaries, expected, strict=True):
        actual = hashlib.sha256(data).hexdigest()
        if actual != digest:
            raise ValueError(f"{path.name} sha256 {actual} != build.json {digest}")
        path.write_bytes(data)
    (destination / native_name).write_bytes(native_data)
    legal_destination = destination / "opentui-licenses"
    legal_destination.mkdir(exist_ok=True)
    for name, data in legal_files.items():
        (legal_destination / name).write_bytes(data)
    if os.name != "nt":
        paths[0].chmod(0o755)
        paths[1].chmod(0o755)
    return paths


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    for path in extract_verified(args.archive, args.destination):
        print(path)


if __name__ == "__main__":
    main()
