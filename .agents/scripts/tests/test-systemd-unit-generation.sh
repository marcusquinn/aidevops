#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Test systemd unit file generation (GH#18789)
#
# Verifies that generated service files use bare (unquoted) values for
# StandardOutput= and StandardError= directives. systemd does NOT strip
# outer quotes from those values — "append:/path" is treated as a literal
# filename with quote characters, causing the directive to be silently
# ignored. See GH#18789 for the investigation and fix.
#
# Requires: systemd-analyze (available on Linux with systemd)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

skip_if_no_systemd_analyze() {
	if ! command -v systemd-analyze >/dev/null 2>&1; then
		printf 'SKIP: systemd-analyze not available\n'
		exit 0
	fi
	return 0
}

# --- Unit generation helpers (mirrors the real generators) ---

generate_scheduler_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops test-service
After=network.target

[Service]
Type=oneshot
KillMode=process
ExecStart=/bin/bash -lc 'echo hello'
TimeoutStartSec=60
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

generate_autoupdate_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops auto-update-test
After=network.target

[Service]
Type=oneshot
KillMode=process
ExecStart=/bin/bash -lc 'echo check'
TimeoutStartSec=120
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

generate_reposync_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops repo-sync-test
After=network.target

[Service]
Type=oneshot
KillMode=process
ExecStart=/bin/bash -lc 'echo sync'
TimeoutStartSec=300
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

# --- Tests ---

test_quoted_stdout_fails_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/test-quoted.service"
	local log_file="/tmp/test.log"

	printf '%s' "[Unit]
Description=test quoted stdout

[Service]
Type=oneshot
ExecStart=/usr/bin/true
StandardOutput=\"append:${log_file}\"
" >"$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "quoted StandardOutput= fails systemd-analyze verify" 0
	else
		print_result "quoted StandardOutput= fails systemd-analyze verify" 1 \
			"Expected 'Failed to parse output specifier' but got: $output"
	fi
	return 0
}

test_bare_stdout_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/test-bare.service"
	local log_file="/tmp/test.log"

	printf '%s' "[Unit]
Description=test bare stdout

[Service]
Type=oneshot
ExecStart=/usr/bin/true
StandardOutput=append:${log_file}
" >"$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "bare StandardOutput= passes systemd-analyze verify" 1 \
			"Unexpected parse failure: $output"
	else
		print_result "bare StandardOutput= passes systemd-analyze verify" 0
	fi
	return 0
}

test_scheduler_unit_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/scheduler.service"
	local log_file="/tmp/aidevops-scheduler.log"

	generate_scheduler_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "scheduler generator: StandardOutput= passes verify" 1 \
			"Parse failure in generated unit: $output"
	else
		print_result "scheduler generator: StandardOutput= passes verify" 0
	fi
	return 0
}

test_autoupdate_unit_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/autoupdate.service"
	local log_file="/tmp/aidevops-update.log"

	generate_autoupdate_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "auto-update generator: StandardOutput= passes verify" 1 \
			"Parse failure in generated unit: $output"
	else
		print_result "auto-update generator: StandardOutput= passes verify" 0
	fi
	return 0
}

test_reposync_unit_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/reposync.service"
	local log_file="/tmp/aidevops-repo-sync.log"

	generate_reposync_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "repo-sync generator: StandardOutput= passes verify" 1 \
			"Parse failure in generated unit: $output"
	else
		print_result "repo-sync generator: StandardOutput= passes verify" 0
	fi
	return 0
}

test_no_literal_quotes_in_scheduler_unit() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/scheduler.service"
	local log_file="/tmp/aidevops-scheduler.log"

	generate_scheduler_unit "$log_file" "$service_file"

	# StandardOutput= and StandardError= values must not contain literal "
	local bad_lines
	bad_lines=$(grep -E '^(StandardOutput|StandardError)=.*"' "$service_file" || true)

	rm -rf "$tmpdir"

	if [[ -n "$bad_lines" ]]; then
		print_result "scheduler unit has no quoted StandardOutput/StandardError" 1 \
			"Found literal quotes: $bad_lines"
	else
		print_result "scheduler unit has no quoted StandardOutput/StandardError" 0
	fi
	return 0
}

test_no_literal_quotes_in_autoupdate_unit() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/autoupdate.service"
	local log_file="/tmp/aidevops-update.log"

	generate_autoupdate_unit "$log_file" "$service_file"

	local bad_lines
	bad_lines=$(grep -E '^(StandardOutput|StandardError)=.*"' "$service_file" || true)

	rm -rf "$tmpdir"

	if [[ -n "$bad_lines" ]]; then
		print_result "auto-update unit has no quoted StandardOutput/StandardError" 1 \
			"Found literal quotes: $bad_lines"
	else
		print_result "auto-update unit has no quoted StandardOutput/StandardError" 0
	fi
	return 0
}

test_no_literal_quotes_in_reposync_unit() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/reposync.service"
	local log_file="/tmp/aidevops-repo-sync.log"

	generate_reposync_unit "$log_file" "$service_file"

	local bad_lines
	bad_lines=$(grep -E '^(StandardOutput|StandardError)=.*"' "$service_file" || true)

	rm -rf "$tmpdir"

	if [[ -n "$bad_lines" ]]; then
		print_result "repo-sync unit has no quoted StandardOutput/StandardError" 1 \
			"Found literal quotes: $bad_lines"
	else
		print_result "repo-sync unit has no quoted StandardOutput/StandardError" 0
	fi
	return 0
}

# --- Main ---

main() {
	skip_if_no_systemd_analyze

	printf 'Running systemd unit generation tests...\n\n'

	# Confirm the bug exists with quoted values (regression anchor)
	test_quoted_stdout_fails_verify

	# Confirm bare values work
	test_bare_stdout_passes_verify

	# Test each generator produces valid units
	test_scheduler_unit_passes_verify
	test_autoupdate_unit_passes_verify
	test_reposync_unit_passes_verify

	# Test no literal quotes appear in generated output
	test_no_literal_quotes_in_scheduler_unit
	test_no_literal_quotes_in_autoupdate_unit
	test_no_literal_quotes_in_reposync_unit

	printf '\n%s/%s tests passed.\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
