#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-auto-dispatch-no-assign.sh — t2218 regression guard.
#
# Asserts that `_auto_assign_issue()` in claim-task-id.sh does NOT call
# `gh issue edit --add-assignee` when TASK_LABELS includes `auto-dispatch`.
#
# Production failure (GH#19718, t2218):
#   claim-task-id.sh::_auto_assign_issue() unconditionally self-assigned
#   the creator when an interactive session created a task with auto-dispatch.
#   The (origin:interactive + assignee) combo blocked pulse dispatch per
#   GH#18352/t1996, requiring manual gh issue edit --remove-assignee.
#
# Fix (t2218): inner guard ",${TASK_LABELS:-}," == *",auto-dispatch,"* skips
# self-assign and emits a log_info line instead.
#
# Tests:
#   1. auto-dispatch in TASK_LABELS → --add-assignee NOT called
#   2. auto-dispatch absent         → --add-assignee IS called (regression)
#   3. auto-dispatch in TASK_LABELS → log_info skip message emitted
#
# Cross-references: GH#19718 / t2218 (fix), GH#18352 / t1996 (dedup rule),
# t2157 (symmetric fix in issue-sync-helper.sh).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2218.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
LOG_INFO_OUTPUT="${TMP}/log_info_output.log"

# Create a fake git repo so _auto_assign_issue can resolve a slug from
# `git -C "$repo_path" remote get-url origin`.
FAKE_REPO="${TMP}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" remote add origin "https://github.com/owner/repo.git"

# =============================================================================
# Source claim-task-id.sh with stubs to suppress noise and prevent main().
# shared-constants.sh may not be in PATH — stub the functions it provides.
# =============================================================================
print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
log_info() { return 0; }
export -f print_info print_warning print_error print_success log_verbose log_info

# shellcheck source=../claim-task-id.sh
source "${SCRIPTS_DIR}/claim-task-id.sh" >/dev/null 2>&1 || true

# =============================================================================
# Post-source stubs (functions beat PATH binaries).
#
# gh stub: records all calls; returns canned responses for paths exercised
#   by _auto_assign_issue():
#     gh api user → "testuser" so current_user is non-empty
#     gh issue edit → recorded (--add-assignee detection)
#
# log_info stub: writes to LOG_INFO_OUTPUT so we can assert skip messages.
# =============================================================================
gh() {
	local cmd="${1:-}"
	local subcmd="${2:-}"
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$cmd" == "api" && "$subcmd" == "user" ]]; then
		printf 'testuser\n'
		return 0
	fi
	return 0
}
export -f gh

# shellcheck disable=SC2317
log_info() {
	local msg="$*"
	printf '[INFO] %s\n' "$msg" >>"${LOG_INFO_OUTPUT}"
	return 0
}
export -f log_info

printf '%sRunning _auto_assign_issue auto-dispatch guard tests (t2218)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — auto-dispatch in TASK_LABELS → --add-assignee NOT called
# =============================================================================
: >"$GH_CALLS"
TASK_LABELS="bug,auto-dispatch,framework"
_auto_assign_issue 99999 "$FAKE_REPO" 2>/dev/null || true

if ! grep -q -- "--add-assignee" "$GH_CALLS" 2>/dev/null; then
	pass "auto-dispatch in TASK_LABELS → --add-assignee NOT called"
else
	fail "auto-dispatch in TASK_LABELS → --add-assignee NOT called" \
		"gh was called with --add-assignee when auto-dispatch was present"
fi

# =============================================================================
# Test 2 — auto-dispatch absent → --add-assignee IS called
# =============================================================================
: >"$GH_CALLS"
TASK_LABELS="bug,framework"
_auto_assign_issue 99998 "$FAKE_REPO" 2>/dev/null || true

if grep -q -- "--add-assignee" "$GH_CALLS" 2>/dev/null; then
	pass "no auto-dispatch → --add-assignee IS called"
else
	fail "no auto-dispatch → --add-assignee IS called" \
		"expected --add-assignee call for non-auto-dispatch issue"
fi

# =============================================================================
# Test 3 — auto-dispatch in TASK_LABELS → log_info skip message emitted
# =============================================================================
: >"$LOG_INFO_OUTPUT"
TASK_LABELS="auto-dispatch,tier:standard"
_auto_assign_issue 99997 "$FAKE_REPO" 2>/dev/null || true

if grep -q "worker-owned" "$LOG_INFO_OUTPUT" 2>/dev/null; then
	pass "auto-dispatch → log_info skip message logged"
else
	fail "auto-dispatch → log_info skip message logged" \
		"expected 'worker-owned' in log_info output — got: $(cat "$LOG_INFO_OUTPUT" 2>/dev/null || printf '(empty)')"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
