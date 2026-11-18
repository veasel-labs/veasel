#!/usr/bin/env python3
"""Backend caller-auth lifecycle against a REAL built `veasel` binary.

Uses an ephemeral port and a disposable data dir (never the real profile).
Covers: CLI-first spawn vs attach, Desktop-style attach to a CLI/TUI-started
backend, Desktop-first start then CLI/TUI attach, restart token reuse, token
rotation while a client holds the old token (stale-token recovery: re-read the
file and retry once), SSE before/after rotation.

  python3 scripts/auth-lifecycle-smoke.py --server /path/to/veasel [--bun bun]
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def http(port: int, path: str, token: str | None = None, method: str = "GET", read: bool = True):
    headers = {"authorization": f"Bearer {token}"} if token else {}
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method, headers=headers,
                                     data=b"" if method == "POST" else None)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, (response.read() if read else b"")
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def health(port: int, token: str | None = None) -> dict:
    status, body = http(port, "/v1/health", token)
    assert status == 200, status
    return json.loads(body)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"ok: {message}")


class Harness:
    def __init__(self, server: Path, bun: str, root: Path) -> None:
        self.server = server
        self.bun = bun
        self.port = free_port()
        self.data = root / "data"
        self.env = {
            **{k: v for k, v in os.environ.items() if not k.startswith("VEASEL_")},
            "VEASEL_PORT": str(self.port),
            "VEASEL_DATA_DIR": str(self.data),
            "VEASEL_PLUGIN_DIR": str(root / "plugins"),
            "HOME": str(root / "home"),
        }
        (root / "home").mkdir(exist_ok=True)
        self.token_path = self.data / "api-token"
        self.serve: subprocess.Popen | None = None

    def token(self) -> str:
        return self.token_path.read_text(encoding="utf-8").strip()

    def start_serve(self) -> None:
        """Desktop-style start: the supervisor runs `veasel serve` directly."""
        self.serve = subprocess.Popen([str(self.server), "serve"], env=self.env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.wait_listening()

    def wait_listening(self) -> None:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                health(self.port)
                return
            except OSError:
                time.sleep(0.05)
        raise TimeoutError("backend did not become healthy")

    def cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.server), *args], env=self.env, capture_output=True,
                              text=True, timeout=60)

    def stop_all(self) -> None:
        """Stop whichever process listens on our port (CLI-spawned servers are detached)."""
        pid = None
        try:
            pid = health(self.port, self.token() if self.token_path.exists() else None).get("pid")
        except OSError:
            pass
        if self.serve is not None:
            self.serve.terminate()
            self.serve.wait(timeout=10)
            self.serve = None
        elif pid:
            os.kill(int(pid), 15)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                time.sleep(0.1)
            except OSError:
                return

    def tui_probe(self, stale: str = "") -> dict:
        env = {**self.env, "VEASEL_API_URL": f"http://127.0.0.1:{self.port}"}
        out = subprocess.run([self.bun, "run", str(REPO / "scripts" / "auth-lifecycle-tui-probe.ts"), stale],
                             env=env, capture_output=True, text=True, timeout=60, cwd=REPO / "tui")
        assert out.returncode == 0, out.stderr
        return json.loads(out.stdout.strip().splitlines()[-1])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--bun", default="bun")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="veasel-auth-lifecycle-") as tmp:
        h = Harness(args.server.resolve(strict=True), args.bun, Path(tmp))
        try:
            run(h)
        finally:
            h.stop_all()
    print("auth lifecycle smoke passed")


def run(h: Harness) -> None:
    # 1. CLI-first: the CLI spawns the backend (spawn path).
    result = h.cli("config", "model", "get", "--json")
    check(result.returncode == 0, f"CLI spawns a backend and authenticates (rc={result.returncode} {result.stderr.strip()[:120]})")
    check(h.token_path.exists(), "token file created by the spawned backend")
    mode = stat.S_IMODE(h.token_path.stat().st_mode)
    check(mode == 0o600, f"token file mode is 0600 (got {oct(mode)})")
    check(stat.S_IMODE(h.data.stat().st_mode) & 0o077 == 0, "data dir is not group/world accessible")
    token1 = h.token()
    check(len(token1) == 64, "token is 256-bit hex")
    anon = health(h.port)
    check(anon == {"healthy": True}, "anonymous health is minimal liveness only")
    authed = health(h.port, token1)
    pid1 = authed["pid"]
    check(authed["version"] and pid1 > 0, "authenticated health returns identity")

    # 2. Attach: a second CLI call reuses the same server (no new spawn).
    result = h.cli("config", "model", "get", "--json")
    check(result.returncode == 0 and health(h.port, token1)["pid"] == pid1, "CLI attaches to the running backend")

    # 3. TUI-first started backend, Desktop-style attach: identity needs the token file value.
    check(health(h.port, h.token())["pid"] == pid1, "Desktop-style probe attaches using the token file")
    tui = h.tui_probe()
    check(tui["sessions"] == 200 and tui["events"] == 200 and tui["requests"] == 2, f"TUI client authenticates incl. SSE ({tui})")

    # 4. Rotation while clients hold the old token.
    result = h.cli("token", "rotate")
    check(result.returncode == 0, "veasel token rotate succeeds against the live server")
    token2 = h.token()
    check(token2 != token1, "token file changed")
    check(http(h.port, "/v1/sessions", token1)[0] == 401, "old token is rejected after rotation")
    check(http(h.port, "/v1/events", token1, read=False)[0] == 401, "SSE with the old token is rejected before any event")
    status, body = http(h.port, "/v1/sessions", token2)
    check(status == 200, "new token works")
    check(health(h.port, token1) == {"healthy": True}, "old token only gets minimal liveness (no identity)")
    check(health(h.port, token2)["pid"] == pid1, "rotation did not restart the server")
    tui = h.tui_probe(stale=token1)
    check(tui["sessions"] == 200 and tui["events"] == 200 and tui["requests"] == 3, f"TUI client holding the old token re-reads the file and retries once ({tui})")
    result = h.cli("config", "model", "get", "--json")
    check(result.returncode == 0, "CLI re-reads the rotated token")

    # 5. Restart reuse.
    h.stop_all()
    h.start_serve()  # Desktop-first style start of a fresh process.
    check(h.token() == token2, "restart reuses the token file")
    check(http(h.port, "/v1/sessions", token2)[0] == 200, "client holding the pre-restart token still works")
    check(http(h.port, "/v1/sessions", token1)[0] == 401, "replay of a pre-rotation token still fails after restart")
    pid2 = health(h.port, token2)["pid"]
    check(pid2 != pid1, "the restart produced a new process")

    # 6. Desktop-first, then CLI/TUI attach (backend owned by a supervisor-style start).
    result = h.cli("config", "model", "get", "--json")
    check(result.returncode == 0 and health(h.port, token2)["pid"] == pid2, "CLI attaches to a Desktop-started backend")
    tui = h.tui_probe()
    check(tui["sessions"] == 200 and tui["events"] == 200, "TUI attaches to a Desktop-started backend")

    # 7. A group-readable token file makes the server refuse to start (fail closed).
    h.stop_all()
    os.chmod(h.token_path, 0o640)
    refused = subprocess.run([str(h.server), "serve"], env=h.env, capture_output=True, text=True, timeout=20)
    check(refused.returncode != 0 and "group or other" in refused.stderr, "server refuses to start with a group-readable token file")
    check(http_down(h.port), "no listener was opened")
    os.chmod(h.token_path, 0o600)


def http_down(port: int) -> bool:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.3).close()
        return False
    except OSError:
        return True


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
