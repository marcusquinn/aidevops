#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-routine-standalone.sh — t3036 / GH#21616 regression guard.
#
# Asserts that pulse-merge-routine.sh (a standalone helper invoked by launchd
# every 120s) bootstraps successfully WITHOUT pulse-wrapper.sh's environment
# in scope. The routine sources pulse-merge.sh which references
# PULSE_START_EPOCH, unlock_issue_after_worker, and fast_fail_reset — all
# normally set by pulse-wrapper.sh. Without explicit defaults / sourcing,
# `set -euo pipefail` in the routine causes a hard fail on the first
# unbound variable, and stderr noise on every merged/closed PR.
#
# Root cause (t3036, GH#21616):
#   1. pulse-merge-routine.sh ran under `set -euo pipefail` (line 42) but did
#      NOT initialise PULSE_START_EPOCH. pulse-merge.sh:326 references it
#      inside _handle_post_merge_actions:
#        _merge_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
#      Hard fail under set -u. Every launchd invocation crashed before
#      writing the last-run marker.
#   2. unlock_issue_after_worker (defined in pulse-dispatch-core.sh) and
#      fast_fail_reset (defined in pulse-fast-fail.sh) were called from
#      pulse-merge.sh:338,383,385 but neither library was sourced by the
#      routine — every successful merge/close emitted 'command not found'
#      stderr noise.
#
# Fix (t3036, this PR):
#   - Initialise PULSE_START_EPOCH in the env-var defaults block.
#   - Source pulse-dispatch-core.sh and pulse-fast-fail.sh in the source chain.
#
# Test scenarios (all run with PULSE_START_EPOCH UNSET to catch regressions):
#   1. --help completes with exit 0 and no stderr noise
#   2. --help emits no 'command not found' errors
#   3. --help emits no 'unbound variable' errors
#   4. The routine file initialises PULSE_START_EPOCH (grep guard)
#   5. The routine file sources pulse-dispatch-core.sh (grep guard)
#   6. The routine file sources pulse-fast-fail.sh (grep guard)
#   7. setup.sh has the _should_setup_noninteractive_pulse_merge_routine helper
#   8. setup.sh call site uses the new helper (not the generic gate)

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)" || exit 1

ROUTINE_FILE="${SCRIPTS_DIR}/pulse-merge-routine.sh"
SETUP_FILE="${REPO_ROOT}/setup.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_YELLOW=$'\033[1;33m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_YELLOW="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$name"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

skip() {
	local name="$1"
	local reason="${2:-}"
	printf '  %sSKIP%s %s (%s)\n' "$TEST_YELLOW" "$TEST_NC" "$name" "$reason"
	return 0
}

if [[ ! -f "$ROUTINE_FILE" ]]; then
	printf '%sFATAL%s pulse-merge-routine.sh not found at %s\n' \
		"$TEST_RED" "$TEST_NC" "$ROUTINE_FILE"
	exit 1
fi

printf '%sRunning pulse-merge-routine standalone tests (t3036, GH#21616)%s\n' \
	"$TEST_GREEN" "$TEST_NC"

# =============================================================================
# Test 1: --help completes with exit 0 (catches Bug 2 PULSE_START_EPOCH crash)
# =============================================================================
# Even with PULSE_START_EPOCH unset, the routine should bootstrap successfully
# enough to print help. Pre-fix, this would crash under `set -u` if any
# pulse-merge.sh code path that touches PULSE_START_EPOCH ran during sourcing.
printf '\n=== Bootstrap tests (PULSE_START_EPOCH unset) ===\n'

unset PULSE_START_EPOCH PULSE_MERGE_BATCH_LIMIT

help_stderr=$(LC_ALL=C timeout 30 "$ROUTINE_FILE" --help 2>&1 >/dev/null) || true
help_exit=$(LC_ALL=C timeout 30 "$ROUTINE_FILE" --help >/dev/null 2>&1; printf '%s' "$?")

if [[ "$help_exit" == "0" ]]; then
	pass "1: --help exits 0 with PULSE_START_EPOCH unset"
else
	fail "1: --help exits 0 with PULSE_START_EPOCH unset" \
		"exit=$help_exit, stderr=$help_stderr"
fi

# =============================================================================
# Test 2: No 'command not found' errors during bootstrap
# =============================================================================
# Pre-fix, sourcing pulse-merge.sh emitted 'unlock_issue_after_worker: command
# not found' and 'fast_fail_reset: command not found' on every PR processed.
if printf '%s\n' "$help_stderr" | grep -q 'command not found'; then
	fail "2: no 'command not found' errors" \
		"stderr: $help_stderr"
else
	pass "2: no 'command not found' errors"
fi

# =============================================================================
# Test 3: No 'unbound variable' errors during bootstrap
# =============================================================================
# Pre-fix, line 326 of pulse-merge.sh (_merge_elapsed=$(($(date +%s) -
# PULSE_START_EPOCH))) failed under `set -u` when PULSE_START_EPOCH was unset.
if printf '%s\n' "$help_stderr" | grep -q 'unbound variable'; then
	fail "3: no 'unbound variable' errors" \
		"stderr: $help_stderr"
else
	pass "3: no 'unbound variable' errors"
fi

# =============================================================================
# Test 4: PULSE_START_EPOCH is initialised in the env-var defaults block
# =============================================================================
printf '\n=== Source-content guards ===\n'

if grep -qE '^PULSE_START_EPOCH="\$\{PULSE_START_EPOCH:-' "$ROUTINE_FILE"; then
	pass "4: PULSE_START_EPOCH initialised with default in routine"
else
	fail "4: PULSE_START_EPOCH initialised with default in routine" \
		"missing 'PULSE_START_EPOCH=\"\${PULSE_START_EPOCH:-...}' line"
fi

# =============================================================================
# Test 5: pulse-dispatch-core.sh is sourced (provides unlock_issue_after_worker)
# =============================================================================
if grep -qE 'source "\$\{SCRIPT_DIR\}/pulse-dispatch-core\.sh"' "$ROUTINE_FILE"; then
	pass "5: pulse-dispatch-core.sh sourced (unlock_issue_after_worker)"
else
	fail "5: pulse-dispatch-core.sh sourced (unlock_issue_after_worker)" \
		"missing 'source ... pulse-dispatch-core.sh' line"
fi

# =============================================================================
# Test 6: pulse-fast-fail.sh is sourced (provides fast_fail_reset)
# =============================================================================
if grep -qE 'source "\$\{SCRIPT_DIR\}/pulse-fast-fail\.sh"' "$ROUTINE_FILE"; then
	pass "6: pulse-fast-fail.sh sourced (fast_fail_reset)"
else
	fail "6: pulse-fast-fail.sh sourced (fast_fail_reset)" \
		"missing 'source ... pulse-fast-fail.sh' line"
fi

# =============================================================================
# Test 7: setup.sh has the new escape-hatch helper (Bug 1 fix)
# =============================================================================
printf '\n=== setup.sh escape-hatch guard (Bug 1) ===\n'

if [[ ! -f "$SETUP_FILE" ]]; then
	skip "7: setup.sh has _should_setup_noninteractive_pulse_merge_routine" \
		"setup.sh not found at $SETUP_FILE"
	skip "8: setup.sh call site uses new helper" \
		"setup.sh not found at $SETUP_FILE"
else
	if grep -qE '^_should_setup_noninteractive_pulse_merge_routine\(\)' "$SETUP_FILE"; then
		pass "7: setup.sh has _should_setup_noninteractive_pulse_merge_routine"
	else
		fail "7: setup.sh has _should_setup_noninteractive_pulse_merge_routine" \
			"missing function definition"
	fi

	# =========================================================================
	# Test 8: setup.sh call site uses the new helper (not the generic gate)
	# =========================================================================
	# The non-interactive scheduler block must call the new helper for the
	# pulse-merge-routine entry, not _should_setup_noninteractive_scheduler.
	# Pattern: an `if _should_setup_noninteractive_pulse_merge_routine; then`
	# line must be immediately followed (within 3 lines, allowing comments) by
	# `setup_pulse_merge_routine` standalone. Use portable awk regex (no \b
	# word boundary — BSD awk on macOS doesn't support it).
	if awk '
		BEGIN { in_block=0; lines_since_gate=0; found_call=0 }
		/^[[:space:]]*if _should_setup_noninteractive_pulse_merge_routine[;[:space:]]/ {
			in_block=1
			lines_since_gate=0
			next
		}
		in_block {
			lines_since_gate++
			if ($0 ~ /^[[:space:]]+setup_pulse_merge_routine([[:space:]]|$)/) {
				found_call=1
				exit
			}
			if (lines_since_gate > 3 || /^[[:space:]]*fi[[:space:]]*$/) {
				in_block=0
			}
		}
		END { exit (found_call) ? 0 : 1 }
	' "$SETUP_FILE"; then
		pass "8: setup.sh call site uses new helper"
	else
		fail "8: setup.sh call site uses new helper" \
			"'if _should_setup_noninteractive_pulse_merge_routine; then' not followed by 'setup_pulse_merge_routine' call"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
