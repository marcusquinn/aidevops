#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-routine-timeout.sh — t3041 / GH#21708 regression guard.
#
# Asserts that pulse-merge-routine.sh wraps merge_ready_prs_all_repos with a
# hard timeout ceiling that kills the process tree when the merge body hangs.
#
# Background (t3041, Bug 3 of GH#21616):
#   The merge routine has historically hung for 30+ hours with green PRs
#   sitting unmerged. Phase 1 (PR #21643) fixed the bootstrap chicken-and-egg
#   gate (Bug 1) and the unbound-variable / command-not-found classes (Bug 2),
#   but the hang symptom (Bug 3) couldn't be reproduced on the local
#   marcusquinn/aidevops repo state. Possible hang sites — gh API call without
#   timeout, flock deadlock, infinite retry loop, wait on a dead worker PID.
#   Without measurable repro from the affected environment, a defence-in-depth
#   timeout ceiling is the durability fix: whatever the underlying cause, the
#   routine cannot exceed PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS.
#
# Test scenarios:
#   1. Source-content guards
#      a. PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS env-var default present
#      b. _pmr_run_with_timeout helper defined
#      c. cmd_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout
#      d. cmd_dry_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout
#      e. exit-code 124 on timeout is logged distinctly
#
#   2. Behavioural test — _pmr_run_with_timeout kills a forced-hang sub-shell
#      by stubbing merge_ready_prs_all_repos with a 30s sleep and setting
#      PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=2. The routine must return 124 in
#      under 10s (well below the 30s sleep), proving the ceiling fires.
#
#   3. Behavioural test — successful sub-shell completes normally, returning
#      whatever exit code merge_ready_prs_all_repos returns (here, 0).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

ROUTINE_FILE="${SCRIPTS_DIR}/pulse-merge-routine.sh"

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

printf '%sRunning pulse-merge-routine timeout tests (t3041, GH#21708)%s\n' \
	"$TEST_GREEN" "$TEST_NC"

# =============================================================================
# Test 1a: PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS env-var default
# =============================================================================
printf '\n=== Source-content guards ===\n'

if grep -qE '^PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS="\$\{PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-' "$ROUTINE_FILE"; then
	pass "1a: PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS initialised with default"
else
	fail "1a: PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS initialised with default" \
		"missing 'PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=\"\${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-...}' line"
fi

# =============================================================================
# Test 1b: _pmr_run_with_timeout helper defined
# =============================================================================
if grep -qE '^_pmr_run_with_timeout\(\)' "$ROUTINE_FILE"; then
	pass "1b: _pmr_run_with_timeout helper defined"
else
	fail "1b: _pmr_run_with_timeout helper defined" \
		"missing '_pmr_run_with_timeout() {' definition"
fi

# =============================================================================
# Test 1c: cmd_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout
# =============================================================================
# Use awk to find _pmr_run_with_timeout invocation within cmd_run() body.
if awk '
	BEGIN { in_cmd_run=0; found=0 }
	/^cmd_run\(\)/ { in_cmd_run=1; next }
	in_cmd_run && /^\}/ { in_cmd_run=0 }
	in_cmd_run && /_pmr_run_with_timeout.*merge_ready_prs_all_repos/ { found=1; exit }
	END { exit (found) ? 0 : 1 }
' "$ROUTINE_FILE"; then
	pass "1c: cmd_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout"
else
	fail "1c: cmd_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout" \
		"cmd_run body does not invoke '_pmr_run_with_timeout ... merge_ready_prs_all_repos'"
fi

# =============================================================================
# Test 1d: cmd_dry_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout
# =============================================================================
if awk '
	BEGIN { in_cmd=0; found=0 }
	/^cmd_dry_run\(\)/ { in_cmd=1; next }
	in_cmd && /^\}/ { in_cmd=0 }
	in_cmd && /_pmr_run_with_timeout.*merge_ready_prs_all_repos/ { found=1; exit }
	END { exit (found) ? 0 : 1 }
' "$ROUTINE_FILE"; then
	pass "1d: cmd_dry_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout"
else
	fail "1d: cmd_dry_run wraps merge_ready_prs_all_repos via _pmr_run_with_timeout" \
		"cmd_dry_run body does not invoke '_pmr_run_with_timeout ... merge_ready_prs_all_repos'"
fi

# =============================================================================
# Test 1e: exit-code 124 on timeout is logged distinctly
# =============================================================================
# Both cmd_run and cmd_dry_run should distinguish exit=124 (timeout) from a
# normal completion in their log output, so operators can spot hangs in the
# runner log.
if grep -qE 'merge_exit.*-eq 124' "$ROUTINE_FILE"; then
	pass "1e: exit=124 is logged distinctly"
else
	fail "1e: exit=124 is logged distinctly" \
		"missing 'merge_exit ... -eq 124' branch in cmd_run/cmd_dry_run"
fi

# =============================================================================
# Test 2: Behavioural — timeout ceiling kills a forced-hang sub-shell
# =============================================================================
# Strategy: source the routine in a sub-bash, override merge_ready_prs_all_repos
# with a 30s sleep stub, set PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=2, invoke
# _pmr_run_with_timeout directly, and assert it returns 124 within 10s.
#
# We invoke _pmr_run_with_timeout directly (rather than cmd_run) to skip the
# lock and last-run-marker side effects. The unit under test is the timeout
# helper itself; cmd_run is just the wiring tested by 1c.
printf '\n=== Behavioural tests ===\n'

# Build a minimal test harness that:
#  - stubs out the source chain that pulse-merge-routine pulls in
#  - defines a hang stub
#  - calls _pmr_run_with_timeout with a 2s ceiling
#  - exits with the helper's return code
HARNESS=$(mktemp "${TMPDIR:-/tmp}/pmr-timeout-harness-XXXXXX")
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail

# Provide minimal stand-ins for the env vars / helpers _pmr_run_with_timeout
# touches, so we can extract just that function from the routine without
# pulling in the whole source chain.
RUNNER_LOG_FILE=/dev/null
_pmr_log() { return 0; }
# Force the fallback path (no _kill_tree) — kill -TERM is enough for sleep.

# Extract the _pmr_run_with_timeout function body from the routine source.
# This avoids pulling in the full source chain (shared-constants, pulse-merge,
# etc.) which is fragile in CI.
ROUTINE_FILE="$ROUTINE_FILE"
# shellcheck disable=SC1090
source <(awk '
	/^_pmr_run_with_timeout\(\)/ { capture=1 }
	capture { print }
	capture && /^\}/ { capture=0 }
' "\$ROUTINE_FILE")

# Hang stub — sleep 30s.
hang_for_30s() {
	sleep 30
}

# Run with 2s ceiling. Should return 124 within ~4s (2s ceiling + 2s poll).
START_EPOCH=\$(date +%s)
_pmr_run_with_timeout 2 hang_for_30s
RC=\$?
END_EPOCH=\$(date +%s)
ELAPSED=\$((END_EPOCH - START_EPOCH))

# Print result for the parent test to capture.
printf 'rc=%d elapsed=%d\n' "\$RC" "\$ELAPSED"

# Assertion: must return 124 (timeout) and elapsed must be < 10s.
if [[ "\$RC" -eq 124 ]] && [[ "\$ELAPSED" -lt 10 ]]; then
	exit 0
fi
exit 1
HARNESS_EOF

chmod +x "$HARNESS"

harness_output=$(timeout 15 bash "$HARNESS" 2>&1)
harness_rc=$?

if [[ "$harness_rc" -eq 0 ]]; then
	pass "2: forced-hang killed within ceiling — ${harness_output}"
else
	fail "2: forced-hang killed within ceiling" \
		"harness rc=${harness_rc}, output=${harness_output}"
fi

# =============================================================================
# Test 3: Behavioural — successful sub-shell returns normally
# =============================================================================
HARNESS3=$(mktemp "${TMPDIR:-/tmp}/pmr-timeout-harness3-XXXXXX")
trap 'rm -f "$HARNESS" "$HARNESS3"' EXIT

cat >"$HARNESS3" <<HARNESS3_EOF
#!/usr/bin/env bash
set -uo pipefail

RUNNER_LOG_FILE=/dev/null
_pmr_log() { return 0; }

ROUTINE_FILE="$ROUTINE_FILE"
# shellcheck disable=SC1090
source <(awk '
	/^_pmr_run_with_timeout\(\)/ { capture=1 }
	capture { print }
	capture && /^\}/ { capture=0 }
' "\$ROUTINE_FILE")

# Quick stub — exits 0 immediately.
quick_success() {
	return 0
}

_pmr_run_with_timeout 5 quick_success
RC=\$?
printf 'rc=%d\n' "\$RC"

if [[ "\$RC" -eq 0 ]]; then
	exit 0
fi
exit 1
HARNESS3_EOF

chmod +x "$HARNESS3"

harness3_output=$(timeout 15 bash "$HARNESS3" 2>&1)
harness3_rc=$?

if [[ "$harness3_rc" -eq 0 ]]; then
	pass "3: successful sub-shell returns normally — ${harness3_output}"
else
	fail "3: successful sub-shell returns normally" \
		"harness rc=${harness3_rc}, output=${harness3_output}"
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
