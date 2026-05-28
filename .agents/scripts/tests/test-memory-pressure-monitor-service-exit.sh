#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression checks for memory-pressure monitor one-shot service exit semantics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
MONITOR_SCRIPT="${REPO_ROOT}/.agents/scripts/memory-pressure-monitor.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

cleanup() {
	if [[ -n "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}
trap cleanup EXIT

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

setup_fake_ps() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/logs" "${TEST_ROOT}/home"
	cat >"${TEST_ROOT}/bin/ps" <<'FAKE_PS'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
if [[ "$args" == *"tty="* ]]; then
	exit 0
fi

case "${MEMPRESS_TEST_SCENARIO:-ok}" in
	ok)
		exit 0
		;;
	warning)
		printf '999991 1048576 /usr/bin/opencode\n'
		;;
	critical)
		printf '999992 2097152 /usr/bin/opencode\n'
		;;
	*)
		exit 2
		;;
esac
FAKE_PS
	chmod +x "${TEST_ROOT}/bin/ps"
	return 0
}

run_monitor_for_scenario() {
	local scenario="$1"
	local output_file="${TEST_ROOT}/${scenario}.out"
	local rc=0

	MEMPRESS_TEST_SCENARIO="$scenario" \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		MEMORY_LOG_DIR="${TEST_ROOT}/logs" \
		MEMORY_NOTIFY=false \
		AUTO_KILL_SHELLCHECK=false \
		PROCESS_RSS_WARN_MB=1024 \
		PROCESS_RSS_CRIT_MB=2048 \
		bash "$MONITOR_SCRIPT" >"$output_file" 2>&1 || rc=$?

	printf '%s' "$rc"
	return 0
}

assert_log_contains() {
	local test_name="$1"
	local needle="$2"
	local log_file="${TEST_ROOT}/logs/memory-pressure.log"

	if [[ -f "$log_file" ]] && grep -qF -- "$needle" "$log_file"; then
		print_result "$test_name" 0
		return 0
	fi

	print_result "$test_name" 1 "Missing log text: $needle"
	return 0
}

test_ok_service_exit_zero() {
	local rc
	rc=$(run_monitor_for_scenario ok)
	if [[ "$rc" -eq 0 ]]; then
		print_result "ok findings exit 0" 0
		return 0
	fi
	print_result "ok findings exit 0" 1 "rc=$rc"
	return 0
}

test_warning_service_exit_zero_and_logs() {
	local rc
	rc=$(run_monitor_for_scenario warning)
	if [[ "$rc" -eq 0 ]]; then
		print_result "warning-only findings exit 0 for service mode" 0
	else
		print_result "warning-only findings exit 0 for service mode" 1 "rc=$rc"
	fi
	assert_log_contains "warning-only finding is logged" "[WARNING] opencode using 1024 MB RSS"
	return 0
}

test_critical_service_exit_nonzero_and_logs() {
	local rc
	rc=$(run_monitor_for_scenario critical)
	if [[ "$rc" -eq 2 ]]; then
		print_result "critical findings remain non-zero" 0
	else
		print_result "critical findings remain non-zero" 1 "rc=$rc"
	fi
	assert_log_contains "critical finding is logged" "[CRITICAL] opencode using 2048 MB RSS"
	return 0
}

main() {
	if [[ ! -f "$MONITOR_SCRIPT" ]]; then
		printf '%bFAIL%b monitor script missing: %s\n' "$TEST_RED" "$TEST_RESET" "$MONITOR_SCRIPT"
		return 1
	fi

	setup_fake_ps
	test_ok_service_exit_zero
	test_warning_service_exit_zero_and_logs
	test_critical_service_exit_nonzero_and_logs

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
