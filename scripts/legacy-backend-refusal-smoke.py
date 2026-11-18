#!/usr/bin/env python3
"""A legacy (unauthenticated) backend on the port must be refused, never used.

Starts fake servers that behave like a backend from before caller
authentication (old health with version/pid, protected routes answer 200), one
that spoofs the capability, and one with unparseable health. The REAL `veasel`
CLI (and the real TUI binary when --tui is given) must exit non-zero with the
recovery message, must not spawn a backend, and the fake must never receive an
Authorization header. A current backend is attached normally.

  python3 scripts/legacy-backend-refusal-smoke.py --server dist/veasel [--tui dist/veasel-tui]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def make_server(mode: str):
    seen_auth: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            auth = self.headers.get("Authorization")
            if auth:
                seen_auth.append(auth)
            status, body = 200, "{}"
            if self.path == "/v1/health":
                body = {
                    "legacy": '{"healthy":true,"version":"0.0.9","pid":4242}',
                    "spoof": '{"healthy":true,"auth":"bearer","protocol":1}',
                    "garbage": "not json at all",
                }[mode]
            elif self.path.startswith("/v1/operations"):
                body = '{"operations":[{"operation":{"status":"running"}}]}'
            data = body.encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_POST = do_GET

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, seen_auth


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"ok: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--tui", type=Path)
    args = parser.parse_args()
    veasel = args.server.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="veasel-legacy-") as tmp:
        root = Path(tmp)
        for mode in ("legacy", "spoof", "garbage"):
            server, seen_auth = make_server(mode)
            port = server.server_address[1]
            data = root / f"data-{mode}"
            # The token a legitimate profile would hold; it must never leave the machine's trust.
            data.mkdir(mode=0o700)
            (data / "api-token").write_text("a" * 64 + "\n")
            os.chmod(data / "api-token", 0o600)
            env = {
                **{k: v for k, v in os.environ.items() if not k.startswith("VEASEL_")},
                "VEASEL_PORT": str(port),
                "VEASEL_DATA_DIR": str(data),
                "VEASEL_SECRET_STORE": "file",
                "HOME": str(root),
            }
            commands = [[str(veasel), "config", "model", "get", "--json"], [str(veasel), "skills", "list"]]
            if args.tui:
                commands.append([str(args.tui.resolve(strict=True))])
            for command in commands:
                result = subprocess.run(command, env={**env, "VEASEL_API_URL": f"http://127.0.0.1:{port}"},
                                        capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
                label = f"{Path(command[0]).name} {' '.join(command[1:3])} vs {mode}"
                check(result.returncode != 0, f"{label}: refused (rc={result.returncode})")
                check("legacy Veasel backend" in result.stderr and f"127.0.0.1:{port}" in result.stderr,
                      f"{label}: recovery message names the port")
                check("taskkill" in result.stderr and "SEPARATE VEASEL_DATA_DIR" in result.stderr,
                      f"{label}: recovery steps are present")
                check(not (data / "veasel.sqlite3").exists(), f"{label}: no backend was spawned on that data dir")
            if mode == "legacy":
                check("1 turn(s) are running or queued" in result.stderr, "in-flight turns are reported read-only")
            check(not seen_auth, f"{mode}: the fake server never received an Authorization header")
            server.shutdown()
    print("legacy backend refusal smoke passed")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
