#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SCHEDULERS_PLATFORM_SH="$REPO_ROOT/.agents/scripts/setup/modules/schedulers-platform.sh"
SCHEDULERS_SH="$REPO_ROOT/.agents/scripts/setup/modules/schedulers.sh"
PULSE_ROUTINES_SH="$REPO_ROOT/.agents/scripts/pulse-routines.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -z "$message" ]] || printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

load_scheduler_helpers() {
	print_info() { return 0; }
	print_warning() { return 0; }
	print_error() { return 0; }
	_resolve_log_dir() { printf '%s\n' "$TEST_DIR/logs"; return 0; }
	_install_scheduler_linux() { return 0; }
	_uninstall_scheduler() { return 0; }
	_resolve_modern_bash() { printf '%s\n' "/bin/bash"; return 0; }
	_xml_escape() { local value="$1"; printf '%s' "$value"; return 0; }
	aidevops_launchd_sanitized_path() { printf '%s\n' "/usr/bin:/bin"; return 0; }
	_launchd_install_if_changed() { return 0; }
	_launchd_has_agent() { return 1; }
	# shellcheck source=/dev/null
	source "$SCHEDULERS_PLATFORM_SH"
	return 0
}

test_core_routine_logged_command_shape() {
	local command_text
	command_text=$(_core_routine_logged_command "r908" "'$TEST_DIR/profile-readme-helper.sh' update")
	if [[ "$command_text" != *"'$TEST_DIR/profile-readme-helper.sh' update"* ]]; then
		print_result "core routine logged command keeps original command" 1 "$command_text"
		return 0
	fi
	# shellcheck disable=SC2016 # the generated command must defer variable expansion to runtime.
	if [[ "$command_text" != *'duration=$(( ${end_epoch:-0} - ${start_epoch:-0} ))'* ]]; then
		print_result "core routine logged command uses robust duration arithmetic" 1 "$command_text"
		return 0
	fi
	# shellcheck disable=SC2016 # the generated command must defer variable expansion to runtime.
	if [[ "$command_text" != *'routine-log-helper.sh" update "r908" --status "$status" --duration "$duration"'* ]]; then
		print_result "core routine logged command records status and duration" 1 "$command_text"
		return 0
	fi
	# shellcheck disable=SC2016 # the generated command must defer variable expansion to runtime.
	if [[ "$command_text" != *'exit "$rc"'* ]]; then
		print_result "core routine logged command preserves script exit" 1 "$command_text"
		return 0
	fi
	print_result "core routine logged command records metrics and preserves exit" 0
	return 0
}

test_core_routine_shell_quote_escapes_single_quotes() {
	local quoted
	quoted=$(_core_routine_shell_quote "one'two")
	if [[ "$quoted" != "'one'\\''two'" ]]; then
		print_result "core routine shell quote escapes single quotes" 1 "$quoted"
		return 0
	fi
	print_result "core routine shell quote escapes single quotes" 0
	return 0
}

test_linux_core_scheduler_commands_are_logged() {
	local fake_home="$TEST_DIR/scheduler-home"
	mkdir -p "$fake_home/.aidevops/agents/scripts" "$fake_home/.aidevops/.agent-workspace/logs"
	local profile_script="$fake_home/.aidevops/agents/scripts/profile-readme-helper.sh"
	local screen_script="$fake_home/.aidevops/agents/scripts/screen-time-helper.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$profile_script"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$screen_script"
	chmod +x "$profile_script" "$screen_script"

	# shellcheck source=/dev/null
	source "$SCHEDULERS_SH"
	uname() { printf 'Linux\n'; return 0; }
	_SCHEDULER_CAPTURED_COMMAND=""
	_install_scheduler_linux() {
		local service_name="$1"
		local cron_tag="$2"
		local cron_schedule="$3"
		local exec_command="$4"
		local interval_sec="$5"
		local log_file="$6"
		local env_vars="$7"
		local success_message="$8"
		local failure_message="$9"
		local run_at_load="${10}"
		local low_priority="${11}"
		: "$service_name" "$cron_tag" "$cron_schedule" "$interval_sec" "$log_file" "$env_vars" "$success_message" "$failure_message" "$run_at_load" "$low_priority"
		_SCHEDULER_CAPTURED_COMMAND="$exec_command"
		return 0
	}

	local orig_home="$HOME"
	HOME="$fake_home"
	_install_profile_readme_scheduler "sh.aidevops.profile-readme-update" "aidevops-profile-readme-update" "$profile_script" "$fake_home/profile.log"
	local profile_command="$_SCHEDULER_CAPTURED_COMMAND"
	setup_screen_time_snapshot
	local screen_command="$_SCHEDULER_CAPTURED_COMMAND"
	HOME="$orig_home"
	unset -f uname _install_scheduler_linux

	# shellcheck disable=SC2016 # the generated command must defer variable expansion to runtime.
	if [[ "$profile_command" != *'update "r908" --status "$status" --duration "$duration"'* ]]; then
		print_result "profile scheduler command updates r908 metrics" 1 "$profile_command"
		return 0
	fi
	# shellcheck disable=SC2016 # the generated command must defer variable expansion to runtime.
	if [[ "$screen_command" != *'update "r909" --status "$status" --duration "$duration"'* ]]; then
		print_result "screen-time scheduler command updates r909 metrics" 1 "$screen_command"
		return 0
	fi
	print_result "linux core scheduler commands update routine metrics" 0
	return 0
}

test_pulse_routine_update_uses_flags_and_duration() {
	local fake_home="$TEST_DIR/home"
	local agents_dir="$fake_home/.aidevops/agents"
	mkdir -p "$agents_dir/scripts" "$TEST_DIR/bin"
	cat >"$agents_dir/scripts/sample.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
	chmod +x "$agents_dir/scripts/sample.sh"
	cat >"$TEST_DIR/bin/routine-log-helper.sh" <<'HELPER'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ROUTINE_LOG_CAPTURE"
exit 0
HELPER
	chmod +x "$TEST_DIR/bin/routine-log-helper.sh"

	HOME="$fake_home"
	ROUTINE_STATE_FILE="$TEST_DIR/state.json"
	LOGFILE="$TEST_DIR/pulse.log"
	ROUTINE_LOG_HELPER="$TEST_DIR/bin/routine-log-helper.sh"
	ROUTINE_LOG_CAPTURE="$TEST_DIR/routine-log.args"
	export ROUTINE_LOG_CAPTURE
	HEADLESS_RUNTIME_HELPER="$TEST_DIR/bin/headless-runtime-helper.sh"
	PULSE_DIR="$TEST_DIR"
	# shellcheck source=/dev/null
	source "$PULSE_ROUTINES_SH"

	_routine_execute "r777" "sample" "scripts/sample.sh" "" "$TEST_DIR"

	local args=""
	if [[ -f "$ROUTINE_LOG_CAPTURE" ]]; then
		args=$(<"$ROUTINE_LOG_CAPTURE")
	fi
	if [[ "$args" == update\ r777\ --status\ success\ --duration\ * ]]; then
		print_result "pulse routine update passes flags and duration" 0
	else
		print_result "pulse routine update passes flags and duration" 1 "$args"
	fi
	return 0
}

test_opencode_archive_scheduler_is_daily_and_low_priority() {
	local fake_home="$TEST_DIR/archive-home"
	mkdir -p "$fake_home/.aidevops/agents/scripts"
	local archive_script="$fake_home/.aidevops/agents/scripts/opencode-db-archive-async-helper.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$archive_script"
	chmod +x "$archive_script"

	local captured_service=""
	local captured_cron=""
	local captured_command=""
	local captured_interval=""
	local captured_log=""
	local captured_env=""
	local captured_run_at_load=""
	local captured_low_priority=""
	local captured_calendar=""
	_install_scheduler_linux() {
		local service_name="$1"
		local cron_tag="$2"
		local cron_schedule="$3"
		local exec_command="$4"
		local interval_sec="$5"
		local log_file="$6"
		local env_vars="$7"
		local success_message="$8"
		local failure_message="$9"
		local run_at_load="${10}"
		local low_priority="${11}"
		local on_calendar="${12:-}"
		: "$cron_tag" "$success_message" "$failure_message"
		captured_service="$service_name"
		captured_cron="$cron_schedule"
		captured_command="$exec_command"
		captured_interval="$interval_sec"
		captured_log="$log_file"
		captured_env="$env_vars"
		captured_run_at_load="$run_at_load"
		captured_low_priority="$low_priority"
		captured_calendar="$on_calendar"
		return 0
	}
	uname() { printf 'Linux\n'; return 0; }

	local orig_home="$HOME"
	HOME="$fake_home"
	setup_opencode_db_archive
	HOME="$orig_home"
	unset -f uname _install_scheduler_linux

	if [[ "$captured_service" != "aidevops-opencode-db-archive" ]]; then
		print_result "opencode archive scheduler uses dedicated service" 1 "$captured_service"
		return 0
	fi
	if [[ "$captured_cron" != "0 5 * * *" || "$captured_interval" != "86400" || "$captured_calendar" != "*-*-* 5:0:00" ]]; then
		print_result "opencode archive scheduler runs daily" 1 "cron=${captured_cron} interval=${captured_interval} calendar=${captured_calendar}"
		return 0
	fi
	if [[ "$captured_command" != "\"${archive_script}\"" || "$captured_log" != "$fake_home/.aidevops/logs/opencode-db-archive.log" ]]; then
		print_result "opencode archive scheduler invokes async helper" 1 "command=${captured_command} log=${captured_log}"
		return 0
	fi
	if [[ "$captured_env" == *"OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN"* || "$captured_env" != "OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC=60" ]]; then
		print_result "opencode archive scheduler leaves cadence to scheduler" 1 "$captured_env"
		return 0
	fi
	if [[ "$captured_run_at_load" != "false" || "$captured_low_priority" != "true" ]]; then
		print_result "opencode archive scheduler is low priority and not run-at-load" 1 "run_at_load=${captured_run_at_load} low_priority=${captured_low_priority}"
		return 0
	fi

	print_result "opencode archive scheduler is daily and low priority" 0
	return 0
}

test_pulse_preflight_does_not_launch_opencode_archive() {
	local preflight_lib="$REPO_ROOT/.agents/scripts/pulse-dispatch-preflight-lib.sh"
	local body
	body=$(<"$preflight_lib")
	# shellcheck disable=SC2016 # Match the literal pre-GH#25136 launch snippet.
	if [[ "$body" == *'nohup "$_archive_async_helper"'* || "$body" == *'archive --max-duration-seconds 30'* ]]; then
		print_result "pulse preflight does not launch opencode archive" 1 "archive launch still present"
		return 0
	fi
	print_result "pulse preflight does not launch opencode archive" 0
	return 0
}

main() {
	setup
	load_scheduler_helpers
	test_core_routine_logged_command_shape
	test_core_routine_shell_quote_escapes_single_quotes
	test_linux_core_scheduler_commands_are_logged
	test_pulse_routine_update_uses_flags_and_duration
	test_opencode_archive_scheduler_is_daily_and_low_priority
	test_pulse_preflight_does_not_launch_opencode_archive
	printf '\n%d/%d tests passed\n' "$TESTS_PASSED" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
