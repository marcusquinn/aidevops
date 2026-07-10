#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../sandbox-exec-helper.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
SURVIVOR_PIDS=""

cleanup() {
	local cleanup_pid=""
	for cleanup_pid in $SURVIVOR_PIDS; do
		kill -KILL "$cleanup_pid" 2>/dev/null || true
	done
	rm -rf "$TEST_ROOT"
	return 0
}

record_result() {
	local test_name="$1"
	local test_status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$test_status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s: %s\n' "$test_name" "$detail" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

process_is_alive() {
	local process_pid="$1"
	local process_state=""
	if ! kill -0 "$process_pid" 2>/dev/null; then
		return 1
	fi
	process_state="$(ps -o stat= -p "$process_pid" 2>/dev/null | tr -d '[:space:]')" || return 1
	[[ "$process_state" != *Z* ]]
}

wait_for_pid_file() {
	local pid_file="$1"
	local attempts=0
	while [[ ! -s "$pid_file" && "$attempts" -lt 30 ]]; do
		sleep 0.1
		attempts=$((attempts + 1))
	done
	[[ -s "$pid_file" ]]
}

wait_for_process_exit() {
	local process_pid="$1"
	local attempts=0
	while process_is_alive "$process_pid" && [[ "$attempts" -lt 30 ]]; do
		sleep 0.1
		attempts=$((attempts + 1))
	done
	! process_is_alive "$process_pid"
}

write_fixture() {
	local fixture_path="$1"
	cat >"$fixture_path" <<'FIXTURE'
#!/usr/bin/env bash
pid_file="$1"
mode="$2"
setsid bash --norc --noprofile -c '
	printf "%s\n" "$$" >"$1"
	trap "" TERM
	while :; do sleep 1; done
' nested-session "$pid_file" &
if [[ "$mode" == "timeout" ]]; then
	wait
else
	sleep 1
fi
FIXTURE
	chmod +x "$fixture_path"
	return 0
}

test_timeout_cleanup() {
	local fixture_path="${TEST_ROOT}/nested-fixture.sh"
	local pid_file="${TEST_ROOT}/timeout.pid"
	local sandbox_status=0
	local nested_pid=""
	write_fixture "$fixture_path"
	set +e
	"$HELPER" run --timeout 2 -- "$fixture_path" "$pid_file" timeout >/dev/null 2>&1
	sandbox_status=$?
	set -e
	if ! wait_for_pid_file "$pid_file"; then
		record_result "timeout fixture records nested PID" 1 "PID file missing"
		return 0
	fi
	nested_pid="$(tr -d '[:space:]' <"$pid_file")"
	SURVIVOR_PIDS="${SURVIVOR_PIDS} ${nested_pid}"
	if [[ "$sandbox_status" -eq 124 ]] && wait_for_process_exit "$nested_pid"; then
		record_result "timeout removes nested process group" 0
	else
		record_result "timeout removes nested process group" 1 "status=${sandbox_status} pid=${nested_pid}"
	fi
	return 0
}

test_normal_exit_and_unrelated_process() {
	local fixture_path="${TEST_ROOT}/nested-fixture.sh"
	local pid_file="${TEST_ROOT}/normal.pid"
	local sandbox_status=0
	local nested_pid=""
	local unrelated_pid=""
	sleep 30 &
	unrelated_pid=$!
	SURVIVOR_PIDS="${SURVIVOR_PIDS} ${unrelated_pid}"
	set +e
	"$HELPER" run --timeout 5 -- "$fixture_path" "$pid_file" normal >/dev/null 2>&1
	sandbox_status=$?
	set -e
	if ! wait_for_pid_file "$pid_file"; then
		record_result "normal fixture records nested PID" 1 "PID file missing"
		return 0
	fi
	nested_pid="$(tr -d '[:space:]' <"$pid_file")"
	SURVIVOR_PIDS="${SURVIVOR_PIDS} ${nested_pid}"
	if [[ "$sandbox_status" -eq 0 ]] && wait_for_process_exit "$nested_pid"; then
		record_result "normal exit removes nested process group" 0
	else
		record_result "normal exit removes nested process group" 1 "status=${sandbox_status} pid=${nested_pid}"
	fi
	if process_is_alive "$unrelated_pid"; then
		record_result "cleanup leaves unrelated process alive" 0
	else
		record_result "cleanup leaves unrelated process alive" 1 "pid=${unrelated_pid} was signalled"
	fi
	return 0
}

test_start_token_mismatch() {
	local snapshot_file="${TEST_ROOT}/recycled.tsv"
	local candidate_pid=""
	local candidate_pgid=""
	sleep 30 &
	candidate_pid=$!
	SURVIVOR_PIDS="${SURVIVOR_PIDS} ${candidate_pid}"
	candidate_pgid="$(ps -o pgid= -p "$candidate_pid" | tr -d '[:space:]')"
	printf '%s\t%s\t%s\n' "$candidate_pid" "$candidate_pgid" "definitely-not-the-start-token" >"$snapshot_file"
	# shellcheck source=../sandbox-exec-helper.sh
	source "$HELPER"
	_sandbox_pgkill_cleanup "" "" "" "$snapshot_file"
	if process_is_alive "$candidate_pid"; then
		record_result "start-token mismatch prevents recycled PID signal" 0
	else
		record_result "start-token mismatch prevents recycled PID signal" 1 "pid=${candidate_pid} was signalled"
	fi
	return 0
}

main() {
	trap cleanup EXIT
	if ! command -v setsid >/dev/null 2>&1; then
		printf 'SKIP setsid is required for nested process-group fixture\n'
		return 0
	fi
	test_timeout_cleanup
	test_normal_exit_and_unrelated_process
	test_start_token_mismatch
	printf 'Tests run: %d\nFailures: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
