"""Deterministic contract tests for the bounded OpenCode Responses proxy.

All upstream requests terminate at a local fixture. No Meta provider is called.
"""

from __future__ import annotations

import importlib
import json
import sys
import threading
import time
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


def _tool(name: str) -> dict[str, Any]:
    return {
        "type": "function", "name": name, "description": f"fixture {name}",
        "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        "strict": False,
    }


class UpstreamFixtureHandler(BaseHTTPRequestHandler):
    requests_seen: list[dict[str, Any]] = []
    requests_lock = threading.Lock()
    input_tokens = 100
    count_status = 200
    count_mode = "complete"
    response_mode = "complete"
    response_usage: dict[str, Any] = {
        "input_tokens": 100,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens": 8,
        "output_tokens_details": {"reasoning_tokens": 3},
        "total_tokens": 108,
    }
    generation_started: threading.Event | None = None
    generation_release: threading.Event | None = None

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _respond_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(body)
        with self.requests_lock:
            self.requests_seen.append({
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "payload": payload,
            })
            count_status = self.count_status
            count_mode = self.count_mode
            input_tokens = self.input_tokens
            mode = self.response_mode
            usage = dict(self.response_usage)
        if self.path == "/v1/responses/input_tokens":
            if count_mode == "duplicate":
                body = (b'{"object":"response.input_tokens","input_tokens":100,'
                        b'"input_tokens":8192}')
                self.send_response(count_status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self._respond_json(count_status, {"object": "response.input_tokens", "input_tokens": input_tokens})
            return
        if self.path != "/v1/responses":
            self._respond_json(404, {"error": "unexpected fixture path"})
            return
        if type(self).generation_started is not None and type(self).generation_release is not None:
            type(self).generation_started.set()
            type(self).generation_release.wait(timeout=10)
        model = payload["model"]
        response = {
            "id": "resp_fixture_1", "object": "response", "status": "completed", "model": model,
            "output": [{
                "id": "msg_fixture_1", "type": "message", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": "Fixture answer verified."}],
            }],
            "usage": usage,
        }
        events = [
            {"type": "response.created", "response": {"id": response["id"], "object": "response",
                                                            "status": "in_progress", "model": model}},
            {"type": "response.output_text.delta", "item_id": "msg_fixture_1", "output_index": 0,
             "content_index": 0, "delta": "Fixture answer verified."},
        ]
        if mode == "complete":
            events.append({"type": "response.completed", "response": response})
        body = "".join(f"event: {item['type']}\ndata: {json.dumps(item)}\n\n" for item in events)
        if mode == "duplicate_usage":
            body = body.replace('"input_tokens": 100,', '"input_tokens": 100, "input_tokens": 1,')
        encoded = (body + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


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
            UpstreamFixtureHandler.input_tokens = 100
            UpstreamFixtureHandler.count_status = 200
            UpstreamFixtureHandler.count_mode = "complete"
            UpstreamFixtureHandler.response_mode = "complete"
            UpstreamFixtureHandler.response_usage = {
                "input_tokens": 100,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 8,
                "output_tokens_details": {"reasoning_tokens": 3},
                "total_tokens": 108,
            }
            UpstreamFixtureHandler.generation_started = None
            UpstreamFixtureHandler.generation_release = None
        self.proxy = self.make_proxy(max_requests=4)
        self.proxy_url = self.proxy.start()

    def make_proxy(self, *, max_requests: int, max_run_cost_usd: str = "0.01") -> Any:
        return responses_proxy.BudgetProxy(
            upstream_base_url=f"http://127.0.0.1:{self.upstream.server_port}/v1",
            api_key="upstream-secret-test",
            model="fixture-model",
            max_requests=max_requests,
            context_tokens=8192,
            output_tokens=2048,
            client_api_key="local-client-secret-test",
            max_request_body_bytes=32 * 1024,
            max_run_cost_usd=max_run_cost_usd,
            input_usd_per_million_tokens="0.1",
            output_usd_per_million_tokens="0.2",
        )

    def responses_endpoint(self, path: str = "/v1/responses") -> str:
        parsed = urlsplit(self.proxy_url)
        return f"{parsed.scheme}://{parsed.netloc}{path}"

    def post_json(self, payload: dict[str, Any]) -> tuple[int, bytes]:
        return self.post_body(json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def post_body(self, body: bytes) -> tuple[int, bytes]:
        request = Request(
            self.responses_endpoint(),
            data=body,
            headers={"Content-Type": "application/json", "Authorization": "Bearer local-client-secret-test"},
            method="POST",
        )
        try:
            with HTTP_OPENER.open(request, timeout=5) as response:
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
            "input": [{"type": "message", "role": "user",
                       "content": [{"type": "input_text", "text": "Summarize this local test fixture."}]}],
            "instructions": "Use the configured client-side tools when needed.",
            "stream": True,
            "max_output_tokens": 2048,
            "store": False,
            "prompt_cache_key": "fixture-prompt-cache-key",
            "include": ["reasoning.encrypted_content"],
            "tools": [_tool(name) for name in (
                "edit", "glob", "grep", "opencode_worktree_remove", "read", "shell", "skill", "write",
            )],
        }
        payload.update(overrides)
        return payload

    @classmethod
    def upstream_requests(cls, path: str | None = None) -> list[dict[str, Any]]:
        with UpstreamFixtureHandler.requests_lock:
            requests = list(UpstreamFixtureHandler.requests_seen)
        return requests if path is None else [request for request in requests if request["path"] == path]

    def test_prechecks_exact_rendered_input_then_forwards_inference_with_replaced_credential(self) -> None:
        status, body = self.post_json(self.valid_payload())
        self.assertEqual(status, 200, body)
        requests = self.upstream_requests()
        self.assertEqual([item["path"] for item in requests], [
            "/v1/responses/input_tokens", "/v1/responses",
        ])
        self.assertEqual(requests[0]["authorization"], "Bearer upstream-secret-test")
        self.assertEqual(set(requests[0]["payload"]), {"model", "input", "instructions", "tools"})
        self.assertEqual(requests[0]["payload"]["model"], "fixture-model")
        self.assertEqual(requests[0]["payload"]["input"], self.valid_payload()["input"])
        self.assertEqual(requests[0]["payload"]["tools"], self.valid_payload()["tools"])
        self.assertEqual(requests[1]["authorization"], "Bearer upstream-secret-test")
        self.assertEqual(requests[1]["payload"]["max_output_tokens"], 2048)
        self.assertEqual(self.proxy.metrics()["upstream_generation_attempts"], 1)
        self.assertEqual(self.proxy.metrics()["input_token_prechecks"], 1)
        self.assertEqual(self.proxy.metrics()["generation_cost_reserved_usd"], "0.00000000")
        self.assertEqual(self.proxy.metrics()["generation_cost_settled_usd"], "0.00001160")
        self.assertNotIn("local-client-secret-test", str(requests))

    def test_rejects_duplicate_json_keys_at_top_level_and_nested_objects(self) -> None:
        payload = json.dumps(self.valid_payload(), separators=(",", ":"))
        duplicate_top_level = payload.replace('"model":"fixture-model"',
                                              '"model":"fixture-model","model":"other-model"', 1)
        duplicate_nested = payload.replace('"type":"input_text","text":"Summarize this local test fixture."',
                                           '"type":"input_text","text":"first","text":"second"', 1)
        for body in (duplicate_top_level.encode(), duplicate_nested.encode()):
            with self.subTest(body=body[:80]):
                status, _response = self.post_body(body)
                self.assertEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_prechecks_client_side_function_tool_round_trip_shape(self) -> None:
        tool_round_input = [
            {"type": "message", "role": "user",
             "content": [{"type": "input_text", "text": "Read fixture.txt."}]},
            {"type": "function_call", "call_id": "call_fixture", "name": "read",
             "arguments": json.dumps({"filePath": "fixture.txt"})},
            {"type": "function_call_output", "call_id": "call_fixture",
             "output": "fixture contents"},
        ]
        status, body = self.post_json(self.valid_payload(input=tool_round_input))
        self.assertEqual(status, 200, body)
        requests = self.upstream_requests()
        self.assertEqual([item["path"] for item in requests], [
            "/v1/responses/input_tokens", "/v1/responses",
        ])
        self.assertEqual(requests[0]["payload"]["input"], tool_round_input)
        self.assertEqual(requests[1]["payload"]["input"], tool_round_input)
        self.assertEqual(self.proxy.metrics()["input_token_prechecks"], 1)
        self.assertEqual(self.proxy.metrics()["upstream_generation_attempts"], 1)

    def test_rejects_hosted_tools_server_history_unknown_fields_and_non_observed_shapes(self) -> None:
        cases = (
            {"tools": [_tool("read") | {"type": "web_search"}]},
            {"previous_response_id": "resp_external"},
            {"background": True},
            {"input": [{"type": "input_image", "image_url": "https://example.invalid/a.png"}]},
            {"unexpected": "not part of pinned OpenCode 2.2.7"},
            {"tools": [_tool("read")]},
        )
        for override in cases:
            with self.subTest(override=tuple(override)):
                status, _body = self.post_json(self.valid_payload(**override))
                self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_non_function_tool_type_before_count_or_generation(self) -> None:
        tools = [_tool(name) for name in (
            "edit", "glob", "grep", "opencode_worktree_remove", "read", "shell", "skill", "write",
        )]
        tools[0]["type"] = "web_search"
        status, _body = self.post_json(self.valid_payload(tools=tools))
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_rejects_wrong_model_or_output_budget(self) -> None:
        for overrides in ({"model": "other-model"}, {"max_output_tokens": 2049}, {"max_output_tokens": True}):
            status, _body = self.post_json(self.valid_payload(**overrides))
            self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests(), [])

    def test_count_failure_and_context_overflow_fail_closed_without_generation(self) -> None:
        UpstreamFixtureHandler.count_status = 503
        status, _body = self.post_json(self.valid_payload())
        self.assertGreaterEqual(status, 400)
        self.assertEqual(self.upstream_requests("/v1/responses"), [])
        with UpstreamFixtureHandler.requests_lock:
            UpstreamFixtureHandler.requests_seen.clear()
            UpstreamFixtureHandler.count_status = 200
            UpstreamFixtureHandler.input_tokens = 8193
        status, _body = self.post_json(self.valid_payload())
        self.assertEqual(status, 413)
        self.assertEqual(self.upstream_requests("/v1/responses"), [])

    def test_duplicate_provider_count_or_usage_keys_never_release_budget(self) -> None:
        UpstreamFixtureHandler.count_mode = "duplicate"
        status, _body = self.post_json(self.valid_payload())
        self.assertEqual(status, 502)
        self.assertEqual(self.upstream_requests("/v1/responses"), [])

        with UpstreamFixtureHandler.requests_lock:
            UpstreamFixtureHandler.requests_seen.clear()
            UpstreamFixtureHandler.count_mode = "complete"
            UpstreamFixtureHandler.response_mode = "duplicate_usage"
        status, _body = self.post_json(self.valid_payload())
        self.assertEqual(status, 502)
        metrics = self.proxy.metrics()
        self.assertEqual(metrics["uncertain_responses"], 1)
        self.assertEqual(metrics["generation_cost_reserved_usd"], "0.00122880")
        self.assertEqual(metrics["generation_cost_settled_usd"], "0.00000000")

    def test_client_retries_each_get_a_precheck_and_cost_reservation(self) -> None:
        for _ in range(2):
            status, _body = self.post_json(self.valid_payload())
            self.assertEqual(status, 200)
        metrics = self.proxy.metrics()
        self.assertEqual(len(self.upstream_requests("/v1/responses/input_tokens")), 2)
        self.assertEqual(len(self.upstream_requests("/v1/responses")), 2)
        self.assertEqual(metrics["upstream_generation_attempts"], 2)
        self.assertEqual(metrics["generation_cost_settled_usd"], "0.00002320")

    def test_precheck_attempts_are_capped_before_calling_count_endpoint(self) -> None:
        self.proxy.close()
        self.proxy = self.make_proxy(max_requests=1)
        self.proxy_url = self.proxy.start()
        for expected in (200, 429):
            status, _body = self.post_json(self.valid_payload())
            self.assertEqual(status, expected)
        self.assertEqual(len(self.upstream_requests("/v1/responses/input_tokens")), 1)
        self.assertEqual(len(self.upstream_requests("/v1/responses")), 1)
        self.assertEqual(self.proxy.metrics()["input_token_precheck_attempts"], 1)

    def test_concurrent_reservations_cannot_exceed_authorized_run_budget(self) -> None:
        self.proxy.close()
        self.proxy = self.make_proxy(max_requests=4, max_run_cost_usd="0.0012288")
        self.proxy_url = self.proxy.start()
        with UpstreamFixtureHandler.requests_lock:
            UpstreamFixtureHandler.input_tokens = 8192
            UpstreamFixtureHandler.response_usage = {
                "input_tokens": 8192,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 2048,
                "output_tokens_details": {"reasoning_tokens": 1800},
                "total_tokens": 10240,
            }
        barrier = threading.Barrier(3)
        results: list[int] = []
        result_lock = threading.Lock()

        def send() -> None:
            barrier.wait()
            status, _ = self.post_json(self.valid_payload())
            with result_lock:
                results.append(status)

        workers = [threading.Thread(target=send) for _ in range(3)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=10)
        self.assertTrue(all(not worker.is_alive() for worker in workers))
        self.assertEqual(sorted(results), [200, 429, 429])
        self.assertEqual(len(self.upstream_requests("/v1/responses")), 1)
        metrics = self.proxy.metrics()
        self.assertEqual(metrics["upstream_generation_attempts"], 1)
        self.assertEqual(metrics["generation_cost_settled_usd"], "0.00122880")

    def test_missing_or_partial_terminal_usage_retains_reservation_and_blocks_retry(self) -> None:
        UpstreamFixtureHandler.response_mode = "partial"
        status, _body = self.post_json(self.valid_payload())
        self.assertEqual(status, 502)
        metrics = self.proxy.metrics()
        self.assertEqual(metrics["uncertain_responses"], 1)
        self.assertEqual(metrics["generation_cost_reserved_usd"], "0.00122880")
        self.assertEqual(metrics["generation_cost_settled_usd"], "0.00000000")
        status, _body = self.post_json(self.valid_payload())
        self.assertEqual(status, 429)
        self.assertEqual(len(self.upstream_requests("/v1/responses")), 1)

    def test_close_drains_or_marks_blocked_generation_uncertain_after_client_disconnect(self) -> None:
        started = threading.Event()
        release = threading.Event()
        UpstreamFixtureHandler.generation_started = started
        UpstreamFixtureHandler.generation_release = release
        self.proxy.DRAIN_TIMEOUT_SECONDS = 0.05
        request = Request(
            self.responses_endpoint(), data=json.dumps(self.valid_payload()).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer local-client-secret-test"},
            method="POST",
        )
        client_errors: list[Exception] = []

        def disconnected_client() -> None:
            try:
                HTTP_OPENER.open(request, timeout=0.2).read()
            except (OSError, URLError) as exc:
                client_errors.append(exc)

        client = threading.Thread(target=disconnected_client)
        client.start()
        try:
            self.assertTrue(started.wait(timeout=3), "upstream generation did not start")
            client.join(timeout=2)
            self.assertFalse(client.is_alive(), "client did not disconnect on its timeout")
            self.proxy.close()
            metrics = self.proxy.metrics()
            self.assertEqual(metrics["generation_cost_in_flight"], 0)
            self.assertEqual(metrics["generation_cost_uncertain"], 1)
            self.assertEqual(metrics["uncertain_responses"], 1)
            self.assertEqual(metrics["generation_cost_reserved_usd"], "0.00122880")
            self.assertEqual(metrics["generation_cost_settled_usd"], "0.00000000")
        finally:
            release.set()
            client.join(timeout=2)
            UpstreamFixtureHandler.generation_started = None
            UpstreamFixtureHandler.generation_release = None
        time.sleep(0.05)
        metrics = self.proxy.metrics()
        self.assertEqual(metrics["generation_cost_reserved_usd"], "0.00122880")
        self.assertEqual(metrics["generation_cost_settled_usd"], "0.00000000")
        self.assertTrue(client_errors)

    def test_usage_outside_reserved_context_or_output_halts_budget(self) -> None:
        UpstreamFixtureHandler.response_usage = {
            "input_tokens": 8193,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 8,
            "output_tokens_details": {"reasoning_tokens": 3},
            "total_tokens": 8201,
        }
        status, _body = self.post_json(self.valid_payload())
        self.assertEqual(status, 502)
        metrics = self.proxy.metrics()
        self.assertEqual(metrics["over_budget_responses"], 1)
        self.assertTrue(metrics["blocked_after_uncertain_usage"])
        self.assertEqual(metrics["generation_cost_reserved_usd"], "0.00122880")

    def test_rejects_oversized_request_before_counting(self) -> None:
        payload = self.valid_payload()
        payload["instructions"] = "x" * (32 * 1024)
        status, _body = self.post_json(payload)
        self.assertEqual(status, 413)
        self.assertEqual(self.upstream_requests(), [])

    def test_upstream_is_pinned_to_meta_origin_outside_loopback_fixture(self) -> None:
        with self.assertRaisesRegex(ValueError, "api.meta.ai"):
            responses_proxy.BudgetProxy(
                upstream_base_url="https://attacker.example/v1",
                api_key="upstream-secret-test", model="fixture-model", max_requests=1,
                context_tokens=8192, output_tokens=2048, client_api_key="local-client-secret-test",
            )


if __name__ == "__main__":
    unittest.main()
