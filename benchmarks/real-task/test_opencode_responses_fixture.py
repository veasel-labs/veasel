"""Optional end-to-end check against the pinned OpenCode CLI and a local fixture."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import run as runner
from responses_proxy import BudgetProxy


CASE_PATH = HERE / "cases/website-173-muse-spark-v0795/case.json"
CASE = json.loads(CASE_PATH.read_text())
OPENCODE = shutil.which("opencode")
PINNED_OPENCODE_AVAILABLE = bool(OPENCODE and runner.open_code_version(OPENCODE) == "opencode v2.2.7")


class _ResponsesFixtureHandler(BaseHTTPRequestHandler):
    requests: list[dict[str, Any]] = []
    lock = threading.Lock()

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_POST(self) -> None:
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        with self.lock:
            self.requests.append({
                "path": self.path,
                "model": payload.get("model"),
                "stream": payload.get("stream"),
                "authorization": self.headers.get("Authorization"),
                "payload_keys": sorted(payload),
            })
        if self.path == "/v1/responses/input_tokens":
            body = json.dumps({"object": "response.input_tokens", "input_tokens": 4096}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        model = payload["model"]
        response = {
            "id": "resp_local_fixture", "object": "response", "status": "completed", "model": model,
            "output": [{
                "id": "msg_local_fixture", "type": "message", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": "Fixture answer verified."}],
            }],
            "usage": {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                      "output_tokens": 4, "output_tokens_details": {"reasoning_tokens": 0},
                      "total_tokens": 14},
        }
        events = [
            {"type": "response.created", "response": {"id": "resp_local_fixture", "object": "response",
                                                            "status": "in_progress", "model": model}},
            {"type": "response.output_text.delta", "item_id": "msg_local_fixture", "output_index": 0,
             "content_index": 0, "delta": "Fixture answer verified."},
            {"type": "response.completed", "response": response},
        ]
        body = "".join(f"event: {item['type']}\ndata: {json.dumps(item)}\n\n" for item in events)
        encoded = (body + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


@unittest.skipUnless(PINNED_OPENCODE_AVAILABLE, "requires pinned OpenCode 2.2.7")
class OpenCodeResponsesFixtureTests(unittest.TestCase):
    def test_pinned_opencode_uses_responses_proxy_and_returns_fixture_usage(self) -> None:
        with _ResponsesFixtureHandler.lock:
            _ResponsesFixtureHandler.requests.clear()
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), _ResponsesFixtureHandler)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        budget = runner.responses_proxy_budget(CASE, "5")
        proxy = BudgetProxy(
            upstream_base_url=f"http://127.0.0.1:{upstream.server_port}/v1",
            api_key="fixture-upstream-secret",
            model=CASE["model"]["name"],
            max_requests=budget["upstream_attempt_limit"],
            context_tokens=CASE["model"]["context_tokens"],
            output_tokens=CASE["model"]["output_tokens"],
            client_api_key="fixture-local-secret",
            max_request_body_bytes=budget["max_request_body_bytes"],
            max_run_cost_usd=budget["enforced_run_cost_cap_usd"],
            input_usd_per_million_tokens=CASE["cost_budget"]["input_usd_per_million_tokens"],
            output_usd_per_million_tokens=CASE["cost_budget"]["output_usd_per_million_tokens"],
        )
        proxy_url = proxy.start()
        try:
            with tempfile.TemporaryDirectory(prefix="veasel-opencode-fixture-") as temp_dir:
                private_root = Path(temp_dir)
                config_path = private_root / "opencode.json"
                config_path.write_text(json.dumps(runner.open_code_config(CASE, proxy_url)))
                config_path.chmod(0o600)
                self.assertNotIn("fixture-local-secret", config_path.read_text())
                self.assertNotIn("fixture-upstream-secret", config_path.read_text())
                env = {
                    "PATH": os.environ["PATH"], "HOME": temp_dir,
                    "OPENCODE_CONFIG": str(config_path),
                    "XDG_CONFIG_HOME": temp_dir, "XDG_DATA_HOME": temp_dir, "XDG_CACHE_HOME": temp_dir,
                    "VEASEL_BENCHMARK_PROXY_KEY": "fixture-local-secret",
                }
                result = subprocess.run(
                    [OPENCODE, "run", "--standalone", "--model", CASE["comparators"]["opencode_model"],
                     "--agent", "build", "--format", "json", "Say exactly Fixture answer verified."],
                    env=env, capture_output=True, text=True, timeout=30, check=False,
                )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout[-1500:])
            self.assertIn('"input":10', result.stdout)
            self.assertIn('"output":4', result.stdout)
            with _ResponsesFixtureHandler.lock:
                calls = list(_ResponsesFixtureHandler.requests)
            self.assertEqual([call["path"] for call in calls], [
                "/v1/responses/input_tokens", "/v1/responses",
            ], calls)
            self.assertEqual(calls[0]["model"], CASE["model"]["name"])
            self.assertEqual(calls[0]["payload_keys"], ["input", "instructions", "model", "tools"])
            self.assertEqual(calls[0]["authorization"], "Bearer fixture-upstream-secret")
            self.assertEqual(calls[1]["model"], CASE["model"]["name"])
            self.assertTrue(calls[1]["stream"])
            self.assertEqual(calls[1]["authorization"], "Bearer fixture-upstream-secret")
            metrics = proxy.metrics()
            self.assertEqual(metrics["upstream_generation_attempts"], 1)
            self.assertEqual(metrics["input_token_prechecks"], 1)
            self.assertLessEqual(metrics["upstream_generation_attempts"], budget["upstream_attempt_limit"])
            self.assertGreater(proxy.metrics()["max_request_body_bytes_seen"], 0)
        finally:
            proxy.close()
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
