"""Fail-closed Responses proxy with per-call token and spend reservations.

The local OpenCode adapter is deliberately limited to the observed 2.2.7
client-side function-tool request shape. Every generation is pre-counted by
Meta's input-token endpoint, reserves a context/output worst case atomically,
and must return final usage before any reservation is released. This module
never logs request bodies, credentials, or provider responses.
"""

from __future__ import annotations

import hmac
import json
import threading
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from typing import Any


_OPEN_CODE_TOP_LEVEL_KEYS = {
    "model", "input", "instructions", "stream", "max_output_tokens", "store",
    "prompt_cache_key", "include", "tools",
}
_OPEN_CODE_TOOLS = {
    "edit", "glob", "grep", "opencode_worktree_remove", "read", "shell", "skill", "write",
}
_REASONING_INCLUDE = ["reasoning.encrypted_content"]
_JSON_SCHEMA_KEYS = {
    "type", "properties", "required", "additionalProperties", "description", "items",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
    "minItems", "maxItems", "enum", "default",
}


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req: Request, fp: Any, code: int, msg: str, headers: Any,
                         newurl: str) -> None:
        return None


class BudgetProxy:
    MAX_REQUEST_BODY_BYTES = 32 * 1024
    MAX_COUNT_RESPONSE_BYTES = 64 * 1024
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024
    UPSTREAM_TIMEOUT_SECONDS = 300

    def __init__(self, upstream_base_url: str, api_key: str, model: str,
                 max_requests: int, context_tokens: int, output_tokens: int,
                 client_api_key: str, max_request_body_bytes: int | None = None,
                 max_run_cost_usd: str | Decimal = "0.11",
                 input_usd_per_million_tokens: str | Decimal = "0.1",
                 output_usd_per_million_tokens: str | Decimal = "0.2") -> None:
        parsed = urlsplit(upstream_base_url)
        local_fixture = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        if (parsed.scheme != "https" and not (parsed.scheme == "http" and local_fixture)) \
                or not parsed.hostname or parsed.username or parsed.password \
                or parsed.query or parsed.fragment:
            raise ValueError("upstream must be a credential-free HTTPS base URL")
        if not local_fixture and (parsed.hostname != "api.meta.ai" or parsed.path.rstrip("/") != "/v1"
                                  or parsed.port not in (None, 443)):
            raise ValueError("live upstream must be https://api.meta.ai/v1")
        if not api_key or not client_api_key or not model:
            raise ValueError("provider credential, client credential, and model are required")
        if any(value <= 0 for value in (max_requests, context_tokens, output_tokens)):
            raise ValueError("request and token budgets must be positive")
        try:
            run_cap = Decimal(str(max_run_cost_usd))
            input_rate = Decimal(str(input_usd_per_million_tokens))
            output_rate = Decimal(str(output_usd_per_million_tokens))
        except InvalidOperation as exc:
            raise ValueError("run budget and token rates must be valid decimals") from exc
        if not all(value.is_finite() and value > 0 for value in (run_cap, input_rate, output_rate)):
            raise ValueError("run budget and token rates must be positive finite decimals")

        self._upstream_base_url = upstream_base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self._max_requests = max_requests
        self._context_tokens = context_tokens
        self._output_tokens = output_tokens
        self._input_rate = input_rate / Decimal(1_000_000)
        self._output_rate = output_rate / Decimal(1_000_000)
        self._max_run_cost = run_cap
        self._worst_case_per_call = (Decimal(context_tokens) * self._input_rate
                                     + Decimal(output_tokens) * self._output_rate)
        self._max_request_body_bytes = (self.MAX_REQUEST_BODY_BYTES if max_request_body_bytes is None
                                        else max_request_body_bytes)
        if not 1 <= self._max_request_body_bytes <= self.MAX_REQUEST_BODY_BYTES:
            raise ValueError("request body byte cap must be between 1 and 32768")
        if self._worst_case_per_call > run_cap:
            raise ValueError("run budget cannot fund one context/output-bounded call")

        self._client_api_key = client_api_key.encode()
        self._lock = threading.Lock()
        self._attempts_reserved = 0
        self._settled_cost = Decimal(0)
        self._reserved_cost = Decimal(0)
        self._input_prechecks = 0
        self._precheck_attempts = 0
        self._max_input_tokens_seen = 0
        self._uncertain_responses = 0
        self._over_budget_responses = 0
        self._budget_rejections = 0
        self._blocked = False
        self._max_request_body_bytes_seen = 0
        self._oversized_requests_rejected = 0
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._opener = build_opener(_NoRedirect())

    def start(self) -> str:
        if self._httpd is not None:
            raise RuntimeError("proxy already started")
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, _format: str, *_args: object) -> None:
                pass

            def _respond(self, status: int, payload: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True

            def do_GET(self) -> None:
                self._respond(405, b'{"error":"method_not_allowed"}')

            def do_POST(self) -> None:
                if self.path != "/v1/responses":
                    self._respond(404, b'{"error":"route_not_allowed"}')
                    return
                auth = self.headers.get("Authorization", "")
                supplied = auth[7:].encode() if auth.startswith("Bearer ") else b""
                if not hmac.compare_digest(supplied, proxy._client_api_key):
                    self._respond(401, b'{"error":"unauthorized"}')
                    return
                try:
                    size = int(self.headers.get("Content-Length", "-1"))
                except ValueError:
                    size = -1
                if size < 0 or size > proxy._max_request_body_bytes:
                    proxy._record_body_size(size, rejected=True)
                    self._respond(413, b'{"error":"request_too_large"}')
                    return
                if self.headers.get("Content-Encoding", "identity").lower() != "identity" \
                        or self.headers.get("Transfer-Encoding"):
                    self._respond(415, b'{"error":"request_encoding_not_allowed"}')
                    return
                proxy._record_body_size(size, rejected=False)
                body = self.rfile.read(size)
                if len(body) != size:
                    self._respond(400, b'{"error":"incomplete_request"}')
                    return
                try:
                    payload = json.loads(body, object_pairs_hook=_unique_object_pairs)
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    self._respond(400, b'{"error":"invalid_json"}')
                    return
                if not _valid_opencode_payload(payload, proxy._model, proxy._output_tokens):
                    self._respond(400, b'{"error":"unsupported_responses_payload"}')
                    return
                canonical_body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
                if not proxy._reserve_precheck():
                    self._respond(429, b'{"error":"request_budget_exhausted"}')
                    return

                count_request = Request(
                    proxy._upstream_base_url + "/responses/input_tokens",
                    data=json.dumps(_input_token_payload(payload), separators=(",", ":")).encode(),
                    headers={"Authorization": f"Bearer {proxy._api_key}",
                             "Content-Type": "application/json", "Accept": "application/json"},
                    method="POST",
                )
                try:
                    with proxy._opener.open(count_request, timeout=proxy.UPSTREAM_TIMEOUT_SECONDS) as response:
                        if response.status != 200:
                            self._respond(502, b'{"error":"input_token_precheck_failed"}')
                            return
                        count_body = response.read(proxy.MAX_COUNT_RESPONSE_BYTES + 1)
                        if len(count_body) > proxy.MAX_COUNT_RESPONSE_BYTES:
                            self._respond(502, b'{"error":"input_token_precheck_invalid"}')
                            return
                except HTTPError as error:
                    error.close()
                    self._respond(502, b'{"error":"input_token_precheck_failed"}')
                    return
                except Exception:
                    self._respond(502, b'{"error":"input_token_precheck_failed"}')
                    return
                try:
                    count_result = json.loads(count_body, object_pairs_hook=_unique_object_pairs)
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    self._respond(502, b'{"error":"input_token_precheck_invalid"}')
                    return
                input_tokens = count_result.get("input_tokens") if isinstance(count_result, dict) else None
                if not isinstance(count_result, dict) or count_result.get("object") != "response.input_tokens":
                    self._respond(502, b'{"error":"input_token_precheck_invalid"}')
                    return
                if not isinstance(input_tokens, int) or isinstance(input_tokens, bool) or input_tokens < 0:
                    self._respond(502, b'{"error":"input_token_precheck_invalid"}')
                    return
                if input_tokens > proxy._context_tokens:
                    proxy._record_precheck(input_tokens)
                    self._respond(413, b'{"error":"context_budget_exceeded"}')
                    return
                proxy._record_precheck(input_tokens)
                if not proxy._reserve_attempt():
                    self._respond(429, b'{"error":"run_budget_exhausted"}')
                    return

                request = Request(
                    proxy._upstream_base_url + "/responses",
                    data=canonical_body,
                    headers={"Authorization": f"Bearer {proxy._api_key}",
                             "Content-Type": "application/json",
                             "Accept": "text/event-stream, application/json"},
                    method="POST",
                )
                try:
                    with proxy._opener.open(request, timeout=proxy.UPSTREAM_TIMEOUT_SECONDS) as response:
                        if int(response.headers.get("Content-Length", "0") or "0") > proxy.MAX_RESPONSE_BYTES:
                            proxy._mark_uncertain()
                            self._respond(502, b'{"error":"upstream_response_too_large"}')
                            return
                        forwarded_body = response.read(proxy.MAX_RESPONSE_BYTES + 1)
                        if len(forwarded_body) > proxy.MAX_RESPONSE_BYTES:
                            proxy._mark_uncertain()
                            self._respond(502, b'{"error":"upstream_response_too_large"}')
                            return
                        status = response.status
                        content_type = response.headers.get("Content-Type", "application/json")
                except HTTPError:
                    proxy._mark_uncertain()
                    self._respond(502, b'{"error":"upstream_request_failed"}')
                    return
                except Exception:
                    proxy._mark_uncertain()
                    self._respond(502, b'{"error":"upstream_request_failed"}')
                    return
                if 300 <= status < 400:
                    proxy._mark_uncertain()
                    self._respond(502, b'{"error":"upstream_redirect_rejected"}')
                    return
                usage = _final_usage(forwarded_body, content_type)
                if status < 200 or status >= 300 or usage is None:
                    proxy._mark_uncertain()
                    self._respond(502, b'{"error":"final_usage_missing_or_ambiguous"}')
                    return
                if not proxy._settle_attempt(usage):
                    self._respond(502, b'{"error":"reported_usage_exceeded_reserved_limit"}')
                    return

                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(forwarded_body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(forwarded_body)
                self.close_connection = True

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._httpd.daemon_threads = True
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return f"http://127.0.0.1:{self._httpd.server_port}/v1"

    def _reserve_attempt(self) -> bool:
        with self._lock:
            if self._blocked or self._attempts_reserved >= self._max_requests \
                    or self._settled_cost + self._reserved_cost + self._worst_case_per_call > self._max_run_cost:
                self._budget_rejections += 1
                return False
            self._attempts_reserved += 1
            self._reserved_cost += self._worst_case_per_call
            return True

    def _reserve_precheck(self) -> bool:
        """Count every token-count request before making it, including failures."""
        with self._lock:
            if self._precheck_attempts >= self._max_requests:
                self._budget_rejections += 1
                return False
            self._precheck_attempts += 1
            return True

    def _record_precheck(self, input_tokens: int) -> None:
        with self._lock:
            self._input_prechecks += 1
            self._max_input_tokens_seen = max(self._max_input_tokens_seen, input_tokens)

    def _record_body_size(self, size: int, rejected: bool) -> None:
        with self._lock:
            if size > self._max_request_body_bytes_seen:
                self._max_request_body_bytes_seen = size
            if rejected:
                self._oversized_requests_rejected += 1

    def _mark_uncertain(self) -> None:
        with self._lock:
            self._uncertain_responses += 1
            self._blocked = True

    def _settle_attempt(self, usage: dict[str, int]) -> bool:
        input_tokens = usage["input_tokens"]
        output_tokens = usage["output_tokens"]
        cached_tokens = usage["cached_tokens"]
        if input_tokens > self._context_tokens or output_tokens > self._output_tokens \
                or cached_tokens > input_tokens:
            with self._lock:
                self._over_budget_responses += 1
                self._blocked = True
            return False
        # Count all input at the uncached rate. This over-reserves cached input
        # and avoids relying on cache accounting or discounts for the cap.
        actual_cost = Decimal(input_tokens) * self._input_rate + Decimal(output_tokens) * self._output_rate
        with self._lock:
            self._reserved_cost -= self._worst_case_per_call
            if actual_cost > self._worst_case_per_call:
                self._over_budget_responses += 1
                self._blocked = True
                self._settled_cost += actual_cost
                return False
            self._settled_cost += actual_cost
        return True

    def metrics(self) -> dict[str, Any]:
        with self._lock:
            return {
                "upstream_generation_attempts": self._attempts_reserved,
                "upstream_generation_attempt_limit": self._max_requests,
                "input_token_prechecks": self._input_prechecks,
                "input_token_precheck_attempts": self._precheck_attempts,
                "max_prechecked_input_tokens": self._max_input_tokens_seen,
                "per_call_worst_case_cost_usd": _money(self._worst_case_per_call),
                "run_cost_cap_usd": _money(self._max_run_cost),
                "generation_cost_reserved_usd": _money(self._reserved_cost),
                "generation_cost_settled_usd": _money(self._settled_cost),
                "uncertain_responses": self._uncertain_responses,
                "over_budget_responses": self._over_budget_responses,
                "budget_rejections": self._budget_rejections,
                "blocked_after_uncertain_usage": self._blocked,
                "max_request_body_bytes_seen": self._max_request_body_bytes_seen,
                "oversized_requests_rejected": self._oversized_requests_rejected,
            }

    def close(self) -> None:
        httpd = self._httpd
        if httpd is None:
            return
        httpd.shutdown()
        httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._httpd = None
        self._thread = None


def _money(value: Decimal) -> str:
    return format(value.quantize(Decimal("0.00000001")), ".8f")


def _input_token_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Fields that affect the rendered input, matching the upstream count API."""
    return {key: payload[key] for key in ("model", "input", "instructions", "tools") if key in payload}


def _unique_object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _valid_opencode_payload(payload: Any, model: str, output_limit: int) -> bool:
    if not isinstance(payload, dict) or set(payload) != _OPEN_CODE_TOP_LEVEL_KEYS:
        return False
    if payload.get("model") != model or payload.get("stream") is not True or payload.get("store") is not False:
        return False
    output = payload.get("max_output_tokens")
    if not isinstance(output, int) or isinstance(output, bool) or not 16 <= output <= output_limit:
        return False
    if not isinstance(payload.get("instructions"), str) or not isinstance(payload.get("prompt_cache_key"), str) \
            or len(payload["prompt_cache_key"]) > 64 or payload.get("include") != _REASONING_INCLUDE:
        return False
    if not _valid_input_items(payload.get("input")):
        return False
    tools = payload.get("tools")
    if not isinstance(tools, list) or len(tools) != len(_OPEN_CODE_TOOLS):
        return False
    names: set[str] = set()
    for tool in tools:
        if not isinstance(tool, dict) or set(tool) != {"type", "name", "description", "parameters", "strict"}:
            return False
        name = tool.get("name")
        if tool.get("type") != "function" or name not in _OPEN_CODE_TOOLS or name in names \
                or not isinstance(tool.get("description"), str) or tool.get("strict") is not False \
                or not _valid_json_schema(tool.get("parameters"), 0):
            return False
        names.add(name)
    return names == _OPEN_CODE_TOOLS


def _valid_input_items(value: Any) -> bool:
    if not isinstance(value, list) or not value or len(value) > 128:
        return False
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get("type"), str):
            return False
        kind = item["type"]
        if kind == "message":
            if set(item) != {"type", "role", "content"} or item.get("role") not in {"user", "assistant"}:
                return False
            content = item.get("content")
            if not isinstance(content, list) or not content or len(content) > 128:
                return False
            for part in content:
                if not isinstance(part, dict) or set(part) != {"type", "text"} \
                        or part.get("type") not in {"input_text", "output_text"} \
                        or not isinstance(part.get("text"), str):
                    return False
        elif kind == "function_call":
            if set(item) != {"type", "call_id", "name", "arguments"} \
                    or not all(isinstance(item.get(key), str) for key in ("call_id", "name", "arguments")) \
                    or item["name"] not in _OPEN_CODE_TOOLS:
                return False
            try:
                arguments = json.loads(item["arguments"])
            except json.JSONDecodeError:
                return False
            if not isinstance(arguments, dict):
                return False
        elif kind == "function_call_output":
            if set(item) != {"type", "call_id", "output"} \
                    or not isinstance(item.get("call_id"), str) \
                    or not isinstance(item.get("output"), str):
                return False
        elif kind == "reasoning":
            if not set(item).issubset({"type", "encrypted_content", "id", "summary", "status"}) \
                    or not isinstance(item.get("encrypted_content"), str):
                return False
        else:
            return False
    return True


def _valid_json_schema(value: Any, depth: int) -> bool:
    if depth > 8 or not isinstance(value, dict) or not set(value).issubset(_JSON_SCHEMA_KEYS):
        return False
    if value.get("type") not in {"object", "array", "string", "integer", "number", "boolean"}:
        return False
    properties = value.get("properties", {})
    if not isinstance(properties, dict) or len(properties) > 64:
        return False
    for name, schema in properties.items():
        if not isinstance(name, str) or not _valid_json_schema(schema, depth + 1):
            return False
    if "required" in value and (not isinstance(value["required"], list)
                                or any(not isinstance(name, str) or name not in properties for name in value["required"])):
        return False
    if "additionalProperties" in value and value["additionalProperties"] is not False:
        return False
    if "items" in value and not _valid_json_schema(value["items"], depth + 1):
        return False
    for key in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"):
        if key in value and (not isinstance(value[key], (int, float)) or isinstance(value[key], bool)):
            return False
    for key in ("minLength", "maxLength", "minItems", "maxItems"):
        if key in value and (not isinstance(value[key], int) or isinstance(value[key], bool) or value[key] < 0):
            return False
    if "enum" in value and (not isinstance(value["enum"], list) or len(value["enum"]) > 64):
        return False
    if "description" in value and not isinstance(value["description"], str):
        return False
    if "default" in value and not isinstance(value["default"], (str, int, float, bool, type(None), list, dict)):
        return False
    return True


def _final_usage(body: bytes, content_type: str) -> dict[str, int] | None:
    """Return usage only from a complete terminal response, never an SSE delta."""
    final_response: dict[str, Any] | None = None
    if "text/event-stream" in content_type.lower():
        terminal_types = {"response.completed", "response.incomplete", "response.failed"}
        for raw_event in body.replace(b"\r\n", b"\n").split(b"\n\n"):
            event_name = ""
            data_lines: list[bytes] = []
            for line in raw_event.splitlines():
                if line.startswith(b"event:"):
                    event_name = line[6:].strip().decode("ascii", "ignore")
                elif line.startswith(b"data:"):
                    data_lines.append(line[5:].lstrip())
            if event_name not in terminal_types or not data_lines:
                continue
            try:
                event = json.loads(b"\n".join(data_lines), object_pairs_hook=_unique_object_pairs)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                return None
            if not isinstance(event, dict) or event.get("type") != event_name:
                return None
            response = event.get("response")
            if not isinstance(response, dict) or response.get("status") not in {"completed", "incomplete", "failed"}:
                return None
            if final_response is not None:
                return None
            final_response = response
    else:
        try:
            response = json.loads(body, object_pairs_hook=_unique_object_pairs)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            return None
        if isinstance(response, dict) and response.get("object") == "response":
            final_response = response
    if final_response is None:
        return None
    usage = final_response.get("usage")
    if not isinstance(usage, dict):
        return None
    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    details = usage.get("input_tokens_details", {})
    cached_tokens = details.get("cached_tokens", 0) if isinstance(details, dict) else None
    values = (input_tokens, output_tokens, cached_tokens)
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in values):
        return None
    return {"input_tokens": input_tokens, "output_tokens": output_tokens, "cached_tokens": cached_tokens}
