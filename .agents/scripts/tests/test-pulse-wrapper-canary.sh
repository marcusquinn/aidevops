#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Canary test for pulse-wrapper.sh main() runtime execution (GH#18790).
#
# Purpose: Catch set -e exit-code propagation regressions (GH#18770 class)
# that static analysis cannot detect. The test actually runs pulse-wrapper.sh
# under bash -e and asserts it reaches a known checkpoint without crashing.
#
# What is exercised:
#   1. Script sourcing under set -euo pipefail (all top-level declarations)
#   2. _pulse_handle_self_check — the exact function GH#18770 broke
#      (returned non-zero under normal operation, killing the script via set -e)
#   3. acquire_instance_lock — the next downstream function
#
# What is NOT exercised (to keep the test fast and side-effect-free):
#   - check_session_gate, check_dedup (skipped via --canary short-circuit)
#   - Preflight stages, merge pass, LLM supervisor, worker dispatch
#   - Any GitHub API calls
#
# Regression verification:
#   Against the pre-GH#18770 fix (PR #18712), this test would have failed with
#   exit 2 — the "not a self-check invocation" signal from
#   _pulse_handle_self_check propagated through the unchecked pattern
#   `_sc_rc=$?` and killed the script before main() could continue.
#
# See also:
#   - test-pulse-wrapper-headless-export.sh  (AIDEVOPS_HEADLESS scoping)
#   - test-pulse-systemd-timeout.sh          (grep-based unit-file checks)
#   - .agents/reference/bash-compat.md       (pre-merge checklist item 4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"
# t3016: _pulse_setup_canary_mode was relocated into pulse-wrapper-bootstrap.sh
# by GH#21311 (the pulse-wrapper.sh split — PR #21553). The canary entrypoint
# is still pulse-wrapper.sh (which sources bootstrap), but Test 3's static
# grep needs to look in the new location.
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper-bootstrap.sh"
# t3016: pulse-wrapper-bootstrap.sh::_load_config requires the canonical
# defaults file to be present at $HOME/.aidevops/agents/configs/. The
# sandboxed HOME used by Tests 1 and 2 must seed this file or the bootstrap
# emits "[config] Failed to parse defaults — config system unavailable" and
# the canary checkpoint never prints.
DEFAULTS_SOURCE="${SCRIPT_DIR}/../../configs/aidevops.defaults.jsonc"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

# t3016: Seed a sandbox HOME with the canonical aidevops defaults config so
# pulse-wrapper-bootstrap.sh::_load_config succeeds. Mirrors what setup.sh
# does at install time. Idempotent — safe to call repeatedly.
seed_sandbox_config() {
	local sandbox_home="$1"
	mkdir -p "${sandbox_home}/.aidevops/agents/configs"
	cp "$DEFAULTS_SOURCE" \
		"${sandbox_home}/.aidevops/agents/configs/aidevops.defaults.jsonc"
	return 0
}

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

# Test 1: pulse-wrapper.sh --canary exits 0 in a sandboxed HOME.
#
# This is the core regression guard. If _pulse_handle_self_check returns
# non-zero under set -e and the call site does not use `|| _sc_rc=$?` to
# capture the code, the script dies at the call site and this test fails.
#
# Sandbox rationale: acquire_instance_lock writes to $HOME/.aidevops/run/.
# A sandboxed HOME prevents lock directory collisions with a live pulse and
# ensures the test is fully isolated.
test_canary_exits_zero() {
	local sandbox rc output
	sandbox=$(mktemp -d)
	mkdir -p "${sandbox}/home"
	# t3016: seed canonical defaults so bootstrap's _load_config succeeds
	seed_sandbox_config "${sandbox}/home"

	output=$(
		HOME="${sandbox}/home" \
			FULL_LOOP_HEADLESS=1 \
			timeout 60 bash "$WRAPPER_SCRIPT" --canary 2>&1
	)
	rc=$?
	rm -rf "$sandbox"

	if [[ "$rc" -eq 0 ]]; then
		print_result "--canary exits 0 (sourcing + self-check + lock passed)" 0
		return 0
	fi
	print_result "--canary exits 0 (sourcing + self-check + lock passed)" 1 \
		"Expected exit 0, got $rc. Output: ${output}"
	return 0
}

# Test 2: --canary prints the expected checkpoint line.
#
# Confirms the short-circuit fires at the right point in main() — after
# acquire_instance_lock, before check_session_gate. If the checkpoint line is
# absent the canary exited early (e.g. via --self-check handling) or the
# printf was removed.
test_canary_prints_checkpoint() {
	local sandbox rc output
	sandbox=$(mktemp -d)
	mkdir -p "${sandbox}/home"
	# t3016: seed canonical defaults so bootstrap's _load_config succeeds
	seed_sandbox_config "${sandbox}/home"

	output=$(
		HOME="${sandbox}/home" \
			FULL_LOOP_HEADLESS=1 \
			timeout 60 bash "$WRAPPER_SCRIPT" --canary 2>&1
	)
	rc=$?
	rm -rf "$sandbox"

	if printf '%s' "$output" | grep -q "^canary: ok"; then
		print_result "--canary prints 'canary: ok' checkpoint" 0
		return 0
	fi
	print_result "--canary prints 'canary: ok' checkpoint" 1 \
		"Expected line starting with 'canary: ok'. Exit $rc. Output: ${output}"
	return 0
}

# Test 3: Static check — _pulse_setup_canary_mode function exists in bootstrap.
#
# Guards against the function being accidentally removed during refactoring.
# Catches the regression before runtime.
#
# t3016: Function relocated from pulse-wrapper.sh to pulse-wrapper-bootstrap.sh
# by GH#21311 (PR #21553). pulse-wrapper.sh now only contains the call site
# (`_pulse_setup_canary_mode "$@"`); the definition lives in bootstrap.
test_canary_function_exists() {
	if grep -q "^_pulse_setup_canary_mode()" "$BOOTSTRAP_SCRIPT"; then
		print_result "_pulse_setup_canary_mode() defined in pulse-wrapper-bootstrap.sh" 0
		return 0
	fi
	print_result "_pulse_setup_canary_mode() defined in pulse-wrapper-bootstrap.sh" 1 \
		"Function _pulse_setup_canary_mode() not found in $BOOTSTRAP_SCRIPT"
	return 0
}

# Test 4: Static check — --canary short-circuit is AFTER acquire_instance_lock.
#
# The canary must exercise acquire_instance_lock to be useful. If the
# short-circuit is accidentally moved before the lock acquisition, the test
# would still pass but would no longer catch lock-related regressions.
test_canary_short_circuit_after_lock() {
	local lock_line canary_line
	lock_line=$(grep -n "if ! acquire_instance_lock" "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	canary_line=$(grep -n 'PULSE_CANARY_MODE:-0.*== "1"' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)

	if [[ -z "$lock_line" || -z "$canary_line" ]]; then
		print_result "canary short-circuit is after acquire_instance_lock" 1 \
			"Could not find lock_line=${lock_line:-<missing>} or canary_line=${canary_line:-<missing>}"
		return 0
	fi

	if [[ "$canary_line" -gt "$lock_line" ]]; then
		print_result "canary short-circuit is after acquire_instance_lock" 0
		return 0
	fi
	print_result "canary short-circuit is after acquire_instance_lock" 1 \
		"canary short-circuit at line $canary_line is BEFORE acquire_instance_lock at line $lock_line"
	return 0
}

main_test() {
	test_canary_exits_zero
	test_canary_prints_checkpoint
	test_canary_function_exists
	test_canary_short_circuit_after_lock

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
