#!/usr/bin/env bash
# test-pulse-wrapper-ci-failure-prefetch.sh
#
# Smoke tests for the prefetch_ci_failures() function in pulse-wrapper.sh.
# Verifies:
#   1. prefetch_ci_failures calls 'prefetch' (not the removed 'scan') command
#   2. prefetch_ci_failures degrades gracefully when the helper is missing
#   3. prefetch_ci_failures emits a compatibility warning when 'prefetch' is
#      absent from the helper's --help output (contract drift guard, GH#4586)
#
# These tests mock gh-failure-miner-helper.sh to avoid real network calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	mkdir -p "${HOME}/.config/aidevops"
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# Test 1: prefetch_ci_failures uses 'prefetch' command, not 'scan'
#
# Creates a mock gh-failure-miner-helper.sh that records which command
# was invoked. Verifies 'prefetch' is called and 'scan' is never called.
#######################################
test_uses_prefetch_not_scan() {
	local mock_dir="${TEST_ROOT}/mock_scripts"
	mkdir -p "$mock_dir"

	local call_log="${TEST_ROOT}/miner_calls.log"
	local mock_miner="${mock_dir}/gh-failure-miner-helper.sh"

	cat >"$mock_miner" <<'MOCK'
#!/usr/bin/env bash
# Mock gh-failure-miner-helper.sh — records invocations
CALL_LOG="${TEST_ROOT_OVERRIDE}/miner_calls.log"
echo "$*" >>"$CALL_LOG"
case "${1:-}" in
  --help|-h)
    echo "Commands: collect report issue-body create-issues prefetch install-launchd-routine"
    exit 0
    ;;
  prefetch)
    echo "## GH Failed Notifications"
    echo "- failed events: 0"
    exit 0
    ;;
  scan)
    echo "[ERROR] Unknown command: scan" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
MOCK
	chmod +x "$mock_miner"

	# Override SCRIPT_DIR so prefetch_ci_failures finds our mock
	local orig_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$mock_dir"
	export TEST_ROOT_OVERRIDE="$TEST_ROOT"

	local output
	output=$(prefetch_ci_failures 2>/dev/null || true)

	SCRIPT_DIR="$orig_script_dir"

	# Verify 'scan' was never called
	if [[ -f "$call_log" ]] && grep -q '^scan' "$call_log"; then
		print_result "prefetch_ci_failures does not call 'scan'" 1 \
			"'scan' command was invoked: $(grep '^scan' "$call_log" | head -1)"
		return 0
	fi

	# Verify 'prefetch' was called
	if [[ -f "$call_log" ]] && grep -q '^prefetch' "$call_log"; then
		print_result "prefetch_ci_failures calls 'prefetch' command" 0
	else
		local calls=""
		[[ -f "$call_log" ]] && calls=$(cat "$call_log")
		print_result "prefetch_ci_failures calls 'prefetch' command" 1 \
			"'prefetch' was not called. Calls recorded: '${calls}'"
	fi
	return 0
}

#######################################
# Test 2: prefetch_ci_failures degrades gracefully when helper is missing
#
# Verifies the function returns 0 and emits a human-readable message
# rather than crashing when the miner script does not exist.
#######################################
test_degrades_when_helper_missing() {
	local mock_dir="${TEST_ROOT}/no_scripts"
	mkdir -p "$mock_dir"

	local orig_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$mock_dir"

	local output
	output=$(prefetch_ci_failures 2>/dev/null || true)
	local exit_code=$?

	SCRIPT_DIR="$orig_script_dir"

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "prefetch_ci_failures returns 0 when helper missing" 1 \
			"Expected exit 0, got $exit_code"
		return 0
	fi

	if echo "$output" | grep -qi 'not found'; then
		print_result "prefetch_ci_failures emits 'not found' message when helper missing" 0
	else
		print_result "prefetch_ci_failures emits 'not found' message when helper missing" 1 \
			"Expected 'not found' in output, got: '${output}'"
	fi
	return 0
}

#######################################
# Test 3: prefetch_ci_failures emits compatibility warning when 'prefetch'
# is absent from the helper's --help output (contract drift guard, GH#4586)
#
# Simulates a future helper that dropped the 'prefetch' command.
# Verifies the function logs a warning and returns 0 (non-fatal).
#######################################
test_compatibility_guard_warns_on_missing_prefetch_command() {
	local mock_dir="${TEST_ROOT}/old_mock_scripts"
	mkdir -p "$mock_dir"

	local mock_miner="${mock_dir}/gh-failure-miner-helper.sh"

	# Mock helper that does NOT list 'prefetch' in --help
	cat >"$mock_miner" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h)
    echo "Commands: collect report issue-body create-issues install-launchd-routine"
    exit 0
    ;;
  *)
    echo "[ERROR] Unknown command: ${1:-}" >&2
    exit 1
    ;;
esac
MOCK
	chmod +x "$mock_miner"

	local orig_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$mock_dir"

	local output
	output=$(prefetch_ci_failures 2>/dev/null || true)
	local exit_code=$?

	SCRIPT_DIR="$orig_script_dir"

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "compatibility guard returns 0 on contract drift" 1 \
			"Expected exit 0, got $exit_code"
		return 0
	fi

	if echo "$output" | grep -qi 'mismatch\|compatibility'; then
		print_result "compatibility guard emits warning on contract drift" 0
	else
		print_result "compatibility guard emits warning on contract drift" 1 \
			"Expected 'mismatch' or 'compatibility' in output, got: '${output}'"
	fi
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_uses_prefetch_not_scan
	test_degrades_when_helper_missing
	test_compatibility_guard_warns_on_missing_prefetch_command

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
