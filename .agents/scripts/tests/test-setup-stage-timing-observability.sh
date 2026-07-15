#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SETUP_SH="${SCRIPT_DIR}/../../../setup.sh"

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

test_time_step_logs_running_before_command() {
	local snippet=""
	snippet=$(perl -0ne 'print $1 if /(_time_step_log\(\) \{.*?^\}\n\n_time_step\(\) \{.*?^\})/ms' "$SETUP_SH")
	if [[ -z "$snippet" ]]; then
		print_result "_time_step extraction succeeds" 1 "timing helper block not found"
		return 0
	fi

	local tmp_home=""
	tmp_home=$(mktemp -d 2>/dev/null || mktemp -d -t setup-stage-timing)
	mkdir -p "${tmp_home}/.aidevops/logs"

	local output=""
	output=$(
		HOME="$tmp_home"
		eval "$snippet"
		print_info() {
			printf '%s\n' "$*"
			return 0
		}
		slow_stage() {
			local marker_file="$1"
			local timing_file="${HOME}/.aidevops/logs/setup-stage-timings.log"
			cp "$timing_file" "$marker_file"
			return 0
		}
		_time_step "update_claude_config" slow_stage "${tmp_home}/during.log"
		printf 'during=%s\n' "$(grep -c $'update_claude_config\t0.00\tRUNNING' "${tmp_home}/during.log" 2>/dev/null || true)"
		printf 'finished=%s\n' "$(grep -c $'update_claude_config\t.*\t0' "${tmp_home}/.aidevops/logs/setup-stage-timings.log" 2>/dev/null || true)"
	) 2>&1

	rm -rf "$tmp_home"

	if [[ "$output" == *"during=1"* && "$output" == *"finished=1"* ]]; then
		print_result "_time_step logs RUNNING before command and completion after" 0
		return 0
	fi

	print_result "_time_step logs RUNNING before command and completion after" 1 "output=${output}"
	return 0
}

test_noninteractive_cli_failure_continues_config_reconciliation() {
	local snippet=""
	snippet=$(perl -0ne 'print $1 if /(_setup_run_non_interactive\(\) \{.*?^\})/ms' "$SETUP_SH")
	if [[ -z "$snippet" ]]; then
		print_result "non-interactive setup extraction succeeds" 1 "setup function block not found"
		return 0
	fi

	local tmp_home=""
	tmp_home=$(mktemp -d 2>/dev/null || mktemp -d -t setup-cli-continuation)
	local trace_file="${tmp_home}/stages.log"
	local output_file="${tmp_home}/output.log"
	local status=0

	(
		set -e
		eval "$snippet"
		SETUP_STAGE_OPENCODE="opencode"
		SETUP_STAGE_AGENTS="agents"
		SETUP_STAGE_OPENCODE_PLUGINS="opencode_plugins"
		SETUP_STAGE_HOTFIX_CONFIG="hotfix_config"
		SETUP_STAGE_HOOKS="hooks"
		_setup_init_stage_timing_log() { return 0; }
		_setup_register_child_pid() { return 0; }
		is_feature_enabled() { return 1; }
		print_info() { return 0; }
		print_warning() {
			printf 'warning=%s\n' "$*"
			return 0
		}
		_time_step() {
			local stage_name="$1"
			printf '%s\n' "$stage_name" >>"$trace_file"
			if [[ "$stage_name" == "install_aidevops_cli" ]]; then
				return 23
			fi
			return 0
		}
		_setup_run_non_interactive
	) >"$output_file" 2>&1
	status=$?

	local output=""
	output=$(<"$output_file")
	if [[ "$status" -eq 0 ]] &&
		grep -qx "install_aidevops_cli" "$trace_file" &&
		grep -qx "update_opencode_config" "$trace_file" &&
		[[ "$output" == *"continuing configuration reconciliation"* ]]; then
		print_result "non-interactive setup continues config reconciliation after CLI failure" 0
		rm -rf "$tmp_home"
		return 0
	fi

	print_result "non-interactive setup continues config reconciliation after CLI failure" 1 \
		"status=${status}, output=${output}"
	rm -rf "$tmp_home"
	return 0
}

main() {
	test_time_step_logs_running_before_command
	test_noninteractive_cli_failure_continues_config_reconciliation

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
