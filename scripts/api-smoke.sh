#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
mkdir "$work_dir/workspace"
plugin_dir="$work_dir/plugins/review-package"
mkdir -p "$plugin_dir/skills/review"
mkdir -p "$plugin_dir/skills/review/references"
mkdir -p "$plugin_dir/com.veasel.code"
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
{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"review-tools","version":"1.0.0","description":"Fixture plugin for API smoke tests.","extensions":{"com.veasel.code":{"display_name":"Review tools"}}}
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
cat >"$plugin_dir/com.veasel.code/note.txt" <<'EOF'
extension-secret-sentinel
EOF
free_port() {
	python3 -c 'import socket; sock = socket.socket(); sock.bind(("127.0.0.1", 0)); print(sock.getsockname()[1]); sock.close()'
}

port="${VEASEL_SMOKE_PORT:-$(free_port)}"
api="http://127.0.0.1:${port}"
server_pid=""
autonomous_server_pid=""
provider_pid=""
cold_server_pid=""

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
	if [[ -n "$cold_server_pid" ]]; then
		kill "$cold_server_pid" 2>/dev/null || true
	fi
	if [[ -n "$autonomous_server_pid" ]]; then
		kill "$autonomous_server_pid" 2>/dev/null || true
		wait "$autonomous_server_pid" 2>/dev/null || true
	fi
	if [[ -n "${VEASEL_KEEP_SMOKE_DIR:-}" ]]; then
		printf 'Keeping smoke artifacts in %s\n' "$work_dir" >&2
	else
		rm -rf "$work_dir"
	fi
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
	if [[ -f "$work_dir/headless-trace.log" ]]; then
		cat "$work_dir/headless-trace.log" >&2
	fi
	if [[ -f "$work_dir/headless-trace-result" ]]; then
		cat "$work_dir/headless-trace-result" >&2
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
	if [[ -f "$work_dir/cold-headless.log" ]]; then
		cat "$work_dir/cold-headless.log" >&2
	fi
	if [[ -f "$work_dir/cold-headless-result" ]]; then
		cat "$work_dir/cold-headless-result" >&2
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
	# Reusing one port across every restart can collide with a lingering
	# listener from the previous server, so take a fresh ephemeral port
	# unless the caller pinned one explicitly.
	if [[ -z "${VEASEL_SMOKE_PORT:-}" ]]; then
		port="$(free_port)"
		api="http://127.0.0.1:${port}"
	fi
	if [[ -n "${1:-}" ]]; then
		provider_base="/v1"
		[[ "$1" == gemini ]] && provider_base="/v1beta"
		[[ "${2:-}" == redirect ]] && provider_base="/redirect/v1"
		provider_model=smoke-model
		provider_api_key=veasel-openai-key
		[[ "$1" == meta ]] && provider_model=muse-wonder-1.0
		if [[ "$1" == openai-responses ]]; then
			provider_model=gpt-5.1-codex
			provider_api_key=veasel-openai-responses-key
		fi
		env -u VEASEL_MODEL_API_KEY VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			VEASEL_PLUGIN_DIR="$work_dir/plugins" \
			VEASEL_MODEL_PROVIDER="$1" VEASEL_MODEL="$provider_model" \
			OPENAI_API_KEY="$provider_api_key" ANTHROPIC_API_KEY=veasel-anthropic-key \
			MODEL_API_KEY=veasel-meta-key \
			GEMINI_API_KEY=veasel-gemini-key \
			DASHSCOPE_API_KEY=veasel-dashscope-key ZAI_API_KEY=veasel-zai-key \
			302AI_API_KEY=veasel-302-ai-key GMI_API_KEY=veasel-gmi-cloud-key \
			MINIMAX_API_KEY=veasel-minimax-key SCW_SECRET_KEY=veasel-scaleway-key \
			BASETEN_API_KEY=veasel-baseten-key CORTECS_API_KEY=veasel-cortecs-key \
			DIGITALOCEAN_ACCESS_TOKEN=veasel-digitalocean-key FROGBOT_API_KEY=veasel-frogbot-key \
			HELICONE_API_KEY=veasel-helicone-key IOINTELLIGENCE_API_KEY=veasel-ionet-key \
			LLMGATEWAY_API_KEY=veasel-llmgateway-key OLLAMA_API_KEY=veasel-ollama-cloud-key \
			ZENMUX_API_KEY=veasel-zenmux-key \
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
		if ! kill -0 "$server_pid" 2>/dev/null; then
			break
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
timeout --foreground -k 2s 5s env VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/serve-help-data" \
	"$work_dir/veasel" serve --help >"$work_dir/serve-help"
grep -Fq 'Usage: veasel serve' "$work_dir/serve-help" || fail 'serve help is missing'
[[ ! -e "$work_dir/serve-help-data" ]] || fail 'serve help unexpectedly initialized backend data'
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
assert plugin['veasel_extension'] == {'display_name': 'Review tools', 'has_directory': True}
assert 'private/path' not in json.dumps(catalog)
assert 'smoke-only-secret' not in json.dumps(catalog)
assert 'extension-secret-sentinel' not in json.dumps(catalog)
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
provider_port="$(cat "$work_dir/provider.port")"
provider_ready=0
for ((attempt = 0; attempt < 80; attempt++)); do
	if (echo >/dev/tcp/127.0.0.1/"$provider_port") >/dev/null 2>&1; then
		provider_ready=1
		break
	fi
	sleep 0.1
done
[[ "$provider_ready" -eq 1 ]] || fail 'mock model provider port is not accepting connections'

printf 'Smoke: checking JSON output when veasel run starts a cold backend\n'
cold_port="$(free_port)"
env VEASEL_PORT="$cold_port" VEASEL_DATA_DIR="$work_dir/cold-data" \
	VEASEL_PLUGIN_DIR="$work_dir/plugins" VEASEL_MODEL_PROVIDER=openai-compatible \
	VEASEL_MODEL=smoke-model OPENAI_API_KEY=veasel-openai-key \
	VEASEL_MODEL_BASE_URL="http://127.0.0.1:${provider_port}/v1" \
	"$work_dir/veasel" run --prompt 'Say hello' --workspace "$work_dir/workspace" --json \
	>"$work_dir/cold-headless-result" 2>"$work_dir/cold-headless.log" \
	|| fail 'cold-start headless task command failed'
python3 - "$work_dir/cold-headless-result" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["status"] == "completed", result
assert result["provider"] == "openai-compatible", result
assert result["model"] == "smoke-model", result
assert result["response"] == "Provider fixture reply", result
PY
cold_server_pid="$(pgrep -f -x "$work_dir/veasel serve" | head -n 1 || true)"
[[ -n "$cold_server_pid" ]] || fail 'cold-start backend process was not found for cleanup'

for provider in openai-compatible openai openai-responses anthropic gemini meta dashscope zai 302-ai gmi-cloud minimax scaleway baseten cortecs digitalocean frogbot helicone io-net llmgateway ollama-cloud zenmux; do
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
	expect_status 200 "$api/v1/config/models?provider=$provider"
	python3 - "$work_dir/response" "$provider" <<'PY'
import json
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
assert catalog["provider"] == sys.argv[2]
models = {model["id"]: model["name"] for model in catalog["models"]}
expected = {
    "openai-compatible": ("smoke-model", "smoke-model"),
    "openai": ("smoke-model", "smoke-model"),
    "openai-responses": ("gpt-5.1-codex", "gpt-5.1-codex"),
    "anthropic": ("claude-fixture", "Claude Fixture"),
    "gemini": ("gemini-fixture", "Gemini Fixture"),
    "meta": ("muse-wonder-1.0", "muse-wonder-1.0"),
    "dashscope": ("smoke-model", "smoke-model"),
    "zai": ("smoke-model", "smoke-model"),
    "302-ai": ("smoke-model", "smoke-model"),
    "gmi-cloud": ("smoke-model", "smoke-model"),
    "minimax": ("smoke-model", "smoke-model"),
    "scaleway": ("smoke-model", "smoke-model"),
    "baseten": ("smoke-model", "smoke-model"),
    "cortecs": ("smoke-model", "smoke-model"),
    "digitalocean": ("smoke-model", "smoke-model"),
    "frogbot": ("smoke-model", "smoke-model"),
    "helicone": ("smoke-model", "smoke-model"),
    "io-net": ("smoke-model", "smoke-model"),
    "llmgateway": ("smoke-model", "smoke-model"),
    "ollama-cloud": ("smoke-model", "smoke-model"),
    "zenmux": ("smoke-model", "smoke-model"),
}[sys.argv[2]]
assert models.get(expected[0]) == expected[1], models
if sys.argv[2] == "meta":
    assert {"muse-wonder-1.0", "muse-spark-1.3"} <= models.keys(), models
    assert not {"muse-image-1.0", "muse-voice-transcribe-1.0", "sam-3.1"} & models.keys(), models
if sys.argv[2] == "gemini":
    assert "embed-fixture" not in models
PY
	if [[ "$provider" == meta ]]; then
		model_api_endpoint="http://127.0.0.1:$(cat "$work_dir/provider.port")/v1"
		expect_status 200 -X POST -H 'content-type: application/json' \
			-d "{\"provider\":\"meta\",\"base_url\":\"$model_api_endpoint\",\"api_key\":\"veasel-meta-key\"}" \
			"$api/v1/config/models"
		python3 - "$work_dir/response" <<'PY'
import json
import sys

models = {model["id"] for model in json.load(open(sys.argv[1], encoding="utf-8"))["models"]}
assert {"muse-wonder-1.0", "muse-spark-1.3"} <= models, models
assert not {"muse-image-1.0", "muse-voice-transcribe-1.0", "sam-3.1"} & models, models
PY
		for error_case in \
			'401 invalid-fixture-key Provider rejected the API key' \
			'403 veasel-meta-forbidden-key Provider denied model-list access' \
			'404 veasel-meta-missing-catalog-key enter a model ID manually' \
			'429 veasel-meta-rate-limited-key rate-limited model discovery'; do
			read -r upstream_status fixture_key expected_message <<<"$error_case"
			expect_status 502 -X POST -H 'content-type: application/json' \
				-d "{\"provider\":\"meta\",\"base_url\":\"$model_api_endpoint\",\"api_key\":\"$fixture_key\"}" \
				"$api/v1/config/models"
			grep -Fq "HTTP $upstream_status" "$work_dir/response" \
				|| fail "Meta HTTP $upstream_status failure lost the upstream status"
			grep -Fq "$expected_message" "$work_dir/response" \
				|| fail "Meta HTTP $upstream_status failure did not show actionable model discovery guidance"
			! grep -Fq "$fixture_key" "$work_dir/response" \
				|| fail "model catalog HTTP $upstream_status error echoed the submitted API key"
		done
		curl -fsS "$api/v1/config/model" >"$work_dir/model-settings-after-discovery"
		python3 - "$work_dir/model-settings-after-discovery" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
assert settings["profiles"] == {}, settings
assert "veasel-meta-key" not in json.dumps(settings)
PY
	fi
	expect_status 200 -H 'content-type: application/json' \
		-d '{"messages":[{"role":"system","content":"Be concise"},{"role":"user","content":"Say hello"}]}' \
		"$api/v1/chat/completions"
	grep -Fq '"content":"Provider fixture reply"' "$work_dir/response" || fail "$provider response did not reach the API client"
	if [[ "$provider" == meta ]]; then
		grep -Fq '"model":"muse-wonder-1.0"' "$work_dir/response" \
			|| fail 'Meta response did not preserve the selected Muse model ID'
	fi
	if [[ "$provider" == openai-responses ]]; then
		grep -Fq '"model":"gpt-5.1-codex"' "$work_dir/response" \
			|| fail 'OpenAI Responses did not preserve the selected Codex model ID'
	fi
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
		printf 'Smoke: exporting an opt-in ATIF trajectory from the live V runtime\n'
		env VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
		"$work_dir/veasel" run --prompt 'Inspect workspace' --workspace "$work_dir/workspace" \
			--trace-file "$work_dir/headless-trajectory.json" --json \
			>"$work_dir/headless-trace-result" 2>"$work_dir/headless-trace.log" \
			|| fail 'headless trace task command failed'
		if [[ -n "${VEASEL_SMOKE_TRACE_ARTIFACT:-}" ]]; then
			cp "$work_dir/headless-trajectory.json" "$VEASEL_SMOKE_TRACE_ARTIFACT"
		fi
		python3 - "$work_dir/headless-trace-result" "$work_dir/headless-trajectory.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
trajectory = json.load(open(sys.argv[2], encoding="utf-8"))
assert result["status"] == "completed", result
assert result["trace_file"] == sys.argv[2], result
assert trajectory["schema_version"] == "ATIF-v1.8", trajectory
assert trajectory["session_id"] == result["session_id"], trajectory
assert trajectory["agent"]["name"] == "Veasel Code", trajectory
assert trajectory["agent"]["model_name"] == "smoke-model", trajectory
assert [step["source"] for step in trajectory["steps"]] == ["system", "user", "agent", "agent"], trajectory
assert "You are Veasel Code" in trajectory["steps"][0]["message"], trajectory
user_prompt = trajectory["steps"][1]["message"].split("\n\n<veasel-repository-map-focus", 1)[0]
assert user_prompt == "Inspect workspace", trajectory
tool_step = trajectory["steps"][2]
assert tool_step["tool_calls"][0]["function_name"] == "workspace_search", tool_step
assert tool_step["observation"]["results"][0]["source_call_id"] == tool_step["tool_calls"][0]["tool_call_id"], tool_step
assert "workspace-search-sentinel" in tool_step["observation"]["results"][0]["content"], tool_step
assert trajectory["steps"][3]["message"] == "Found workspace-search-sentinel", trajectory
assert trajectory["extra"]["token_usage"] == "reported", trajectory
assert trajectory["extra"]["cost"] == "unavailable", trajectory
assert trajectory["final_metrics"] == {"total_prompt_tokens": 24, "total_completion_tokens": 12}, trajectory
PY
		printf 'Smoke: autonomous execution is rejected unless the server opts in\n'
		if env VEASEL_PORT="$port" VEASEL_DATA_DIR="$work_dir/data" \
			"$work_dir/veasel" run --autonomous --prompt 'Autonomous workspace edit' \
			--workspace "$work_dir/workspace" --json >"$work_dir/autonomous-denied.json" 2>"$work_dir/autonomous-denied.log"; then
			fail 'headless autonomous execution unexpectedly used a server without the opt-in'
		fi
		python3 - "$work_dir/autonomous-denied.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["status"] == "failed", result
assert "Sandbox-auto / autonomous tool execution is disabled" in result["error"], result
assert "VEASEL_ALLOW_AUTONOMOUS_EXECUTION=1" in result["error"], result
PY
		printf 'Smoke: applying a patch and running a shell command in the explicitly opted-in fixture server\n'
		autonomous_port="$(free_port)"
		autonomous_api="http://127.0.0.1:${autonomous_port}"
		env VEASEL_ALLOW_AUTONOMOUS_EXECUTION=1 VEASEL_PORT="$autonomous_port" \
			VEASEL_DATA_DIR="$work_dir/autonomous-data" VEASEL_PLUGIN_DIR="$work_dir/autonomous-plugins" \
			VEASEL_MODEL_PROVIDER=openai-compatible VEASEL_MODEL=smoke-model \
			VEASEL_MODEL_API_KEY=veasel-openai-key \
			VEASEL_MODEL_BASE_URL="http://127.0.0.1:$(cat "$work_dir/provider.port")/v1" \
			"$work_dir/veasel" serve >"$work_dir/autonomous-server.log" 2>&1 &
		autonomous_server_pid=$!
		for ((attempt = 0; attempt < 80; attempt++)); do
			if command curl --connect-timeout 2 --max-time 2 -fsS \
				"$autonomous_api/v1/health" >/dev/null 2>&1; then
				break
			fi
			sleep 0.1
		done
		command curl --connect-timeout 2 --max-time 2 -fsS "$autonomous_api/v1/health" \
			>/dev/null || fail 'autonomous fixture server did not become ready'
		env VEASEL_PORT="$autonomous_port" VEASEL_DATA_DIR="$work_dir/autonomous-data" \
			"$work_dir/veasel" run --autonomous --prompt 'Autonomous workspace edit' \
			--workspace "$work_dir/workspace" --trace-file "$work_dir/autonomous-edit.json" --json \
			>"$work_dir/autonomous-edit-result.json" 2>"$work_dir/autonomous-edit.log" \
			|| fail 'autonomous workspace edit failed'
		grep -Fq 'fn greet(name string)' "$work_dir/workspace/src/main.v" \
			|| fail 'autonomous workspace edit did not update the fixture'
		grep -Fq 'Applied by explicit autonomous benchmark policy' "$work_dir/autonomous-edit.json" \
			|| fail 'autonomous ATIF trace omitted the edit result'
		env VEASEL_PORT="$autonomous_port" VEASEL_DATA_DIR="$work_dir/autonomous-data" \
			"$work_dir/veasel" run --autonomous --prompt 'Autonomous shell' \
			--workspace "$work_dir/workspace" --trace-file "$work_dir/autonomous-shell.json" \
			--json >"$work_dir/autonomous-shell-result.json" \
			2>"$work_dir/autonomous-shell.log" || fail 'autonomous shell execution failed'
		grep -Fq 'Autonomous shell completed.' "$work_dir/autonomous-shell-result.json" \
			|| fail 'autonomous shell completion was not returned to the model'
		grep -Fq 'autonomous-shell-ok' "$work_dir/autonomous-shell.json" \
			|| fail 'autonomous shell output was not captured in the trace'
		! grep -Fq 'veasel-openai-key' "$work_dir/autonomous-shell.json" \
			|| fail 'provider credentials leaked into the autonomous shell result'
		cat >"$work_dir/workspace/src/main.v" <<'EOF'
module fixture

// workspace-search-sentinel
EOF
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
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/hold-slow-response" >/dev/null \
			|| fail 'slow provider fixture could not be held for cancellation'
		operation_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
		cancel_prompt="Wait for cancellation $operation_id"
		curl -sS -o "$work_dir/cancelled-turn-response" -w '%{http_code}' \
			-X POST -H 'content-type: application/json' -H "x-veasel-operation-id: $operation_id" \
			-d "{\"content\":\"$cancel_prompt\"}" \
			"$api/v1/sessions/$session_id/messages" >"$work_dir/cancelled-turn-status" &
		turn_pid=$!
		for ((attempt = 0; attempt < 200; attempt++)); do
			grep -Fq "SLOW_PROVIDER_REQUEST_STARTED:$cancel_prompt" "$work_dir/provider.log" && break
			sleep 0.05
		done
		grep -Fq "SLOW_PROVIDER_REQUEST_STARTED:$cancel_prompt" "$work_dir/provider.log" || fail 'slow provider cancellation request did not reach the provider'
		cancel_status=""
		for ((attempt = 0; attempt < 10; attempt++)); do
			cancel_status="$(curl -sS -o "$work_dir/cancel-response" -w '%{http_code}' --max-time 1 \
				-X POST "$api/v1/sessions/$session_id/operations/$operation_id/cancel" 2>/dev/null)" || cancel_status=""
			[[ "$cancel_status" == 202 || "$cancel_status" == 404 ]] && break
		done
		[[ "$cancel_status" == 202 ]] || fail "cancellation endpoint returned ${cancel_status:-no response}, expected 202 for an active provider request"
		wait "$turn_pid"
		cancelled_turn_status="$(cat "$work_dir/cancelled-turn-status")"
		[[ "$cancelled_turn_status" == 409 ]] || fail "cancelled provider request returned HTTP ${cancelled_turn_status:-no response}, expected 409 ($(cat "$work_dir/cancelled-turn-response"))"
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/release-slow-response" >/dev/null || fail 'slow provider fixture could not be released'
		printf 'Smoke: provider cancellation passed\n'
		printf 'Smoke: checking partial ATIF trajectory for a cancelled async turn\n'
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/hold-slow-response" >/dev/null \
			|| fail 'slow provider fixture could not be held for partial trace'
		partial_operation_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
		partial_prompt="Wait for cancellation $partial_operation_id"
		expect_status 202 -X POST -H 'content-type: application/json' -H 'Prefer: respond-async' \
			-H "x-veasel-operation-id: $partial_operation_id" \
			-d "{\"content\":\"$partial_prompt\",\"collect_trace\":true}" \
			"$api/v1/sessions/$session_id/messages"
		for ((attempt = 0; attempt < 200; attempt++)); do
			grep -Fq "SLOW_PROVIDER_REQUEST_STARTED:$partial_prompt" "$work_dir/provider.log" && break
			sleep 0.05
		done
		grep -Fq "SLOW_PROVIDER_REQUEST_STARTED:$partial_prompt" "$work_dir/provider.log" \
			|| fail 'partial trace provider request did not reach the provider'
		expect_status 202 -X POST "$api/v1/sessions/$session_id/operations/$partial_operation_id/cancel"
		partial_status=""
		for ((attempt = 0; attempt < 200; attempt++)); do
			curl -fsS "$api/v1/sessions/$session_id/operations/$partial_operation_id" >"$work_dir/partial-operation" 2>/dev/null || true
			partial_status="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["status"])' "$work_dir/partial-operation" 2>/dev/null || true)"
			[[ "$partial_status" == cancelled || "$partial_status" == failed ]] && break
			sleep 0.05
		done
		[[ "$partial_status" == cancelled ]] || fail "partial trace operation ended as ${partial_status:-unknown}, expected cancelled"
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/release-slow-response" >/dev/null \
			|| fail 'slow provider fixture could not be released after partial trace'
		curl -fsS "$api/v1/sessions/$session_id/operations/$partial_operation_id/result" >"$work_dir/cancelled-partial-trace" \
			|| fail 'cancelled turn did not expose its partial ATIF trajectory'
		python3 - "$work_dir/cancelled-partial-trace" "$partial_prompt" <<'PY' || fail 'cancelled partial ATIF trajectory was invalid'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["status"] == "cancelled", result
trajectory = json.loads(result["trajectory"])
assert trajectory["schema_version"] == "ATIF-v1.8", trajectory
assert trajectory["extra"]["outcome"] == "cancelled", trajectory
assert trajectory["extra"]["token_usage"] == "unavailable", trajectory
messages = [step["message"] for step in trajectory["steps"]]
assert sys.argv[2] in messages, messages
PY
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
providers = {provider["id"]: provider for provider in settings["providers"]}
assert len(providers) == 210
assert providers["ollama"]["requires_api_key"] is False
assert providers["atomic-chat"]["requires_api_key"] is False
assert providers["dashscope"]["environment_key"] == "DASHSCOPE_API_KEY"
assert providers["zai"]["protocol"] == "openai-compatible"
assert providers["302-ai"]["environment_key"] == "302AI_API_KEY"
assert providers["gmi-cloud"]["environment_key"] == "GMI_API_KEY"
assert providers["minimax"]["environment_key"] == "MINIMAX_API_KEY"
assert providers["scaleway"]["environment_key"] == "SCW_SECRET_KEY"
assert providers["baseten"]["environment_key"] == "BASETEN_API_KEY"
assert providers["cortecs"]["environment_key"] == "CORTECS_API_KEY"
assert providers["agentrouter"]["environment_key"] == "AGENTROUTER_API_KEY"
assert providers["aimlapi"]["environment_key"] == "AIMLAPI_API_KEY"
assert providers["bailing"]["environment_key"] == "BAILING_API_TOKEN"
assert providers["digitalocean"]["environment_key"] == "DIGITALOCEAN_ACCESS_TOKEN"
assert providers["frogbot"]["environment_key"] == "FROGBOT_API_KEY"
assert providers["helicone"]["environment_key"] == "HELICONE_API_KEY"
assert providers["io-net"]["environment_key"] == "IOINTELLIGENCE_API_KEY"
assert providers["llmgateway"]["environment_key"] == "LLMGATEWAY_API_KEY"
assert providers["ollama-cloud"]["environment_key"] == "OLLAMA_API_KEY"
assert providers["zenmux"]["environment_key"] == "ZENMUX_API_KEY"
assert providers["poe"]["documentation_url"] == "https://creator.poe.com/docs/external-applications/openai-compatible-api"
assert providers["deepseek"]["protocol"] == "openai-compatible"
assert providers["meta"]["protocol"] == "openai-responses"
assert providers["openai-responses"]["protocol"] == "openai-responses"
assert providers["meta"]["environment_key"] == "MODEL_API_KEY"
assert providers["anthropic"]["protocol"] == "anthropic"
profile = settings["profiles"]["openai-compatible"]
assert profile["model"] == "settings-smoke-model"
assert profile["api_key_saved"] is True
assert "api_key" not in profile
assert "smoke-only-model-key" not in json.dumps(settings)
PY
grep -Fq 'smoke-only-model-key' "$work_dir/data/model-settings.json" || fail 'model key was lost after server restart'
! grep -Fq 'smoke-only-model-key' "$work_dir/server.log" || fail 'server logs exposed the model API key'

printf 'API and provider smoke passed\n'
