#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
mkdir "$work_dir/workspace"
plugin_dir="$work_dir/plugins/review-package"
mkdir -p "$plugin_dir/skills/review"
mkdir -p "$work_dir/workspace/src" "$work_dir/outside"
cat >"$work_dir/workspace/README.md" <<'EOF'
Veasel workspace smoke fixture.
EOF
cat >"$work_dir/workspace/src/main.v" <<'EOF'
module fixture

// workspace-search-sentinel
EOF
cat >"$work_dir/outside/secret.txt" <<'EOF'
outside-root-secret
EOF
ln -s "$work_dir/outside" "$work_dir/workspace/outside-link"
cat >"$plugin_dir/plugin.json" <<'EOF'
{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"review-tools","version":"1.0.0","description":"Fixture plugin for API smoke tests."}
EOF
cat >"$plugin_dir/skills/review/SKILL.md" <<'EOF'
---
name: review
description: Review code changes carefully.
---

Fixture skill instructions for verifying session activation.
EOF
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
	if [[ -f "$work_dir/provider.log" ]]; then
		cat "$work_dir/provider.log" >&2
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
grep -Fq 'review-tools' "$work_dir/response" || fail 'skill enable response is missing the plugin name'
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
	kill "$server_pid"
	wait "$server_pid" 2>/dev/null || true
	server_pid=""
	start_server "$provider"
	curl -fsS "$api/v1/capabilities" >"$work_dir/configured-capabilities"
	grep -Fq 'chat.complete' "$work_dir/configured-capabilities" || fail "$provider chat capability is missing"
	grep -Fq 'chat.cancel' "$work_dir/configured-capabilities" || fail "$provider chat cancellation capability is missing"
	grep -Fq 'agent.tools.workspace_readonly' "$work_dir/configured-capabilities" || fail "$provider workspace tool capability is missing"
	expect_status 200 -H 'content-type: application/json' \
		-d '{"messages":[{"role":"system","content":"Be concise"},{"role":"user","content":"Say hello"}]}' \
		"$api/v1/chat/completions"
	grep -Fq '"content":"Provider fixture reply"' "$work_dir/response" || fail "$provider response did not reach the API client"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Continue this session"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq "\"provider\":\"$provider\"" "$work_dir/response" || fail "$provider session response reported the wrong provider"
	if [[ "$provider" == openai-compatible ]]; then
		operation_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
		curl -sS -o "$work_dir/cancelled-turn-response" -w '%{http_code}' \
			-X POST -H 'content-type: application/json' -H "x-veasel-operation-id: $operation_id" \
			-d '{"content":"Wait for cancellation"}' \
			"$api/v1/sessions/$session_id/messages" >"$work_dir/cancelled-turn-status" &
		turn_pid=$!
		for ((attempt = 0; attempt < 50; attempt++)); do
			grep -Fq 'SLOW_PROVIDER_REQUEST_STARTED' "$work_dir/provider.log" && break
			sleep 0.05
		done
		grep -Fq 'SLOW_PROVIDER_REQUEST_STARTED' "$work_dir/provider.log" || fail 'slow provider request did not start'
		expect_status 202 -X POST "$api/v1/sessions/$session_id/operations/$operation_id/cancel"
		wait "$turn_pid"
		cancelled_turn_status="$(cat "$work_dir/cancelled-turn-status")"
		[[ "$cancelled_turn_status" == 409 ]] || fail "cancelled provider request returned HTTP ${cancelled_turn_status:-no response}, expected 409 ($(cat "$work_dir/cancelled-turn-response"))"
		curl -fsS "http://127.0.0.1:$(cat "$work_dir/provider.port")/release-slow-response" >/dev/null || fail 'slow provider fixture could not be released'
	fi
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
	edit_path="src/$provider-edit.v"
	[[ ! -e "$work_dir/workspace/$edit_path" ]] || fail "$provider proposal wrote a file before approval"
	curl -fsS "$api/v1/sessions/$session_id/workspace/edits" >"$work_dir/provider-edits"
	grep -Fq "$edit_path" "$work_dir/provider-edits" || fail "$provider proposal was not persisted"
	edit_id="$(python3 -c 'import json, sys; path = sys.argv[1]; edits = json.load(open(sys.argv[2])); print(next((edit["id"] for edit in edits if edit["path"] == path), ""))' "$edit_path" "$work_dir/provider-edits")"
	[[ -n "$edit_id" ]] || fail "$provider proposal id is missing"
	expect_status 200 -X GET "$api/v1/sessions/$session_id/workspace/edits/$edit_id"
	grep -Fq '+fn main() {}' "$work_dir/response" || fail "$provider proposal diff is missing"
	expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/edits/$edit_id/approve"
	grep -Fq '"status":"applied"' "$work_dir/response" || fail "$provider proposal approval failed"
	grep -Fq 'fn main() {}' "$work_dir/workspace/$edit_path" || fail "$provider approved edit was not applied"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Propose shell command"}' \
		"$api/v1/sessions/$session_id/messages"
	grep -Fq 'Proposed a shell command for review.' "$work_dir/response" || fail "$provider shell command proposal did not reach the user"
	curl -fsS "$api/v1/sessions/$session_id/workspace/commands" >"$work_dir/provider-commands"
	command_id="$(python3 -c 'import json, sys; commands = json.load(open(sys.argv[1])); print(next((item["id"] for item in commands if item["command"] == "echo veasel-shell-approved"), ""))' "$work_dir/provider-commands")"
	[[ -n "$command_id" ]] || fail "$provider shell command proposal was not persisted"
	expect_status 409 -X POST "$api/v1/sessions/$session_id/workspace/commands/$command_id/approve"
	grep -Fq 'Inspect the exact command first' "$work_dir/response" || fail "$provider shell command ran without a recorded review"
	expect_status 200 "$api/v1/sessions/$session_id/workspace/commands/$command_id"
	grep -Fq 'echo veasel-shell-approved' "$work_dir/response" || fail "$provider command review omitted the exact command"
	expect_status 200 -X POST "$api/v1/sessions/$session_id/workspace/commands/$command_id/approve"
	grep -Fq '"status":"succeeded"' "$work_dir/response" || fail "$provider command approval did not finish successfully"
	grep -Fq 'veasel-shell-approved' "$work_dir/response" || fail "$provider command output was not captured"
	expect_status 200 -H 'content-type: application/json' -d '{"content":"Propose slow shell command"}' \
		"$api/v1/sessions/$session_id/messages"
	curl -fsS "$api/v1/sessions/$session_id/workspace/commands" >"$work_dir/provider-commands"
	command_id="$(python3 -c 'import json, sys; commands = json.load(open(sys.argv[1])); print(next((item["id"] for item in commands if item["timeout_seconds"] == 1), ""))' "$work_dir/provider-commands")"
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

printf 'API and provider smoke passed\n'
