#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SETUP_SCRIPT="${REPO_ROOT}/setup.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR=""

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

cleanup() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

load_setup_restart_helper() {
	local helper_definition=""
	helper_definition="$(awk '
		/^_setup_restart_pulse_if_running\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$SETUP_SCRIPT")"

	if [[ -z "$helper_definition" ]]; then
		printf 'failed to load helper from %s\n' "$SETUP_SCRIPT" >&2
		return 1
	fi

	eval "$helper_definition"
	return 0
}

write_pulse_helper_stub() {
	local helper_path="$1"
	local log_path="$2"
	mkdir -p "$(dirname "$helper_path")"
	cat >"$helper_path" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"${log_path}"
exit 0
STUB
	chmod +x "$helper_path"
	return 0
}

run_restart_helper_with_stub() {
	local skip_value="$1"
	local output_dir="$2"
	local log_path="${output_dir}/pulse-helper.log"
	local helper_path="${output_dir}/.aidevops/agents/scripts/pulse-lifecycle-helper.sh"

	write_pulse_helper_stub "$helper_path" "$log_path"

	(
		HOME="$output_dir"
		AIDEVOPS_SKIP_PULSE_RESTART="$skip_value"
		print_warning() { printf 'warning: %s\n' "$*"; return 0; }
		load_setup_restart_helper
		_setup_restart_pulse_if_running
	)

	if [[ -f "$log_path" ]]; then
		tr '\n' ' ' <"$log_path"
	fi
	return 0
}

test_release_path_starts_stopped_pulse() {
	local output=""
	output="$(run_restart_helper_with_stub "0" "${TEST_DIR}/start-stopped")"

	if [[ "$output" == *"restart-if-running start "* ]]; then
		print_result "release deploy restarts if running then starts if stopped" 0
		return 0
	fi

	print_result "release deploy restarts if running then starts if stopped" 1 "helper calls=${output}"
	return 0
}

test_skip_flag_suppresses_restart_and_start() {
	local output=""
	output="$(run_restart_helper_with_stub "1" "${TEST_DIR}/skip-flag")"

	if [[ -z "$output" ]]; then
		print_result "skip flag suppresses release pulse restart and start" 0
		return 0
	fi

	print_result "skip flag suppresses release pulse restart and start" 1 "helper calls=${output}"
	return 0
}

main() {
	TEST_DIR="$(mktemp -d)"
	trap cleanup EXIT

	test_release_path_starts_stopped_pulse
	test_skip_flag_suppresses_restart_and_start

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
