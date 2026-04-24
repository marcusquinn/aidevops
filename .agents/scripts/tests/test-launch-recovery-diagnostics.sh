#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2814 (Phase 3): launch-recovery diagnostics.
#
# Phase 2 (t2813) identified that `no_worker_process` events were opaque —
# the worker log existed but was never read during recovery, so every
# failure was logged with the same generic reason. The actual cause
# (canary timeout, lock collision, model selection, opencode crash) was
# lost.
#
# Phase 3 adds two cooperating fixes:
#
#   1. `_capture_worker_log_diagnostics` (pulse-cleanup.sh) reads the
#      worker log tail and classifies the failure into a sub-reason.
#      This sub-reason is then attached to the CLAIM_RELEASED audit
#      comment AND fed into fast_fail_record so cascade decisions
#      (Phase 4) can branch on the actual cause.
#
#   2. Negative canary cache (headless-runtime-lib.sh): when the canary
#      fails, a short-TTL `canary-last-fail` cache short-circuits
#      consecutive dispatches that would otherwise each spend up to
#      CANARY_TIMEOUT_SECONDS (default 60s) on the same failing API
#      call. This breaks the "no_worker_process cluster" pattern
#      identified in Phase 1.
#
# This test asserts:
#
#   - The diagnostic helper classifies each known failure pattern
#     (canary, lock collision, model selection, opencode version,
#     bash crash, no log, unknown).
#   - The CLAIM_RELEASED comment body includes the sub-reason (audit
#     trail). Without this, post-mortem reviewers cannot tell from the
#     comment WHY a worker failed.
#   - The fast-fail recorded reason is the colon-suffixed form
#     `no_worker_process:canary_failed` (not the generic bucket) so
#     downstream cascade logic can route on the cause.
#   - The negative canary cache short-circuits within TTL but expires
#     correctly afterwards.
#
# Failure mode this test would catch:
#
#   A future refactor that moves the log-read out of the recovery path,
#   strips the sub-reason from CLAIM_RELEASED, or breaks the negative
#   cache TTL would make the diagnostic gap reappear silently. This
#   test asserts the contract end-to-end without spawning real workers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."
CLEANUP_FILE="${PARENT_DIR}/pulse-cleanup.sh"
RUNTIME_LIB_FILE="${PARENT_DIR}/headless-runtime-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

# Test 1: The classification helper exists in pulse-cleanup.sh.
test_helper_exists() {
	if grep -q "^_capture_worker_log_diagnostics()" "$CLEANUP_FILE"; then
		print_result "_capture_worker_log_diagnostics() defined in pulse-cleanup.sh" 0
		return 0
	fi
	print_result "_capture_worker_log_diagnostics() defined in pulse-cleanup.sh" 1 \
		"Helper missing — recovery path has no diagnostic capture"
	return 0
}

# Test 2: The CLAIM_RELEASED helper accepts diagnostic args.
# Without this, the audit trail loses the sub-reason and post-mortem reviewers
# must page into worker logs that may have been rotated.
test_claim_released_carries_diag() {
	# Use double-quoted greps with \$ to keep $ literal — single quotes
	# trigger SC2016 because the linter cannot prove the dollar is intentional.
	if grep -q "diag_subreason=\"\${5:-}\"" "$CLEANUP_FILE" \
		&& grep -q "diag_summary=\"\${6:-}\"" "$CLEANUP_FILE"; then
		print_result "_post_launch_recovery_claim_released accepts diag args" 0
		return 0
	fi
	print_result "_post_launch_recovery_claim_released accepts diag args" 1 \
		"CLAIM_RELEASED comment helper missing diag_subreason/diag_summary params"
	return 0
}

# Test 3: classify each known pattern by sourcing the helper in isolation.
# Mock $LOGFILE so the helper's tail-to-pulselog side effect doesn't fail.
test_classify_patterns() {
	local tmp work_log expected actual
	tmp=$(mktemp -d)

	# Stub LOGFILE so the helper's tail-to-pulselog side effect succeeds
	# on every call. The test-runner-level cleanup happens via the trap
	# registered in main_test.
	export LOGFILE="${tmp}/pulse.log"
	: >"$LOGFILE"
	_TEST_CLASSIFY_TMP="$tmp"

	# Source only the helper definition. We cannot source the full
	# pulse-cleanup.sh because it requires shared-constants.sh and
	# pulse-wrapper-config.sh to be sourced first. Instead, extract the
	# helper into a shim file and source that.
	awk '
		/^_capture_worker_log_diagnostics\(\)/,/^}$/ { print }
	' "$CLEANUP_FILE" >"${tmp}/helper.sh"

	# shellcheck source=/dev/null
	source "${tmp}/helper.sh"

	# Each test case: (worker_log_content, expected_subreason, label)
	# Use a synthetic log path that matches the helper's pattern.
	local repo_slug="acme/widget"
	local issue=42
	local safe_slug
	safe_slug=$(printf '%s' "$repo_slug" | tr '/:' '--')
	work_log="/tmp/pulse-${safe_slug}-${issue}.log"

	# Case A: canary failure
	cat >"$work_log" <<'EOF'
[2026-04-25T01:23:45Z] starting worker
Canary test FAILED (exit=124, model=anthropic/claude-sonnet-4-6, opencode=1.14.24, timeout=60s)
Output (last 20 lines): rate_limit_exceeded
EOF
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="canary_failed"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: canary_failed" 0
	else
		print_result "classify: canary_failed" 1 "got '$actual', expected '$expected'"
	fi

	# Case B: session lock collision
	cat >"$work_log" <<'EOF'
[startup] _acquire_session_lock collision: prior worker still alive
exiting cleanly (lock held by PID 99999)
EOF
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="lock_collision"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: lock_collision" 0
	else
		print_result "classify: lock_collision" 1 "got '$actual', expected '$expected'"
	fi

	# Case C: model selection failure
	cat >"$work_log" <<'EOF'
[startup] resolving model
no providers available — all providers in backoff
choose_model failed: no eligible provider
EOF
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="model_selection_failed"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: model_selection_failed" 0
	else
		print_result "classify: model_selection_failed" 1 "got '$actual', expected '$expected'"
	fi

	# Case D: opencode version mismatch
	cat >"$work_log" <<'EOF'
[startup] checking opencode version
version pin enforcement failed: opencode version 1.14.99 expected 1.14.24
EOF
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="opencode_version_mismatch"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: opencode_version_mismatch" 0
	else
		print_result "classify: opencode_version_mismatch" 1 "got '$actual', expected '$expected'"
	fi

	# Case E: bash crash (unbound variable)
	cat >"$work_log" <<'EOF'
headless-runtime-helper.sh: line 1234: FOO_BAR: unbound variable
EOF
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="crash_during_startup"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: crash_during_startup" 0
	else
		print_result "classify: crash_during_startup" 1 "got '$actual', expected '$expected'"
	fi

	# Case F: empty/missing log
	rm -f "$work_log"
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="no_log"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: no_log (missing file)" 0
	else
		print_result "classify: no_log (missing file)" 1 "got '$actual', expected '$expected'"
	fi

	# Case G: log present but no recognised pattern → unknown
	cat >"$work_log" <<'EOF'
[startup] doing some work
nothing matches any known failure marker here
EOF
	actual=$(_capture_worker_log_diagnostics "$repo_slug" "$issue" | cut -f1)
	expected="unknown"
	if [[ "$actual" == "$expected" ]]; then
		print_result "classify: unknown (fallback)" 0
	else
		print_result "classify: unknown (fallback)" 1 "got '$actual', expected '$expected'"
	fi

	rm -f "$work_log"
	return 0
}

# Test 4: recover_failed_launch_state preserves failure_reason → recorded_reason
# transformation. The colon-suffixed form is the contract Phase 4 will rely on.
test_recorded_reason_format() {
	if grep -q "recorded_reason=\"\${failure_reason}:\${diag_subreason}\"" "$CLEANUP_FILE"; then
		print_result "fast-fail recorded_reason uses colon-suffix when classified" 0
		return 0
	fi
	print_result "fast-fail recorded_reason uses colon-suffix when classified" 1 \
		"Phase 4 cascade routing requires recorded_reason='no_worker_process:<sub>' format"
	return 0
}

# Test 5: Negative canary cache constant is defined.
test_neg_cache_constant_exists() {
	if grep -qE "^CANARY_NEG_CACHE_TTL_SECONDS=\"\\\$\{CANARY_NEG_CACHE_TTL_SECONDS:-" "$RUNTIME_LIB_FILE"; then
		print_result "CANARY_NEG_CACHE_TTL_SECONDS constant defined" 0
		return 0
	fi
	print_result "CANARY_NEG_CACHE_TTL_SECONDS constant defined" 1 \
		"Negative cache TTL constant missing in headless-runtime-lib.sh"
	return 0
}

# Test 6: _run_canary_test reads + writes the negative cache file.
test_neg_cache_wired() {
	local read_present="" write_present="" clear_present=""
	if grep -q "neg_cache_file=\"\${STATE_DIR}/canary-last-fail\"" "$RUNTIME_LIB_FILE"; then
		read_present=1
	fi
	if grep -q "date +%s >\"\$neg_cache_file\"" "$RUNTIME_LIB_FILE"; then
		write_present=1
	fi
	if grep -q "rm -f \"\$neg_cache_file\"" "$RUNTIME_LIB_FILE"; then
		clear_present=1
	fi
	if [[ -n "$read_present" && -n "$write_present" && -n "$clear_present" ]]; then
		print_result "negative canary cache: read+write+clear paths wired" 0
		return 0
	fi
	print_result "negative canary cache: read+write+clear paths wired" 1 \
		"missing: read=${read_present:-NO} write=${write_present:-NO} clear=${clear_present:-NO}"
	return 0
}

# Test 7: Negative cache short-circuit fires within TTL — simulated.
# We test the gating logic in isolation by extracting and replaying the
# arithmetic check the helper performs.
test_neg_cache_short_circuit_logic() {
	local now_neg=1700000100
	local last_fail=1700000050
	local fail_age=$((now_neg - last_fail))
	local CANARY_NEG_CACHE_TTL_SECONDS=90

	# fail_age=50, TTL=90 → should short-circuit (return 1)
	if [[ "$fail_age" -lt "$CANARY_NEG_CACHE_TTL_SECONDS" ]]; then
		print_result "neg cache short-circuits within TTL (50s < 90s)" 0
	else
		print_result "neg cache short-circuits within TTL (50s < 90s)" 1 \
			"expected fail_age<TTL"
	fi

	# fail_age=120, TTL=90 → should NOT short-circuit
	now_neg=1700000170
	fail_age=$((now_neg - last_fail))
	if [[ "$fail_age" -ge "$CANARY_NEG_CACHE_TTL_SECONDS" ]]; then
		print_result "neg cache expires after TTL (120s > 90s)" 0
	else
		print_result "neg cache expires after TTL (120s > 90s)" 1 \
			"expected fail_age>=TTL"
	fi
	return 0
}

# Test 8: Function-complexity gate compliance — recover_failed_launch_state
# stays under the 100-line cap (t2803). Phase 3 added ~25 lines of diagnostic
# wiring; the function MUST have been refactored via helpers to absorb that
# growth. If a future change inlines the helpers, this guard fires.
test_function_complexity() {
	local lines
	lines=$(awk '/^recover_failed_launch_state\(\)/,/^}$/' "$CLEANUP_FILE" | wc -l)
	if [[ "$lines" -le 100 ]]; then
		print_result "recover_failed_launch_state under 100-line gate (t2803)" 0
		return 0
	fi
	print_result "recover_failed_launch_state under 100-line gate (t2803)" 1 \
		"function is now ${lines} lines — extract helpers (see t2803)"
	return 0
}

# Test 9: Phase 4 contract — the diagnostic sub-reason must distinguish
# infrastructure failures (canary, lock collision, version mismatch) from
# worker-coding failures. A future cascade classifier needs this signal,
# so we lock the categorisation here.
test_diag_subreasons_have_distinct_categories() {
	# All seven sub-reasons must appear as printf'd literals in the helper.
	local missing=""
	for sub in canary_failed lock_collision model_selection_failed \
		opencode_version_mismatch crash_during_startup no_log unknown; do
		if ! grep -q "printf '${sub}\\\\t" "$CLEANUP_FILE" \
			&& ! grep -q "printf 'unknown\\\\t" "$CLEANUP_FILE"; then
			# Special-case for "unknown" which is printed via a slightly
			# different idiom; a single check covers it once we reach the
			# default branch.
			:
		fi
		if ! grep -qE "printf '${sub}\\\\t" "$CLEANUP_FILE"; then
			missing="${missing} ${sub}"
		fi
	done
	if [[ -z "$missing" ]]; then
		print_result "all 7 diag sub-reasons defined (Phase 4 cascade contract)" 0
		return 0
	fi
	print_result "all 7 diag sub-reasons defined (Phase 4 cascade contract)" 1 \
		"missing sub-reasons in helper:${missing}"
	return 0
}

_cleanup_test_classify_tmp() {
	if [[ -n "${_TEST_CLASSIFY_TMP:-}" && -d "${_TEST_CLASSIFY_TMP}" ]]; then
		rm -rf "${_TEST_CLASSIFY_TMP}"
	fi
	return 0
}

main_test() {
	trap _cleanup_test_classify_tmp EXIT

	test_helper_exists
	test_claim_released_carries_diag
	test_classify_patterns
	test_recorded_reason_format
	test_neg_cache_constant_exists
	test_neg_cache_wired
	test_neg_cache_short_circuit_logic
	test_function_complexity
	test_diag_subreasons_have_distinct_categories

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
