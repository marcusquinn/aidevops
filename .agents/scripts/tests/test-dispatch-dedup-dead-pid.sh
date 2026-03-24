#!/usr/bin/env bash
# Test: dispatch-dedup-helper.sh correctly handles dead PIDs (GH#5662)
#
# Verifies that is-duplicate does NOT report DUPLICATE when the matched PID
# is no longer running. Dead PIDs from previous sessions should not block
# new dispatch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)

	# Create fake pgrep and ps that simulate a dead PID scenario.
	# pgrep returns a PID, but kill -0 on that PID fails (process is dead).
	mkdir -p "${TEST_ROOT}/bin"

	# Use a PID that is guaranteed to not exist: find a dead PID
	# by spawning and immediately killing a subprocess.
	local dead_pid
	bash -c 'exit 0' &
	dead_pid=$!
	wait "$dead_pid" 2>/dev/null || true

	# Verify the PID is actually dead
	if kill -0 "$dead_pid" 2>/dev/null; then
		# Extremely unlikely — try a high PID that almost certainly doesn't exist
		dead_pid=4194300
	fi

	export TEST_DEAD_PID="$dead_pid"

	# Create a fake pgrep that returns our dead PID
	cat >"${TEST_ROOT}/bin/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
# Fake pgrep: always returns the dead PID as if a worker is running
printf '%s\n' "$TEST_DEAD_PID"
exit 0
PGREP_EOF
	chmod +x "${TEST_ROOT}/bin/pgrep"

	# Create a fake ps that returns a command line for the dead PID
	# (simulating stale process table entry or PID recycling)
	cat >"${TEST_ROOT}/bin/ps" <<'PS_EOF'
#!/usr/bin/env bash
# Fake ps: returns a worker-like command line for any PID query
# Parse args to find the PID being queried
for arg in "$@"; do
	if [[ "$arg" =~ ^[0-9]+$ ]]; then
		printf 'claude run --prompt /full-loop Implement issue #649 -- Fix auth bug\n'
		exit 0
	fi
done
exit 1
PS_EOF
	chmod +x "${TEST_ROOT}/bin/ps"

	# Prepend our fake binaries to PATH
	export PATH="${TEST_ROOT}/bin:${PATH}"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# Test: is-duplicate returns 1 (safe to dispatch) when the matched PID is dead.
# This is the core fix for GH#5662.
#######################################
test_dead_pid_not_reported_as_duplicate() {
	# The fake pgrep returns a dead PID, fake ps returns a matching command line.
	# But kill -0 on the dead PID should fail, so is-duplicate should return 1.
	local output=""
	local exit_code=0
	output=$("$HELPER_SCRIPT" is-duplicate "Issue #649: Fix auth bug" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "dead PID not reported as duplicate (GH#5662)" 0
	else
		print_result "dead PID not reported as duplicate (GH#5662)" 1 \
			"Expected exit 1 (safe to dispatch) but got exit ${exit_code}. Output: ${output}"
	fi
	return 0
}

#######################################
# Test: list-running-keys returns empty when all PIDs are dead.
#######################################
test_list_running_keys_skips_dead_pids() {
	local output=""
	output=$("$HELPER_SCRIPT" list-running-keys 2>&1) || true

	if [[ -z "$output" ]]; then
		print_result "list-running-keys skips dead PIDs" 0
	else
		print_result "list-running-keys skips dead PIDs" 1 \
			"Expected empty output but got: ${output}"
	fi
	return 0
}

#######################################
# Test: extract-keys still works correctly (regression check).
#######################################
test_extract_keys_regression() {
	local output=""
	output=$("$HELPER_SCRIPT" extract-keys "Issue #649: t1337 Fix auth bug" 2>&1) || true

	local has_issue=false
	local has_task=false
	if printf '%s' "$output" | grep -q 'issue-649'; then
		has_issue=true
	fi
	if printf '%s' "$output" | grep -q 'task-t1337'; then
		has_task=true
	fi

	if [[ "$has_issue" == "true" && "$has_task" == "true" ]]; then
		print_result "extract-keys regression (issue + task)" 0
	else
		print_result "extract-keys regression (issue + task)" 1 \
			"Expected issue-649 and task-t1337 in output: ${output}"
	fi
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_dead_pid_not_reported_as_duplicate
	test_list_running_keys_skips_dead_pids
	test_extract_keys_regression

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
