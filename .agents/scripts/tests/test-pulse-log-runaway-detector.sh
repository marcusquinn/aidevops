#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-log-runaway-detector.sh — Unit tests for pulse-log-runaway-detector.sh
#
# Covers: absolute cap hit, growth rate hit, repetition pattern hit,
# healthy-log no-op, missing-file fail-open.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="${SCRIPT_DIR}/pulse-log-runaway-detector.sh"

_PASS=0
_FAIL=0
_TEST_TMPDIR=""

#######################################
# _setup — create a fresh temp directory for each test.
# Returns: 0
#######################################
_setup() {
	_TEST_TMPDIR=$(mktemp -d)
	export WRAPPER_LOGFILE="${_TEST_TMPDIR}/pulse-wrapper.log"
	export PULSE_WRAPPER_LOG_LAST_SIZE_FILE="${_TEST_TMPDIR}/last-size"
	export PULSE_LOG_ARCHIVE_DIR="${_TEST_TMPDIR}/archive"
	mkdir -p "$PULSE_LOG_ARCHIVE_DIR"
	return 0
}

#######################################
# _teardown — clean up temp directory.
# Returns: 0
#######################################
_teardown() {
	[[ -n "$_TEST_TMPDIR" ]] && rm -rf "$_TEST_TMPDIR"
	return 0
}

#######################################
# _assert — check condition and record result.
# Arguments:
#   $1 — test name
#   $2 — condition (0=pass, non-zero=fail)
# Returns: 0
#######################################
_assert() {
	local name="$1"
	local result="$2"
	if [[ "$result" == "0" ]]; then
		printf '  PASS: %s\n' "$name"
		_PASS=$((_PASS + 1))
	else
		printf '  FAIL: %s\n' "$name" >&2
		_FAIL=$((_FAIL + 1))
	fi
	return 0
}

# ===== Test 1: Absolute cap hit =====
test_absolute_cap_hit() {
	printf 'Test 1: Absolute cap hit\n'
	_setup

	# Create a file larger than the default 500MB cap
	# Use truncate for speed (creates a sparse file)
	truncate -s 600M "$WRAPPER_LOGFILE"

	# Run detector
	bash "$DETECTOR" check-and-heal 2>/dev/null

	# Verify: wrapper log was truncated (size should be near 0)
	local after_size=0
	after_size=$(wc -c <"$WRAPPER_LOGFILE" 2>/dev/null || echo "999999999")
	after_size="${after_size//[[:space:]]/}"
	[[ "$after_size" =~ ^[0-9]+$ ]] || after_size=999999999

	local result=1
	[[ "$after_size" -lt 1048576 ]] && result=0
	_assert "wrapper log truncated after cap hit" "$result"

	# Verify: archive was created
	local archive_count=0
	archive_count=$(find "$PULSE_LOG_ARCHIVE_DIR" -name "pulse-wrapper-*.log.gz" 2>/dev/null | wc -l)
	archive_count="${archive_count//[[:space:]]/}"
	local archive_result=1
	[[ "$archive_count" -gt 0 ]] && archive_result=0
	_assert "archive file created" "$archive_result"

	# Verify: advisory written
	local advisory_result=1
	[[ -f "${_TEST_TMPDIR}/../cache/pulse-wrapper-log-runaway-advisory.txt" ]] || \
	[[ -f "${HOME}/.aidevops/cache/pulse-wrapper-log-runaway-advisory.txt" ]] && advisory_result=0
	_assert "advisory stamp written" "$advisory_result"

	_teardown
	return 0
}

# ===== Test 2: Growth rate hit =====
test_growth_rate_hit() {
	printf 'Test 2: Growth rate hit\n'
	_setup

	# Seed a last-size sentinel with a small number, very recently
	printf '0' >"$PULSE_WRAPPER_LOG_LAST_SIZE_FILE"
	# Touch to set mtime to now (age ~0s)
	touch "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE"
	# Brief sleep so age > 0
	sleep 1

	# Create a 200MB file (growth of 200MB in ~1s = >>100MB/min)
	truncate -s 200M "$WRAPPER_LOGFILE"

	bash "$DETECTOR" check-and-heal 2>/dev/null

	# Verify: wrapper log was truncated
	local after_size=0
	after_size=$(wc -c <"$WRAPPER_LOGFILE" 2>/dev/null || echo "999999999")
	after_size="${after_size//[[:space:]]/}"
	[[ "$after_size" =~ ^[0-9]+$ ]] || after_size=999999999

	local result=1
	[[ "$after_size" -lt 1048576 ]] && result=0
	_assert "wrapper log truncated on growth-rate hit" "$result"

	_teardown
	return 0
}

# ===== Test 3: Repetition pattern hit =====
test_repetition_pattern_hit() {
	printf 'Test 3: Repetition pattern hit\n'
	_setup

	# Create a file with highly repetitive content (>100KB, <500MB cap)
	# 200KB of the same line repeated
	export PULSE_WRAPPER_LOG_RUNAWAY_BYTES=1073741824  # Set cap high so absolute check doesn't trigger
	local i=0
	while [[ "$i" -lt 5000 ]]; do
		printf 'wait: pid 12345 is not a child of this shell\n' >>"$WRAPPER_LOGFILE"
		i=$((i + 1))
	done

	# Run without growth rate sentinel so only repetition check fires
	# (remove sentinel to give growth check a pass since it'll record first size)
	rm -f "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE"

	bash "$DETECTOR" check-and-heal 2>/dev/null

	# Check that advisory was written (repetition detection is advisory-only,
	# doesn't necessarily rotate on its own if under size cap)
	local advisory_result=1
	[[ -f "${HOME}/.aidevops/cache/pulse-wrapper-log-runaway-advisory.txt" ]] && advisory_result=0
	_assert "advisory written on repetition pattern" "$advisory_result"

	_teardown
	return 0
}

# ===== Test 4: Healthy log no-op =====
test_healthy_log_noop() {
	printf 'Test 4: Healthy log no-op\n'
	_setup

	# Create a small, diverse log (well under cap)
	local i=0
	while [[ "$i" -lt 50 ]]; do
		printf '[pulse-wrapper] cycle %d complete at %s\n' "$i" "$(date)" >>"$WRAPPER_LOGFILE"
		i=$((i + 1))
	done

	# Remove any previous advisory
	rm -f "${HOME}/.aidevops/cache/pulse-wrapper-log-runaway-advisory.txt" 2>/dev/null || true

	bash "$DETECTOR" check-and-heal 2>/dev/null

	# Verify: no archive was created
	local archive_count=0
	archive_count=$(find "$PULSE_LOG_ARCHIVE_DIR" -name "pulse-wrapper-*.log.gz" 2>/dev/null | wc -l)
	archive_count="${archive_count//[[:space:]]/}"

	local result=1
	[[ "$archive_count" == "0" ]] && result=0
	_assert "no rotation on healthy log" "$result"

	_teardown
	return 0
}

# ===== Test 5: Missing file fail-open =====
test_missing_file_failopen() {
	printf 'Test 5: Missing file fail-open\n'
	_setup

	# Remove the wrapper log — detector should exit 0 gracefully
	rm -f "$WRAPPER_LOGFILE"

	local exit_code=0
	bash "$DETECTOR" check-and-heal 2>/dev/null || exit_code=$?

	_assert "exit 0 on missing file" "$exit_code"

	_teardown
	return 0
}

# ===== Run all tests =====
printf '=== pulse-log-runaway-detector tests ===\n\n'

test_absolute_cap_hit
test_growth_rate_hit
test_repetition_pattern_hit
test_healthy_log_noop
test_missing_file_failopen

printf '\n=== Results: %d passed, %d failed ===\n' "$_PASS" "$_FAIL"

if [[ "$_FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
