#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
mkdir "$work_dir/workspace"
plugin_dir="$work_dir/plugins/review-package"
mkdir -p "$plugin_dir/skills/review"
mkdir -p "$plugin_dir/skills/review/references"
mkdir -p "$work_dir/workspace/src" "$work_dir/outside"
cat >"$work_dir/workspace/README.md" <<'EOF'
Veasel workspace smoke fixture.
EOF
cat >"$work_dir/workspace/src/main.v" <<'EOF'
module fixture

// workspace-search-sentinel
EOF
cat >"$work_dir/workspace/src/main_test.v" <<'EOF'
module fixture

fn test_greet_personalizes_hello() {
	assert greet('Ada') == 'Hello, Ada!'
}
EOF
cat >"$work_dir/outside/secret.txt" <<'EOF'
outside-root-secret
EOF
ln -s "$work_dir/outside" "$work_dir/workspace/outside-link"
cat >"$plugin_dir/plugin.json" <<'EOF'
{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"review-tools","version":"1.0.0","description":"Fixture plugin for API smoke tests."}
EOF
cat >"$plugin_dir/mcp.json" <<'EOF'
{"$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{"catalog-http":{"type":"streamable-http","url":"https://catalog.example.invalid/private/path?token=smoke-only-secret","headers":{"Authorization":"Bearer smoke-only-secret"}}}}
EOF
cat >"$plugin_dir/skills/review/SKILL.md" <<'EOF'
---
name: review
description: Review code changes carefully.
---

Fixture skill instructions for verifying session activation.
EOF
cat >"$plugin_dir/skills/review/references/REFERENCE.md" <<'EOF'
Skill reference smoke sentinel.
EOF
port="${VEASEL_SMOKE_PORT:-$((30000 + $$ % 20000))}"
api="http://127.0.0.1:${port}"
server_pid=""
provider_pid=""

# Every smoke request must fail with a useful error instead of hanging until the
# GitHub Actions job timeout. Individual calls may override max-time when needed.
curl() {
	command curl --connect-timeout 2 --max-time 30 "$@"
}

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
	if [[ -f "$work_dir/provider.log" ]]; then
		cat "$work_dir/provider.log" >&2
	fi
	if [[ -f "$work_dir/headless.log" ]]; then
		cat "$work_dir/headless.log" >&2
	fi
	if [[ -f "$work_dir/headless-continuation.log" ]]; then
		cat "$work_dir/headless-continuation.log" >&2
	fi
	if [[ -f "$work_dir/headless-timeout.log" ]]; then
		cat "$work_dir/headless-timeout.log" >&2
	fi
	if [[ -f "$work_dir/headless-timeout-result" ]]; then
		cat "$work_dir/headless-timeout-result" >&2
	fi
	if [[ -f "$work_dir/headless-result" ]]; then
		cat "$work_dir/headless-result" >&2
	fi
	if [[ -f "$plugin_dir/requests.log" ]]; then
		cat "$plugin_dir/requests.log" >&2
	fi
	exit 1
}

expect_status() {
	local expected="$1"
	shift
	local actual
	actual="$(curl -sS -o "$work_dir/response" -w '%{http_code}' "$@")" || fail "request failed: $*"
	[[ "$actual" == "$expected" ]] || fail "expected HTTP $expected, got $actual ($(cat "$work_dir/response"))"
}

start_mcp_turn() {
	local content="$1"
	local operation_id
	operation_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
	expect_status 202 -H 'Prefer: respond-async' -H 'content-type: application/json' \
		-H "X-Veasel-Operation-ID: $operation_id" -d "{\"content\":\"$content\"}" \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq "\"operation_id\":\"$operation_id\"" "$work_dir/response" \
		|| fail 'async session response did not return its operation ID'
	operation="$(curl -fsS "$api/v1/sessions/$session_id/operations/$operation_id")" \
		|| fail 'durable async operation status endpoint was unavailable'
	printf '%s' "$operation" | python3 -c 'import json, sys; operation = json.load(sys.stdin); assert operation["id"] == sys.argv[1]; assert operation["session_id"] == sys.argv[2]; assert operation["status"] in {"running", "completed", "failed", "cancelled"}' "$operation_id" "$session_id" \
		|| fail 'durable async operation response did not match the accepted session turn'
	printf '%s' "$operation_id"
}

get_turn_completion_status() {
	python3 - "$work_dir/data/veasel.sqlite3" "$session_id" "$1" <<'PY'
import json
import sqlite3
import sys

database, session_id, operation_id = sys.argv[1:]
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
rows = connection.execute(
    "SELECT data FROM events WHERE type = 'session.turn_completed' AND session_id = ? ORDER BY id DESC",
    (session_id,),
).fetchall()
for (encoded,) in rows:
    event = json.loads(encoded)
    if event.get("operation_id") == operation_id:
        print(event.get("status", ""))
        break
PY
}

wait_for_turn_completion() {
	local operation_id="$1"
	local expected_status="$2"
	local status
	for ((attempt = 0; attempt < 150; attempt++)); do
		status="$(get_turn_completion_status "$operation_id")"
		if [[ "$status" == "$expected_status" ]]; then return; fi
		if [[ -n "$status" ]]; then fail "session turn ended as $status; expected $expected_status"; fi
		sleep 0.1
	done
	fail "session turn $operation_id did not emit a completion event"
}

start_server() {
	if [[ -n "${1:-}" ]]; then
		provider_base="/v1"
		[[ "$1" == gemini ]] && provider_base="/v1beta"
		[[ "${2:-}" == redirect ]] && provider_base="/redirect/v1"
		env -u VEASEL_MODEL_API_KEY VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			VEASEL_PLUGIN_DIR="$work_dir/plugins" \
			VEASEL_MODEL_PROVIDER="$1" VEASEL_MODEL=smoke-model \
			OPENAI_API_KEY=veasel-openai-key ANTHROPIC_API_KEY=veasel-anthropic-key \
			GEMINI_API_KEY=veasel-gemini-key \
			VEASEL_MODEL_BASE_URL="http://127.0.0.1:$(cat "$work_dir/provider.port")${provider_base}" \
			"$work_dir/veasel" serve >"$work_dir/server.log" 2>&1 &
	else
		env -u VEASEL_MODEL -u VEASEL_MODEL_API_KEY -u VEASEL_MODEL_BASE_URL -u VEASEL_MODEL_PROVIDER \
			VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" VEASEL_PLUGIN_DIR="$work_dir/plugins" \
			"$work_dir/veasel" serve >"$work_dir/server.log" 2>&1 &
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
"$work_dir/veasel" --help >"$work_dir/help"
expected_version="$(sed -n '1s/^Veasel Code //p' "$work_dir/help")"
[[ -n "$expected_version" ]] || fail 'CLI version is missing from help output'
start_server
expect_status 403 -H 'Host: attacker.example' "$api/v1/health"

grep -Fq '"healthy":true' "$work_dir/health" || fail 'health response is incorrect'
grep -Fq "\"version\":\"$expected_version\"" "$work_dir/health" || fail 'health version does not match the CLI version'
curl -fsS "$api/v1/capabilities" >"$work_dir/capabilities"
grep -Fq 'sessions.create' "$work_dir/capabilities" || fail 'session capability is missing'
grep -Fq 'sessions.skills' "$work_dir/capabilities" || fail 'session skill capability is missing'
grep -Fq 'workspace.search' "$work_dir/capabilities" || fail 'workspace search capability is missing'
curl -fsS "$api/v1/plugins" >"$work_dir/plugins.json"
grep -Fq 'review-tools' "$work_dir/plugins.json" || fail 'plugin catalog is missing the fixture plugin'
grep -Fq 'Review code changes carefully.' "$work_dir/plugins.json" || fail 'plugin catalog is missing skill metadata'
python3 - "$work_dir/plugins.json" <<'PY'
import json
import sys

catalog = json.load(open(sys.argv[1], encoding='utf-8'))
assert isinstance(catalog.get('plugins'), list)
assert isinstance(catalog.get('diagnostics'), list)
plugin = next(item for item in catalog['plugins'] if item['name'] == 'review-tools')
assert {'version', 'description', 'skills', 'mcp_servers', 'diagnostics'} <= plugin.keys()
assert isinstance(plugin['skills'], list)
assert isinstance(plugin['mcp_servers'], list)
assert isinstance(plugin['diagnostics'], list)
skill = next(item for item in plugin['skills'] if item['name'] == 'review')
assert skill['description'] == 'Review code changes carefully.'
assert isinstance(skill['allowed_tools'], list)
assert isinstance(skill['allowed_tools_declared'], bool)
assert 'instructions' not in skill and 'body' not in skill
server = next(item for item in plugin['mcp_servers'] if item['name'] == 'catalog-http')
assert server['url_origin'] == 'https://catalog.example.invalid'
assert server['header_count'] == 1
assert server['header_names'] == ['Authorization']
assert 'private/path' not in json.dumps(catalog)
assert 'smoke-only-secret' not in json.dumps(catalog)
PY
expect_status 400 -H 'content-type: application/json' -d '{"messages":[{"role":"assistant","content":"not a user turn"}]}' "$api/v1/chat/completions"
expect_status 403 -H 'Origin: http://attacker.example' -H 'content-type: application/json' \
	-d '{"title":"forbidden","directory":"/tmp"}' "$api/v1/sessions"
expect_status 503 -H 'Origin: http://localhost:3000' -H 'content-type: application/json' \
	-d '{"messages":[{"role":"user","content":"hello"}]}' "$api/v1/chat/completions"

expect_status 400 -H 'content-type: application/json' -d '{"title":" ","directory":"/tmp"}' "$api/v1/sessions"
expect_status 400 -H 'content-type: application/json' \
	-d "{\"title\":\"Missing workspace\",\"directory\":\"$work_dir/missing\"}" "$api/v1/sessions"
expect_status 201 -H 'content-type: application/json' \
	-d "{\"title\":\"API smoke\",\"directory\":\"$work_dir/workspace\"}" "$api/v1/sessions"
grep -Fq '"title":"API smoke"' "$work_dir/response" || fail 'created session is missing from the response'
grep -Fq "\"directory\":\"$work_dir/workspace\"" "$work_dir/response" || fail 'workspace root was not stored canonically'
session_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$work_dir/response")"
[[ -n "$session_id" ]] || fail 'session id is missing'
expect_status 200 "$api/v1/sessions/$session_id/messages?limit=1"
python3 - "$work_dir/response" <<'PY'
import json
import sys

assert json.load(open(sys.argv[1], encoding='utf-8')) == []
PY
expect_status 400 "$api/v1/sessions/$session_id/messages?limit=0"
expect_status 400 "$api/v1/sessions/$session_id/messages?before=not-an-id"

curl -fsS "$api/v1/sessions/$session_id/workspace/files" >"$work_dir/workspace-files"
grep -Fq 'src/main.v' "$work_dir/workspace-files" || fail 'workspace file listing omitted a source file'
grep -Fq 'README.md' "$work_dir/workspace-files" || fail 'workspace file listing omitted the README'
! grep -Fq '.git/' "$work_dir/workspace-files" || fail 'workspace listing exposed .git contents'
expect_status 200 -H 'content-type: application/json' \
	-d '{"path":"src/main.v"}' "$api/v1/sessions/$session_id/workspace/file"
grep -Fq 'workspace-search-sentinel' "$work_dir/response" || fail 'workspace file content was not returned'
expect_status 400 -H 'content-type: application/json' \
	-d '{"path":"../outside/secret.txt"}' "$api/v1/sessions/$session_id/workspace/file"
expect_status 400 -H 'content-type: application/json' \
	-d '{"path":"outside-link/secret.txt"}' "$api/v1/sessions/$session_id/workspace/file"
expect_status 200 -H 'content-type: application/json' \
	-d '{"query":"workspace-search-sentinel"}' "$api/v1/sessions/$session_id/workspace/search"
grep -Fq '"path":"src/main.v"' "$work_dir/response" || fail 'workspace search did not return the matching path'
grep -Fq '"line":3' "$work_dir/response" || fail 'workspace search returned the wrong line number'

expect_status 201 -H 'content-type: application/json' \
	-d '{"path":"src/main.v","content":"module fixture\n// workspace-search-sentinel\nfn main() { println(\"approved\") }\n"}' \
	"$api/v1/sessions/$session_id/workspace/edits"
grep -Fq '"status":"pending"' "$work_dir/response" || fail 'workspace edit proposal is not pending review'
grep -Fq -- '+fn main()' "$work_dir/response" || fail 'workspace edit proposal omitted the new content diff'
edit_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$work_dir/response")"
[[ -n "$edit_id" ]] || fail 'workspace edit proposal id is missing'
cmp -s "$work_dir/workspace/src/main.v" <(printf 'module fixture\n\n// workspace-search-sentinel\n') || fail 'proposing a workspace edit changed the file before approval'
expect_status 409 -X POST -H 'content-type: application/json' -d '{}' "$api/v1/sessions/$session_id/workspace/edits/$edit_id/approve"
grep -Fq 'has not been reviewed' "$work_dir/response" || fail 'approval did not require a prior diff review'
expect_status 200 "$api/v1/sessions/$session_id/workspace/edits/$edit_id"
grep -Fq '+fn main()' "$work_dir/response" || fail 'workspace edit detail omitted the diff'
expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/edits/$edit_id/approve"
grep -Fq '"status":"applied"' "$work_dir/response" || fail 'approved workspace edit was not marked applied'
grep -Fq 'println("approved")' "$work_dir/workspace/src/main.v" || fail 'approved workspace edit was not applied to disk'
expect_status 409 -X POST "$api/v1/sessions/$session_id/workspace/edits/$edit_id/approve"

expect_status 201 -H 'content-type: application/json' \
	-d '{"path":"src/main.v","content":"module fixture\n// workspace-search-sentinel\nfn main() { println(\"rejected\") }\n"}' \
	"$api/v1/sessions/$session_id/workspace/edits"
edit_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$work_dir/response")"
[[ -n "$edit_id" ]] || fail 'second workspace edit proposal id is missing'
expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/edits/$edit_id/reject"
grep -Fq '"status":"rejected"' "$work_dir/response" || fail 'workspace edit rejection was not persisted'
grep -Fq 'println("approved")' "$work_dir/workspace/src/main.v" || fail 'rejecting a workspace edit changed the file'

curl -fsS "$api/v1/sessions/$session_id/skills" >"$work_dir/skills"
[[ "$(cat "$work_dir/skills")" == '[]' ]] || fail 'new session unexpectedly has active skills'
expect_status 200 -H 'content-type: application/json' \
	-d '{"plugin_name":"review-tools","skill_name":"review","enabled":true}' \
	"$api/v1/sessions/$session_id/skills"
python3 - "$work_dir/response" <<'PY'
import json
import sys

active = json.load(open(sys.argv[1], encoding='utf-8'))
assert {'plugin_name': 'review-tools', 'skill_name': 'review'} in active
PY
expect_status 400 -H 'content-type: application/json' \
	-d '{"plugin_name":"review-tools","skill_name":"review"}' \
	"$api/v1/sessions/$session_id/skills"
expect_status 404 -H 'content-type: application/json' \
	-d '{"plugin_name":"review-tools","skill_name":"missing","enabled":true}' \
	"$api/v1/sessions/$session_id/skills"

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
curl -fsS "$api/v1/sessions/$session_id/skills" >"$work_dir/recovered-skills"
grep -Fq 'review-tools' "$work_dir/recovered-skills" || fail 'session skill selection did not survive a server restart'

python3 "$repo_root/scripts/mock-provider.py" "$work_dir/provider.port" >"$work_dir/provider.log" 2>&1 &
provider_pid=$!
for ((attempt = 0; attempt < 80; attempt++)); do
	[[ -s "$work_dir/provider.port" ]] && break
	sleep 0.1
done
[[ -s "$work_dir/provider.port" ]] || fail 'mock model provider did not become ready'
for provider in openai-compatible anthropic gemini; do
	printf 'Smoke: provider workflow starting (%s)\n' "$provider"
	rm -f "$work_dir/workspace/approved-effect.txt"
	cat >"$work_dir/workspace/src/main.v" <<'EOF'
module fixture

// workspace-search-sentinel
EOF
	kill "$server_pid"
	wait "$server_pid" 2>/dev/null || true
	server_pid=""
	start_server "$provider"
	curl -fsS "$api/v1/capabilities" >"$work_dir/configured-capabilities"
	grep -Fq 'chat.complete' "$work_dir/configured-capabilities" || fail "$provider chat capability is missing"
	grep -Fq 'chat.cancel' "$work_dir/configured-capabilities" || fail "$provider chat cancellation capability is missing"
	grep -Fq 'agent.tools.workspace_readonly' "$work_dir/configured-capabilities" || fail "$provider workspace tool capability is missing"
	grep -Fq 'agent.tools.skill_read_resource' "$work_dir/configured-capabilities" || fail "$provider skill resource capability is missing"
	expect_status 200 -H 'content-type: application/json' \
		-d '{"messages":[{"role":"system","content":"Be concise"},{"role":"user","content":"Say hello"}]}' \
		"$api/v1/chat/completions"
	grep -Fq '"content":"Provider fixture reply"' "$work_dir/response" || fail "$provider response did not reach the API client"
	if [[ "$provider" == openai-compatible ]]; then
		printf 'Smoke: exercising the headless CLI against the shared provider/runtime\n'
		env VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			"$work_dir/veasel" run --prompt 'Say hello' --workspace "$work_dir/workspace" --json \
			>"$work_dir/headless-result" 2>"$work_dir/headless.log" || fail 'headless task command failed'
		headless_session_id="$(python3 - "$work_dir/headless-result" "$session_id" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
existing_session_id = sys.argv[2]
assert result["status"] == "completed", result
assert result["provider"] == "openai-compatible", result
assert result["model"] == "smoke-model", result
assert result["response"] == "Provider fixture reply", result
assert len(result["session_id"]) == 36, result
assert len(result["operation_id"]) == 36, result
assert result["session_id"] != existing_session_id, result
print(result["session_id"])
PY
		)" || fail 'headless result was invalid'
		curl -fsS "$api/v1/sessions/$headless_session_id/messages" >"$work_dir/headless-messages"
		grep -Fq '"content":"Say hello"' "$work_dir/headless-messages" || fail 'headless user turn was not persisted'
		grep -Fq '"content":"Provider fixture reply"' "$work_dir/headless-messages" || fail 'headless assistant turn was not persisted'
		printf 'Smoke: continuing the same headless session with an independent operation ID\n'
		env VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			"$work_dir/veasel" run --prompt 'Say hello' --session "$headless_session_id" --json \
			>"$work_dir/headless-continuation-result" 2>"$work_dir/headless-continuation.log" \
			|| fail 'headless session continuation failed'
		python3 - "$work_dir/headless-continuation-result" "$headless_session_id" \
			"$work_dir/headless-result" <<'PY'
import json
import sys

continued = json.load(open(sys.argv[1], encoding="utf-8"))
first = json.load(open(sys.argv[3], encoding="utf-8"))
assert continued["status"] == "completed", continued
assert continued["session_id"] == sys.argv[2], continued
assert continued["operation_id"] != first["operation_id"], continued
assert continued["response"] == "Provider fixture reply", continued
PY
		curl -fsS "$api/v1/sessions/$headless_session_id/messages" >"$work_dir/headless-messages"
		python3 - "$work_dir/headless-messages" <<'PY'
import json
import sys

messages = json.load(open(sys.argv[1], encoding="utf-8"))
assert sum(message["role"] == "user" and message["content"] == "Say hello" for message in messages) == 2
assert sum(message["role"] == "assistant" and message["content"] == "Provider fixture reply" for message in messages) == 2
PY
		printf 'Smoke: checking headless timeout cancellation and operation IDs\n'
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/hold-slow-response" >/dev/null \
			|| fail 'slow provider fixture could not be held'
		if env VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			"$work_dir/veasel" run --prompt 'Wait for cancellation' --workspace "$work_dir/workspace" \
			--timeout 1 --json >"$work_dir/headless-timeout-result" 2>"$work_dir/headless-timeout.log"; then
			fail 'headless task unexpectedly completed despite its one-second timeout'
		else
			headless_timeout_status=$?
		fi
		[[ "$headless_timeout_status" == 1 ]] || fail "headless timeout exited with ${headless_timeout_status}, expected 1"
		python3 - "$work_dir/headless-timeout-result" <<'PY'
import json
import sys
import uuid

result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["status"] in {"cancelling", "cancelled", "timed_out"}, result
assert str(uuid.UUID(result["session_id"])) == result["session_id"], result
assert str(uuid.UUID(result["operation_id"])) == result["operation_id"], result
PY
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/release-slow-response" >/dev/null \
			|| fail 'slow provider fixture could not be released after headless cancellation'
	fi
	event_cursor="$(python3 -c 'import sqlite3, sys; db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True); print(db.execute("SELECT COALESCE(MAX(id), 0) FROM events").fetchone()[0])' "$work_dir/data/veasel.sqlite3")"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Continue this session"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq "\"provider\":\"$provider\"" "$work_dir/response" || fail "$provider session response reported the wrong provider"
	timeout 2s curl -NsS -H "Last-Event-ID: $event_cursor" "$api/v1/events" >"$work_dir/provider-events" 2>/dev/null || [[ "$?" -eq 124 ]]
	grep -Fq 'event: assistant.delta' "$work_dir/provider-events" || fail "$provider did not persist assistant streaming events"
	grep -Fq '"operation_id":"' "$work_dir/provider-events" || fail "$provider streaming events omitted the operation identifier"
	grep -Fq '"delta":"Provider ' "$work_dir/provider-events" || fail "$provider streaming events omitted incremental text"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Read skill reference"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq 'Read skill reference smoke sentinel' "$work_dir/response" || fail "$provider could not read an active Agent Skill resource"
	if [[ "$provider" == openai-compatible ]]; then
		printf 'Smoke: testing provider cancellation\n'
		operation_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
		curl -sS -o "$work_dir/cancelled-turn-response" -w '%{http_code}' \
			-X POST -H 'content-type: application/json' -H "x-veasel-operation-id: $operation_id" \
			-d '{"content":"Wait for cancellation"}' \
			"$api/v1/sessions/$session_id/messages" >"$work_dir/cancelled-turn-status" &
		turn_pid=$!
		for ((attempt = 0; attempt < 200; attempt++)); do
			grep -Fq 'SLOW_PROVIDER_REQUEST_STARTED' "$work_dir/provider.log" && break
			sleep 0.05
		done
		grep -Fq 'SLOW_PROVIDER_REQUEST_STARTED' "$work_dir/provider.log" || fail 'slow provider request did not start'
		cancel_status=""
		for ((attempt = 0; attempt < 10; attempt++)); do
			cancel_status="$(curl -sS -o "$work_dir/cancel-response" -w '%{http_code}' --max-time 1 \
				-X POST "$api/v1/sessions/$session_id/operations/$operation_id/cancel" 2>/dev/null)" || cancel_status=""
			[[ "$cancel_status" == 202 || "$cancel_status" == 404 ]] && break
		done
		[[ "$cancel_status" == 202 || "$cancel_status" == 404 ]] || fail "cancellation endpoint did not respond: ${cancel_status:-timeout}"
		if [[ "$cancel_status" == 404 ]]; then
			grep -Fq 'active operation not found' "$work_dir/cancel-response" || fail 'cancellation retry returned an unexpected 404'
		fi
		wait "$turn_pid"
		cancelled_turn_status="$(cat "$work_dir/cancelled-turn-status")"
		[[ "$cancelled_turn_status" == 409 ]] || fail "cancelled provider request returned HTTP ${cancelled_turn_status:-no response}, expected 409 ($(cat "$work_dir/cancelled-turn-response"))"
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/release-slow-response" >/dev/null || fail 'slow provider fixture could not be released'
		printf 'Smoke: provider cancellation passed\n'
	fi
	printf 'Smoke: testing provider workspace tools (%s)\n' "$provider"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Inspect workspace"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq 'Found workspace-search-sentinel' "$work_dir/response" || fail "$provider native tool call did not return the workspace search result"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Try to read outside"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq 'The path was rejected.' "$work_dir/response" || fail "$provider tool call did not reject parent traversal"
	! grep -Fq 'outside-root-secret' "$work_dir/response" || fail "$provider tool result exposed a file outside the workspace"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Propose workspace edit"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq 'Proposed a file edit for review.' "$work_dir/response" || fail "$provider edit proposal did not reach the user"
	edit_path='src/main.v'
	cmp -s "$work_dir/workspace/$edit_path" <(printf 'module fixture\n\n// workspace-search-sentinel\n') || fail "$provider proposal changed a file before approval"
	curl -fsS "$api/v1/sessions/$session_id/workspace/edits" >"$work_dir/provider-edits"
	grep -Fq "$edit_path" "$work_dir/provider-edits" || fail "$provider proposal was not persisted"
	edit_id="$(python3 -c 'import json, sys; path = sys.argv[1]; edits = json.load(open(sys.argv[2])); print(next((edit["id"] for edit in edits if edit["path"] == path), ""))' "$edit_path" "$work_dir/provider-edits")"
	[[ -n "$edit_id" ]] || fail "$provider proposal id is missing"
	expect_status 200 -X GET "$api/v1/sessions/$session_id/workspace/edits/$edit_id"
	grep -Fq '+fn greet(name string) string' "$work_dir/response" || fail "$provider proposal diff is missing"
	expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/edits/$edit_id/approve"
	grep -Fq '"status":"applied"' "$work_dir/response" || fail "$provider proposal approval failed"
	grep -Fq 'fn greet(name string) string' "$work_dir/workspace/$edit_path" || fail "$provider approved greeting implementation was not applied"
	"${V_BIN:-v}" test "$work_dir/workspace/src" || fail "$provider-approved coding task did not pass its fixture test"
	printf 'Smoke: testing provider shell approval and timeout (%s)\n' "$provider"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Propose shell command"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq 'Proposed a shell command for review.' "$work_dir/response" || fail "$provider shell command proposal did not reach the user"
	curl -fsS "$api/v1/sessions/$session_id/workspace/commands" >"$work_dir/provider-commands"
	command_id="$(python3 -c 'import json, sys; commands = json.load(open(sys.argv[1])); print(next((item["id"] for item in commands if item["status"] == "pending" and "echo veasel-shell-approved" in item["command"]), ""))' "$work_dir/provider-commands")"
	[[ -n "$command_id" ]] || fail "$provider shell command proposal was not persisted"
	expect_status 409 -X POST "$api/v1/sessions/$session_id/workspace/commands/$command_id/approve"
	grep -Fq 'Inspect the exact command first' "$work_dir/response" || fail "$provider shell command ran without a recorded review"
	[[ ! -e "$work_dir/workspace/approved-effect.txt" ]] || fail "$provider unreviewed command changed the workspace"
	expect_status 200 "$api/v1/sessions/$session_id/workspace/commands/$command_id"
	grep -Fq 'echo veasel-shell-approved' "$work_dir/response" || fail "$provider command review omitted the exact command"
	expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/commands/$command_id/approve"
	grep -Fq '"status":"succeeded"' "$work_dir/response" || fail "$provider command approval did not finish successfully"
	grep -Fq 'veasel-shell-approved' "$work_dir/response" || fail "$provider command output was not captured"
	[[ "$(cat "$work_dir/workspace/approved-effect.txt")" == 'veasel-shell-approved' ]] || fail "$provider approved command did not create its fixture effect"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Propose slow shell command"}' \
		"$api/v1/sessions/$session_id/messages"
	curl -fsS "$api/v1/sessions/$session_id/workspace/commands" >"$work_dir/provider-commands"
	command_id="$(python3 -c 'import json, sys; commands = json.load(open(sys.argv[1])); print(next((item["id"] for item in commands if item["status"] == "pending" and item["timeout_seconds"] == 1), ""))' "$work_dir/provider-commands")"
	[[ -n "$command_id" ]] || fail "$provider bounded shell command proposal was not persisted"
	expect_status 200 "$api/v1/sessions/$session_id/workspace/commands/$command_id"
	expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/commands/$command_id/approve"
	grep -Fq '"status":"timed_out"' "$work_dir/response" || fail "$provider shell timeout was not enforced"
	curl -fsS "$api/v1/sessions/$session_id/messages" >"$work_dir/messages"
	grep -Fq '"content":"Continue this session"' "$work_dir/messages" || fail "$provider user turn was not persisted"
	grep -Fq '"content":"Inspect workspace"' "$work_dir/messages" || fail "$provider tool-call user turn was not persisted"
	grep -Fq '"content":"Provider fixture reply"' "$work_dir/messages" || fail "$provider assistant turn was not persisted"
	grep -Fq '"content":"Found workspace-search-sentinel"' "$work_dir/messages" || fail "$provider tool result was not followed by a final response"
	grep -Fq '"content":"The path was rejected."' "$work_dir/messages" || fail "$provider traversal attempt was not safely answered"
	grep -Fq '"content":"Proposed a file edit for review."' "$work_dir/messages" || fail "$provider edit proposal was not persisted"
	grep -Fq '"content":"Proposed a shell command for review."' "$work_dir/messages" || fail "$provider shell command proposal was not persisted"
done
curl -fsS "$api/v1/sessions/$session_id/messages" >"$work_dir/all-messages"
expect_status 200 "$api/v1/sessions/$session_id/messages?limit=2"
cp "$work_dir/response" "$work_dir/latest-page"
python3 - "$work_dir/all-messages" "$work_dir/latest-page" <<'PY'
import json
import sys

history = json.load(open(sys.argv[1], encoding='utf-8'))
page = json.load(open(sys.argv[2], encoding='utf-8'))
assert len(history) >= 4
assert page == history[-2:]
assert page[0]['id'] < page[1]['id']
PY
first_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[0]["id"])' "$work_dir/latest-page")"
expect_status 200 "$api/v1/sessions/$session_id/messages?before=$first_id&limit=2"
python3 - "$work_dir/all-messages" "$work_dir/latest-page" "$work_dir/response" <<'PY'
import json
import sys

history = json.load(open(sys.argv[1], encoding='utf-8'))
latest = json.load(open(sys.argv[2], encoding='utf-8'))
previous = json.load(open(sys.argv[3], encoding='utf-8'))
assert previous == history[-4:-2]
assert previous[-1]['id'] < latest[0]['id']
PY
expect_status 400 "$api/v1/sessions/$session_id/messages?limit=101"
expect_status 400 "$api/v1/sessions/$session_id/messages?before=-1"
printf 'Smoke: provider workflows passed; starting MCP approval checks\n'

# Exercise a provider-requested MCP side effect through the real approval API.
printf 'Smoke: exercising MCP tool approval, rejection, and error persistence\n'
cat >"$plugin_dir/mcp.json" <<'EOF'
{"$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{"effect":{"type":"stdio","command":"node","args":["${PLUGIN_ROOT}/effect.mjs"]}}}
EOF
cat >"$plugin_dir/effect.mjs" <<'EOF'
import readline from 'node:readline';
import { appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  appendFileSync(join(process.env.PLUGIN_ROOT, 'requests.log'), `${request.method}\n`);
  if (!request.id) continue;
  let result = {};
  if (request.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'effect-fixture', version: '1.0.0' } };
  else if (request.method === 'tools/list') result = { tools: [{ name: 'write', description: 'Write one fixture value.', inputSchema: { type: 'object', properties: { value: { type: 'string' } }, required: ['value'], additionalProperties: false } }] };
  else if (request.method === 'tools/call') {
    if (request.params.arguments.value === 'tool-error') {
      result = { content: [{ type: 'text', text: 'fixture tool error' }], isError: true };
    } else {
      writeFileSync(join(process.env.PLUGIN_ROOT, 'effect.txt'), request.params.arguments.value);
      result = { content: [{ type: 'text', text: `fixture effect: ${request.params.arguments.value}` }], isError: false };
    }
  }
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n');
}
EOF
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
start_server openai-compatible
expect_status 200 -H 'content-type: application/json' \
	-d '{"plugin_name":"review-tools","server_name":"effect","trusted":true}' \
	"$api/v1/sessions/$session_id/mcp-servers"
python3 - "$work_dir/response" <<'PY'
import json
import sys

trusted = json.load(open(sys.argv[1], encoding='utf-8'))
assert {'plugin_name': 'review-tools', 'server_name': 'effect'} in trusted
PY
rm -f "$plugin_dir/effect.txt"
mcp_operation_id="$(start_mcp_turn 'Call MCP effect')"
for ((attempt = 0; attempt < 100; attempt++)); do
	curl --max-time 10 -fsS "$api/v1/sessions/$session_id/mcp-tool-calls" >"$work_dir/mcp-calls" || fail 'unable to poll MCP approval status'
	mcp_call_id="$(python3 -c 'import json,sys; calls=json.load(open(sys.argv[1])); print(next((item["id"] for item in calls if item["status"] == "pending"), ""))' "$work_dir/mcp-calls")"
	[[ -n "$mcp_call_id" ]] && break
	turn_status="$(get_turn_completion_status "$mcp_operation_id")"
	[[ -z "$turn_status" ]] || fail "provider turn completed ($turn_status) before MCP approval was created"
	sleep 0.1
done
[[ -n "$mcp_call_id" ]] || fail 'provider MCP call did not pause for approval'
printf 'Smoke: MCP approval call discovered; inspecting and approving\n'
[[ ! -e "$plugin_dir/effect.txt" ]] || fail 'MCP server produced an effect before user approval'
expect_status 409 -X POST "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id/approve"
grep -Fq 'inspected before approval' "$work_dir/response" || fail 'MCP call was approvable before inspection'
expect_status 200 "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id"
grep -Fq 'approved-effect' "$work_dir/response" || fail 'MCP call inspection omitted the exact arguments'
expect_status 200 -X POST "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id/approve"
grep -Fq '"status":"approved"' "$work_dir/response" || fail 'MCP call approval was not persisted'
wait_for_turn_completion "$mcp_operation_id" completed
curl -fsS "$api/v1/sessions/$session_id/messages" >"$work_dir/mcp-approved-messages"
grep -Fq 'MCP effect completed.' "$work_dir/mcp-approved-messages" || fail 'approved MCP result did not resume the provider turn'
[[ "$(cat "$plugin_dir/effect.txt")" == 'approved-effect' ]] || fail 'approved MCP tool did not produce exactly the expected fixture effect'
printf 'Smoke: MCP approval path passed; exercising rejection\n'

mcp_operation_id="$(start_mcp_turn 'Reject MCP effect')"
for ((attempt = 0; attempt < 100; attempt++)); do
	curl --max-time 10 -fsS "$api/v1/sessions/$session_id/mcp-tool-calls" >"$work_dir/mcp-calls" || fail 'unable to poll rejected MCP call status'
	mcp_call_id="$(python3 -c 'import json,sys; calls=json.load(open(sys.argv[1])); print(next((item["id"] for item in calls if item["status"] == "pending"), ""))' "$work_dir/mcp-calls")"
	[[ -n "$mcp_call_id" ]] && break
	turn_status="$(get_turn_completion_status "$mcp_operation_id")"
	[[ -z "$turn_status" ]] || fail "provider turn completed ($turn_status) before rejected MCP approval was created"
	sleep 0.1
done
[[ -n "$mcp_call_id" ]] || fail 'second provider MCP call did not pause for approval'
printf 'Smoke: MCP rejection call discovered; rejecting\n'
expect_status 200 "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id"
expect_status 200 -X POST "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id/reject"
grep -Fq '"status":"rejected"' "$work_dir/response" || fail 'MCP call rejection was not persisted'
wait_for_turn_completion "$mcp_operation_id" completed
curl -fsS "$api/v1/sessions/$session_id/messages" >"$work_dir/mcp-rejected-messages"
grep -Fq 'MCP request rejected.' "$work_dir/mcp-rejected-messages" || fail 'provider did not receive the MCP rejection result'
[[ "$(cat "$plugin_dir/effect.txt")" == 'approved-effect' ]] || fail 'rejected MCP tool changed the fixture effect'
printf 'Smoke: MCP rejection path passed; exercising MCP isError persistence\n'

mcp_operation_id="$(start_mcp_turn 'Fail MCP effect')"
for ((attempt = 0; attempt < 100; attempt++)); do
	curl --max-time 10 -fsS "$api/v1/sessions/$session_id/mcp-tool-calls" >"$work_dir/mcp-calls" || fail 'unable to poll MCP error approval status'
	mcp_call_id="$(python3 -c 'import json,sys; calls=json.load(open(sys.argv[1])); print(next((item["id"] for item in calls if item["status"] == "pending"), ""))' "$work_dir/mcp-calls")"
	[[ -n "$mcp_call_id" ]] && break
	turn_status="$(get_turn_completion_status "$mcp_operation_id")"
	[[ -z "$turn_status" ]] || fail "provider turn completed ($turn_status) before MCP error approval was created"
	sleep 0.1
done
[[ -n "$mcp_call_id" ]] || fail 'provider MCP error call did not pause for approval'
printf 'Smoke: MCP error call discovered; inspecting and approving\n'
expect_status 200 "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id"
expect_status 200 -X POST "$api/v1/sessions/$session_id/mcp-tool-calls/$mcp_call_id/approve"
wait_for_turn_completion "$mcp_operation_id" completed
curl -fsS "$api/v1/sessions/$session_id/messages" >"$work_dir/mcp-error-messages"
grep -Fq 'MCP tool reported an error.' "$work_dir/mcp-error-messages" || fail 'provider did not receive the MCP tool error result'
curl -fsS "$api/v1/sessions/$session_id/mcp-tool-calls" >"$work_dir/mcp-calls"
python3 -c 'import json,sys; calls=json.load(open(sys.argv[1])); assert any(item["id"] == sys.argv[2] and item["status"] == "failed" for item in calls)' "$work_dir/mcp-calls" "$mcp_call_id" || fail 'MCP isError result was not persisted as failed'
[[ "$(cat "$plugin_dir/effect.txt")" == 'approved-effect' ]] || fail 'MCP error fixture unexpectedly changed the effect'
printf 'Smoke: MCP approval, rejection, and error persistence passed\n'

rm -rf "$work_dir/plugins/review-package"
expect_status 200 -H 'content-type: application/json' \
	-d '{"plugin_name":"review-tools","skill_name":"review","enabled":false}' \
	"$api/v1/sessions/$session_id/skills"
[[ "$(cat "$work_dir/response")" == '[]' ]] || fail 'skill disable did not clear the session selection'

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
start_server openai-compatible redirect
expect_status 502 -H 'content-type: application/json' \
	-d '{"messages":[{"role":"user","content":"Say hello"}]}' "$api/v1/chat/completions"
grep -Fq 'Model provider request failed' "$work_dir/response" || fail 'provider redirect response was not rejected'

printf 'Smoke: model settings API redaction and persistence\n'
curl -fsS "$api/v1/config/model" >"$work_dir/model-settings-before"
expect_status 400 -H 'content-type: application/json' \
	-d '{"provider":"unsupported","model":"smoke-model","base_url":"https://example.com"}' \
	"$api/v1/config/model"
expect_status 200 -X POST -H 'content-type: application/json' \
	-d '{"provider":"openai-compatible","model":"settings-smoke-model","base_url":"http://127.0.0.1:1/v1","api_key":"smoke-only-model-key"}' \
	"$api/v1/config/model"
grep -Fq '"api_key_saved":true' "$work_dir/response" || fail 'saved API key presence is missing from settings response'
! grep -Fq 'smoke-only-model-key' "$work_dir/response" || fail 'settings API exposed the saved API key'
[[ "$(stat -c '%a' "$work_dir/data/model-settings.json")" == '600' ]] || fail 'model settings file is not owner-only'
grep -Fq 'smoke-only-model-key' "$work_dir/data/model-settings.json" || fail 'saved model key was not persisted'
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
start_server openai-compatible redirect
curl -fsS "$api/v1/config/model" >"$work_dir/model-settings-after"
python3 - "$work_dir/model-settings-after" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
assert settings["active_provider"] == "openai-compatible"
profile = settings["profiles"]["openai-compatible"]
assert profile["model"] == "settings-smoke-model"
assert profile["api_key_saved"] is True
assert "api_key" not in profile
assert "smoke-only-model-key" not in json.dumps(settings)
PY
grep -Fq 'smoke-only-model-key' "$work_dir/data/model-settings.json" || fail 'model key was lost after server restart'
! grep -Fq 'smoke-only-model-key' "$work_dir/server.log" || fail 'server logs exposed the model API key'

printf 'API and provider smoke passed\n'
