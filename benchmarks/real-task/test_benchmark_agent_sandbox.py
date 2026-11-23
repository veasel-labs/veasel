from __future__ import annotations

import os
import socket
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from benchmark_agent_sandbox import build_bwrap_command
from proxy_network_bridge import UnixBudgetProxyRelay
from sandbox_test_support import LINUX_BWRAP_NETWORK_SKIP_REASON, LINUX_BWRAP_NETWORK_SUPPORTED


SCRIPT_DIR = Path(__file__).resolve().parent


class ProxyFixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        response = b"BOUNDED_PROXY:" + body
        self.send_response(200)
        self.send_header("Content-Length", str(len(response)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args: object) -> None:
        pass


@unittest.skipUnless(Path("/usr/bin/bwrap").is_file(), "Bubblewrap is required for the Linux outer-sandbox proof")
class BenchmarkAgentSandboxTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="veasel-agent-sandbox-", dir=Path.home())
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.parent = self.root / "workspaces"
        self.parent.mkdir(mode=0o700)
        self.task = self.parent / "veasel-real-task-sandbox-test"
        self.task.mkdir(mode=0o700)
        (self.task / "tracked.txt").write_text("workspace fixture")
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        shutil.copy2(SCRIPT_DIR / "opencode-shell-sandbox.sh", self.state / "opencode-shell-sandbox.sh")
        (self.state / "opencode-shell-sandbox.sh").chmod(0o700)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir(mode=0o700)
        self.relay_dir = self.root / "relay"
        self.relay_dir.mkdir(mode=0o700)
        self.hidden = self.root / "other-run-secret.txt"
        self.hidden.write_text("must not enter the agent namespace")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ProxyFixtureHandler)
        self.httpd.daemon_threads = True
        self.http_thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.http_thread.start()
        self.relay = UnixBudgetProxyRelay(self.relay_dir / "budget.sock", self.httpd.server_port)
        self.relay.start()
        env = {
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "VEASEL_REAL_TASK_ROOT": str(self.task),
            "VEASEL_REAL_TASK_PARENT": str(self.parent),
            "VEASEL_BENCHMARK_STATE_DIR": str(self.state),
            "VEASEL_BENCHMARK_ARTIFACTS": str(self.artifacts),
            "VEASEL_BENCHMARK_PROXY_SOCKET": str(self.relay.socket_path),
            "VEASEL_BENCHMARK_PROXY_KEY": "fixture-client-key",
            "VEASEL_BENCHMARK_AGENT": "veasel",
            "VEASEL_BENCHMARK_BRIDGE_SCRIPT": str(SCRIPT_DIR / "proxy_network_bridge.py"),
            "VEASEL_BWRAP": os.environ.get("VEASEL_BWRAP", "/usr/bin/bwrap"),
        }
        self.wrapper_env = env

    def tearDown(self) -> None:
        self.relay.close()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.http_thread.join(timeout=2)
        self.temp.cleanup()

    @unittest.skipUnless(LINUX_BWRAP_NETWORK_SUPPORTED, LINUX_BWRAP_NETWORK_SKIP_REASON)
    def test_wrapper_exposes_only_task_state_artifacts_and_budget_proxy(self) -> None:
        host_port = socket.socket()
        host_port.bind(("127.0.0.1", 0))
        unrelated_loopback_port = host_port.getsockname()[1]
        host_port.close()
        child_code = (
            "import os,socket; from pathlib import Path; "
            "assert 'VEASEL_BENCHMARK_PROXY_KEY' not in os.environ; "
            "assert not Path('/tmp/veasel-proxy/budget.sock').exists(); "
            f"s=socket.socket(); s.settimeout(1); "
            f"assert s.connect_ex(('127.0.0.1',{unrelated_loopback_port})) != 0"
        )
        probe = (
            "from pathlib import Path; import os,socket,subprocess,urllib.request; "
            "assert Path(os.environ['VEASEL_REAL_TASK_ROOT'],'tracked.txt').read_text() == 'workspace fixture'; "
            "assert 'VEASEL_BENCHMARK_PROXY_KEY' not in os.environ; "
            "assert 'VEASEL_BENCHMARK_PROXY_SOCKET' not in os.environ; "
            "assert 'VEASEL_MODEL_API_KEY' not in os.environ; "
            f"hidden={str(self.hidden)!r}; "
            "assert not Path(hidden).exists(), 'unrelated benchmark state is visible'; "
            "s=socket.socket(); s.settimeout(1); "
            f"assert s.connect_ex(('127.0.0.1',{unrelated_loopback_port})) != 0, 'host loopback is visible'; "
            "r=urllib.request.Request('http://127.0.0.1:18765/v1/responses', "
            "data=b'approved-request', method='POST'); "
            "assert urllib.request.urlopen(r, timeout=3).read() == b'BOUNDED_PROXY:approved-request'; "
            f"child={child_code!r}; "
            "shell_env=dict(os.environ); shell_env['VEASEL_BWRAP']='/usr/bin/bwrap'; "
            "nested=subprocess.run(['/tmp/veasel-state/opencode-shell-sandbox.sh','-c',"
            "'/usr/bin/python3 -c ' + repr(child)], cwd=os.environ['VEASEL_REAL_TASK_ROOT'], "
            "env=shell_env, capture_output=True, text=True, timeout=5); "
            "assert nested.returncode == 0, nested.stderr; "
            "Path('/tmp/veasel-artifacts/wrapper-proof.txt').write_text('sandbox-ok')"
        )
        env = dict(self.wrapper_env)
        command = [sys.executable, str(SCRIPT_DIR / "benchmark_agent_sandbox.py"), "--",
                   "/usr/bin/python3", "-c", probe]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=12, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.artifacts / "wrapper-proof.txt").read_text(), "sandbox-ok")

    def test_refuses_direct_upstream_credentials_and_invalid_task_parent(self) -> None:
        env = dict(self.wrapper_env)
        env["VEASEL_MODEL_API_KEY"] = "never-forward-upstream-credential"
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(ValueError, "direct provider credentials"):
                build_bwrap_command(["/usr/bin/python3", "-c", "pass"])
        bad_env = dict(self.wrapper_env)
        bad_env["VEASEL_MODEL_API_KEY"] = bad_env["VEASEL_BENCHMARK_PROXY_KEY"]
        bad_env["VEASEL_BENCHMARK_PROXY_KEY"] = "different-ephemeral-proxy-key"
        with patch.dict(os.environ, bad_env, clear=True):
            with self.assertRaisesRegex(ValueError, "direct provider credentials"):
                build_bwrap_command(["/usr/bin/python3", "-c", "pass"])
        bad_env = dict(self.wrapper_env)
        bad_env["VEASEL_REAL_TASK_PARENT"] = str(self.root)
        with patch.dict(os.environ, bad_env, clear=True):
            with self.assertRaisesRegex(ValueError, "direct veasel-real-task"):
                build_bwrap_command(["/usr/bin/python3", "-c", "pass"])

    def test_only_opencode_receives_the_proxy_credential_in_its_runtime_environment(self) -> None:
        env = dict(self.wrapper_env)
        env["VEASEL_BENCHMARK_AGENT"] = "opencode"
        with patch.dict(os.environ, env, clear=True):
            _command, guest = build_bwrap_command(["/usr/bin/python3", "-c", "pass"])
        self.assertEqual(guest["VEASEL_BENCHMARK_PROXY_KEY"], "fixture-client-key")
        self.assertNotIn("VEASEL_BENCHMARK_PROXY_SOCKET", guest)
        self.assertNotIn("VEASEL_MODEL_API_KEY", guest)


if __name__ == "__main__":
    unittest.main()
