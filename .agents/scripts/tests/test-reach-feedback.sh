#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-feedback.sh - Local tests for reach performance logs and miner dry-runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../reach-helper.sh"

PASS=0
FAIL=0

assert_contains() {
	local output="$1"
	local expected="$2"
	local description="$3"

	if grep -Fq -- "$expected" <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Expected output to contain: %s\n' "$expected"
		printf '    Output: %s\n' "$output"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local description="$3"

	if grep -Fq -- "$unexpected" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Unexpected output: %s\n' "$unexpected"
		printf '    Output: %s\n' "$output"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_json_valid() {
	local output="$1"
	local description="$2"

	if python3 -m json.tool >/dev/null 2>&1 <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Invalid JSON: %s\n' "$output"
	fi
	return 0
}

json_value() {
	local json_text="$1"
	local field_name="$2"
	python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$field_name" <<<"$json_text"
	return $?
}

cleanup() {
	local temp_dir="$1"
	if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
		rm -rf "$temp_dir"
	fi
	return 0
}

printf '=== Reach Feedback Tests ===\n\n'

temp_dir="$(mktemp -d)"
trap 'cleanup "$temp_dir"' EXIT
export AIDEVOPS_REACH_PERFORMANCE_LOG="${temp_dir}/reach-capture.jsonl"
export AIDEVOPS_SESSION_ID="reach-feedback-test-session-a"

fixture="${temp_dir}/fixture.html"
cat >"$fixture" <<'HTML'
<!doctype html><html><body><h1>Feedback fixture</h1></body></html>
HTML

pushd "$temp_dir" >/dev/null

capture_output="$($HELPER capture --input "$fixture" --dest inbox --method file --format json)"
assert_json_valid "$capture_output" "capture emits valid JSON"
if [[ -s "$AIDEVOPS_REACH_PERFORMANCE_LOG" ]]; then
	PASS=$((PASS + 1))
	printf '  PASS: capture appends performance JSONL\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: capture appends performance JSONL\n'
fi

log_text="$(<"$AIDEVOPS_REACH_PERFORMANCE_LOG")"
assert_contains "$log_text" '"backend"' "performance log records backend"
assert_contains "$log_text" '"profile_class"' "performance log records profile class"
assert_contains "$log_text" '"proxy_class"' "performance log records proxy class"
assert_contains "$log_text" '"latency_ms"' "performance log records latency"
assert_contains "$log_text" '"token_estimate"' "performance log records token estimate"
assert_not_contains "$log_text" "$temp_dir" "performance log omits private temp path"

now_iso="$(python3 - <<'PY'
import datetime
print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'))
PY
)"
for session_id in session-a session-b session-c; do
	python3 - "$AIDEVOPS_REACH_PERFORMANCE_LOG" "$now_iso" "$session_id" <<'PY'
import json
import sys

path, ts, session_id = sys.argv[1:]
record = {
    "schema_version": 1,
    "timestamp": ts,
    "session_ref": session_id,
    "target_key": "url:abc123",
    "target_hash": "abc123",
    "operation": "capture",
    "backend": "fetch",
    "agency_level": 1,
    "headed": False,
    "mode": "static",
    "profile_class": "none",
    "proxy_class": "none",
    "offload": "local",
    "latency_ms": 6500,
    "discovery_steps": 6,
    "token_estimate": 9000,
    "bytes_in": 12,
    "bytes_out": 0,
    "status": "failure",
    "failure_class": "network_timeout",
    "temporary": True,
    "next_best_action": "retry once with backoff",
}
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
done

mine_output="$($HELPER feedback mine --window 7d --format json)"
assert_json_valid "$mine_output" "feedback miner emits valid JSON"
assert_contains "$mine_output" '"repeated temporary failures"' "miner reports repeated temporary failures"
assert_contains "$mine_output" '"high token estimate"' "miner reports high token estimate"
assert_not_contains "$mine_output" "$temp_dir" "miner output omits private temp path"

issue_output="$($HELPER feedback issue --dry-run --format markdown)"
assert_contains "$issue_output" "## Files to Modify" "dry-run issue includes worker-ready files section"
assert_contains "$issue_output" "## Verification" "dry-run issue includes verification section"
assert_contains "$issue_output" "Privacy:" "dry-run issue includes privacy guard"
assert_not_contains "$issue_output" "$temp_dir" "dry-run issue omits private temp path"

popd >/dev/null

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
