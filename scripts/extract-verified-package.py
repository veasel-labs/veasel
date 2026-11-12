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
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            manifest_data = package.read("build.json")
            manifest = json.loads(manifest_data)
            names = (manifest["binary"], manifest["tui_binary"])
            if any(Path(name).name != name for name in names) or len(set(names)) != 2:
                raise ValueError("build.json contains unsafe or duplicate binary names")
            binaries = [package.read(name) for name in names]
    else:
        with tarfile.open(archive, "r:gz") as package:
            manifest_file = package.extractfile("build.json")
            if manifest_file is None:
                raise ValueError("package is missing build.json")
            manifest = json.loads(manifest_file.read())
            names = (manifest["binary"], manifest["tui_binary"])
            if any(Path(name).name != name for name in names) or len(set(names)) != 2:
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

    expected = (manifest["binary_sha256"], manifest["tui_binary_sha256"])
    paths = tuple(destination / name for name in names)
    for path, data, digest in zip(paths, binaries, expected, strict=True):
        actual = hashlib.sha256(data).hexdigest()
        if actual != digest:
            raise ValueError(f"{path.name} sha256 {actual} != build.json {digest}")
        path.write_bytes(data)
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
