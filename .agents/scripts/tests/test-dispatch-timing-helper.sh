#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# test-dispatch-timing-helper.sh — t3003 helper unit tests.
#
# Covers:
#   1. Bootstrap default with no records
#   2. Bootstrap default with <3 successes
#   3. EWMA convergence after sufficient successes
#   4. Probe-mode escalation after timeout
#   5. MIN/MAX clamps
#   6. File-corruption recovery (malformed JSONL line ignored)
#   7. Concurrent-write safety (two parallel record calls don't corrupt state)
#   8. Stats output (text + JSON)
#   9. Reset clears state
#   10. Window trimming (>WINDOW records → only last N considered)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../dispatch-timing-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "FAIL: helper not found or not executable at $HELPER" >&2
	exit 1
fi

# Isolate state to a temp file so we don't pollute production state.
# Note: extension dropped — mktemp portability rule (t2997) requires XXXXXX
# at the end of the template. The helper accepts any path via env var.
TEST_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/t3003-test-XXXXXX")"
export DISPATCH_TIMING_STATE_FILE="$TEST_STATE_FILE"
export DISPATCH_TIMING_BOOTSTRAP_MS=90000
export DISPATCH_TIMING_MIN_TIMEOUT_MS=30000
export DISPATCH_TIMING_MAX_TIMEOUT_MS=300000
export DISPATCH_TIMING_WINDOW=20
export DISPATCH_TIMING_EWMA_ALPHA_PCT=30
export DISPATCH_TIMING_SAFETY_MULT_PCT=200
export DISPATCH_TIMING_PROBE_MULT_PCT=200

PASS=0
FAIL=0
FAILURES=()

cleanup() {
	rm -f "$TEST_STATE_FILE" "${TEST_STATE_FILE}.1" 2>/dev/null
	rm -rf "${TEST_STATE_FILE}.lock.d" 2>/dev/null
	return 0
}
trap cleanup EXIT

_assert_eq() {
	local label="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS: %s (got %s)\n' "$label" "$actual"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label: expected '$expected', got '$actual'")
		printf '  FAIL: %s — expected %s, got %s\n' "$label" "$expected" "$actual"
	fi
	return 0
}

_assert_in_range() {
	local label="$1"
	local actual="$2"
	local lo="$3"
	local hi="$4"
	if [[ "$actual" =~ ^[0-9]+$ ]] && ((actual >= lo && actual <= hi)); then
		PASS=$((PASS + 1))
		printf '  PASS: %s (got %s in [%s,%s])\n' "$label" "$actual" "$lo" "$hi"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label: expected $lo<=value<=$hi, got '$actual'")
		printf '  FAIL: %s — expected [%s,%s], got %s\n' "$label" "$lo" "$hi" "$actual"
	fi
	return 0
}

_reset_state() {
	rm -f "$DISPATCH_TIMING_STATE_FILE" "${DISPATCH_TIMING_STATE_FILE}.1" 2>/dev/null
	rm -rf "${DISPATCH_TIMING_STATE_FILE}.lock.d" 2>/dev/null
	return 0
}

_record() {
	local outcome="$1"
	local elapsed_ms="$2"
	local timeout_ms="${3:-30000}"
	"$HELPER" record \
		--repo "owner/repo" --issue "1" --outcome "$outcome" \
		--elapsed-ms "$elapsed_ms" --timeout-used-ms "$timeout_ms" \
		>/dev/null 2>&1
	return $?
}

# ---------------------------------------------------------------------------
# Test 1: Bootstrap default (no records)
# ---------------------------------------------------------------------------
test_bootstrap_no_records() {
	echo "Test 1: bootstrap with no records"
	_reset_state
	local result
	result=$("$HELPER" recommend)
	_assert_eq "no records → bootstrap default" "$result" "90000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Bootstrap with <3 successes
# ---------------------------------------------------------------------------
test_bootstrap_insufficient_successes() {
	echo "Test 2: bootstrap with <3 successes"
	_reset_state
	_record success 5000
	_record success 5500
	local result
	result=$("$HELPER" recommend)
	_assert_eq "2 successes → bootstrap default" "$result" "90000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: EWMA convergence — 5 successes ~5s should give recommendation
#         floor-clamped to 30000ms (since EWMA*2 ~ 10s < 30s floor)
# ---------------------------------------------------------------------------
test_ewma_low_avg_clamped_to_floor() {
	echo "Test 3: EWMA with low avg → clamped to MIN floor"
	_reset_state
	_record success 4500
	_record success 5000
	_record success 5500
	_record success 4800
	_record success 5200
	local result
	result=$("$HELPER" recommend)
	_assert_eq "5 successes ~5s → clamped to MIN floor 30000" "$result" "30000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: EWMA — high avg, recommendation reflects EWMA*2 (above floor)
# ---------------------------------------------------------------------------
test_ewma_high_avg_above_floor() {
	echo "Test 4: EWMA with high avg → recommendation tracks EWMA*2"
	_reset_state
	# 5 successes averaging ~25s: EWMA*2 ~ 50s = 50000ms (above 30s floor)
	_record success 25000
	_record success 26000
	_record success 24000
	_record success 25500
	_record success 24500
	local result
	result=$("$HELPER" recommend)
	# Expected range: EWMA*2 should be ~50000, p95 ~26000, max → ~50000
	# Allow wide range since EWMA depends on order
	_assert_in_range "5 successes ~25s → ~50000ms" "$result" "40000" "65000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Probe mode after timeout
# ---------------------------------------------------------------------------
test_probe_mode_after_timeout() {
	echo "Test 5: probe mode after timeout (last record = timeout)"
	_reset_state
	# Establish baseline of low successes first
	_record success 4000
	_record success 5000
	_record success 4500
	_record success 5500
	_record success 5000
	# Then timeout at 30s
	_record timeout 30000 30000
	local result
	result=$("$HELPER" recommend)
	# Probe mode: max(recommended, last_timeout × 2) = max(~30s, 60s) = 60000
	_assert_eq "timeout → probe = 2×timeout = 60000" "$result" "60000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: Probe mode escalates with successive timeouts
# ---------------------------------------------------------------------------
test_probe_mode_escalation() {
	echo "Test 6: probe mode escalates with successive timeouts"
	_reset_state
	_record success 5000
	_record success 5000
	_record success 5000
	_record success 5000
	_record success 5000
	_record timeout 60000 60000
	local result
	result=$("$HELPER" recommend)
	# Last timeout used 60000 → probe = 60000 × 2 = 120000
	_assert_eq "60s timeout → probe = 120000" "$result" "120000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: MAX_TIMEOUT clamp
# ---------------------------------------------------------------------------
test_max_timeout_clamp() {
	echo "Test 7: MAX_TIMEOUT clamp"
	_reset_state
	# Establish high baseline so EWMA pushes above MAX
	_record success 200000
	_record success 200000
	_record success 200000
	_record success 200000
	_record success 200000
	local result
	result=$("$HELPER" recommend)
	# EWMA*2 = 400000, but MAX = 300000 → clamped
	_assert_eq "EWMA above MAX → clamped to 300000" "$result" "300000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: File-corruption recovery — malformed line is ignored
# ---------------------------------------------------------------------------
test_corruption_recovery() {
	echo "Test 8: corruption recovery — malformed JSONL ignored"
	_reset_state
	_record success 5000
	# Inject corruption directly
	printf 'NOT VALID JSON\n' >>"$DISPATCH_TIMING_STATE_FILE"
	printf '{"ts":"foo","outcome":"" broken\n' >>"$DISPATCH_TIMING_STATE_FILE"
	_record success 5500
	_record success 4800
	_record success 5200
	local result
	result=$("$HELPER" recommend)
	# Should still produce a valid recommendation, not crash.
	_assert_in_range "corruption tolerated → valid output" "$result" "30000" "300000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: Concurrent-write safety
# ---------------------------------------------------------------------------
test_concurrent_writes() {
	echo "Test 9: concurrent writes don't corrupt state"
	_reset_state
	# Fire 10 concurrent record calls. Use direct backgrounding (not subshell
	# wrapping) so the outer `wait` actually blocks until each child exits.
	local i pids=()
	for i in $(seq 1 10); do
		_record success $((4000 + i * 100)) &
		pids+=($!)
	done
	# Wait for each PID explicitly (more robust than bare `wait`)
	for i in "${pids[@]}"; do
		wait "$i" 2>/dev/null || true
	done
	# All 10 records should be present, no half-written lines
	local line_count
	line_count=$(wc -l <"$DISPATCH_TIMING_STATE_FILE" 2>/dev/null | tr -d ' ')
	[[ -z "$line_count" ]] && line_count=0
	_assert_eq "10 concurrent writes → 10 lines" "$line_count" "10"
	# Each line should be valid JSON-ish (starts with `{`, ends with `}`)
	local malformed_count
	malformed_count=$(grep -cv '^{.*}$' "$DISPATCH_TIMING_STATE_FILE" 2>/dev/null || true)
	[[ "$malformed_count" =~ ^[0-9]+$ ]] || malformed_count=0
	_assert_eq "no malformed lines from concurrent writes" "$malformed_count" "0"
	# Recommend should still produce valid output
	local result
	result=$("$HELPER" recommend)
	_assert_in_range "post-concurrent recommend valid" "$result" "30000" "300000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: Stats output (text + JSON)
# ---------------------------------------------------------------------------
test_stats_output() {
	echo "Test 10: stats output"
	_reset_state
	_record success 5000
	_record success 6000
	_record success 7000
	_record timeout 30000 30000
	# Text
	local text_out
	text_out=$("$HELPER" stats 2>&1)
	if [[ "$text_out" == *"successes:"* && "$text_out" == *"recommended:"* ]]; then
		PASS=$((PASS + 1))
		echo "  PASS: stats text contains expected fields"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("stats text missing fields: $text_out")
		echo "  FAIL: stats text missing fields"
	fi
	# JSON
	local json_out
	json_out=$("$HELPER" stats --json 2>&1)
	if [[ "$json_out" == *'"recommended_ms":'* && "$json_out" == *'"successes":3'* ]]; then
		PASS=$((PASS + 1))
		echo "  PASS: stats --json valid"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("stats --json malformed: $json_out")
		echo "  FAIL: stats --json malformed"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 11: Reset clears state
# ---------------------------------------------------------------------------
test_reset() {
	echo "Test 11: reset clears state"
	_reset_state
	_record success 5000
	"$HELPER" reset >/dev/null
	local result
	result=$("$HELPER" recommend)
	_assert_eq "after reset → bootstrap default" "$result" "90000"
	return 0
}

# ---------------------------------------------------------------------------
# Test 12: Window trimming — only last N records considered
# ---------------------------------------------------------------------------
test_window_limit() {
	echo "Test 12: window limits how many records contribute"
	_reset_state
	# 25 records: first 5 are huge (200000), last 20 are small (5000)
	# Window is 20 → only the small ones should drive EWMA.
	local i
	for i in $(seq 1 5); do
		_record success 200000 >/dev/null 2>&1
	done
	for i in $(seq 1 20); do
		_record success 5000 >/dev/null 2>&1
	done
	local result
	result=$("$HELPER" recommend)
	# Only last 20 small records → EWMA ~5000 → *2 = 10000 → clamped to MIN 30000
	_assert_eq "window=20 ignores oldest 5 huge records" "$result" "30000"
	return 0
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

_run_tests() {
	echo "===== dispatch-timing-helper.sh tests ====="
	test_bootstrap_no_records
	test_bootstrap_insufficient_successes
	test_ewma_low_avg_clamped_to_floor
	test_ewma_high_avg_above_floor
	test_probe_mode_after_timeout
	test_probe_mode_escalation
	test_max_timeout_clamp
	test_corruption_recovery
	test_concurrent_writes
	test_stats_output
	test_reset
	test_window_limit

	echo ""
	echo "===== Summary ====="
	echo "PASS: $PASS"
	echo "FAIL: $FAIL"
	if ((FAIL > 0)); then
		echo ""
		echo "Failures:"
		local f
		for f in "${FAILURES[@]}"; do
			echo "  - $f"
		done
		return 1
	fi
	return 0
}

_run_tests
exit $?
