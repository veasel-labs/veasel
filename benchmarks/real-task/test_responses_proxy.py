"""Contract tests for the isolated OpenAI Responses API budget proxy.

All upstream traffic is sent to a local HTTP fixture; these tests never call a
hosted model provider.
"""

from __future__ import annotations

import importlib
import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


TEST_DIR = Path(__file__).resolve().parent
if str(TEST_DIR) not in sys.path:
    sys.path.insert(0, str(TEST_DIR))

responses_proxy = importlib.import_module("responses_proxy")


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, _req: Request, _fp: Any, _code: int, _message: str,
                         _headers: Any, _new_url: str) -> None:
        return None


HTTP_OPENER = build_opener(_NoRedirect())


class UpstreamFixtureHandler(BaseHTTPRequestHandler):
    requests_seen: list[dict[str, Any]] = []
    requests_lock = threading.Lock()
    redirect_next = False

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _record(self, body: bytes = b"") -> None:
        with self.requests_lock:
            self.requests_seen.append({
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "body": body,
            })

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self._record(body)
        with self.requests_lock:
            should_redirect = self.redirect_next
            self.redirect_next = False
        if should_redirect:
            self.send_response(307)
            self.send_header("Location", "/redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        payload = json.dumps({"id": "resp_fixture_1", "output": []}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        self._record()
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


class ResponsesProxyTests(unittest.TestCase):
    upstream: ThreadingHTTPServer
    upstream_thread: threading.Thread
    proxy: Any
    proxy_url: str

    @classmethod
    def setUpClass(cls) -> None:
        UpstreamFixtureHandler.requests_seen = []
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamFixtureHandler)
        cls.upstream_thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.upstream_thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.upstream_thread.join(timeout=2)

    def setUp(self) -> None:
        with UpstreamFixtureHandler.requests_lock:
            UpstreamFixtureHandler.requests_seen.clear()
            UpstreamFixtureHandler.redirect_next = False
        self.proxy = responses_proxy.BudgetProxy(
            upstream_base_url=f"http://127.0.0.1:{self.upstream.server_port}/v1",
            api_key="upstream-secret-test",
            model="fixture-model",
            max_requests=4,
            context_tokens=8192,
            output_tokens=32,
            client_api_key="local-client-secret-test",
        )
        self.proxy_url = self.proxy.start()
        self.addCleanup(lambda: self.proxy.close())

    def test_live_upstream_is_pinned_to_meta_api_host(self) -> None:
        with self.assertRaisesRegex(ValueError, "api.meta.ai"):
            responses_proxy.BudgetProxy(
                upstream_base_url="https://attacker.example/v1",
                api_key="upstream-secret-test", model="fixture-model", max_requests=1,
                context_tokens=256, output_tokens=32, client_api_key="local-client-secret-test",
            )

    def responses_endpoint(self, path: str = "/v1/responses") -> str:
        parsed = urlsplit(self.proxy_url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        return origin + path

    def post_json(
        self,
        payload: dict[str, Any],
        *,
        path: str = "/v1/responses",
        api_key: str | None = "local-client-secret-test",
    ) -> tuple[int, bytes]:
        headers = {"Content-Type": "application/json"}
        if api_key is not None:
            headers["Authorization"] = f"Bearer {api_key}"
        request = Request(
            self.responses_endpoint(path),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with HTTP_OPENER.open(request, timeout=3) as response:
                return response.status, response.read()
        except HTTPError as error:
            try:
                return error.code, error.read()
            finally:
                error.close()
        except URLError as error:
            self.fail(f"proxy request failed before returning an HTTP response: {error}")

    @staticmethod
    def valid_payload(**overrides: Any) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": "fixture-model",
            "input": "Summarize this local test fixture.",
            "max_output_tokens": 16,
        }
        payload.update(overrides)
        return payload

    @classmethod
    def upstream_requests(cls) -> list[dict[str, Any]]:
        with UpstreamFixtureHandler.requests_lock:
            return list(UpstreamFixtureHandler.requests_seen)

    def test_forwards_only_responses_posts_and_replaces_local_auth(self) -> None:
        status, body = self.post_json(self.valid_payload())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["id"], "resp_fixture_1")

        forwarded = self.upstream_requests()
        self.assertEqual(len(forwarded), 1)
        self.assertEqual(forwarded[0]["method"], "POST")
        self.assertEqual(forwarded[0]["path"], "/v1/responses")
        self.assertEqual(forwarded[0]["authorization"], "Bearer upstream-secret-test")
        forwarded_body = json.loads(forwarded[0]["body"])
        self.assertEqual(forwarded_body["model"], "fixture-model")
        self.assertEqual(forwarded_body["max_output_tokens"], 16)
        self.assertNotIn("local-client-secret-test", str(forwarded))
        self.assertEqual(self.proxy.metrics()["upstream_attempts_reserved"], 1)

    def test_rejects_redirects_without_following_them(self) -> None:
        with UpstreamFixtureHandler.requests_lock:
            UpstreamFixtureHandler.redirect_next = True
        status, _body = self.post_json(self.valid_payload())
        self.assertGreaterEqual(status, 300)
        self.assertEqual([item["path"] for item in self.upstream_requests()], ["/v1/responses"])
        self.assertEqual(self.proxy.metrics()["upstream_attempts_reserved"], 1)

    def test_rejects_unsupported_routes_without_forwarding(self) -> None:
        status, _body = self.post_json(self.valid_payload(), path="/v1/chat/completions")
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_non_post_methods_without_forwarding(self) -> None:
        request = Request(self.responses_endpoint(), method="GET")
        try:
            with HTTP_OPENER.open(request, timeout=3) as response:
                status = response.status
        except HTTPError as error:
            try:
                status = error.code
            finally:
                error.close()
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_missing_or_invalid_client_credentials_without_forwarding(self) -> None:
        for key in (None, "wrong-client-secret"):
            with self.subTest(api_key=key):
                status, body = self.post_json(self.valid_payload(), api_key=key)
                self.assertGreaterEqual(status, 400)
                self.assertNotIn(b"upstream-secret-test", body)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_a_model_override_without_forwarding(self) -> None:
        status, _body = self.post_json(self.valid_payload(model="another-model"))
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_output_budget_overflow_without_forwarding(self) -> None:
        status, _body = self.post_json(self.valid_payload(max_output_tokens=33))
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_oversized_utf8_body_before_forwarding(self) -> None:
        payload = self.valid_payload(input="")
        empty_body_size = len(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        remaining_bytes = 8193 - empty_body_size
        self.assertGreater(remaining_bytes, 0)
        payload["input"] = ("é" * (remaining_bytes // 2)) + ("x" if remaining_bytes % 2 else "")
        serialized = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.assertEqual(len(serialized), 8193)

        status, _body = self.post_json(payload)
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_non_text_input_before_forwarding(self) -> None:
        payload = self.valid_payload(input=[{
            "type": "input_image",
            "image_url": "https://example.invalid/never-fetch-this.png",
        }])
        status, _body = self.post_json(payload)
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_enforces_request_count_without_forwarding_over_budget_call(self) -> None:
        self.proxy.close()
        self.proxy = responses_proxy.BudgetProxy(
            upstream_base_url=f"http://127.0.0.1:{self.upstream.server_port}/v1",
            api_key="upstream-secret-test",
            model="fixture-model",
            max_requests=2,
            context_tokens=8192,
            output_tokens=32,
            client_api_key="local-client-secret-test",
        )
        self.proxy_url = self.proxy.start()

        first_status, _ = self.post_json(self.valid_payload())
        retry_status, _ = self.post_json(self.valid_payload())
        over_budget_status, second_body = self.post_json(self.valid_payload())
        self.assertEqual(first_status, 200)
        self.assertEqual(retry_status, 200)
        self.assertGreaterEqual(over_budget_status, 400)
        self.assertNotIn(b"upstream-secret-test", second_body)
        self.assertEqual(len(self.upstream_requests()), 2)
        self.assertEqual(self.proxy.metrics()["upstream_attempts_reserved"], 2)

    def test_metrics_redact_both_client_and_upstream_secrets(self) -> None:
        self.post_json(self.valid_payload())
        metrics = self.proxy.metrics()
        serialized = json.dumps(metrics, sort_keys=True)
        self.assertNotIn("upstream-secret-test", serialized)
        self.assertNotIn("local-client-secret-test", serialized)


if __name__ == "__main__":
    unittest.main()
