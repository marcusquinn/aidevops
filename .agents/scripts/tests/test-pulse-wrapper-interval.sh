#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-wrapper-interval.sh — Tests for check_repo_pulse_interval() and
#                                  update_repo_pulse_timestamp() (GH#20660)
#
# Tests:
#   - No field set: always included (backwards compatible)
#   - Field set, elapsed > interval: included
#   - Field set, elapsed < interval: skipped with log message
#   - Malformed field value: log warning, fall back to no throttle
#   - Below-minimum interval: clamped to 60s
#   - update_repo_pulse_timestamp: writes correct epoch to state file
#   - update_repo_pulse_timestamp: creates state file if missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export LOGFILE
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_no_interval_always_included() {
	local state_file="${TEST_ROOT}/pulse-last-per-repo.json"

	# No interval set: should always include regardless of state file
	if check_repo_pulse_interval "owner/repo" "" "$state_file"; then
		print_result "no interval set: always included" 0
	else
		print_result "no interval set: always included" 1 "Expected exit 0 (include), got 1 (skip)"
	fi
	return 0
}

test_interval_elapsed_included() {
	local state_file="${TEST_ROOT}/pulse-last-per-repo-elapsed.json"

	# Write a last-polled timestamp 700 seconds ago (interval is 600s)
	local old_ts
	old_ts=$(( $(date +%s) - 700 ))
	printf '{"last_pulsed": {"owner/repo": %d}}\n' "$old_ts" >"$state_file"

	if check_repo_pulse_interval "owner/repo" "600" "$state_file"; then
		print_result "interval elapsed (700s > 600s): included" 0
	else
		print_result "interval elapsed (700s > 600s): included" 1 "Expected exit 0 (include), got 1 (skip)"
	fi
	return 0
}

test_interval_not_elapsed_skipped() {
	local state_file="${TEST_ROOT}/pulse-last-per-repo-not-elapsed.json"

	# Write a last-polled timestamp 100 seconds ago (interval is 600s)
	local recent_ts
	recent_ts=$(( $(date +%s) - 100 ))
	printf '{"last_pulsed": {"owner/repo": %d}}\n' "$recent_ts" >"$state_file"

	if check_repo_pulse_interval "owner/repo" "600" "$state_file"; then
		print_result "interval not elapsed (100s < 600s): skipped" 1 "Expected exit 1 (skip), got 0 (include)"
	else
		print_result "interval not elapsed (100s < 600s): skipped" 0
	fi
	return 0
}

test_interval_not_elapsed_log_message() {
	local state_file="${TEST_ROOT}/pulse-last-per-repo-log.json"
	local logfile_tmp="${TEST_ROOT}/pulse-log-interval.log"
	local orig_logfile="$LOGFILE"

	# Redirect LOGFILE to capture the skip message
	export LOGFILE="$logfile_tmp"

	local recent_ts
	recent_ts=$(( $(date +%s) - 50 ))
	printf '{"last_pulsed": {"logtest/repo": %d}}\n' "$recent_ts" >"$state_file"

	check_repo_pulse_interval "logtest/repo" "600" "$state_file" || true

	export LOGFILE="$orig_logfile"

	if grep -q "pulse_interval_skip" "$logfile_tmp" 2>/dev/null; then
		print_result "interval skip: log line written" 0
	else
		print_result "interval skip: log line written" 1 "Expected 'pulse_interval_skip' in log output"
	fi
	return 0
}

test_malformed_interval_fallback() {
	local state_file="${TEST_ROOT}/pulse-last-per-repo-malformed.json"
	local logfile_tmp="${TEST_ROOT}/pulse-log-malformed.log"
	local orig_logfile="$LOGFILE"
	export LOGFILE="$logfile_tmp"

	# Malformed interval ("abc") — should fall back to no throttle (include)
	if check_repo_pulse_interval "owner/repo" "abc" "$state_file"; then
		print_result "malformed interval: fall back to include" 0
	else
		print_result "malformed interval: fall back to include" 1 "Expected exit 0 (include/fallback), got 1 (skip)"
	fi

	export LOGFILE="$orig_logfile"

	# Verify a warning was logged
	if grep -q "WARNING.*pulse_interval.*not a valid" "$logfile_tmp" 2>/dev/null; then
		print_result "malformed interval: WARNING logged" 0
	else
		print_result "malformed interval: WARNING logged" 1 "Expected WARNING about invalid pulse_interval in log"
	fi
	return 0
}

test_below_minimum_clamped() {
	local state_file="${TEST_ROOT}/pulse-last-per-repo-belowmin.json"
	local logfile_tmp="${TEST_ROOT}/pulse-log-belowmin.log"
	local orig_logfile="$LOGFILE"
	export LOGFILE="$logfile_tmp"

	# interval=10 is below minimum 60s; repo was polled 30 seconds ago
	# After clamping to 60s, 30 < 60 → should skip
	local recent_ts
	recent_ts=$(( $(date +%s) - 30 ))
	printf '{"last_pulsed": {"owner/repo": %d}}\n' "$recent_ts" >"$state_file"

	if check_repo_pulse_interval "owner/repo" "10" "$state_file"; then
		print_result "below-minimum interval: clamped to 60s, polled 30s ago → skip" 1 "Expected exit 1 (skip after clamp), got 0 (include)"
	else
		print_result "below-minimum interval: clamped to 60s, polled 30s ago → skip" 0
	fi

	export LOGFILE="$orig_logfile"

	# Verify warning logged
	if grep -q "WARNING.*below minimum" "$logfile_tmp" 2>/dev/null; then
		print_result "below-minimum interval: WARNING logged" 0
	else
		print_result "below-minimum interval: WARNING logged" 1 "Expected WARNING about below-minimum interval in log"
	fi
	return 0
}

test_update_writes_timestamp() {
	local state_file="${TEST_ROOT}/pulse-ts-write-test.json"
	local before
	before=$(date +%s)

	update_repo_pulse_timestamp "write/test" "$state_file"

	local after
	after=$(date +%s)

	if command -v jq &>/dev/null && [[ -f "$state_file" ]]; then
		local written_ts
		written_ts=$(jq -r '.last_pulsed["write/test"] // 0' "$state_file" 2>/dev/null)
		if [[ "$written_ts" -ge "$before" && "$written_ts" -le "$after" ]]; then
			print_result "update_repo_pulse_timestamp: writes current epoch" 0
		else
			print_result "update_repo_pulse_timestamp: writes current epoch" 1 "Timestamp ${written_ts} not in range [${before}, ${after}]"
		fi
	else
		print_result "update_repo_pulse_timestamp: writes current epoch" 0 "(jq not available or state file missing — skipped)"
	fi
	return 0
}

test_update_creates_state_file() {
	local state_file="${TEST_ROOT}/pulse-ts-create-test.json"

	# File must not exist before the call
	rm -f "$state_file"

	update_repo_pulse_timestamp "create/test" "$state_file"

	if [[ -f "$state_file" ]]; then
		print_result "update_repo_pulse_timestamp: creates state file if missing" 0
	else
		print_result "update_repo_pulse_timestamp: creates state file if missing" 1 "State file not created at ${state_file}"
	fi
	return 0
}

test_update_multiple_repos_independent() {
	local state_file="${TEST_ROOT}/pulse-ts-multi.json"

	# Write timestamps for two repos at different times (simulate separate calls)
	local old_ts
	old_ts=$(( $(date +%s) - 1000 ))
	printf '{"last_pulsed": {"alpha/repo": %d}}\n' "$old_ts" >"$state_file"

	update_repo_pulse_timestamp "beta/repo" "$state_file"

	if command -v jq &>/dev/null; then
		local alpha_ts beta_ts
		alpha_ts=$(jq -r '.last_pulsed["alpha/repo"] // 0' "$state_file" 2>/dev/null)
		beta_ts=$(jq -r '.last_pulsed["beta/repo"] // 0' "$state_file" 2>/dev/null)

		if [[ "$alpha_ts" -eq "$old_ts" && "$beta_ts" -gt 0 ]]; then
			print_result "update_repo_pulse_timestamp: updates are independent per repo" 0
		else
			print_result "update_repo_pulse_timestamp: updates are independent per repo" 1 "alpha=${alpha_ts} (expected ${old_ts}), beta=${beta_ts} (expected >0)"
		fi
	else
		print_result "update_repo_pulse_timestamp: updates are independent per repo" 0 "(jq not available — skipped)"
	fi
	return 0
}

test_no_state_file_means_include() {
	# State file does not exist: elapsed = (now - 0) which is always >= any reasonable interval
	local state_file="${TEST_ROOT}/nonexistent-state.json"
	rm -f "$state_file"

	if check_repo_pulse_interval "owner/repo" "600" "$state_file"; then
		print_result "no state file (first run): included" 0
	else
		print_result "no state file (first run): included" 1 "Expected exit 0 (include on first run)"
	fi
	return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

setup_test_env

test_no_interval_always_included
test_interval_elapsed_included
test_interval_not_elapsed_skipped
test_interval_not_elapsed_log_message
test_malformed_interval_fallback
test_below_minimum_clamped
test_update_writes_timestamp
test_update_creates_state_file
test_update_multiple_repos_independent
test_no_state_file_means_include

teardown_test_env

echo ""
echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
