#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-cas-retry-exhaustion.sh — Regression tests for GH#19880
#
# Tests the CAS retry budget increase (10→30), uncapped backoff, and the
# CAS_EXHAUSTION_FATAL guard that prevents silent +100 offset drift when
# online allocation exhausts retries due to contention (not genuine offline).
#
# Branches covered:
#   1. allocate_online: CAS succeeds on attempt 1 → returns 0 immediately
#   2. allocate_online: CAS fails 20 times, succeeds on 21 → returns 0 (was fatal at 10)
#   3. allocate_online: CAS fails 50 times → returns 1 (exhausted)
#   4. _main_resolve_allocation: CAS_EXHAUSTION_FATAL=1 (default) blocks offline fallback
#   5. _main_resolve_allocation: CAS_EXHAUSTION_FATAL=0 allows offline fallback (legacy)
#   6. allocate_offline: explicit --offline flag still works as before
#   7. CAS_MAX_RETRIES is configurable via env var

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# Temp file for cross-subshell call counting.
# allocate_counter_cas is invoked inside $(...) by allocate_online,
# so global variable increments don't propagate to the parent shell.
_STUB_COUNTER_FILE=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Source claim-task-id.sh to gain access to internal helper functions.
# The script uses BASH_SOURCE guard so main() is NOT called on source.
_source_claim_script() {
	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi
	return 0
}

# Create a temporary directory for test repos
_setup_tmpdir() {
	local tmpdir
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cas-retry-test.XXXXXX") || exit 1
	echo "$tmpdir"
	return 0
}

_cleanup_tmpdir() {
	local dir="$1"
	[[ -d "$dir" ]] && rm -rf "$dir"
	return 0
}

# Read the call count from the temp file counter
_get_stub_call_count() {
	if [[ -f "$_STUB_COUNTER_FILE" ]]; then
		wc -l < "$_STUB_COUNTER_FILE" | tr -d ' '
	else
		echo "0"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Stub installation — MUST be called AFTER _source_claim_script()
# because sourcing defines the real functions that we need to override.
# ---------------------------------------------------------------------------

_STUB_FAIL_COUNT=0
_STUB_SUCCESS_ID=100

_install_stubs() {
	# Create temp file for call counting across subshells
	_STUB_COUNTER_FILE=$(mktemp "${TMPDIR:-/tmp}/cas-stub-counter.XXXXXX") || exit 1
	# Truncate
	: > "$_STUB_COUNTER_FILE"

	# Override allocate_counter_cas with a stub that uses a file-based counter.
	# Returns exit 2 (retriable conflict) for the first $_STUB_FAIL_COUNT calls,
	# then returns exit 0 (success) and echoes a task ID.
	allocate_counter_cas() {
		local _repo_path="$1"  # unused in stub
		local _count="$2"      # unused in stub

		# Append a line to the counter file (atomic enough for single-process tests)
		echo "call" >> "$_STUB_COUNTER_FILE"
		local call_count
		call_count=$(wc -l < "$_STUB_COUNTER_FILE" | tr -d ' ')

		if [[ "$call_count" -le "$_STUB_FAIL_COUNT" ]]; then
			return 2  # retriable conflict
		fi

		echo "$_STUB_SUCCESS_ID"
		return 0
	}

	# Suppress sleep during tests for speed
	# shellcheck disable=SC2317
	sleep() { :; return 0; }

	return 0
}

_reset_stub() {
	_STUB_FAIL_COUNT=0
	_STUB_SUCCESS_ID=100
	if [[ -n "$_STUB_COUNTER_FILE" && -f "$_STUB_COUNTER_FILE" ]]; then
		: > "$_STUB_COUNTER_FILE"
	fi
	return 0
}

_cleanup_stubs() {
	[[ -n "$_STUB_COUNTER_FILE" && -f "$_STUB_COUNTER_FILE" ]] && rm -f "$_STUB_COUNTER_FILE"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Test 1: CAS succeeds on attempt 1 → returns 0 immediately
test_success_on_first_attempt() {
	local name="allocate_online succeeds on first CAS attempt"
	_reset_stub
	_STUB_FAIL_COUNT=0  # no failures
	_STUB_SUCCESS_ID=200

	local result=""
	local exit_code=0
	result=$(allocate_online "/tmp/fake-repo" 1 2>/dev/null) || exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		fail "$name" "allocate_online returned $exit_code"
		return 0
	fi

	if [[ "$result" == "200" ]]; then
		pass "$name"
	else
		fail "$name" "expected 200, got '$result'"
	fi

	local calls
	calls=$(_get_stub_call_count)
	if [[ "$calls" -eq 1 ]]; then
		pass "${name} (call count)"
	else
		fail "${name} (call count)" "expected 1 CAS call, got $calls"
	fi
	return 0
}

# Test 2: CAS fails 20 times, succeeds on attempt 21 → returns 0.
# This is the key regression: old CAS_MAX_RETRIES=10 would have exhausted.
test_success_after_20_failures() {
	local name="allocate_online succeeds after 20 CAS conflicts (was fatal at 10)"
	_reset_stub
	_STUB_FAIL_COUNT=20
	_STUB_SUCCESS_ID=300

	local result=""
	local exit_code=0
	result=$(allocate_online "/tmp/fake-repo" 1 2>/dev/null) || exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		fail "$name" "allocate_online returned $exit_code (should have succeeded on attempt 21)"
		return 0
	fi

	if [[ "$result" == "300" ]]; then
		pass "$name"
	else
		fail "$name" "expected 300, got '$result'"
	fi

	local calls
	calls=$(_get_stub_call_count)
	if [[ "$calls" -eq 21 ]]; then
		pass "${name} (attempt count)"
	else
		fail "${name} (attempt count)" "expected 21 CAS calls, got $calls"
	fi
	return 0
}

# Test 3: CAS fails 50 times → allocate_online returns 1 (exhausted at 30)
test_exhaustion_at_50_failures() {
	local name="allocate_online exhausts after ${CAS_MAX_RETRIES} attempts on 50 failures"
	_reset_stub
	_STUB_FAIL_COUNT=50

	local result=""
	local exit_code=0
	result=$(allocate_online "/tmp/fake-repo" 1 2>/dev/null) || exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero exit, got 0 with result '$result'"
	fi

	# Should have tried exactly CAS_MAX_RETRIES times
	local calls
	calls=$(_get_stub_call_count)
	if [[ "$calls" -eq "$CAS_MAX_RETRIES" ]]; then
		pass "${name} (tried ${CAS_MAX_RETRIES} times)"
	else
		fail "${name} (attempt count)" "expected ${CAS_MAX_RETRIES} CAS calls, got $calls"
	fi
	return 0
}

# Test 4: CAS_EXHAUSTION_FATAL=1 (default) blocks offline fallback after online exhaustion.
# _main_resolve_allocation should return 1, NOT fall through to allocate_offline.
test_cas_exhaustion_fatal_blocks_offline() {
	local name="CAS_EXHAUSTION_FATAL=1 prevents silent offline fallback"
	_reset_stub
	_STUB_FAIL_COUNT=50  # exhaust all retries

	# Override globals to simulate online mode
	local orig_offline="$OFFLINE_MODE"
	local orig_dry="$DRY_RUN"
	OFFLINE_MODE="false"
	DRY_RUN="false"
	CAS_EXHAUSTION_FATAL=1

	# We need a temp dir with a .task-counter so allocate_offline would succeed
	local tmpdir
	tmpdir=$(_setup_tmpdir)
	echo "99" >"${tmpdir}/.task-counter"
	REPO_PATH="$tmpdir"
	ALLOC_COUNT=1

	local output=""
	local exit_code=0
	output=$(_main_resolve_allocation 2>/dev/null) || exit_code=$?

	OFFLINE_MODE="$orig_offline"
	DRY_RUN="$orig_dry"
	_cleanup_tmpdir "$tmpdir"

	if [[ $exit_code -ne 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero exit, got 0. Output: '$output'"
	fi
	return 0
}

# Test 5: CAS_EXHAUSTION_FATAL=0 allows legacy offline fallback after online exhaustion.
test_cas_exhaustion_disabled_allows_offline() {
	local name="CAS_EXHAUSTION_FATAL=0 allows offline fallback (legacy)"
	_reset_stub
	_STUB_FAIL_COUNT=50  # exhaust all retries

	local orig_offline="$OFFLINE_MODE"
	local orig_dry="$DRY_RUN"
	OFFLINE_MODE="false"
	DRY_RUN="false"
	CAS_EXHAUSTION_FATAL=0

	local tmpdir
	tmpdir=$(_setup_tmpdir)
	echo "99" >"${tmpdir}/.task-counter"
	REPO_PATH="$tmpdir"
	ALLOC_COUNT=1

	local output=""
	local exit_code=0
	output=$(_main_resolve_allocation 2>/dev/null) || exit_code=$?

	OFFLINE_MODE="$orig_offline"
	DRY_RUN="$orig_dry"

	if [[ $exit_code -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (offline fallback), got $exit_code"
		_cleanup_tmpdir "$tmpdir"
		return 0
	fi

	# Verify offline allocation happened (first_id = 99 + OFFLINE_OFFSET = 199)
	if echo "$output" | grep -q "_alloc_is_offline=true"; then
		pass "${name} (offline flag set)"
	else
		fail "${name} (offline flag)" "expected _alloc_is_offline=true in output: '$output'"
	fi

	_cleanup_tmpdir "$tmpdir"
	return 0
}

# Test 6: Explicit --offline flag still works (allocate_offline called directly).
test_explicit_offline_still_works() {
	local name="Explicit --offline flag allocates with offset (unchanged)"

	local tmpdir
	tmpdir=$(_setup_tmpdir)
	echo "99" >"${tmpdir}/.task-counter"

	local result=""
	local exit_code=0
	result=$(allocate_offline "$tmpdir" 1 2>/dev/null) || exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "allocate_offline returned $exit_code"
		_cleanup_tmpdir "$tmpdir"
		return 0
	fi

	# Expected: 99 + OFFLINE_OFFSET(100) = 199
	if [[ "$result" == "199" ]]; then
		pass "${name} (ID = 199)"
	else
		fail "${name} (ID)" "expected 199, got '$result'"
	fi

	# Verify .task-counter was updated: 199 + 1 = 200
	local counter_val
	counter_val=$(cat "${tmpdir}/.task-counter" 2>/dev/null)
	if [[ "$counter_val" == "200" ]]; then
		pass "${name} (counter updated to 200)"
	else
		fail "${name} (counter)" "expected 200 in .task-counter, got '$counter_val'"
	fi

	_cleanup_tmpdir "$tmpdir"
	return 0
}

# Test 7: Verify CAS_MAX_RETRIES is configurable via env var.
test_cas_max_retries_env_override() {
	local name="CAS_MAX_RETRIES respects env override"
	_reset_stub
	_STUB_FAIL_COUNT=50  # exhaust

	# Override CAS_MAX_RETRIES to a smaller value
	local orig_max="$CAS_MAX_RETRIES"
	CAS_MAX_RETRIES=5

	local result=""
	local exit_code=0
	result=$(allocate_online "/tmp/fake-repo" 1 2>/dev/null) || exit_code=$?

	local calls
	calls=$(_get_stub_call_count)

	if [[ $exit_code -ne 0 ]] && [[ "$calls" -eq 5 ]]; then
		pass "$name"
	else
		fail "$name" "expected exhaustion after 5 attempts, got exit=$exit_code calls=$calls"
	fi

	CAS_MAX_RETRIES="$orig_max"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	printf 'test-cas-retry-exhaustion.sh — GH#19880 regression tests\n'
	printf '==========================================================\n\n'

	# Step 1: Source the script (defines all real functions)
	_source_claim_script

	# Step 2: Install stubs AFTER sourcing (overrides real functions)
	_install_stubs

	# Override DRY_RUN and OFFLINE_MODE defaults from the sourced script
	DRY_RUN="${DRY_RUN:-false}"
	OFFLINE_MODE="${OFFLINE_MODE:-false}"

	test_success_on_first_attempt
	test_success_after_20_failures
	test_exhaustion_at_50_failures
	test_cas_exhaustion_fatal_blocks_offline
	test_cas_exhaustion_disabled_allows_offline
	test_explicit_offline_still_works
	test_cas_max_retries_env_override

	_cleanup_stubs

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
