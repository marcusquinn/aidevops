#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-auto-dispatch-no-assign.sh — t2157 regression guard.
#
# Asserts that `_push_create_issue()` does NOT call `gh issue edit
# --add-assignee` when the issue labels include `auto-dispatch`.
#
# Production failure (GH#19453, t2157):
#   issue-sync-helper.sh::_push_create_issue() unconditionally self-assigned
#   the TODO pusher when origin_label == origin:interactive. For tasks tagged
#   #auto-dispatch the user intended worker dispatch, but the auto-assign
#   created the (origin:interactive + assigned + active status) combo that
#   GH#18352/t1996 treats as a permanent blocking signal, stranding the issue
#   until manual gh issue edit --remove-assignee or the 24h
#   STAMPLESS_INTERACTIVE_AGE_THRESHOLD safety net (t2148).
#
# Fix (t2157): inner guard ",${all_labels}," == *",auto-dispatch,"* skips
# self-assign and emits an [INFO] line instead.
#
# Tests:
#   1. auto-dispatch in labels → --add-assignee NOT called
#   2. auto-dispatch absent    → --add-assignee IS called (regression guard)
#   3. auto-dispatch in labels → [INFO] skip log emitted
#
# Stub strategy: define `gh` and `print_info` as shell functions AFTER
# sourcing the helper. Shell functions take precedence over PATH binaries,
# and re-defining after source overrides what shared-constants.sh set.
# issue-sync-helper.sh resets PATH on source (export PATH=.../usr/bin/...),
# so PATH-based stubs get shadowed — function stubs avoid that entirely.
#
# Cross-references: GH#19453 / t2157 (fix), GH#18352 / t1996 (dedup rule),
# t2148 (STAMPLESS_INTERACTIVE_AGE_THRESHOLD safety net).

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
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2157.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_INFO_OUTPUT="${TMP}/info_output.log"

# Minimal TODO.md — used by _push_create_issue for ref-duplicate checking
TODO="${TMP}/TODO.md"
printf '%s\n' '- [ ] t2157 test' >"$TODO"

# =============================================================================
# Source the helper with quiet print_* stubs to suppress noise.
# shared-constants.sh overwrites print_info during source — we re-override
# it as a function after sourcing (shell functions beat PATH lookups).
# =============================================================================
print_info() { :; }
print_warning() { :; }
print_error() { :; }
print_success() { :; }
log_verbose() { :; }
export -f print_info print_warning print_error print_success log_verbose

export AIDEVOPS_SESSION_ORIGIN=interactive
export AIDEVOPS_SESSION_USER=testuser

# BASH_SOURCE guard in the helper prevents main() from executing when sourced
# shellcheck source=../issue-sync-helper.sh
source "${SCRIPTS_DIR}/issue-sync-helper.sh" >/dev/null 2>&1 || true

# =============================================================================
# Post-source stubs (functions beat PATH binaries regardless of PATH order).
#
# gh stub: records all calls; returns canned responses for the paths exercised
#   by _push_create_issue():
#     gh issue list        → empty string (race guard finds no duplicate)
#     gh issue create      → URL so _PUSH_CREATED_NUM gets set
#     gh api user          → "testuser" so current_user is non-empty
#     gh label create      → silent success (ensure_labels_exist path)
#     gh issue edit        → recorded (--add-assignee detection)
#     gh issue lock        → silent success
#
# print_info stub: writes to GH_INFO_OUTPUT so we can assert skip messages.
# =============================================================================
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$1" == "api" && "$2" == "user" ]]; then
		printf '"testuser"\n'
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "list" ]]; then
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "create" ]]; then
		printf 'https://github.com/owner/repo/issues/9901\n'
		return 0
	fi
	return 0
}
export -f gh

# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; }
export -f print_info

printf '%sRunning _push_create_issue auto-dispatch guard tests (t2157)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — auto-dispatch in labels → --add-assignee NOT called
# =============================================================================
: >"$GH_CALLS"
_PUSH_CREATED_NUM=""
_push_create_issue \
	"t9901" "owner/repo" "$TODO" \
	"t9901: test task" "body" \
	"auto-dispatch,tier:standard" "" 2>/dev/null || true

if ! grep -q -- "--add-assignee" "$GH_CALLS" 2>/dev/null; then
	pass "auto-dispatch labels → --add-assignee NOT called"
else
	fail "auto-dispatch labels → --add-assignee NOT called" \
		"gh was called with --add-assignee when auto-dispatch was present"
fi

# =============================================================================
# Test 2 — auto-dispatch absent → --add-assignee IS called
# =============================================================================
: >"$GH_CALLS"
_PUSH_CREATED_NUM=""
_CACHED_GH_USER="" # force fresh user lookup so the assign branch fires
_push_create_issue \
	"t9902" "owner/repo" "$TODO" \
	"t9902: test task" "body" \
	"tier:standard" "" 2>/dev/null || true

if grep -q -- "--add-assignee" "$GH_CALLS" 2>/dev/null; then
	pass "no auto-dispatch → --add-assignee IS called"
else
	fail "no auto-dispatch → --add-assignee IS called" \
		"expected --add-assignee call for interactive non-auto-dispatch issue"
fi

# =============================================================================
# Test 3 — auto-dispatch in labels → [INFO] skip log emitted
# =============================================================================
: >"$GH_INFO_OUTPUT"
_PUSH_CREATED_NUM=""
_push_create_issue \
	"t9903" "owner/repo" "$TODO" \
	"t9903: test task" "body" \
	"auto-dispatch,tier:standard" "" 2>/dev/null || true

if grep -q "worker-owned" "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "auto-dispatch → [INFO] skip message logged"
else
	fail "auto-dispatch → [INFO] skip message logged" \
		"expected 'worker-owned' in info output — got: $(cat "$GH_INFO_OUTPUT" 2>/dev/null || printf '(empty)')"
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
