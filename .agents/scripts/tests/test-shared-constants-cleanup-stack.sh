#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Test: shared-constants.sh cleanup stack reversal
# Verifies cleanup commands execute in LIFO order without reversal stderr noise.
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
TESTS=0

_test() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	TESTS=$((TESTS + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  PASS: %s\n' "$desc"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s\n' "$desc"
		printf '    expected: %s\n' "$expected"
		printf '    actual:   %s\n' "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "$SCRIPT_DIR" == "$SCRIPT_PATH" ]] && SCRIPT_DIR="."
SCRIPT_DIR="${SCRIPT_DIR}/.."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

source "$SCRIPT_DIR/shared-constants.sh"

printf '=== cleanup stack reversal tests ===\n'

order_file="$TMPDIR_TEST/order.txt"
stderr_file="$TMPDIR_TEST/stderr.txt"
: >"$order_file"

_CLEANUP_CMDS=""
push_cleanup "printf '%s\\n' first >> '$order_file'"
push_cleanup "printf '%s\\n' second >> '$order_file'"
push_cleanup "printf '%s\\n' third >> '$order_file'"

_run_cleanups 2>"$stderr_file"

actual_order="$(tr '\n' ' ' <"$order_file")"
actual_stderr="$(<"$stderr_file")"

_test "Cleanup stack executes in LIFO order" "third second first " "$actual_order"
_test "Cleanup stack reversal emits no stderr" "" "$actual_stderr"
_test "Cleanup stack is empty after execution" "" "$_CLEANUP_CMDS"

cleanup_function_probe() {
	CLEANUP_FUNCTION_PROBE="ran"
	return 0
}

CLEANUP_FUNCTION_PROBE="pending"
push_cleanup 'cleanup_function_probe'
_run_cleanups
_test "Bare cleanup function executes in the current shell" "ran" "$CLEANUP_FUNCTION_PROBE"

# -----------------------------------------------------------------------------
# t18679: each scope runs only when its owning frame returns.
# -----------------------------------------------------------------------------
printf '\n=== cleanup scope ownership tests (bash %s) ===\n' "$BASH_VERSION"

events_file="$TMPDIR_TEST/events.txt"

_reset_events() {
	: >"$events_file"
	return 0
}

_event() {
	local name="$1"
	printf '%s\n' "$name" >>"$events_file"
	return 0
}

_events() {
	tr '\n' ' ' <"$events_file"
	return 0
}

# Cleanup command that records an event from a child shell.
_cleanup_event_cmd() {
	local name="$1"
	printf "printf '%%s\\\\n' '%s' >> '%s'" "$name" "$events_file"
	return 0
}

# Mirrors a gh_* write wrapper: scope opened through the shared helper.
fake_gh_wrapper() {
	_gh_wrapper_enter_cleanup_scope
	push_cleanup "$(_cleanup_event_cmd wrapper-cleanup)"
	_event wrapper-body
	return 0
}

# Case 1 (issue reproduction): a gh wrapper call must not run the caller's
# pending cleanups.
caller_with_wrapper() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd caller-cleanup)"
	fake_gh_wrapper
	_event caller-continues
	return 0
}

_reset_events
caller_with_wrapper
_test "gh wrapper scope runs at wrapper return, caller scope at caller return" \
	"wrapper-body wrapper-cleanup caller-continues caller-cleanup " "$(_events)"
_test "Stack is empty after wrapper case" "0||" "${_CLEANUP_OWNER}|${_CLEANUP_OWNER_STACK}|${_CLEANUP_CMDS}"

# Case 2 (issue reproduction): a documented-pattern helper called from a
# trap-less function must not run the outer owner's scope early.
pattern_helper() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd helper-cleanup)"
	return 0
}

trapless_middle() {
	pattern_helper
	_event middle-continues
	return 0
}

outer_owner() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd outer-cleanup)"
	trapless_middle
	_event outer-continues
	return 0
}

_reset_events
outer_owner
_test "Helper trap in a trap-less caller does not run the outer scope early" \
	"helper-cleanup middle-continues outer-continues outer-cleanup " "$(_events)"
# Inspect at top level: a function call would save and clear the trap.
_test "RETURN trap is cleared after the outermost owner returns" "" "$(trap -p RETURN)"

# Nested owners: three levels, each with two LIFO cleanups.
level3() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd l3-a)"
	push_cleanup "$(_cleanup_event_cmd l3-b)"
	_event l3-body
	return 0
}

level2() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd l2-a)"
	level3
	push_cleanup "$(_cleanup_event_cmd l2-b)"
	fake_gh_wrapper
	_event l2-body
	return 0
}

level1() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd l1-a)"
	level2
	trapless_middle
	_event l1-body
	return 0
}

_reset_events
level1
_test "Nested owners each run their own scope at their own return" \
	"l3-body l3-b l3-a wrapper-body wrapper-cleanup l2-body l2-b l2-a helper-cleanup middle-continues l1-body l1-a " \
	"$(_events)"

# Command-substitution call: the subshell's scope runs inside the subshell;
# the parent's pending scope is untouched.
subst_owner() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd subst-parent-cleanup)"
	local out
	out="$(fake_gh_wrapper && pattern_helper && printf 'subst-out')"
	_event "$out"
	_event subst-parent-continues
	return 0
}

_reset_events
subst_owner
_test "Command-substitution calls keep the parent scope pending" \
	"wrapper-body wrapper-cleanup helper-cleanup subst-out subst-parent-continues subst-parent-cleanup " \
	"$(_events)"

# Background-subshell call.
background_owner() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd bg-parent-cleanup)"
	trapless_middle &
	wait "$!"
	_event bg-parent-continues
	return 0
}

_reset_events
background_owner
_test "Background-subshell calls keep the parent scope pending" \
	"helper-cleanup middle-continues bg-parent-continues bg-parent-cleanup " \
	"$(_events)"

# A caller's own (different) RETURN trap survives a pattern-helper call.
different_trap_owner() {
	trap '_event different-trap' RETURN
	pattern_helper
	_event different-continues
	return 0
}

_reset_events
different_trap_owner
trap - RETURN
_test "Caller's different RETURN trap is restored after a pattern helper" \
	"helper-cleanup different-continues different-trap " "$(_events)"

# A failing cleanup command does not stop the rest of its scope.
failing_owner() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd fail-first)"
	push_cleanup "false"
	push_cleanup "$(_cleanup_event_cmd fail-last)"
	return 0
}

_reset_events
failing_owner
_test "Failing cleanup does not skip the remaining commands" "fail-last fail-first " "$(_events)"

# Direct call from an EXIT trap after `exit` in a trap-less callee still runs
# the innermost pending scope (exit-time behaviour).
exiting_callee() {
	exit 0
	# shellcheck disable=SC2317 # unreachable; satisfies the return ratchet
	return 0
}

exiting_owner() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "$(_cleanup_event_cmd exit-cleanup)"
	exiting_callee
	return 0
}

_reset_events
(
	trap '_run_cleanups' EXIT
	exiting_owner
)
_test "EXIT-trap direct call runs the pending scope after a nested exit" "exit-cleanup " "$(_events)"
_test "Stack is empty after ownership tests" "0||" "${_CLEANUP_OWNER}|${_CLEANUP_OWNER_STACK}|${_CLEANUP_CMDS}"

printf '\nResults: %s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TESTS"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
