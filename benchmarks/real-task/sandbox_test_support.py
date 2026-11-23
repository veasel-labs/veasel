"""Detect Linux hosts that can execute the real Bubblewrap namespace proofs."""

from __future__ import annotations

import platform
import shutil
import subprocess


def _probe_network_namespace() -> tuple[bool, str]:
    if platform.system() != "Linux":
        return False, "requires Linux network namespaces"
    bwrap = shutil.which("bwrap")
    if not bwrap:
        return False, "requires Bubblewrap"
    try:
        result = subprocess.run(
            [bwrap, "--unshare-all", "--ro-bind", "/", "/", "--", "true"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"Bubblewrap namespace probe failed: {type(exc).__name__}"
    if result.returncode == 0:
        return True, ""
    detail = result.stderr.strip().splitlines()
    reason = detail[-1] if detail else f"Bubblewrap exited {result.returncode}"
    return False, f"host cannot create required Bubblewrap namespaces: {reason}"


LINUX_BWRAP_NETWORK_SUPPORTED, LINUX_BWRAP_NETWORK_SKIP_REASON = _probe_network_namespace()
