#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../session-output-efficiency-helper.sh"
REVIEW_HELPER="${SCRIPT_DIR}/../session-review-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

assert_omits() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected ${needle}"
	fi
	return 0
}

normalized_fixture="${TMPDIR_TEST}/normalized.jsonl"
claude_fixture="${TMPDIR_TEST}/claude.jsonl"
opencode_db="${TMPDIR_TEST}/opencode.db"

python3 - "$normalized_fixture" "$claude_fixture" "$opencode_db" <<'PY'
import json
import sqlite3
import sys

normalized_path, claude_path, database_path = sys.argv[1:]
repeated = "unchanged status snapshot SECRET-MARKER " + ("x" * 100)
oversized = "large setup output " + ("y" * 9000)

with open(normalized_path, "w", encoding="utf-8") as handle:
    for _ in range(3):
        handle.write(json.dumps({"tool": "bash", "input": {"command": "poll"}, "output": repeated}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "poll"}, "output": "changed status"}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "setup"}, "output": oversized}) + "\n")

with open(claude_path, "w", encoding="utf-8") as handle:
    for call_id in ("call-1", "call-2"):
        handle.write(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": call_id, "name": "Bash", "input": {"command": "poll"}}
        ]}}) + "\n")
        handle.write(json.dumps({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": call_id, "content": repeated}
        ]}}) + "\n")

connection = sqlite3.connect(database_path)
connection.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
for index in range(2):
    part = {
        "type": "tool",
        "tool": "bash",
        "state": {"status": "completed", "input": {"command": "poll"}, "output": repeated},
    }
    connection.execute(
        "INSERT INTO part (id, session_id, time_created, data) VALUES (?, ?, ?, ?)",
        (f"part-{index}", "session-test", index, json.dumps(part)),
    )
connection.commit()
connection.close()
PY

text_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$normalized_fixture")
assert_contains "text reports one repeated group" "Repeated unchanged snapshots: 1 groups, 2 redundant results" "$text_output"
assert_contains "text reports oversized output" "Oversized tool results: 1" "$text_output"
assert_contains "text identifies aggregate repeat" "exact-repeat" "$text_output"
assert_omits "text omits raw output" "SECRET-MARKER" "$text_output"

json_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$normalized_fixture" --json)
if python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["schema"] == "aidevops.session-output-efficiency/v1"; assert report["stats"]["redundant_tool_results"] == 2; assert report["stats"]["oversized_tool_results"] == 1' <<<"$json_output"; then
	pass "JSON contract exposes aggregate metrics"
else
	fail "JSON contract exposes aggregate metrics"
fi

claude_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime claude-code --input "$claude_fixture")
assert_contains "Claude JSONL tool results are correlated" "Repeated unchanged snapshots: 1 groups, 1 redundant results" "$claude_output"

database_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session session-test)
assert_contains "OpenCode database tool parts are analysed" "Repeated unchanged snapshots: 1 groups, 1 redundant results" "$database_output"

review_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$REVIEW_HELPER" output-efficiency --input "$normalized_fixture" --json)
assert_contains "session review delegates output analysis" '"schema":"aidevops.session-output-efficiency/v1"' "$review_output"

set +e
invalid_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "${TMPDIR_TEST}/missing.jsonl" 2>&1)
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 2 ]] && pass "missing transcript returns usage error" || fail "missing transcript returns usage error" "got ${invalid_rc}"
assert_omits "missing transcript does not expose requested path" "$TMPDIR_TEST" "$invalid_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
