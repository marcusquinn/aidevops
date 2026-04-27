#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-gate-pulse-parity.sh — t2890 regression guard.
#
# Asserts that `_check_linked_issue_gate` in `.agents/scripts/full-loop-helper.sh`
# inherits the pulse-side structural dispatch gates by calling
# `dispatch-dedup-helper.sh is-assigned` and translating PARENT_TASK_BLOCKED
# and NO_AUTO_DISPATCH_BLOCKED signals into hard blocks.
#
# Background: pre-t2890, the interactive `/full-loop` path only checked
# needs-maintainer-review + missing assignee. The pulse meanwhile honored
# parent-task and no-auto-dispatch via dispatch-dedup-helper.sh. A user typing
# /full-loop on a parent-task or no-auto-dispatch issue would bypass those
# gates entirely. This test prevents accidental regression of the wiring.
#
# This is a static structural check — runtime behaviour is verified at install
# time via the smoke flow documented in todo/tasks/t2890-brief.md. CI is the
# authoritative runtime test (the gate is exercised whenever any worker runs
# /full-loop on a real issue).
#
# NOTE: not using `set -e` — assertions capture non-zero exits.

set -uo pipefail

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
	return 0
}

# Resolve the helper file relative to the test (tests live in .agents/scripts/tests/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HELPER_FILE="${REPO_ROOT}/.agents/scripts/full-loop-helper.sh"

if [[ ! -f "$HELPER_FILE" ]]; then
	print_result "helper file exists" 1 "not found: $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "helper file exists" 0

# Extract just the _check_linked_issue_gate function body so per-check
# assertions only see the function we care about.
GATE_BODY=$(awk '/^_check_linked_issue_gate\(\) \{/,/^}/' "$HELPER_FILE")

if [[ -z "$GATE_BODY" ]]; then
	print_result "extract _check_linked_issue_gate function body" 1 "function not found in $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "extract _check_linked_issue_gate function body" 0

assert_in_gate() {
	local pattern="$1" label="$2"
	if printf '%s\n' "$GATE_BODY" | grep -qE -- "$pattern"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in _check_linked_issue_gate body"
	fi
	return 0
}

# -------------------------------------------------------------------
# Assertion A: gate calls dispatch-dedup-helper.sh::enumerate-blockers (t2894)
# -------------------------------------------------------------------
assert_in_gate \
	'dispatch-dedup-helper\.sh' \
	"_check_linked_issue_gate references dispatch-dedup-helper.sh"
assert_in_gate \
	'enumerate-blockers' \
	"_check_linked_issue_gate calls enumerate-blockers subcommand (t2894)"

# -------------------------------------------------------------------
# Assertion B: PARENT_TASK_BLOCKED case translates to a block
# -------------------------------------------------------------------
assert_in_gate \
	'PARENT_TASK_BLOCKED' \
	"_check_linked_issue_gate matches PARENT_TASK_BLOCKED signal"
assert_in_gate \
	'parent-task' \
	"_check_linked_issue_gate mentions parent-task label in user-facing message"

# -------------------------------------------------------------------
# Assertion C: NO_AUTO_DISPATCH_BLOCKED case translates to a block
# -------------------------------------------------------------------
assert_in_gate \
	'NO_AUTO_DISPATCH_BLOCKED' \
	"_check_linked_issue_gate matches NO_AUTO_DISPATCH_BLOCKED signal"
assert_in_gate \
	'no-auto-dispatch' \
	"_check_linked_issue_gate mentions no-auto-dispatch label in user-facing message"

# -------------------------------------------------------------------
# Assertion D: fail-open pattern present (matches existing gh-api fail-open)
# -------------------------------------------------------------------
assert_in_gate \
	'\|\| true' \
	"_check_linked_issue_gate uses fail-open pattern (|| true) on dedup call"

# -------------------------------------------------------------------
# Assertion E: gate sets blocked=true on hard-block signals
# -------------------------------------------------------------------
assert_in_gate \
	'blocked=true' \
	"_check_linked_issue_gate sets blocked=true on hard-block signals"

# -------------------------------------------------------------------
# Assertion G (t2894): gate iterates over enumerate-blockers output
# with a loop so ALL blockers are reported (not just the first).
# -------------------------------------------------------------------
assert_in_gate \
	'while.*read.*_blocker_line' \
	"_check_linked_issue_gate iterates enumerate-blockers output with a loop (t2894)"
assert_in_gate \
	'done.*dedup_out' \
	"_check_linked_issue_gate loop reads from dedup_out heredoc string (t2894)"

# -------------------------------------------------------------------
# Assertion F: full-loop-helper.sh shellcheck-clean
# -------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$HELPER_FILE" >/dev/null 2>&1; then
		print_result "full-loop-helper.sh passes shellcheck" 0
	else
		print_result "full-loop-helper.sh passes shellcheck" 1 "shellcheck reported violations"
	fi
else
	# Linter binary unavailable in the runner — skip without failing.
	printf '%sSKIP%s shellcheck (binary not on PATH)\n' "$TEST_GREEN" "$TEST_RESET"
fi

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
