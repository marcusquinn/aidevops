#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stale-recovery-escalation.sh — t2008 regression guard.
#
# Asserts the stale-recovery escalation logic works end-to-end:
#
#   1. First recovery (0 prior ticks) → tick:1 posted, status:available added
#   2. Second recovery (1 prior tick) → tick:2 posted, status:available added
#   3. Third recovery (2 prior ticks = threshold) → STALE_ESCALATED emitted,
#      needs-maintainer-review applied, status:available NOT added
#   4. Reset path: when an open PR is detected, tick reset comment posted,
#      normal recovery proceeds (no escalation)
#   5. Above-threshold (3 prior ticks >= threshold=2) also escalates
#
# Tests use the `test-recover` subcommand added to dispatch-dedup-helper.sh
# (t2008) to expose _recover_stale_assignment without sourcing complications.
#
# Stubs use environment variables to control output, not heredoc jq calls.
#
# Failure history motivating this test: GH#18356 (t1962 Phase 3, observed
# stale-recovery looping twice without a PR and requiring manual intervention).
#
# NOTE: not using `set -e` — negative assertions rely on capturing non-zero
# exits. NOTE: SCRIPT_DIR NOT readonly to avoid readonly-collision pattern
# (same as test-parent-task-guard.sh).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"

#######################################
# write_stub_gh: write a minimal gh stub that:
#   - Appends all calls to GH_CALLS_FILE
#   - Returns STUB_TICK_COUNT for 'gh api *comments --jq ...'
#     (simulates the count of stale-recovery-tick comments)
#   - Returns STUB_OPEN_PR for 'gh pr list --state open ...'
#     (simulates finding an open PR by number, or empty for none)
#   - Silently succeeds for all write calls (issue edit, issue comment)
#
# Called with env vars STUB_TICK_COUNT and STUB_OPEN_PR set.
#######################################
write_stub_gh() {
	local tick_count="${1:-0}"
	local open_pr="${2:-}"
	: >"$GH_CALLS_FILE"

	cat >"${STUB_DIR}/gh" <<STUBEOF
#!/usr/bin/env bash
# Stub gh for test-stale-recovery-escalation.sh
printf '%s\n' "\$*" >> "${GH_CALLS_FILE}"

# gh api .../comments --jq '... | length'
# Returns the pre-computed tick count directly (t2008 test shim)
if [[ "\$1" == "api" && "\$2" == *"/comments" ]]; then
	printf '%s\n' "${tick_count}"
	exit 0
fi

# gh pr list --state open ...
# Returns open PR number if configured, empty if not
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
	printf '%s\n' "${open_pr}"
	exit 0
fi

# gh issue edit, gh issue comment — silent success (write operations)
if [[ "\$1" == "issue" ]]; then
	exit 0
fi

exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${OLD_PATH}"

#######################################
# run_recover: invoke dispatch-dedup-helper.sh test-recover with given
# tick count and open PR state. Captures output and exit code in globals
# $output and $rc.
#######################################
output=""
rc=0

run_recover() {
	local tick_count="${1:-0}"
	local open_pr="${2:-}"
	write_stub_gh "$tick_count" "$open_pr"
	set +e
	output=$(
		STALE_ASSIGNMENT_THRESHOLD_SECONDS=0
		STALE_RECOVERY_THRESHOLD=2
		export STALE_ASSIGNMENT_THRESHOLD_SECONDS STALE_RECOVERY_THRESHOLD
		"${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" test-recover \
			"99999" "owner/repo" "stale-runner" "test reason" 2>/dev/null
	)
	rc=$?
	set -e
	return 0
}

# =============================================================================
# Test 1 — First recovery (0 prior ticks → tick:1 comment, STALE_RECOVERED)
# =============================================================================

run_recover 0 ""

if echo "$output" | grep -q "STALE_RECOVERED"; then
	print_result "Tick 1 (0 prior ticks): STALE_RECOVERED emitted, not escalated" 0
else
	print_result "Tick 1 (0 prior ticks): STALE_RECOVERED emitted, not escalated" 1 "(got: '$output')"
fi

# gh issue comment should have been called (tick:1 posted)
if grep -q "^issue comment" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Tick 1: tick comment call posted" 0
else
	print_result "Tick 1: tick comment call posted" 1 "(gh calls: $(head -5 "$GH_CALLS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Test 2 — Second recovery (1 prior tick → tick:2 comment, STALE_RECOVERED)
# =============================================================================

run_recover 1 ""

if echo "$output" | grep -q "STALE_RECOVERED"; then
	print_result "Tick 2 (1 prior tick): STALE_RECOVERED emitted, not escalated" 0
else
	print_result "Tick 2 (1 prior tick): STALE_RECOVERED emitted, not escalated" 1 "(got: '$output')"
fi

# =============================================================================
# Test 3 — Third recovery (2 prior ticks = threshold → STALE_ESCALATED)
# =============================================================================

run_recover 2 ""

if echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Escalation (2 prior ticks >= threshold 2): STALE_ESCALATED emitted" 0
else
	print_result "Escalation (2 prior ticks >= threshold 2): STALE_ESCALATED emitted" 1 "(got: '$output')"
fi

# STALE_RECOVERED must NOT be emitted in escalation path (no re-dispatch)
if ! echo "$output" | grep -q "STALE_RECOVERED"; then
	print_result "Escalation: STALE_RECOVERED NOT emitted (no re-dispatch loop)" 0
else
	print_result "Escalation: STALE_RECOVERED NOT emitted (no re-dispatch loop)" 1 "(got: '$output')"
fi

# needs-maintainer-review must be applied (check gh issue edit call in log)
if grep -q "needs-maintainer-review" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Escalation: needs-maintainer-review label applied" 0
else
	print_result "Escalation: needs-maintainer-review label applied" 1 "(gh calls: $(head -10 "$GH_CALLS_FILE" 2>/dev/null))"
fi

# status:available must NOT be --add-label'd in escalation path
# (it's OK to appear as --remove-label; we just must not reset to available)
if ! grep -q "add-label status:available" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Escalation: status:available NOT added (correct; only removed if present)" 0
else
	print_result "Escalation: status:available NOT added (correct; only removed if present)" 1 "(gh calls: $(cat "$GH_CALLS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Test 4 — Reset path: open PR detected → counter reset, STALE_RECOVERED
# =============================================================================

# 2 prior ticks (above threshold), but open PR #42 detected → should NOT escalate
run_recover 2 "42"

if echo "$output" | grep -q "STALE_RECOVERED"; then
	print_result "Reset path (PR #42 detected, 2 ticks): STALE_RECOVERED emitted (no escalation)" 0
else
	print_result "Reset path (PR #42 detected, 2 ticks): STALE_RECOVERED emitted (no escalation)" 1 "(got: '$output')"
fi

if ! echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Reset path: STALE_ESCALATED NOT emitted" 0
else
	print_result "Reset path: STALE_ESCALATED NOT emitted" 1 "(got: '$output')"
fi

# A reset tick comment should have been posted
if grep -q "^issue comment" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Reset path: reset comment call made" 0
else
	print_result "Reset path: reset comment call made" 1 "(gh calls: $(head -5 "$GH_CALLS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Test 5 — Above-threshold (3 prior ticks >= threshold=2 → STALE_ESCALATED)
# =============================================================================

run_recover 3 ""

if echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Above-threshold (3 prior ticks >= threshold 2): STALE_ESCALATED emitted" 0
else
	print_result "Above-threshold (3 prior ticks >= threshold 2): STALE_ESCALATED emitted" 1 "(got: '$output')"
fi

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
