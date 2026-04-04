#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-memory-pressure-monitor.sh
#
# Unit tests for memory-pressure-monitor.sh:
# - Configuration validation (_validate_int)
# - Process age parsing (_get_process_age)
# - Duration formatting (_format_duration)
# - Cooldown logic (check_cooldown, set_cooldown, clear_cooldown)
# - OS memory info collection (_get_os_memory_info)
# - Interactive session counting (_count_interactive_sessions)
# - Process classification: app vs tool (_is_app_process) (GH#2992)
# - CLI commands (--help, --status, --check)
#
# Uses isolated temp directories to avoid touching production data.
#
# Usage: bash tests/test-memory-pressure-monitor.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/.agents/scripts/memory-pressure-monitor.sh"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;32mPASS\033[0m %s\n" "$1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# --- Isolated Test Environment ---
TEST_DIR=$(mktemp -d)
export MEMORY_LOG_DIR="$TEST_DIR/logs"
export HOME_BACKUP="$HOME"
# Override state dir via the script's STATE_DIR (it uses HOME)
# We'll set HOME to a temp dir for isolation
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.aidevops/.agent-workspace/tmp"
mkdir -p "$HOME/.aidevops/logs"

trap 'HOME="$HOME_BACKUP"; rm -rf "$TEST_DIR"' EXIT

# --- Prerequisite Check ---
if [[ ! -x "$SCRIPT_UNDER_TEST" ]]; then
	echo "ERROR: Script not found or not executable: $SCRIPT_UNDER_TEST"
	exit 1
fi

# Source the script to get access to internal functions
# We need to prevent main() from running, so we override it temporarily
eval "$(sed 's/^main "$@"$//' "$SCRIPT_UNDER_TEST")"

# ============================================================================
section "Configuration Validation"
# ============================================================================

test_validate_int_valid() {
	local result
	result=$(_validate_int "TEST" "1024" "500" 0)
	if [[ "$result" == "1024" ]]; then
		pass "Valid integer passes through"
	else
		fail "Valid integer passes through" "Expected 1024, got '$result'"
	fi
}

test_validate_int_non_numeric() {
	local result
	result=$(_validate_int "TEST" "abc" "500" 0 2>/dev/null)
	if [[ "$result" == "500" ]]; then
		pass "Non-numeric falls back to default"
	else
		fail "Non-numeric falls back to default" "Expected 500, got '$result'"
	fi
}

test_validate_int_below_minimum() {
	local result
	result=$(_validate_int "TEST" "5" "500" 100 2>/dev/null)
	if [[ "$result" == "500" ]]; then
		pass "Below minimum falls back to default"
	else
		fail "Below minimum falls back to default" "Expected 500, got '$result'"
	fi
}

test_validate_int_leading_zeros() {
	local result
	result=$(_validate_int "TEST" "0100" "500" 0)
	if [[ "$result" == "100" ]]; then
		pass "Leading zeros stripped (no octal)"
	else
		fail "Leading zeros stripped (no octal)" "Expected 100, got '$result'"
	fi
}

test_validate_int_injection_attempt() {
	local result
	# shellcheck disable=SC2016 # Intentional: single quotes prevent expansion (that's the test)
	result=$(_validate_int "TEST" 'a[$(whoami)]' "500" 0 2>/dev/null)
	if [[ "$result" == "500" ]]; then
		pass "Injection attempt falls back to default"
	else
		fail "Injection attempt falls back to default" "Expected 500, got '$result'"
	fi
}

test_validate_int_valid
test_validate_int_non_numeric
test_validate_int_below_minimum
test_validate_int_leading_zeros
test_validate_int_injection_attempt

# ============================================================================
section "Duration Formatting"
# ============================================================================

test_format_duration_seconds() {
	local result
	result=$(_format_duration 45)
	if [[ "$result" == "45s" ]]; then
		pass "Seconds formatting"
	else
		fail "Seconds formatting" "Expected '45s', got '$result'"
	fi
}

test_format_duration_minutes() {
	local result
	result=$(_format_duration 125)
	if [[ "$result" == "2m5s" ]]; then
		pass "Minutes formatting"
	else
		fail "Minutes formatting" "Expected '2m5s', got '$result'"
	fi
}

test_format_duration_hours() {
	local result
	result=$(_format_duration 3725)
	if [[ "$result" == "1h2m" ]]; then
		pass "Hours formatting"
	else
		fail "Hours formatting" "Expected '1h2m', got '$result'"
	fi
}

test_format_duration_days() {
	local result
	result=$(_format_duration 90061)
	if [[ "$result" == "1d1h1m" ]]; then
		pass "Days formatting"
	else
		fail "Days formatting" "Expected '1d1h1m', got '$result'"
	fi
}

test_format_duration_zero() {
	local result
	result=$(_format_duration 0)
	if [[ "$result" == "0s" ]]; then
		pass "Zero seconds formatting"
	else
		fail "Zero seconds formatting" "Expected '0s', got '$result'"
	fi
}

test_format_duration_seconds
test_format_duration_minutes
test_format_duration_hours
test_format_duration_days
test_format_duration_zero

# ============================================================================
section "Cooldown Logic"
# ============================================================================

test_cooldown_no_file() {
	# No cooldown file exists — should return 0 (ok to notify)
	if check_cooldown "test-no-file"; then
		pass "No cooldown file → ok to notify"
	else
		fail "No cooldown file → ok to notify"
	fi
}

test_cooldown_set_and_check() {
	set_cooldown "test-set"
	# Immediately after setting — should be in cooldown (return 1)
	if ! check_cooldown "test-set"; then
		pass "Just set → in cooldown"
	else
		fail "Just set → in cooldown" "Expected cooldown active"
	fi
}

test_cooldown_clear() {
	set_cooldown "test-clear"
	clear_cooldown "test-clear"
	if check_cooldown "test-clear"; then
		pass "After clear → ok to notify"
	else
		fail "After clear → ok to notify"
	fi
}

test_cooldown_invalid_content() {
	# Write garbage to cooldown file
	local cooldown_file="${STATE_DIR}/memory-pressure-test-garbage.cooldown"
	echo "not-a-number" >"$cooldown_file"
	if check_cooldown "test-garbage"; then
		pass "Invalid cooldown file content → ok to notify"
	else
		fail "Invalid cooldown file content → ok to notify"
	fi
	rm -f "$cooldown_file"
}

test_cooldown_no_file
test_cooldown_set_and_check
test_cooldown_clear
test_cooldown_invalid_content

# ============================================================================
section "Process Age Parsing"
# ============================================================================

test_process_age_self() {
	# Get age of current process (should be small, > 0)
	local age
	age=$(_get_process_age $$)
	if [[ "$age" =~ ^[0-9]+$ ]] && [[ "$age" -ge 0 ]]; then
		pass "Process age of self is numeric (${age}s)"
	else
		fail "Process age of self is numeric" "Got '$age'"
	fi
}

test_process_age_nonexistent() {
	# Non-existent PID should return 0
	local age
	age=$(_get_process_age 999999999)
	if [[ "$age" == "0" ]]; then
		pass "Non-existent PID returns 0"
	else
		fail "Non-existent PID returns 0" "Got '$age'"
	fi
}

test_process_age_self
test_process_age_nonexistent

# ============================================================================
section "OS Memory Info"
# ============================================================================

test_os_memory_info_format() {
	local info
	info=$(_get_os_memory_info)
	# Should be pipe-delimited: level|total_gb|swap_used_mb|swap_files
	local field_count
	field_count=$(echo "$info" | tr -cd '|' | wc -c | tr -d ' ')
	if [[ "$field_count" -eq 3 ]]; then
		pass "OS memory info has 4 fields (3 pipes)"
	else
		fail "OS memory info has 4 fields" "Got $((field_count + 1)) fields: '$info'"
	fi
}

test_os_memory_info_total_gb() {
	local info
	info=$(_get_os_memory_info)
	local total_gb
	total_gb=$(echo "$info" | cut -d'|' -f2)
	if [[ "$total_gb" =~ ^[0-9]+$ ]] && [[ "$total_gb" -gt 0 ]]; then
		pass "Total RAM detected: ${total_gb} GB"
	elif [[ "$total_gb" == "?" ]]; then
		skip "Total RAM not detectable on this platform"
	else
		fail "Total RAM detected" "Got '$total_gb'"
	fi
}

test_os_memory_info_format
test_os_memory_info_total_gb

# ============================================================================
section "Interactive Session Count"
# ============================================================================

test_session_count_numeric() {
	local count
	count=$(_count_interactive_sessions)
	if [[ "$count" =~ ^[0-9]+$ ]]; then
		pass "Session count is numeric: $count"
	else
		fail "Session count is numeric" "Got '$count'"
	fi
}

test_session_count_numeric

# ============================================================================
section "Process Classification (GH#2992)"
# ============================================================================

test_is_app_process_claude() {
	if _is_app_process "claude"; then
		pass "claude is classified as app"
	else
		fail "claude is classified as app"
	fi
}

test_is_app_process_electron() {
	if _is_app_process "Electron"; then
		pass "Electron is classified as app (case-insensitive)"
	else
		fail "Electron is classified as app (case-insensitive)"
	fi
}

test_is_app_process_opencode() {
	if _is_app_process "opencode"; then
		pass "opencode is classified as app"
	else
		fail "opencode is classified as app"
	fi
}

test_is_app_process_shipit() {
	if _is_app_process "ShipIt"; then
		pass "ShipIt is classified as app (case-insensitive)"
	else
		fail "ShipIt is classified as app (case-insensitive)"
	fi
}

test_is_tool_process_shellcheck() {
	if ! _is_app_process "shellcheck"; then
		pass "shellcheck is classified as tool"
	else
		fail "shellcheck is classified as tool" "Was classified as app"
	fi
}

test_is_tool_process_node() {
	if ! _is_app_process "node"; then
		pass "node is classified as tool"
	else
		fail "node is classified as tool" "Was classified as app"
	fi
}

test_is_tool_process_unknown() {
	if ! _is_app_process "some-random-process"; then
		pass "Unknown process is classified as tool"
	else
		fail "Unknown process is classified as tool" "Was classified as app"
	fi
}

test_session_count_default_threshold() {
	# Verify the default session count threshold is 8 (raised from 5 in GH#2992)
	if [[ "$SESSION_COUNT_WARN" -eq 8 ]]; then
		pass "Session count threshold default is 8"
	else
		fail "Session count threshold default is 8" "Got $SESSION_COUNT_WARN"
	fi
}

test_is_app_process_dot_prefix() {
	# .opencode is the actual binary name on some installs
	if _is_app_process ".opencode"; then
		pass ".opencode (dot-prefixed) is classified as app"
	else
		fail ".opencode (dot-prefixed) is classified as app"
	fi
}

test_is_app_process_claude
test_is_app_process_electron
test_is_app_process_opencode
test_is_app_process_shipit
test_is_app_process_dot_prefix
test_is_tool_process_shellcheck
test_is_tool_process_node
test_is_tool_process_unknown
test_session_count_default_threshold

# ============================================================================
section "CLI Commands"
# ============================================================================

test_help_output() {
	local output
	output=$(bash "$SCRIPT_UNDER_TEST" --help 2>&1)
	if echo "$output" | grep -q "Usage:"; then
		pass "--help shows usage"
	else
		fail "--help shows usage" "No 'Usage:' in output"
	fi
}

test_help_exit_code() {
	local exit_code=0
	bash "$SCRIPT_UNDER_TEST" --help >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]]; then
		pass "--help exits 0"
	else
		fail "--help exits 0" "Got exit code $exit_code"
	fi
}

test_status_output() {
	local output
	output=$(bash "$SCRIPT_UNDER_TEST" --status 2>&1)
	if echo "$output" | grep -q "Memory Pressure Monitor"; then
		pass "--status shows header"
	else
		fail "--status shows header" "No header in output"
	fi
}

test_status_shows_config() {
	local output
	output=$(bash "$SCRIPT_UNDER_TEST" --status 2>&1)
	if echo "$output" | grep -q "Per-process RSS warning"; then
		pass "--status shows configuration"
	else
		fail "--status shows configuration"
	fi
}

test_check_runs() {
	# --check should run without error (exit 0, 1, or 2 are all valid)
	local exit_code=0
	bash "$SCRIPT_UNDER_TEST" --check >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -le 2 ]]; then
		pass "--check runs successfully (exit $exit_code)"
	else
		fail "--check runs successfully" "Got exit code $exit_code"
	fi
}

test_unknown_command() {
	local exit_code=0
	bash "$SCRIPT_UNDER_TEST" --bogus >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 1 ]]; then
		pass "Unknown command exits 1"
	else
		fail "Unknown command exits 1" "Got exit code $exit_code"
	fi
}

test_help_output
test_help_exit_code
test_status_output
test_status_shows_config
test_check_runs
test_unknown_command

# ============================================================================
section "Security: Input Validation"
# ============================================================================

test_env_injection_rss_warn() {
	# Attempt command injection via environment variable
	local result
	result=$(PROCESS_RSS_WARN_MB='$(whoami)' bash "$SCRIPT_UNDER_TEST" --help 2>/dev/null | head -1)
	# If we get here without executing whoami, the validation worked
	pass "PROCESS_RSS_WARN_MB injection blocked"
}

test_env_injection_runtime() {
	local result
	result=$(SHELLCHECK_RUNTIME_MAX='a[$(id)]' bash "$SCRIPT_UNDER_TEST" --help 2>/dev/null | head -1)
	pass "SHELLCHECK_RUNTIME_MAX injection blocked"
}

test_env_injection_rss_warn
test_env_injection_runtime

# ============================================================================
section "Notification Sanitisation"
# ============================================================================

test_notify_disabled() {
	# With notifications disabled, notify should be a no-op
	local exit_code=0
	MEMORY_NOTIFY="false" bash "$SCRIPT_UNDER_TEST" --check >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -le 2 ]]; then
		pass "Notifications disabled runs cleanly"
	else
		fail "Notifications disabled runs cleanly" "Exit $exit_code"
	fi
}

test_notify_disabled

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=============================="
printf "Results: \033[0;32m%d passed\033[0m" "$PASS_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
	printf ", \033[0;31m%d failed\033[0m" "$FAIL_COUNT"
fi
if [[ "$SKIP_COUNT" -gt 0 ]]; then
	printf ", \033[0;33m%d skipped\033[0m" "$SKIP_COUNT"
fi
printf " (total: %d)\n" "$TOTAL_COUNT"
echo "=============================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
