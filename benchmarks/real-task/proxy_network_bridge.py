"""Narrow host-proxy bridge for an isolated benchmark network namespace.

The host side accepts only a private Unix socket and forwards bytes to one
fixed loopback BudgetProxy port. The namespace side exposes that socket as a
loopback TCP endpoint for clients that cannot use Unix sockets directly.
Neither side logs request data or credentials.
"""

from __future__ import annotations

import argparse
import os
import select
import socket
import stat
import subprocess
import sys
import threading
from pathlib import Path
from typing import Sequence


MAX_RELAY_CONNECTIONS = 8
BUFFER_SIZE = 64 * 1024


def _relay_bidirectional(left: socket.socket, right: socket.socket) -> None:
    """Copy bytes without interpreting or persisting either stream."""
    open_reads = {left, right}
    while open_reads:
        readable, _, exceptional = select.select(list(open_reads), [], list(open_reads), 1.0)
        if exceptional:
            return
        for source in readable:
            destination = right if source is left else left
            try:
                chunk = source.recv(BUFFER_SIZE)
            except OSError:
                return
            if not chunk:
                open_reads.discard(source)
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                continue
            try:
                destination.sendall(chunk)
            except OSError:
                return


class UnixBudgetProxyRelay:
    """Expose one loopback HTTP budget proxy through a private Unix socket."""

    def __init__(self, socket_path: Path, proxy_port: int) -> None:
        socket_path = socket_path.expanduser()
        if not socket_path.is_absolute():
            raise ValueError("relay socket path must be absolute")
        if isinstance(proxy_port, bool) or not isinstance(proxy_port, int) or not 1 <= proxy_port <= 65535:
            raise ValueError("budget proxy port is invalid")
        parent = socket_path.parent.resolve(strict=True)
        metadata = parent.stat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() \
                or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise ValueError("relay directory must be owned by this user with mode 0700")
        socket_path = parent / socket_path.name
        if socket_path.exists() or socket_path.is_symlink():
            raise ValueError("refusing to replace an existing relay path")
        self.socket_path = socket_path
        self.proxy_port = proxy_port
        self._server: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._closing = threading.Event()
        self._active = threading.BoundedSemaphore(MAX_RELAY_CONNECTIONS)

    def start(self) -> Path:
        if self._server is not None:
            raise RuntimeError("Unix relay already started")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(self.socket_path))
            os.chmod(self.socket_path, 0o600)
            server.listen(MAX_RELAY_CONNECTIONS)
            server.settimeout(0.25)
        except Exception:
            server.close()
            try:
                self.socket_path.unlink()
            except FileNotFoundError:
                pass
            raise
        self._server = server
        self._thread = threading.Thread(target=self._serve, name="benchmark-proxy-unix", daemon=True)
        self._thread.start()
        return self.socket_path

    def _serve(self) -> None:
        assert self._server is not None
        while not self._closing.is_set():
            try:
                client, _ = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            if not self._active.acquire(blocking=False):
                client.close()
                continue
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _handle(self, client: socket.socket) -> None:
        upstream: socket.socket | None = None
        try:
            upstream = socket.create_connection(("127.0.0.1", self.proxy_port), timeout=5)
            client.settimeout(None)
            upstream.settimeout(None)
            _relay_bidirectional(client, upstream)
        except OSError:
            # Do not expose local proxy details or stream content to the agent.
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        finally:
            client.close()
            if upstream is not None:
                upstream.close()
            self._active.release()

    def close(self) -> None:
        if self._closing.is_set():
            return
        self._closing.set()
        server = self._server
        self._server = None
        if server is not None:
            server.close()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        try:
            metadata = self.socket_path.lstat()
            if stat.S_ISSOCK(metadata.st_mode) and metadata.st_uid == os.getuid():
                self.socket_path.unlink()
        except FileNotFoundError:
            pass

    def __enter__(self) -> UnixBudgetProxyRelay:
        self.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()


def run_namespace_bridge(socket_path: Path, command: Sequence[str], port: int = 18765) -> int:
    """Run an agent with a loopback listener backed only by the mounted socket."""
    if not command:
        raise ValueError("agent command is required")
    if not socket_path.is_absolute():
        raise ValueError("relay socket path must be absolute")
    if isinstance(port, bool) or not 1 <= port <= 65535:
        raise ValueError("local relay port is invalid")

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
    listener.bind(("127.0.0.1", port))
    listener.listen(MAX_RELAY_CONNECTIONS)
    listener.settimeout(0.25)
    closing = threading.Event()
    active = threading.BoundedSemaphore(MAX_RELAY_CONNECTIONS)

    def handle(client: socket.socket) -> None:
        upstream: socket.socket | None = None
        try:
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.settimeout(5)
            upstream.connect(str(socket_path))
            client.settimeout(None)
            upstream.settimeout(None)
            _relay_bidirectional(client, upstream)
        except OSError:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        finally:
            client.close()
            if upstream is not None:
                upstream.close()
            active.release()

    def accept_connections() -> None:
        while not closing.is_set():
            try:
                client, _ = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            if not active.acquire(blocking=False):
                client.close()
                continue
            threading.Thread(target=handle, args=(client,), daemon=True).start()

    accept_thread = threading.Thread(target=accept_connections, name="benchmark-proxy-loopback", daemon=True)
    accept_thread.start()
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(list(command), start_new_session=False)
        return process.wait()
    except KeyboardInterrupt:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        return 130
    finally:
        closing.set()
        listener.close()
        accept_thread.join(timeout=2)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    try:
        return run_namespace_bridge(args.socket, command, args.port)
    except (OSError, ValueError) as exc:
        print(f"benchmark proxy bridge unavailable: {type(exc).__name__}", file=sys.stderr)
        return 69


if __name__ == "__main__":
    raise SystemExit(main())
