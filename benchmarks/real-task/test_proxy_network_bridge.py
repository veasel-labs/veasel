from __future__ import annotations

import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

from proxy_network_bridge import UnixBudgetProxyRelay, run_namespace_bridge
from sandbox_test_support import LINUX_BWRAP_NETWORK_SKIP_REASON, LINUX_BWRAP_NETWORK_SUPPORTED


class ProxyFixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        response = b"PROXY_FIXTURE:" + body
        self.send_response(200)
        self.send_header("Content-Length", str(len(response)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args: object) -> None:
        pass


class ProxyNetworkBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="veasel-proxy-bridge-")
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ProxyFixtureHandler)
        self.httpd.daemon_threads = True
        self.http_thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.http_thread.start()

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.http_thread.join(timeout=2)
        self.temp.cleanup()

    def test_unix_relay_forwards_only_to_the_configured_loopback_proxy(self) -> None:
        relay = UnixBudgetProxyRelay(self.root / "budget.sock", self.httpd.server_port)
        with relay:
            self.assertEqual((relay.socket_path.stat().st_mode & 0o777), 0o600)
            request = Request(
                f"http://127.0.0.1:{self.httpd.server_port}/responses",
                data=b"fixture-request",
                method="POST",
            )
            with urlopen(request, timeout=3) as response:
                self.assertEqual(response.read(), b"PROXY_FIXTURE:fixture-request")
        self.assertFalse(relay.socket_path.exists())

    def test_rejects_nonprivate_directories_and_existing_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="veasel-public-") as public_dir:
            Path(public_dir).chmod(0o755)
            with self.assertRaisesRegex(ValueError, "mode 0700"):
                UnixBudgetProxyRelay(Path(public_dir) / "budget.sock", self.httpd.server_port)
        existing = self.root / "occupied"
        existing.write_text("preserve")
        with self.assertRaisesRegex(ValueError, "refusing to replace"):
            UnixBudgetProxyRelay(existing, self.httpd.server_port)
        self.assertEqual(existing.read_text(), "preserve")

    def test_guest_bridge_exposes_the_unix_relay_as_loopback_tcp(self) -> None:
        relay = UnixBudgetProxyRelay(self.root / "guest.sock", self.httpd.server_port)
        relay.start()
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        code = (
            "from urllib.request import Request,urlopen; "
            f"r=Request('http://127.0.0.1:{port}/responses',data=b'guest',method='POST'); "
            "print(urlopen(r,timeout=3).read().decode())"
        )
        try:
            result = run_namespace_bridge(
                relay.socket_path,
                [sys.executable, "-c", code],
                port=port,
            )
            self.assertEqual(result, 0)
        finally:
            relay.close()

    @unittest.skipUnless(LINUX_BWRAP_NETWORK_SUPPORTED, LINUX_BWRAP_NETWORK_SKIP_REASON)
    def test_bubblewrap_cannot_reach_host_loopback_but_can_reach_mounted_budget_relay(self) -> None:
        denied = ThreadingHTTPServer(("127.0.0.1", 0), ProxyFixtureHandler)
        denied.daemon_threads = True
        denied_thread = threading.Thread(target=denied.serve_forever, daemon=True)
        denied_thread.start()
        try:
            code = (
                "from urllib.request import urlopen; "
                f"urlopen('http://127.0.0.1:{denied.server_port}/',timeout=1)"
            )
            result = subprocess.run(
                ["/usr/bin/bwrap", "--unshare-all", "--ro-bind", "/", "/",
                 "/usr/bin/python3", "-c", code],
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, "isolated agent unexpectedly reached host loopback")
        finally:
            denied.shutdown()
            denied.server_close()
            denied_thread.join(timeout=2)

        relay = UnixBudgetProxyRelay(self.root / "mounted.sock", self.httpd.server_port)
        relay.start()
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        # Keep the script simple and use the source checkout only as read-only code.
        module_dir = str(Path(__file__).resolve().parent)
        script = (
            "import sys; from pathlib import Path; "
            f"sys.path.insert(0,{module_dir!r}); "
            "from proxy_network_bridge import run_namespace_bridge; "
            f"raise SystemExit(run_namespace_bridge(Path({str(relay.socket_path)!r}), "
            f"[sys.executable,'-c',{('from urllib.request import Request,urlopen; ' + f'r=Request(\"http://127.0.0.1:{port}/responses\",data=b\"sandbox\",method=\"POST\"); print(urlopen(r,timeout=3).read().decode())')!r}], {port}))"
        )
        wrapped = subprocess.run(
            [os.environ.get("VEASEL_BWRAP", "/usr/bin/bwrap"), "--unshare-all", "--ro-bind", "/", "/",
             "/usr/bin/python3", "-c", script],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        relay.close()
        self.assertEqual(wrapped.returncode, 0, wrapped.stderr)
        self.assertIn("PROXY_FIXTURE:sandbox", wrapped.stdout)


if __name__ == "__main__":
    unittest.main()
