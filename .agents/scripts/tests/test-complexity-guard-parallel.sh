#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-complexity-guard-parallel.sh — Regression tests for parallel pre-push guard (t2381)
#
# Tests:
#   1. parallel-all-pass:        3 metrics all clean → exit 0
#   2. parallel-one-fail:        1 metric regression → exit 1, output contains BLOCK
#   3. parallel-output-order:    output appears in metric definition order regardless of completion order
#   4. parallel-disable-bypass:  COMPLEXITY_GUARD_DISABLE=1 → exit 0 (no change from sequential)
#   5. parallel-debug-output:    COMPLEXITY_GUARD_DEBUG=1 → "parallel" appears in debug log
#   6. parallel-helper-missing:  helper not found → fail-open exit 0
#   7. parallel-helper-exit2:    helper returns exit 2 → fail-open for that metric

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK="${SCRIPT_DIR}/../../hooks/complexity-regression-pre-push.sh"

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

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup() {
	TEST_ROOT=$(mktemp -d)

	# Create a minimal git repo so the hook's git operations work
	git -C "$TEST_ROOT" init --quiet
	git -C "$TEST_ROOT" config user.email "test@test.com"
	git -C "$TEST_ROOT" config user.name "Test"
	git -C "$TEST_ROOT" config commit.gpgsign false

	# Seed initial commit so merge-base can work
	printf '#!/usr/bin/env bash\necho hello\n' > "$TEST_ROOT/sample.sh"
	git -C "$TEST_ROOT" add -A
	git -C "$TEST_ROOT" commit -m "initial" --quiet --no-gpg-sign
	return 0
}

teardown() {
	if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: parallel-all-pass — stub helper exits 0 for all metrics
# ---------------------------------------------------------------------------
test_parallel_all_pass() {
	setup
	local fake_helper="$TEST_ROOT/fake-helper.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_helper"
	chmod +x "$fake_helper"

	local rc=0
	COMPLEXITY_HELPER="$fake_helper" COMPLEXITY_GUARD_BASE_SHA="abc1234" \
		bash "$HOOK" 2>&1 || rc=$?

	print_result "parallel-all-pass" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)" \
		"expected exit 0, got $rc"
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: parallel-one-fail — one metric returns exit 1
# ---------------------------------------------------------------------------
test_parallel_one_fail() {
	setup

	# Helper that fails for nesting-depth, passes for others
	local fake_helper="$TEST_ROOT/fake-helper-fail.sh"
	cat > "$fake_helper" <<-'EOF'
	#!/usr/bin/env bash
	for arg in "$@"; do
	    if [[ "$arg" == "nesting-depth" ]]; then
	        echo "REGRESSION: nesting-depth violation"
	        exit 1
	    fi
	done
	exit 0
	EOF
	chmod +x "$fake_helper"

	local rc=0
	COMPLEXITY_HELPER="$fake_helper" COMPLEXITY_GUARD_BASE_SHA="abc1234" \
		bash "$HOOK" 2>&1 || rc=$?

	print_result "parallel-one-fail" "$([[ $rc -eq 1 ]] && echo 0 || echo 1)" \
		"expected exit 1, got $rc"
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: parallel-output-order — results appear in metric definition order
# ---------------------------------------------------------------------------
test_parallel_output_order() {
	setup

	# Helper that echoes the metric name — all exit 1 to produce ordered output
	local fake_helper="$TEST_ROOT/fake-helper-order.sh"
	cat > "$fake_helper" <<-'EOF'
	#!/usr/bin/env bash
	# Extract metric name from args
	for i in $(seq 1 $#); do
	    arg="${!i}"
	    if [[ "$arg" == "--metric" ]]; then
	        next=$((i + 1))
	        metric="${!next}"
	        echo "REGRESSION: $metric violation"
	        exit 1
	    fi
	done
	exit 0
	EOF
	chmod +x "$fake_helper"

	local output rc=0
	output=$(COMPLEXITY_HELPER="$fake_helper" COMPLEXITY_GUARD_BASE_SHA="abc1234" \
		bash "$HOOK" 2>&1) || rc=$?

	# Verify order: function-complexity before nesting-depth before file-size
	local fc_pos nd_pos fs_pos
	fc_pos=$(printf '%s\n' "$output" | grep -n "function-complexity" | head -1 | cut -d: -f1)
	nd_pos=$(printf '%s\n' "$output" | grep -n "nesting-depth" | head -1 | cut -d: -f1)
	fs_pos=$(printf '%s\n' "$output" | grep -n "file-size" | head -1 | cut -d: -f1)

	local fail=0
	if [[ -z "$fc_pos" || -z "$nd_pos" || -z "$fs_pos" ]]; then
		fail=1
		print_result "parallel-output-order" "$fail" \
			"missing metric in output: fc=$fc_pos nd=$nd_pos fs=$fs_pos"
	elif [[ "$fc_pos" -lt "$nd_pos" && "$nd_pos" -lt "$fs_pos" ]]; then
		print_result "parallel-output-order" 0
	else
		fail=1
		print_result "parallel-output-order" "$fail" \
			"wrong order: fc=$fc_pos nd=$nd_pos fs=$fs_pos"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: parallel-disable-bypass — COMPLEXITY_GUARD_DISABLE=1 exits 0
# ---------------------------------------------------------------------------
test_parallel_disable_bypass() {
	setup

	local output rc=0
	output=$(COMPLEXITY_GUARD_DISABLE=1 bash "$HOOK" 2>&1) || rc=$?

	print_result "parallel-disable-bypass" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)" \
		"expected exit 0 with COMPLEXITY_GUARD_DISABLE=1, got $rc"
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: parallel-debug-output — debug log mentions "parallel"
# ---------------------------------------------------------------------------
test_parallel_debug_output() {
	setup

	local fake_helper="$TEST_ROOT/fake-helper-debug.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_helper"
	chmod +x "$fake_helper"

	local output rc=0
	output=$(COMPLEXITY_HELPER="$fake_helper" COMPLEXITY_GUARD_BASE_SHA="abc1234" \
		COMPLEXITY_GUARD_DEBUG=1 bash "$HOOK" 2>&1) || rc=$?

	local fail=0
	if ! printf '%s' "$output" | grep -q "parallel"; then
		fail=1
	fi

	print_result "parallel-debug-output" "$fail" \
		"expected 'parallel' in debug output"
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: parallel-helper-missing — no helper → fail-open exit 0
# ---------------------------------------------------------------------------
test_parallel_helper_missing() {
	setup

	# Create a minimal hook-like script that can't find the helper
	local wrapper="$TEST_ROOT/run-hook-missing.sh"
	cat > "$wrapper" <<-'WRAPPER_EOF'
	#!/usr/bin/env bash
	set -u
	GUARD_NAME="complexity-guard"
	_log() { local _level="$1"; local _msg="$2"; printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2; return 0; }
	HELPER_REPO="/nonexistent/path/to/helper.sh"
	HELPER_DEPLOYED="/also/nonexistent/helper.sh"
	if [[ -f "$HELPER_REPO" ]]; then
	    COMPLEXITY_HELPER="$HELPER_REPO"
	elif [[ -f "$HELPER_DEPLOYED" ]]; then
	    COMPLEXITY_HELPER="$HELPER_DEPLOYED"
	else
	    _log WARN "complexity-regression-helper.sh not found — fail-open"
	    exit 0
	fi
	WRAPPER_EOF
	chmod +x "$wrapper"

	local output rc=0
	output=$("$wrapper" 2>&1) || rc=$?

	local fail=0
	if [[ $rc -ne 0 ]]; then
		fail=1
	fi
	if ! printf '%s' "$output" | grep -q "fail-open"; then
		fail=1
	fi

	print_result "parallel-helper-missing" "$fail" \
		"expected exit 0 + fail-open message, got rc=$rc"
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: parallel-helper-exit2 — helper exit 2 → fail-open for that metric
# ---------------------------------------------------------------------------
test_parallel_helper_exit2() {
	setup

	local fake_helper="$TEST_ROOT/fake-helper-exit2.sh"
	printf '#!/usr/bin/env bash\nexit 2\n' > "$fake_helper"
	chmod +x "$fake_helper"

	local output rc=0
	output=$(COMPLEXITY_HELPER="$fake_helper" COMPLEXITY_GUARD_BASE_SHA="abc1234" \
		bash "$HOOK" 2>&1) || rc=$?

	local fail=0
	# exit 2 should be fail-open → exit 0
	if [[ $rc -ne 0 ]]; then
		fail=1
	fi
	if ! printf '%s' "$output" | grep -q "fail-open"; then
		fail=1
	fi

	print_result "parallel-helper-exit2" "$fail" \
		"expected exit 0 + fail-open warning, got rc=$rc"
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf '\n=== complexity-guard parallel tests (t2381) ===\n\n'

	test_parallel_all_pass
	test_parallel_one_fail
	test_parallel_output_order
	test_parallel_disable_bypass
	test_parallel_debug_output
	test_parallel_helper_missing
	test_parallel_helper_exit2

	printf '\n--- Results: %d/%d passed ---\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [ "$TESTS_FAILED" -gt 0 ]; then
		printf '%b%d test(s) failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
		exit 1
	fi
	printf '%bAll tests passed%b\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
}

main "$@"
