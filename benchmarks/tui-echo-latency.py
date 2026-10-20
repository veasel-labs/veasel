#!/usr/bin/env python3
"""Composer key-echo latency probe against the real packaged binaries.

OpenTUI renders frame diffs, so raw PTY byte growth cannot measure echo:
this probe feeds the PTY stream into a pyte screen emulator and times how
long each typed character takes to become visible in the composer. It
proves interactive echo latency on this host only; it does not measure
model quality, coding-task success, or rendering fidelity beyond the
asserted screen text.

Requires: pyte (pip install pyte). Binaries via env:
  VEASEL_BIN (default: veasel), VEASEL_TUI_BIN (default: veasel-tui).

Baseline (2026-10-20, v0.64.2-next.0 binaries, 100x24):
  connect render 96 ms, composer-after-Enter 23 ms,
  key echo p50 16 ms, p95 18 ms, 16/16 keys (one 60 fps frame).
"""
import fcntl
import os
import pty
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import urllib.request

try:
    import pyte
except ImportError:
    print("pyte is required: pip install pyte", file=sys.stderr)
    raise SystemExit(2)

TUI = os.environ.get("VEASEL_TUI_BIN", "veasel-tui")
SERVER = os.environ.get("VEASEL_BIN", "veasel")
PROBE = "echo probe 12345"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_health(port, timeout=20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=2) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("server health timeout")


def main():
    port = free_port()
    data = tempfile.mkdtemp(prefix="veasel-echo-")
    env = dict(os.environ)
    env.update(
        TERM="xterm-256color",
        VEASEL_PORT=str(port),
        VEASEL_DATA_DIR=data,
        VEASEL_PLUGIN_DIR=os.path.join(data, "plugins"),
        VEASEL_API_URL=f"http://127.0.0.1:{port}",
    )
    server = subprocess.Popen(
        [SERVER, "serve"], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        wait_health(port)
        child, term = pty.fork()
        if child == 0:
            os.execve(TUI, [TUI], env)
        fcntl.ioctl(term, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        screen = pyte.Screen(100, 24)
        stream = pyte.ByteStream(screen)

        def pump(timeout):
            r, _, _ = select.select([term], [], [], timeout)
            if r:
                try:
                    chunk = os.read(term, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    stream.feed(chunk)

        def text():
            return "\n".join(screen.display)

        def wait(marker, timeout):
            start = time.monotonic()
            while time.monotonic() - start < timeout:
                if marker in text():
                    return (time.monotonic() - start) * 1000
                pump(0.002)
            return -1.0

        try:
            print(f"connected_ms {wait('connected', 15):.0f}")
            os.write(term, b"n")  # fresh store: create the first session
            print(f"composer_ms {wait('Compose', 10):.0f}")
            for _ in range(60):  # clear any restored draft
                os.write(term, b"\x7f")
            time.sleep(0.3)
            pump(0.3)
            lat, typed = [], ""
            for ch in PROBE:
                typed += ch
                os.write(term, ch.encode())
                lat.append(wait(typed, 3))
            ok = sorted(x for x in lat if x >= 0)
            if len(ok) != len(lat):
                print(f"FAIL: {len(ok)}/{len(lat)} keys became visible")
                return 1
            print(f"echo_p50_ms {ok[len(ok) // 2]:.0f}")
            print(f"echo_p95_ms {ok[int(len(ok) * 0.95)]:.0f}")
            print(f"echo_max_ms {ok[-1]:.0f}")
            print(f"keys {len(ok)}/{len(lat)}")
            return 0
        finally:
            try:
                os.kill(child, 9)
                os.waitpid(child, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


if __name__ == "__main__":
    raise SystemExit(main())
