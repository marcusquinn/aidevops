#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../gh-checks-wait-helper.sh"
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

write_fixture() {
	local directory="$1"
	local number="$2"
	local content="$3"
	mkdir -p "$directory"
	printf '%s\n' "$content" >"${directory}/poll-${number}.json"
	return 0
}

run_fixture_wait() {
	local fixture_dir="$1"
	shift
	AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$fixture_dir" \
		AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 \
		AIDEVOPS_GH_CHECKS_TEST_HEAD=fixture-head \
		"$HELPER" wait 123 --repo example/repo --initial-interval 1 --max-interval 4 "$@"
	return $?
}

transition_dir="${TMPDIR_TEST}/transition"
write_fixture "$transition_dir" 1 '[{"name":"Complexity","workflow":"CI","state":"PENDING","bucket":"pending","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$transition_dir" 2 '[{"name":"Complexity","workflow":"CI","state":"PENDING","bucket":"pending","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$transition_dir" 3 '[{"name":"Complexity","workflow":"CI","state":"SUCCESS","bucket":"pass","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'

transition_output=$(run_fixture_wait "$transition_dir")
assert_contains "wait prints initial state once" "CI wait started: pass=1 pending=1" "$transition_output"
assert_contains "wait prints state transition" "+ Complexity: pending -> pass" "$transition_output"
assert_contains "wait prints terminal success" "PASS: required checks completed" "$transition_output"
pending_count=$(printf '%s\n' "$transition_output" | grep -c '^  Complexity: pending$' || true)
[[ "$pending_count" -eq 1 ]] && pass "unchanged snapshot is not replayed" || fail "unchanged snapshot is not replayed" "count ${pending_count}"

failure_dir="${TMPDIR_TEST}/failure"
write_fixture "$failure_dir" 1 '[{"name":"ShellCheck","workflow":"CI","state":"FAILURE","bucket":"fail","link":"https://example.invalid/failure"}]'
set +e
failure_output=$(run_fixture_wait "$failure_dir" 2>&1)
failure_rc=$?
set -e
[[ "$failure_rc" -eq 1 ]] && pass "terminal failure returns one" || fail "terminal failure returns one" "got ${failure_rc}"
assert_contains "terminal failure names failed check" "ShellCheck: fail" "$failure_output"
failure_link_count=$(printf '%s\n' "$failure_output" | grep -c 'https://example.invalid/failure' || true)
[[ "$failure_link_count" -eq 1 ]] && pass "failure link is emitted once" || fail "failure link is emitted once" "count ${failure_link_count}"

recovery_dir="${TMPDIR_TEST}/recovery"
write_fixture "$recovery_dir" 1 'not-json'
write_fixture "$recovery_dir" 2 '[{"name":"Recovered","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
recovery_output=$(run_fixture_wait "$recovery_dir" 2>&1)
assert_contains "API failure is visible" "state unavailable" "$recovery_output"
assert_contains "API recovery is visible" "API state recovered" "$recovery_output"
assert_contains "API recovery can reach success" "PASS: required checks completed" "$recovery_output"

timeout_dir="${TMPDIR_TEST}/timeout"
write_fixture "$timeout_dir" 1 '[{"name":"Slow","workflow":"CI","state":"PENDING","bucket":"pending","link":""}]'
set +e
timeout_output=$(run_fixture_wait "$timeout_dir" --timeout 0 2>&1)
timeout_rc=$?
set -e
[[ "$timeout_rc" -eq 8 ]] && pass "pending timeout preserves gh pending exit" || fail "pending timeout preserves gh pending exit" "got ${timeout_rc}"
assert_contains "pending timeout remains diagnostic" "TIMEOUT: required checks remain non-terminal" "$timeout_output"

heartbeat_dir="${TMPDIR_TEST}/heartbeat"
heartbeat_file="${TMPDIR_TEST}/heartbeat/state"
mkdir -p "$(dirname "$heartbeat_file")"
write_fixture "$heartbeat_dir" 1 '[{"name":"Immediate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE="$heartbeat_file" run_fixture_wait "$heartbeat_dir" >/dev/null
[[ -s "$heartbeat_file" ]] && pass "wait updates out-of-context runtime heartbeat" || fail "wait updates out-of-context runtime heartbeat"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
