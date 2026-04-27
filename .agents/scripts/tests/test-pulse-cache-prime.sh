#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for pulse-cache-prime.sh (t2992).
#
# The helper invokes pulse-batch-prefetch-helper.sh refresh from its own
# SCRIPT_DIR. Tests stage a temp scripts/ directory containing a copy of
# pulse-cache-prime.sh next to a mock pulse-batch-prefetch-helper.sh whose
# exit code we control via TEST_PRIME_HELPER_EXIT.
#
# Covers:
#   1. AIDEVOPS_SKIP_CACHE_PRIME=1 → exit 0, log records skip, no sentinel
#   2. Missing pulse-batch-prefetch-helper.sh → exit 1
#   3. Successful refresh → exit 0, sentinel touched, log records duration
#   4. Failed refresh → exit 1, log records FAILED

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SOURCE_HELPER="${SCRIPT_DIR}/../pulse-cache-prime.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

_print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "1" ]]; then
		printf '%b[PASS]%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%b[FAIL]%b %s\n' "$TEST_RED" "$TEST_RESET" "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		_print_result "$name" 1
	else
		_print_result "$name (expected='$expected' actual='$actual')" 0
	fi
	return 0
}

_setup() {
	TEST_ROOT=$(mktemp -d -t pulse-cache-prime-test.XXXXXX)
	mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/logs" "${TEST_ROOT}/cache"

	# Stage a copy of the helper under test.
	cp "$SOURCE_HELPER" "${TEST_ROOT}/scripts/pulse-cache-prime.sh"
	chmod +x "${TEST_ROOT}/scripts/pulse-cache-prime.sh"

	# Re-route HOME so the helper writes to TEST_ROOT-scoped paths.
	export HOME="$TEST_ROOT"

	# Mock pulse-batch-prefetch-helper.sh — exit code controlled by env.
	cat >"${TEST_ROOT}/scripts/pulse-batch-prefetch-helper.sh" <<'SH'
#!/usr/bin/env bash
echo "mock prefetch refresh: exit ${TEST_PRIME_HELPER_EXIT:-0}"
exit "${TEST_PRIME_HELPER_EXIT:-0}"
SH
	chmod +x "${TEST_ROOT}/scripts/pulse-batch-prefetch-helper.sh"

	# Default: log + cache directory paths inside TEST_ROOT (HOME re-routed).
	mkdir -p "${TEST_ROOT}/.aidevops/logs" "${TEST_ROOT}/.aidevops/cache"
	return 0
}

_teardown() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

# Test 1: AIDEVOPS_SKIP_CACHE_PRIME=1 short-circuits.
test_skip_env_var() {
	local rc=0
	AIDEVOPS_SKIP_CACHE_PRIME=1 "${TEST_ROOT}/scripts/pulse-cache-prime.sh" >/dev/null 2>&1 || rc=$?
	_assert_eq "skip env var → exit 0" "0" "$rc"

	# Sentinel must NOT exist.
	if [[ ! -f "${TEST_ROOT}/.aidevops/cache/pulse-cache-prime-last-run" ]]; then
		_print_result "skip env var → no sentinel" 1
	else
		_print_result "skip env var → no sentinel" 0
	fi

	# Log must contain the skip message.
	if grep -q "AIDEVOPS_SKIP_CACHE_PRIME=1" "${TEST_ROOT}/.aidevops/logs/pulse-cache-prime.log" 2>/dev/null; then
		_print_result "skip env var → log records skip" 1
	else
		_print_result "skip env var → log records skip" 0
	fi
	return 0
}

# Test 2: Missing pulse-batch-prefetch-helper.sh → exit 1.
test_missing_helper() {
	rm -f "${TEST_ROOT}/scripts/pulse-batch-prefetch-helper.sh"
	local rc=0
	"${TEST_ROOT}/scripts/pulse-cache-prime.sh" >/dev/null 2>&1 || rc=$?
	_assert_eq "missing helper → exit 1" "1" "$rc"
	return 0
}

# Test 3: Successful refresh → exit 0, sentinel touched, log records duration.
test_success() {
	# Re-stage helper (test 2 deleted it).
	cat >"${TEST_ROOT}/scripts/pulse-batch-prefetch-helper.sh" <<'SH'
#!/usr/bin/env bash
echo "mock prefetch refresh: exit ${TEST_PRIME_HELPER_EXIT:-0}"
exit "${TEST_PRIME_HELPER_EXIT:-0}"
SH
	chmod +x "${TEST_ROOT}/scripts/pulse-batch-prefetch-helper.sh"

	rm -f "${TEST_ROOT}/.aidevops/cache/pulse-cache-prime-last-run"

	local rc=0
	TEST_PRIME_HELPER_EXIT=0 "${TEST_ROOT}/scripts/pulse-cache-prime.sh" >/dev/null 2>&1 || rc=$?
	_assert_eq "success → exit 0" "0" "$rc"

	if [[ -f "${TEST_ROOT}/.aidevops/cache/pulse-cache-prime-last-run" ]]; then
		_print_result "success → sentinel touched" 1
	else
		_print_result "success → sentinel touched" 0
	fi

	if grep -q "Cache prime succeeded" "${TEST_ROOT}/.aidevops/logs/pulse-cache-prime.log" 2>/dev/null; then
		_print_result "success → log records 'succeeded'" 1
	else
		_print_result "success → log records 'succeeded'" 0
	fi
	return 0
}

# Test 4: Failed refresh → exit 1, log records FAILED, no sentinel update.
test_failure() {
	rm -f "${TEST_ROOT}/.aidevops/cache/pulse-cache-prime-last-run"

	local rc=0
	TEST_PRIME_HELPER_EXIT=1 "${TEST_ROOT}/scripts/pulse-cache-prime.sh" >/dev/null 2>&1 || rc=$?
	_assert_eq "failure → exit 1" "1" "$rc"

	if [[ ! -f "${TEST_ROOT}/.aidevops/cache/pulse-cache-prime-last-run" ]]; then
		_print_result "failure → no new sentinel" 1
	else
		_print_result "failure → no new sentinel" 0
	fi

	if grep -q "Cache prime FAILED" "${TEST_ROOT}/.aidevops/logs/pulse-cache-prime.log" 2>/dev/null; then
		_print_result "failure → log records FAILED" 1
	else
		_print_result "failure → log records FAILED" 0
	fi
	return 0
}

main() {
	_setup
	test_skip_env_var
	test_missing_helper
	test_success
	test_failure
	_teardown

	echo ""
	echo "Tests run: ${TESTS_RUN}"
	echo "Tests failed: ${TESTS_FAILED}"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%b[OK]%b All tests passed\n' "$TEST_GREEN" "$TEST_RESET"
		return 0
	fi
	printf '%b[FAIL]%b %d test(s) failed\n' "$TEST_RED" "$TEST_RESET" "$TESTS_FAILED"
	return 1
}

main "$@"
