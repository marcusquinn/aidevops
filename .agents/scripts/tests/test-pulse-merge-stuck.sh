#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-stuck.sh — Structural tests for t3193 stuck-merge detector.
#
# Verifies (no live GitHub API calls):
#   1. pulse-merge-stuck.conf exists with the four canonical env-var defaults.
#   2. pulse-merge-stuck.sh sources cleanly and applies positive-integer defaults.
#   3. _pms_iso_to_epoch round-trips a valid ISO timestamp; returns 0 for garbage.
#   4. _pms_hash_fingerprint returns a 16-hex-char digest, deterministic
#      across calls with the same input, and survives empty input.
#   5. pulse_stats_set_gauge / pulse_stats_get_gauge round-trip integer values
#      against an isolated PULSE_STATS_FILE; non-numeric set is rejected.
#   6. pulse_merge_zero_progress_record:
#        merged>0 → gauge reset to 0
#        merged=0 + eligible=0 → gauge reset to 0 (streak broken)
#        merged=0 + eligible>0 → gauge incremented by 1
#   7. pulse-merge-stuck.sh and pulse-stats-helper.sh pass shellcheck.
#
# The test never makes real network calls; functions that require gh API
# (_classify_stuck_pr, _escalate_individual_stuck_pr, pulse_merge_stuck_run_pass,
# _pms_count_eligible_unmerged_for_repo) are intentionally not exercised here —
# they're integration-level and would need a live fixture repo.

set -u

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

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

assert_match() {
	local label="$1" regex="$2" value="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$value" =~ $regex ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  regex: $regex"
		echo "  value: $(printf '%q' "$value")"
	fi
	return 0
}

assert_gt() {
	local label="$1" lhs="$2" rhs="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$lhs" =~ ^[0-9]+$ && "$rhs" =~ ^[0-9]+$ && "$lhs" -gt "$rhs" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label ($lhs > $rhs ?)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files, isolate PULSE_STATS_FILE, source the modules.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-stuck.sh"
STATS_HELPER="$SCRIPT_DIR/pulse-stats-helper.sh"
CONF_FILE="$SCRIPT_DIR/../configs/pulse-merge-stuck.conf"

for required in "$MODULE" "$STATS_HELPER"; do
	if [[ ! -f "$required" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $required not found"
		exit 1
	fi
done

# Isolate state writes to a temp file so the live ~/.aidevops/logs/pulse-stats.json
# is not perturbed. Cleanup on exit.
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-pulse-merge-stuck-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export PULSE_STATS_FILE="$TEST_TMPDIR/pulse-stats.json"
export LOGFILE="$TEST_TMPDIR/pulse.log"

# Source the helpers. pulse-stats-helper.sh sets -euo pipefail; turn that off
# after source so a single failed assertion doesn't abort the whole suite.
# shellcheck source=/dev/null
source "$MODULE"
set +e
set +o pipefail

echo "${TEST_BLUE}=== t3193: pulse-merge-stuck detector tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Section 1: conf file integrity.
# ---------------------------------------------------------------------------
echo "--- Section 1: conf file integrity ---"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$CONF_FILE" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1a: pulse-merge-stuck.conf exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1a: pulse-merge-stuck.conf NOT found at $CONF_FILE"
fi

for entry in \
	AIDEVOPS_MERGE_STUCK_AGE_MINUTES \
	AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES \
	AIDEVOPS_MERGE_PATTERN_MIN_PRS \
	AIDEVOPS_MERGE_STUCK_ENABLED; do
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "^${entry}=" "$CONF_FILE" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 1: conf contains ${entry}"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 1: conf missing ${entry}"
	fi
done
echo ""

# ---------------------------------------------------------------------------
# Section 2: defaults applied as positive integers after sourcing.
# ---------------------------------------------------------------------------
echo "--- Section 2: post-source defaults ---"

assert_match "2a: AIDEVOPS_MERGE_STUCK_AGE_MINUTES is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-x}"
assert_match "2b: AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-x}"
assert_match "2c: AIDEVOPS_MERGE_PATTERN_MIN_PRS is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_PATTERN_MIN_PRS:-x}"
assert_match "2d: AIDEVOPS_MERGE_STUCK_ENABLED is 0|1" \
	"^[01]$" "${AIDEVOPS_MERGE_STUCK_ENABLED:-x}"

assert_gt "2e: STUCK_AGE_MINUTES > 0" "$AIDEVOPS_MERGE_STUCK_AGE_MINUTES" "0"
assert_gt "2f: ZERO_PROGRESS_CYCLES > 0" "$AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES" "0"
assert_gt "2g: PATTERN_MIN_PRS > 1" "$AIDEVOPS_MERGE_PATTERN_MIN_PRS" "1"
echo ""

# ---------------------------------------------------------------------------
# Section 3: pure-logic helpers.
# ---------------------------------------------------------------------------
echo "--- Section 3: _pms_iso_to_epoch + _pms_hash_fingerprint ---"

# 3a: ISO timestamp → positive epoch
epoch=$(_pms_iso_to_epoch "2026-04-30T14:00:00Z")
assert_gt "3a: valid ISO 2026-04-30T14:00:00Z → epoch > 0" "$epoch" "0"

# 3b: garbage → 0
garbage_epoch=$(_pms_iso_to_epoch "not-a-date")
assert_eq "3b: garbage input → 0" "0" "$garbage_epoch"

# 3c: hash returns 16 hex chars
hash_out=$(_pms_hash_fingerprint "Format,Lint,Typecheck")
assert_match "3c: hash is 16 hex chars" "^[0-9a-f]{16}$" "$hash_out"

# 3d: hash deterministic
hash_a=$(_pms_hash_fingerprint "stable-input")
hash_b=$(_pms_hash_fingerprint "stable-input")
assert_eq "3d: hash deterministic for same input" "$hash_a" "$hash_b"

# 3e: hash differs for different input (collision check, not cryptographic)
hash_x=$(_pms_hash_fingerprint "input-one")
hash_y=$(_pms_hash_fingerprint "input-two")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$hash_x" != "$hash_y" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 3e: hash differs across distinct inputs"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 3e: hash collision on trivially distinct inputs ($hash_x)"
fi

# 3f: empty input still produces 16 hex chars
hash_empty=$(_pms_hash_fingerprint "")
assert_match "3f: hash of empty string is 16 hex chars" "^[0-9a-f]{16}$" "$hash_empty"
echo ""

# ---------------------------------------------------------------------------
# Section 4: pulse_stats_set_gauge / pulse_stats_get_gauge round-trip.
# ---------------------------------------------------------------------------
echo "--- Section 4: gauge round-trip ---"

# 4a: get on missing file returns "0"
rm -f "$PULSE_STATS_FILE"
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4a: get on missing file → 0" "0" "$got"

# 4b: set then get round-trip
pulse_stats_set_gauge "test_gauge_a" "7" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4b: set 7 → get 7" "7" "$got"

# 4c: overwrite
pulse_stats_set_gauge "test_gauge_a" "42" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4c: overwrite to 42 → get 42" "42" "$got"

# 4d: non-numeric is rejected (silently — gauge stays at prior value)
pulse_stats_set_gauge "test_gauge_a" "not-a-number" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4d: non-numeric set ignored, prior value retained" "42" "$got"

# 4e: distinct gauges don't collide
pulse_stats_set_gauge "test_gauge_b" "99" >/dev/null 2>&1
got_a=$(pulse_stats_get_gauge "test_gauge_a")
got_b=$(pulse_stats_get_gauge "test_gauge_b")
assert_eq "4e: gauge_a unaffected by gauge_b write" "42" "$got_a"
assert_eq "4e: gauge_b reads back" "99" "$got_b"
echo ""

# ---------------------------------------------------------------------------
# Section 5: pulse_merge_zero_progress_record state transitions.
# ---------------------------------------------------------------------------
echo "--- Section 5: zero_progress_record transitions ---"

# Reset gauge for a clean state.
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1

# 5a: merged>0 + eligible=anything → gauge reset to 0
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "3" >/dev/null 2>&1
pulse_merge_zero_progress_record 5 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5a: merged>0 resets cycles to 0 (was 3)" "0" "$got"

# 5b: merged=0 + eligible=0 → gauge reset to 0 (idle cycle breaks streak)
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "2" >/dev/null 2>&1
pulse_merge_zero_progress_record 0 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5b: merged=0 + eligible=0 resets cycles to 0 (was 2)" "0" "$got"

# 5c: merged=0 + eligible>0 → gauge increments by 1
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 4 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5c: merged=0 + eligible=4 → cycles 0→1" "1" "$got"

# 5d: a second consecutive zero-progress cycle increments again.
pulse_merge_zero_progress_record 4 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5d: second consecutive zero-progress → 1→2" "2" "$got"

# 5e: a successful merge then resets the streak to 0.
pulse_merge_zero_progress_record 4 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5e: merge during stuck-streak resets cycles to 0" "0" "$got"
echo ""

# ---------------------------------------------------------------------------
# Section 6: shellcheck cleanliness.
# ---------------------------------------------------------------------------
echo "--- Section 6: shellcheck ---"

run_shellcheck() {
	local label="$1" file="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! command -v shellcheck >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label (shellcheck not installed — skipping)"
		return 0
	fi
	local sc_out sc_rc
	sc_out=$(shellcheck "$file" 2>&1)
	sc_rc=$?
	if [[ $sc_rc -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "$sc_out"
	fi
	return 0
}

run_shellcheck "6a: pulse-merge-stuck.sh passes shellcheck" "$MODULE"
run_shellcheck "6b: pulse-stats-helper.sh passes shellcheck" "$STATS_HELPER"
echo ""

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ===${TEST_NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
