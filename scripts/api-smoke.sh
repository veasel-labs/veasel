#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
port="${VEASEL_SMOKE_PORT:-$((30000 + $$ % 20000))}"
api="http://127.0.0.1:${port}"
server_pid=""

cleanup() {
	if [[ -n "$server_pid" ]]; then
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	fi
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
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
	VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" "$work_dir/veasel" serve >"$work_dir/server.log" 2>&1 &
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

grep -Fq '"healthy":true' "$work_dir/health" || fail 'health response is incorrect'
curl -fsS "$api/v1/capabilities" >"$work_dir/capabilities"
grep -Fq 'sessions.create' "$work_dir/capabilities" || fail 'session capability is missing'

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

printf 'API smoke passed\n'
