#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Integration test for t2897: assert that pulse-wrapper.sh and
# pulse-cleanup.sh wire pulse-runner-health-helper.sh in the documented
# way. Structural assertions complement the behavioural unit tests in
# test-pulse-runner-health-helper.sh.
#
# What this test asserts:
#   1. The shared dispatch gate (pulse-wrapper-dispatch-gates.sh, GH#36122)
#      runs pulse-runner-health-helper.sh is-paused.
#   2. The main cycle calls that gate BEFORE apply_dispatch_max, and
#      apply_dispatch_max itself gates every other caller.
#   3. pulse-wrapper.sh skips fill-floor and increments the
#      pulse_dispatch_runner_health_breaker_tripped counter when paused.
#   4. pulse-cleanup.sh wires record-outcome no_worker_process into the
#      launch-recovery path.
#   5. Behavioural simulation: with a tripped breaker, a downstream
#      consumer of `is-paused` gets exit code 0 (paused). Confirms the
#      helper-as-imported behaviour matches what the wrapper expects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AGENT_SCRIPT_DIR="${SCRIPT_DIR}/.."
WRAPPER="${AGENT_SCRIPT_DIR}/pulse-wrapper.sh"
CLEANUP="${AGENT_SCRIPT_DIR}/pulse-cleanup.sh"
HEALTH_HELPER="${AGENT_SCRIPT_DIR}/pulse-runner-health-helper.sh"
GATES="${AGENT_SCRIPT_DIR}/pulse-wrapper-dispatch-gates.sh"
ENGINE="${AGENT_SCRIPT_DIR}/pulse-dispatch-engine.sh"

TEST_RED='\033[0;31m'
TEST_GREEN='\033[0;32m'
TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local outcome="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$outcome" == "PASS" ]]; then
		printf '  %b%s%b: %s\n' "$TEST_GREEN" "$outcome" "$TEST_RESET" "$test_name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %b%s%b: %s%s\n' "$TEST_RED" "$outcome" "$TEST_RESET" "$test_name" \
			"${detail:+ — $detail}"
	fi
	return 0
}

echo "Integration tests for pulse-wrapper + pulse-runner-health-helper:"

for f in "$WRAPPER" "$CLEANUP" "$HEALTH_HELPER" "$GATES" "$ENGINE"; do
	if [[ ! -f "$f" ]]; then
		print_result "required file exists: $(basename "$f")" "FAIL" "missing at $f"
		exit 1
	fi
done
print_result "required files exist (wrapper, cleanup, health helper)" "PASS"

# --- Test 1: the shared dispatch gate runs the helper's is-paused check ---
# GH#36122: the breakers live in pulse-wrapper-dispatch-gates.sh so every
# launch path (not only the main cycle) consults them.
# shellcheck disable=SC2016 # matches literal source text, not an expansion
if grep -q 'pulse-runner-health-helper.sh' "$GATES" && grep -qF '"$helper" is-paused' "$GATES"; then
	print_result "dispatch gates run pulse-runner-health-helper.sh is-paused" "PASS"
else
	print_result "dispatch gates run pulse-runner-health-helper.sh is-paused" "FAIL"
fi

# --- Test 2: main-cycle breaker gate happens before apply_dispatch_max ---
# Line numbers of the first gate call and the first non-comment
# apply_dispatch_max invocation; `|| true` keeps a missing match reportable.
# grep -m1 reads the file itself, so no reader closes the pipe early.
gate_line=$(grep -n -m1 -F 'pulse_dispatch_breakers_allow "main"' "$WRAPPER" | cut -d: -f1 || true)
fill_floor_line=$(grep -n -m1 '^[^#]*apply_dispatch_max' "$WRAPPER" | cut -d: -f1 || true)
if [[ -n "$gate_line" ]] && [[ -n "$fill_floor_line" ]] \
	&& [[ "$gate_line" -lt "$fill_floor_line" ]]; then
	print_result "breaker gate precedes main-cycle apply_dispatch_max" "PASS"
else
	print_result "breaker gate precedes main-cycle apply_dispatch_max" "FAIL" \
		"gate=$gate_line fill_floor=$fill_floor_line"
fi
# shellcheck disable=SC2016 # matches literal source text, not an expansion
if grep -qF 'pulse_dispatch_breakers_allow "${_PULSE_DISPATCH_BREAKER_CONTEXT:-dispatch_max}"' "$ENGINE"; then
	print_result "apply_dispatch_max gates every caller on the shared breakers" "PASS"
else
	print_result "apply_dispatch_max gates every caller on the shared breakers" "FAIL"
fi

# --- Test 3: counter increment present ---
if grep -q 'pulse_dispatch_runner_health_breaker_tripped' "$WRAPPER"; then
	print_result "pulse-wrapper.sh increments runner_health breaker counter" "PASS"
else
	print_result "pulse-wrapper.sh increments runner_health breaker counter" "FAIL"
fi

# --- Test 4: pulse-cleanup.sh wires record-outcome ---
if grep -q 'record-outcome no_worker_process' "$CLEANUP"; then
	print_result "pulse-cleanup.sh wires record-outcome no_worker_process" "PASS"
else
	print_result "pulse-cleanup.sh wires record-outcome no_worker_process" "FAIL"
fi

# --- Test 5: behavioural — tripped breaker reports paused via helper ---
SANDBOX=$(mktemp -d -t rh-int-XXXXXX)
export RUNNER_HEALTH_CACHE_DIR="$SANDBOX/cache"
export RUNNER_HEALTH_ADVISORY_DIR="$SANDBOX/advisories"
export RUNNER_HEALTH_STATE_FILE="$RUNNER_HEALTH_CACHE_DIR/runner-health.json"
export RUNNER_HEALTH_ADVISORY_FILE="$RUNNER_HEALTH_ADVISORY_DIR/runner-health-degraded.advisory"
export RUNNER_HEALTH_ADVISORY_STAMP="$RUNNER_HEALTH_CACHE_DIR/runner-health-advisory.stamp"
export RUNNER_HEALTH_FAILURE_THRESHOLD=1
export HOME_BACKUP="${HOME:-/tmp}"
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

# Trip the breaker manually.
"$HEALTH_HELPER" pause --reason "integration test trip" >/dev/null 2>&1

# Verify is-paused returns 0 (the wrapper's branch path expects this).
rc=0
"$HEALTH_HELPER" is-paused || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "tripped breaker → is-paused returns 0 (consumed by wrapper as paused)" "PASS"
else
	print_result "tripped breaker → is-paused returns 0 (consumed by wrapper as paused)" "FAIL" \
		"got rc=$rc"
fi

# Cleanup.
rm -rf "$SANDBOX"
export HOME="$HOME_BACKUP"

echo ""
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
