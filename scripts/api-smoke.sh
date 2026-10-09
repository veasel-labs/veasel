#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
port="${VEASEL_SMOKE_PORT:-$((30000 + $$ % 20000))}"
api="http://127.0.0.1:${port}"
server_pid=""
provider_pid=""

cleanup() {
	if [[ -n "$provider_pid" ]]; then
		kill "$provider_pid" 2>/dev/null || true
		wait "$provider_pid" 2>/dev/null || true
	fi
	if [[ -n "$server_pid" ]]; then
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	fi
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	if [[ -f "$work_dir/server.log" ]]; then
		cat "$work_dir/server.log" >&2
	fi
	exit 1
}

expect_status() {
	local expected="$1"
	shift
	local actual
	actual="$(curl -sS -o "$work_dir/response" -w '%{http_code}' "$@")"
	[[ "$actual" == "$expected" ]] || fail "expected HTTP $expected, got $actual ($(cat "$work_dir/response"))"
}

start_server() {
	if [[ -n "${1:-}" ]]; then
		provider_base="/v1"
		[[ "$1" == gemini ]] && provider_base="/v1beta"
		env -u VEASEL_MODEL_API_KEY VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			VEASEL_MODEL_PROVIDER="$1" VEASEL_MODEL=smoke-model \
			OPENAI_API_KEY=veasel-openai-key ANTHROPIC_API_KEY=veasel-anthropic-key \
			GEMINI_API_KEY=veasel-gemini-key \
			VEASEL_MODEL_BASE_URL="http://127.0.0.1:$(cat "$work_dir/provider.port")${provider_base}" \
			"$work_dir/veasel" serve >"$work_dir/server.log" 2>&1 &
	else
		env -u VEASEL_MODEL -u VEASEL_MODEL_API_KEY -u VEASEL_MODEL_BASE_URL -u VEASEL_MODEL_PROVIDER \
			VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" "$work_dir/veasel" serve >"$work_dir/server.log" 2>&1 &
	fi
	server_pid=$!
	for ((attempt = 0; attempt < 80; attempt++)); do
		if curl -fsS "$api/v1/health" >"$work_dir/health" 2>/dev/null; then
			return
		fi
		sleep 0.1
	done
	cat "$work_dir/server.log" >&2
	fail 'server did not become ready'
}

cd "$repo_root"
"${V_BIN:-v}" -o "$work_dir/veasel" .
start_server
expect_status 403 -H 'Host: attacker.example' "$api/v1/health"

grep -Fq '"healthy":true' "$work_dir/health" || fail 'health response is incorrect'
curl -fsS "$api/v1/capabilities" >"$work_dir/capabilities"
grep -Fq 'sessions.create' "$work_dir/capabilities" || fail 'session capability is missing'
expect_status 400 -H 'content-type: application/json' -d '{"messages":[{"role":"assistant","content":"not a user turn"}]}' "$api/v1/chat/completions"
expect_status 403 -H 'Origin: http://attacker.example' -H 'content-type: application/json' \
	-d '{"title":"forbidden","directory":"/tmp"}' "$api/v1/sessions"
expect_status 503 -H 'Origin: http://localhost:3000' -H 'content-type: application/json' \
	-d '{"messages":[{"role":"user","content":"hello"}]}' "$api/v1/chat/completions"

expect_status 400 -H 'content-type: application/json' -d '{"title":" ","directory":"/tmp"}' "$api/v1/sessions"
expect_status 201 -H 'content-type: application/json' -d '{"title":"API smoke","directory":"/tmp/veasel-smoke"}' "$api/v1/sessions"
grep -Fq '"title":"API smoke"' "$work_dir/response" || fail 'created session is missing from the response'
session_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$work_dir/response")"
[[ -n "$session_id" ]] || fail 'session id is missing'

curl -fsS "$api/v1/sessions" >"$work_dir/sessions"
grep -Fq "$session_id" "$work_dir/sessions" || fail 'created session is missing from the list'
curl -fsS "$api/v1/sessions/$session_id" >"$work_dir/session"
grep -Fq '"title":"API smoke"' "$work_dir/session" || fail 'session retrieval failed'
expect_status 404 "$api/v1/sessions/not-a-session"
expect_status 400 -H 'Last-Event-ID: not-a-number' "$api/v1/events"

timeout 2s curl -NsS -H 'Last-Event-ID: 0' "$api/v1/events" >"$work_dir/events" 2>/dev/null || [[ "$?" -eq 124 ]]
grep -Fq 'event: session.created' "$work_dir/events" || fail 'SSE did not replay the creation event'
grep -Fq "$session_id" "$work_dir/events" || fail 'SSE event has the wrong session id'

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
start_server
curl -fsS "$api/v1/sessions/$session_id" >"$work_dir/recovered"
grep -Fq '"title":"API smoke"' "$work_dir/recovered" || fail 'session did not survive a server restart'

python3 "$repo_root/scripts/mock-provider.py" "$work_dir/provider.port" >/dev/null 2>&1 &
provider_pid=$!
for ((attempt = 0; attempt < 80; attempt++)); do
	[[ -s "$work_dir/provider.port" ]] && break
	sleep 0.1
done
[[ -s "$work_dir/provider.port" ]] || fail 'mock model provider did not become ready'
for provider in openai-compatible anthropic gemini; do
	kill "$server_pid"
	wait "$server_pid" 2>/dev/null || true
	server_pid=""
	start_server "$provider"
	curl -fsS "$api/v1/capabilities" >"$work_dir/configured-capabilities"
	grep -Fq 'chat.complete' "$work_dir/configured-capabilities" || fail "$provider chat capability is missing"
	expect_status 200 -H 'content-type: application/json' \
		-d '{"messages":[{"role":"system","content":"Be concise"},{"role":"user","content":"Say hello"}]}' \
		"$api/v1/chat/completions"
	grep -Fq '"content":"Provider fixture reply"' "$work_dir/response" || fail "$provider response did not reach the API client"
done

printf 'API and provider smoke passed\n'
