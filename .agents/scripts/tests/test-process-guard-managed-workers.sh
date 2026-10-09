#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/process-guard-helper.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/process-guard-managed.XXXXXX")"
export HOME="${TEST_ROOT}/home"
export AIDEVOPS_PROCESS_GUARD_PROC_ROOT="${TEST_ROOT}/proc"
mkdir -p "$HOME" "$AIDEVOPS_PROCESS_GUARD_PROC_ROOT"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# shellcheck source=../process-guard-helper.sh
source "$HELPER"

TESTS_RUN=0
TESTS_FAILED=0
MOCK_PROCESS_LINE=""
MOCK_PROCESS_AGE=0
MOCK_KILL_LOG="${TEST_ROOT}/kill.log"
MOCK_PLATFORM="Linux"
MOCK_EXECUTABLE_PATH=""
MOCK_COMMAND=""
MOCK_LAUNCHD_PID=""
# Space-separated "pid:ppid" pairs for the lineage walk.
MOCK_PARENTS=""
DESKTOP_CLI="/Users/test/Library/Application Support/ai.opencode.desktop/cli/2.0.24/opencode-cli"

_process_guard_platform() {
	printf '%s' "$MOCK_PLATFORM"
	return 0
}

_get_process_executable_path() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_EXECUTABLE_PATH"
	return 0
}

_get_process_command() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_COMMAND"
	return 0
}

_launchd_job_pid() {
	local label="$1"
	: "$label"
	printf '%s' "$MOCK_LAUNCHD_PID"
	return 0
}

_get_process_parent_pid() {
	local pid="$1"
	local pair=""
	for pair in $MOCK_PARENTS; do
		if [[ "${pair%%:*}" == "$pid" ]]; then
			printf '%s' "${pair#*:}"
			return 0
		fi
	done
	printf '%s' "1"
	return 0
}

reset_macos_mocks() {
	MOCK_PLATFORM="Darwin"
	MOCK_EXECUTABLE_PATH=""
	MOCK_COMMAND=""
	MOCK_LAUNCHD_PID=""
	MOCK_PARENTS=""
	return 0
}

_list_ai_processes() {
	printf '%s\n' "$MOCK_PROCESS_LINE"
	return 0
}

_get_process_age() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_PROCESS_AGE"
	return 0
}

_get_process_cwd() {
	local pid="$1"
	: "$pid"
	printf '%s' "${TEST_ROOT}/worktree"
	return 0
}

kill() {
	printf '%s\n' "$*" >>"$MOCK_KILL_LOG"
	return 0
}

sleep() {
	local seconds="$1"
	: "$seconds"
	return 0
}

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n     expected=%s actual=%s\n' "$test_name" "$expected" "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

write_cgroup() {
	local pid="$1"
	local cgroup_path="$2"
	mkdir -p "${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}"
	printf '0::%s\n' "$cgroup_path" >"${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}/cgroup"
	return 0
}

write_hybrid_cgroup() {
	local pid="$1"
	local cgroup_path="$2"
	mkdir -p "${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}"
	printf '13:pids:/user.slice/user-1000.slice/user@1000.service\n1:name=systemd:%s\n0::%s\n' \
		"$cgroup_path" "$cgroup_path" >"${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}/cgroup"
	return 0
}

test_managed_worker_runtime_is_delegated() {
	write_cgroup 4101 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-17.service'
	local actual
	actual=$(_classify_runtime_limit 4101 2064 600)
	assert_eq "managed worker older than generic limit is delegated" "MANAGED" "$actual"
	return 0
}

test_managed_worker_descendant_is_delegated() {
	write_cgroup 4102 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-17.service/runtime.scope'
	local actual
	actual=$(_classify_runtime_limit 4102 966 600)
	assert_eq "managed worker descendant inherits service protection" "MANAGED" "$actual"
	return 0
}

test_managed_observer_runtime_is_delegated() {
	write_cgroup 4103 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-observer-27693-4001-18.service'
	local actual
	actual=$(_classify_runtime_limit 4103 1200 600)
	assert_eq "managed worker observer is delegated" "MANAGED" "$actual"
	return 0
}

test_opencode_web_service_runtime_is_delegated() {
	write_hybrid_cgroup 4104 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web.service'
	local actual
	actual=$(_classify_runtime_limit 4104 7210 7200)
	assert_eq "OpenCode web server older than generic limit is delegated" "MANAGED" "$actual"
	return 0
}

test_opencode_web_service_descendant_is_delegated() {
	write_cgroup 4105 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web.service/browser.scope'
	local actual
	actual=$(_classify_runtime_limit 4105 9000 7200)
	assert_eq "OpenCode web-service descendant inherits protection" "MANAGED" "$actual"
	return 0
}

test_opencode_web_template_service_is_delegated() {
	write_cgroup 4106 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web@4096.service'
	local actual
	actual=$(_classify_runtime_limit 4106 9000 7200)
	assert_eq "OpenCode web template service inherits protection" "MANAGED" "$actual"
	return 0
}

test_opencode_web_watchdog_service_is_delegated() {
	write_hybrid_cgroup 4107 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web-watchdog.service'
	local actual
	actual=$(_classify_runtime_limit 4107 7210 7200)
	assert_eq "OpenCode web watchdog older than generic limit is delegated" "MANAGED" "$actual"
	return 0
}

test_unmanaged_lookalike_remains_over_limit() {
	write_cgroup 4201 '/user.slice/user-1000.slice/session-2.scope'
	local actual
	actual=$(_classify_runtime_limit 4201 966 600)
	assert_eq "unmanaged process remains eligible" "OVER" "$actual"
	return 0
}

test_command_string_is_not_lineage_evidence() {
	write_cgroup 4202 '/user.slice/user-1000.slice/aidevops-worker-not-a-real-unit.scope'
	local actual
	actual=$(_classify_runtime_limit 4202 966 600)
	assert_eq "worker-like cgroup text without valid service identity is rejected" "OVER" "$actual"
	return 0
}

test_opencode_web_scope_lookalike_remains_over_limit() {
	write_cgroup 4203 '/user.slice/user-1000.slice/opencode-web.scope'
	local actual
	actual=$(_classify_runtime_limit 4203 7210 7200)
	assert_eq "OpenCode-like scope without service identity is rejected" "OVER" "$actual"
	return 0
}

test_unavailable_cgroup_keeps_existing_behavior() {
	local actual
	actual=$(_classify_runtime_limit 4301 966 600)
	assert_eq "missing cgroup evidence fails closed to generic guard" "OVER" "$actual"
	return 0
}

test_fresh_managed_worker_is_not_misreported() {
	write_cgroup 4401 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-19.service'
	local actual
	actual=$(_classify_runtime_limit 4401 300 600)
	assert_eq "fresh worker remains under limit" "OK" "$actual"
	return 0
}

test_kill_runaways_skips_managed_worker() {
	write_cgroup 4501 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-20.service'
	MOCK_PROCESS_LINE='4501 1 ? 1024 16:06 bash /usr/bin/bash worker-wrapper opencode run'
	MOCK_PROCESS_AGE=966
	CHILD_RUNTIME_LIMIT=600
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	assert_eq "kill path skips old managed worker" "No runaway processes found" "$output"
	assert_eq "managed worker receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	return 0
}

test_kill_runaways_skips_opencode_web_service() {
	write_hybrid_cgroup 4504 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web.service'
	MOCK_PROCESS_LINE='4504 1 ? 2860032 2:00:10 /home/test/.opencode/bin/opencode serve --port 4096'
	MOCK_PROCESS_AGE=7210
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=4194304
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	assert_eq "kill path skips long-running OpenCode web service" "No runaway processes found" "$output"
	assert_eq "OpenCode web service receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	return 0
}

test_kill_runaways_skips_opencode_web_watchdog() {
	write_hybrid_cgroup 4505 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web-watchdog.service'
	MOCK_PROCESS_LINE='4505 1 ? 3072 2:00:10 bash /home/test/.local/bin/opencode-web-watchdog.sh'
	MOCK_PROCESS_AGE=7210
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=4194304
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	assert_eq "kill path skips long-running OpenCode web watchdog" "No runaway processes found" "$output"
	assert_eq "OpenCode web watchdog receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	return 0
}

test_kill_runaways_keeps_unmanaged_cleanup() {
	write_cgroup 4502 '/user.slice/user-1000.slice/session-2.scope'
	MOCK_PROCESS_LINE='4502 1 ? 1024 16:06 bash /usr/bin/bash stale-wrapper opencode run'
	MOCK_PROCESS_AGE=966
	CHILD_RUNTIME_LIMIT=600
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	if [[ "$output" == *"Killing PID 4502"* && "$(<"$MOCK_KILL_LOG")" == *"4502"* ]]; then
		assert_eq "unmanaged orphan remains kill-eligible" "eligible" "eligible"
	else
		assert_eq "unmanaged orphan remains kill-eligible" "kill signal for 4502" "$output / $(<"$MOCK_KILL_LOG")"
	fi
	return 0
}

test_status_matches_kill_exemption() {
	write_cgroup 4503 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-21.service'
	MOCK_PROCESS_LINE='4503 1 ? 1024 16:06 bash /usr/bin/bash worker-wrapper opencode run'
	MOCK_PROCESS_AGE=966
	CHILD_RUNTIME_LIMIT=600
	local output
	output=$(cmd_status)
	if [[ "$output" == *'"violations":0'* ]]; then
		assert_eq "status excludes managed runtime from violations" "0" "0"
	else
		assert_eq "status excludes managed runtime from violations" '"violations":0' "$output"
	fi
	return 0
}

test_linux_opencode_server_unit_is_delegated() {
	MOCK_PLATFORM="Linux"
	write_cgroup 4601 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-opencode-server.service'
	local actual
	actual=$(_classify_runtime_limit 4601 7210 7200)
	assert_eq "Linux aidevops OpenCode server unit is delegated" "MANAGED" "$actual"
	return 0
}

test_macos_opencode_server_lineage_is_delegated() {
	reset_macos_mocks
	MOCK_LAUNCHD_PID=4700
	MOCK_PARENTS="4702:4701 4701:4700 4700:1"
	assert_eq "macOS launchd OpenCode server job is delegated" "MANAGED" "$(_classify_runtime_limit 4700 7210 7200)"
	assert_eq "macOS launchd OpenCode server descendant is delegated" "MANAGED" "$(_classify_runtime_limit 4702 7210 7200)"
	assert_eq "macOS launchd owner label" "opencode-server-service" "$(_runtime_management_owner 4702)"
	return 0
}

test_macos_unrelated_or_missing_server_job_stays_over() {
	reset_macos_mocks
	MOCK_LAUNCHD_PID=4700
	MOCK_PARENTS="4710:1"
	assert_eq "macOS process outside server lineage stays eligible" "OVER" "$(_classify_runtime_limit 4710 7210 7200)"
	MOCK_LAUNCHD_PID=""
	MOCK_PARENTS="4702:4701 4701:4700"
	assert_eq "macOS lineage without running server job stays eligible" "OVER" "$(_classify_runtime_limit 4702 7210 7200)"
	return 0
}

test_macos_desktop_bundle_processes_are_delegated() {
	reset_macos_mocks
	local bundle="/Applications/OpenCode.app/Contents"
	MOCK_EXECUTABLE_PATH="${bundle}/Frameworks/OpenCode Helper (GPU).app/Contents/MacOS/OpenCode Helper (GPU)"
	assert_eq "desktop Electron helper is delegated" "MANAGED" "$(_classify_runtime_limit 4801 7231 7200)"
	MOCK_EXECUTABLE_PATH="${bundle}/Frameworks/Squirrel.framework/Resources/ShipIt"
	assert_eq "desktop Squirrel ShipIt is delegated" "MANAGED" "$(_classify_runtime_limit 4802 7231 7200)"
	assert_eq "desktop owner label" "opencode-desktop-app" "$(_runtime_management_owner 4802)"
	return 0
}

test_macos_desktop_cli_only_serve_is_delegated() {
	reset_macos_mocks
	MOCK_EXECUTABLE_PATH="$DESKTOP_CLI"
	MOCK_COMMAND="${DESKTOP_CLI} serve --service"
	assert_eq "desktop bundled server is delegated" "MANAGED" "$(_classify_runtime_limit 4803 7231 7200)"
	MOCK_COMMAND="${DESKTOP_CLI} run --model x serve"
	assert_eq "desktop bundled CLI run stays eligible" "OVER" "$(_classify_runtime_limit 4804 7231 7200)"
	MOCK_COMMAND="opencode-cli serve --service"
	assert_eq "relative argv0 bundled server is delegated" "MANAGED" "$(_classify_runtime_limit 4805 7231 7200)"
	MOCK_COMMAND="renamed-argv serve --service"
	assert_eq "unparseable argv fails closed" "OVER" "$(_classify_runtime_limit 4808 7231 7200)"
	return 0
}

test_desktop_argv_text_is_not_ownership_evidence() {
	reset_macos_mocks
	MOCK_EXECUTABLE_PATH="/bin/sleep"
	MOCK_COMMAND="/fake/OpenCode.app/Contents/MacOS/OpenCode --user-data-dir=ai.opencode.desktop"
	assert_eq "spoofed desktop argv stays eligible" "OVER" "$(_classify_runtime_limit 4806 7231 7200)"
	MOCK_PLATFORM="Linux"
	MOCK_EXECUTABLE_PATH="/opt/OpenCode.app/Contents/MacOS/OpenCode"
	assert_eq "desktop path classification is macOS-only" "OVER" "$(_classify_runtime_limit 4807 7231 7200)"
	return 0
}

test_kill_runaways_desktop_runtime_skipped_rss_enforced() {
	reset_macos_mocks
	MOCK_EXECUTABLE_PATH="/Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper (Renderer).app/Contents/MacOS/OpenCode Helper (Renderer)"
	MOCK_PROCESS_LINE='4901 4900 ?? 693248 02:00:31 /Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper (Renderer).app/Contents/MacOS/OpenCode Helper (Renderer) --user-data-dir=/Users/test/Library/Application Support/ai.opencode.desktop'
	MOCK_PROCESS_AGE=7231
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=8388608
	: >"$MOCK_KILL_LOG"
	assert_eq "kill path skips old desktop helper" "No runaway processes found" "$(cmd_kill_runaways)"
	assert_eq "desktop helper receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	CHILD_RSS_LIMIT_KB=524288
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	if [[ "$output" == *"Killing PID 4901"* && "$(<"$MOCK_KILL_LOG")" == *"4901"* ]]; then
		assert_eq "desktop helper over RSS limit remains kill-eligible" "eligible" "eligible"
	else
		assert_eq "desktop helper over RSS limit remains kill-eligible" "kill signal for 4901" "$output / $(<"$MOCK_KILL_LOG")"
	fi
	MOCK_PLATFORM="Linux"
	return 0
}

test_command_basename_handles_spaced_paths() {
	local spaced_dir="${TEST_ROOT}/Library/Application Support/ai.opencode.desktop/cli/2.0.24"
	mkdir -p "$spaced_dir"
	: >"${spaced_dir}/opencode-cli"
	assert_eq "basename keeps spaced executable path" "opencode-cli" \
		"$(_command_basename "${spaced_dir}/opencode-cli serve --service")"
	assert_eq "basename of plain command" "shellcheck" "$(_command_basename "/usr/bin/shellcheck --shell=bash x.sh")"
	assert_eq "basename of relative command" "bash" "$(_command_basename "bash /usr/bin/bash worker-wrapper")"
	return 0
}

main() {
	test_managed_worker_runtime_is_delegated
	test_managed_worker_descendant_is_delegated
	test_managed_observer_runtime_is_delegated
	test_opencode_web_service_runtime_is_delegated
	test_opencode_web_service_descendant_is_delegated
	test_opencode_web_template_service_is_delegated
	test_opencode_web_watchdog_service_is_delegated
	test_unmanaged_lookalike_remains_over_limit
	test_command_string_is_not_lineage_evidence
	test_opencode_web_scope_lookalike_remains_over_limit
	test_unavailable_cgroup_keeps_existing_behavior
	test_fresh_managed_worker_is_not_misreported
	test_kill_runaways_skips_managed_worker
	test_kill_runaways_skips_opencode_web_service
	test_kill_runaways_skips_opencode_web_watchdog
	test_kill_runaways_keeps_unmanaged_cleanup
	test_status_matches_kill_exemption
	test_linux_opencode_server_unit_is_delegated
	test_macos_opencode_server_lineage_is_delegated
	test_macos_unrelated_or_missing_server_job_stays_over
	test_macos_desktop_bundle_processes_are_delegated
	test_macos_desktop_cli_only_serve_is_delegated
	test_desktop_argv_text_is_not_ownership_evidence
	test_kill_runaways_desktop_runtime_skipped_rss_enforced
	test_command_basename_handles_spaced_paths

	printf '\n%s/%s tests passed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
