#!/usr/bin/env python3
"""Validate a Veasel ATIF trace with a pinned Harbor source checkout."""

from __future__ import annotations

import importlib.metadata
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} HARBOR_SOURCE TRAJECTORY", file=sys.stderr)
        return 2

    harbor_source = Path(sys.argv[1]).resolve() / "src"
    trajectory = Path(sys.argv[2]).resolve()
    if not harbor_source.is_dir() or not trajectory.is_file():
        print("Harbor source or trajectory file does not exist", file=sys.stderr)
        return 2

    original_version = importlib.metadata.version

    def pinned_harbor_version(distribution: str) -> str:
        if distribution == "harbor":
            return "0.24.0"
        return original_version(distribution)

    importlib.metadata.version = pinned_harbor_version
    sys.path.insert(0, str(harbor_source))

    from harbor.utils.trajectory_validator import TrajectoryValidator

    validator = TrajectoryValidator()
    if not validator.validate(trajectory):
        print("Harbor rejected the ATIF trajectory:", file=sys.stderr)
        for error in validator.errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Harbor 0.24.0 ATIF trajectory validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
